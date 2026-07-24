import Foundation

/// A human-readable failure from the LLM endpoint — surfaced in the UI, never swallowed.
enum LLMError: LocalizedError {
    case badURL
    case http(Int, String?)
    case network(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Неверный адрес эндпоинта. Проверьте поле «Эндпоинт» в настройках."
        case .http(let code, let body):
            switch code {
            case 401, 403: return "Доступ отклонён (\(code)). Проверьте API-ключ."
            case 404:      return "Не найдено (404). Проверьте адрес и название модели."
            case 400:      return "Запрос отклонён (400). Модель может не поддерживать JSON-режим. \(Self.snippet(body))"
            case 500...599: return "Ошибка сервера (\(code)). Эндпоинт недоступен или перегружен."
            default:       return "Сервер вернул \(code). \(Self.snippet(body))"
            }
        case .network(let m):
            return "Нет связи с эндпоинтом: \(m)"
        case .emptyResponse:
            return "Пустой или нечитаемый ответ модели."
        }
    }

    private static func snippet(_ body: String?) -> String {
        guard let b = body?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty else { return "" }
        return String(b.prefix(160))
    }
}

/// Thin OpenAI-compatible chat client (default: the user's self-hosted Qwen). One place that
/// builds the request, checks the HTTP status, and turns failures into `LLMError` messages.
actor LLMClient {
    private let endpoint: String
    private let model: String
    private let apiKey: String?
    private let style: LLMAPIStyle

    init(endpoint: String, model: String, apiKey: String?, style: LLMAPIStyle = .openai) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.style = style
    }

    private func url(_ path: String) -> URL? {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        return URL(string: base + path)
    }
    /// The secret only goes on the wire over https or to loopback (local Ollama) — never cleartext remote.
    private func secure(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return url.scheme?.lowercased() == "https" || host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// One chat turn → the assistant's message content. Throws a typed `LLMError` on any failure.
    func chat(system: String?, user: String, json: Bool, maxTokens: Int, temperature: Double = 0.2) async throws -> String {
        switch style {
        case .openai:    return try await chatOpenAI(system: system, user: user, json: json, maxTokens: maxTokens, temperature: temperature)
        case .anthropic: return try await chatAnthropic(system: system, user: user, json: json, maxTokens: maxTokens, temperature: temperature)
        }
    }

    private func chatOpenAI(system: String?, user: String, json: Bool, maxTokens: Int, temperature: Double) async throws -> String {
        guard let url = url("/chat/completions") else { throw LLMError.badURL }

        var messages: [[String: Any]] = []
        if let system { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": user])

        var body: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "messages": messages,
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { throw LLMError.badURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty, secure(url) { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = payload
        req.timeoutInterval = 45

        let (data, http) = try await send(req)
        guard http.statusCode == 200 else { throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8)) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw LLMError.emptyResponse
        }
        return content
    }

    /// Anthropic Messages API — different shape: system is top-level, key is `x-api-key`, no
    /// `response_format` (JSON is coaxed via the system prompt), reply is `content[].text`.
    private func chatAnthropic(system: String?, user: String, json: Bool, maxTokens: Int, temperature: Double) async throws -> String {
        guard let url = url("/messages") else { throw LLMError.badURL }
        var sys = system
        if json { sys = [(sys ?? ""), "Ответь ТОЛЬКО валидным JSON-объектом, без markdown и пояснений."].joined(separator: "\n") }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "messages": [["role": "user", "content": user]],
        ]
        if let sys, !sys.isEmpty { body["system"] = sys }
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { throw LLMError.badURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let apiKey, !apiKey.isEmpty, secure(url) { req.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        req.httpBody = payload
        req.timeoutInterval = 45

        let (data, http) = try await send(req)
        guard http.statusCode == 200 else { throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8)) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else { throw LLMError.emptyResponse }
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw LLMError.emptyResponse }
        return text
    }

    /// Retry transient failures (network error, timeout, 5xx) up to 3 attempts with backoff. 4xx and
    /// success return immediately (no point retrying a bad request / auth error).
    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error = LLMError.emptyResponse
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000) }
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw LLMError.emptyResponse }
                if (500...599).contains(http.statusCode), attempt < 2 {
                    lastError = LLMError.http(http.statusCode, String(data: data, encoding: .utf8)); continue
                }
                return (data, http)
            } catch {
                lastError = LLMError.network(error.localizedDescription)
            }
        }
        throw lastError
    }

    /// A tiny round-trip used by Settings → «Проверить соединение».
    func ping() async throws {
        _ = try await chat(system: "Сервис проверки связи.", user: "Ответь одним словом: ok",
                           json: false, maxTokens: 5)
    }
}
