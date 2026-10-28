import Foundation
import CryptoKit

struct LLMHTTPHeader: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var value: String
}

enum LLMHTTPHeaders {
    /// Extra headers supplement the client; authentication and HTTP framing keep one owner.
    private static let reserved: Set<String> = ["authorization", "proxy-authorization", "x-api-key", "content-type",
        "content-length", "host", "connection", "transfer-encoding", "trailer", "te", "upgrade", "accept-encoding", "anthropic-version"]
    static func validated(_ headers: [LLMHTTPHeader]) throws -> [LLMHTTPHeader] {
        guard headers.count <= 32 else { throw LLMError.invalidHeaders("Допустимо не более 32 заголовков.") }
        var seen = Set<String>()
        return try headers.map { header in
            var item = header
            item.name = header.name.trimmingCharacters(in: .whitespaces)
            let token = "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
            guard !item.name.isEmpty, item.name.utf8.count <= 128,
                  item.name.allSatisfy({ token.contains($0) }) else {
                throw LLMError.invalidHeaders("Имя заголовка должно содержать латинские буквы, цифры или дефис, без пробелов.")
            }
            let name = item.name.lowercased()
            guard !reserved.contains(name) else { throw LLMError.invalidHeaders("Заголовок \(item.name) задаётся приложением. Для авторизации используйте поле API-ключа.") }
            guard seen.insert(name).inserted else { throw LLMError.invalidHeaders("Заголовок \(item.name) указан дважды.") }
            guard header.value.utf8.count <= 8192,
                  header.value.unicodeScalars.allSatisfy({ ($0.value >= 32 && $0.value <= 126) || $0.value == 9 }) else {
                throw LLMError.invalidHeaders("Значение должно быть одной строкой ASCII, без переносов и управляющих символов.")
            }
            item.value = header.value.trimmingCharacters(in: .whitespaces)
            return item
        }
    }

    /// Preserve path/query case, normalize only URL components that are case-insensitive.
    static func account(provider: LLMProvider, endpoint: String) -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        var canonical = trimmed
        if var parts = URLComponents(string: trimmed) {
            parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
            if (parts.scheme == "http" && parts.port == 80) || (parts.scheme == "https" && parts.port == 443) { parts.port = nil }
            parts.fragment = nil
            if parts.path.hasSuffix("/") { parts.path.removeLast() }
            canonical = parts.string ?? trimmed
        }
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return "llm.headers.\(provider.rawValue).\(digest)"
    }

    static func load(provider: LLMProvider, endpoint: String) -> [LLMHTTPHeader] {
        guard let raw = Keychain.get(account: account(provider: provider, endpoint: endpoint)) else { return [] }
        return (try? JSONDecoder().decode([LLMHTTPHeader].self, from: Data(raw.utf8))) ?? []
    }
    static func save(_ headers: [LLMHTTPHeader], provider: LLMProvider, endpoint: String) throws {
        let validated = try validated(headers)
        let value = String(decoding: try JSONEncoder().encode(validated), as: UTF8.self)
        let account = account(provider: provider, endpoint: endpoint)
        Keychain.set(value, account: account)
        guard Keychain.get(account: account) == value else { throw LLMError.invalidHeaders("Не удалось сохранить заголовки в Keychain. Попробуйте ещё раз.") }
    }
}

/// A custom header may itself be a credential. Never forward it to another origin on redirect.
final class LLMRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let target = request.url,
              Self.sameOrigin(original, target) else { completionHandler(nil); return }
        completionHandler(request)
    }
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil) }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() && port(a) == port(b)
    }
}
