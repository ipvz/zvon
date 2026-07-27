import Foundation

enum TelegramError: LocalizedError {
    case notConfigured
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return L("Укажите токен бота и chat ID.", "Set the bot token and chat ID.")
        case .http(let c, let m): return "Telegram \(c): \(m)"
        }
    }
}

/// Deliver derived text (theses / minutes) to a Telegram chat via the Bot API. Pure HTTPS from a
/// non-sandboxed app — no OAuth, no server. Bot token lives in the Keychain; only text goes out.
enum Telegram {
    static let tokenAccount = "telegramBot"
    static let chatKey = "telegramChatId"

    static var token: String { Keychain.get(account: tokenAccount) ?? "" }
    static var chatId: String { UserDefaults.standard.string(forKey: chatKey) ?? "" }
    static var isConfigured: Bool { !token.isEmpty && !chatId.isEmpty }

    static func setToken(_ t: String) {
        let v = t.trimmingCharacters(in: .whitespaces)
        v.isEmpty ? Keychain.delete(account: tokenAccount) : Keychain.set(v, account: tokenAccount)
    }
    static func setChatId(_ id: String) {
        UserDefaults.standard.set(id.trimmingCharacters(in: .whitespaces), forKey: chatKey)
    }

    /// Send text to the configured chat, split into ≤4096-char HTML messages.
    static func send(_ text: String) async throws {
        guard isConfigured else { throw TelegramError.notConfigured }
        let chunks = split(escapeHTML(text))
        for (i, chunk) in chunks.enumerated() {
            try await post("sendMessage", ["chat_id": chatId, "text": chunk, "parse_mode": "HTML", "disable_web_page_preview": true])
            if i < chunks.count - 1 { try? await Task.sleep(nanoseconds: 1_100_000_000) }   // ~1 msg/sec per chat
        }
    }

    static func test() async throws {
        guard isConfigured else { throw TelegramError.notConfigured }
        try await post("sendMessage", ["chat_id": chatId, "text": "ZVON \u{2713}", "disable_notification": true])
    }

    // MARK: - internals

    private static func post(_ method: String, _ body: [String: Any]) async throws {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else { throw TelegramError.notConfigured }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 {   // rate-limited → wait retry_after and retry once
            let retry = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { ($0["parameters"] as? [String: Any])?["retry_after"] as? Int } ?? 2
            try await Task.sleep(nanoseconds: UInt64(min(retry, 30)) * 1_000_000_000)
            try await post(method, body); return
        }
        guard (200..<300).contains(code) else {
            let desc = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["description"] as? String
                ?? String(data: data, encoding: .utf8) ?? ""
            throw TelegramError.http(code, desc)
        }
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Split on paragraph boundaries under the limit (headroom below Telegram's 4096 for HTML entities).
    private static func split(_ text: String, limit: Int = 3800) -> [String] {
        if text.count <= limit { return [text] }
        var chunks: [String] = []; var cur = ""
        for para in text.components(separatedBy: "\n") {
            if cur.count + para.count + 1 > limit {
                if !cur.isEmpty { chunks.append(cur); cur = "" }
                if para.count > limit {
                    var rest = Substring(para)
                    while rest.count > limit { chunks.append(String(rest.prefix(limit))); rest = rest.dropFirst(limit) }
                    cur = String(rest); continue
                }
            }
            cur += (cur.isEmpty ? "" : "\n") + para
        }
        if !cur.isEmpty { chunks.append(cur) }
        return chunks
    }
}
