import Foundation

final class RequestLog: @unchecked Sendable {
    let lock = NSLock()
    private var requests: [URLRequest] = []
    func append(_ request: URLRequest) { lock.lock(); requests.append(request); lock.unlock() }
    var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

final class MockLLMProtocol: URLProtocol, @unchecked Sendable {
    static let log = RequestLog()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.log.append(request)
        if request.url!.host == "cancel.test" {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        if request.url!.host == "retry.test", Self.log.all.filter({ $0.url?.host == "retry.test" }).count == 1 {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
        let data = Data(#"{"choices":[{"message":{"content":"ok"}}],"content":[{"text":"ok"}]}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct LLMClientTests {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockLLMProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for endpoint in ["http://203.0.113.1:31009/v1", "https://inference.test/v1", "http://localhost:11434/v1"] {
            for style in [LLMAPIStyle.openai, .anthropic] {
                let client = LLMClient(endpoint: endpoint, model: "test-model", apiKey: "test-only-key", style: style, session: session)
                try await client.ping()
                let request = MockLLMProtocol.log.all.last!
                let header = style == .openai ? "Authorization" : "x-api-key"
                let expected = style == .openai ? "Bearer test-only-key" : "test-only-key"
                precondition(request.value(forHTTPHeaderField: header) == expected, "configured key missing from request")
            }
        }
        print("PASS: configured auth reaches remote HTTP, HTTPS and localhost for both API styles")
        try await LLMClient(endpoint: "http://localhost:11434/v1", model: "test", apiKey: nil, session: session).ping()
        precondition(MockLLMProtocol.log.all.last!.value(forHTTPHeaderField: "Authorization") == nil)
        print("PASS: a keyless local endpoint remains keyless")
        let count = MockLLMProtocol.log.all.count
        do {
            try await LLMClient(endpoint: "http://cancel.test/v1", model: "test", apiKey: nil, session: session).ping()
            preconditionFailure("expected cancellation")
        } catch is CancellationError {}
        precondition(MockLLMProtocol.log.all.count == count + 1, "cancelled request was retried")
        print("PASS: cancelled network requests are not retried")
        let headers = [LLMHTTPHeader(name: " X-Traffic-Class ", value: " interactive "), LLMHTTPHeader(name: "X-Workspace", value: "test")]
        for style in [LLMAPIStyle.openai, .anthropic] {
            let client = LLMClient(endpoint: "http://headers.test/v1", model: "test", apiKey: "test-only-key", style: style, additionalHeaders: headers, session: session)
            try await client.ping()
            _ = try await client.chat(system: nil, user: "test", json: false, maxTokens: 32)
            for request in MockLLMProtocol.log.all.suffix(2) {
                precondition(request.value(forHTTPHeaderField: "X-Traffic-Class") == "interactive")
                precondition(request.value(forHTTPHeaderField: "X-Workspace") == "test")
                precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                precondition(request.value(forHTTPHeaderField: style == .openai ? "Authorization" : "x-api-key") == (style == .openai ? "Bearer test-only-key" : "test-only-key"))
            }
        }
        try await LLMClient(endpoint: "http://retry.test/v1", model: "test", apiKey: nil, additionalHeaders: headers, session: session).ping()
        precondition(MockLLMProtocol.log.all.suffix(2).allSatisfy { $0.value(forHTTPHeaderField: "X-Traffic-Class") == "interactive" })
        try await LLMClient(endpoint: "http://plain.test/v1", model: "test", apiKey: nil, session: session).ping()
        precondition(MockLLMProtocol.log.all.last!.value(forHTTPHeaderField: "X-Traffic-Class") == nil)
        print("PASS: extra headers on ping/chat/retry for both API styles; auth preserved; no global header leakage")
        let invalid: [[LLMHTTPHeader]] = [
            [.init(name: "X-Test", value: "a\r\nAuthorization: stolen")],
            [.init(name: "Bad Name", value: "a")], [.init(name: "", value: "a")],
            [.init(name: "Authorization", value: "override")], [.init(name: "hOsT", value: "elsewhere.test")],
            [.init(name: "Content-Length", value: "1")], [.init(name: "Content-Type", value: "text/plain")],
            [.init(name: "X-Test", value: "a"), .init(name: "x-test", value: "b")]
        ]
        let beforeInvalid = MockLLMProtocol.log.all.count
        for invalidHeaders in invalid {
            do {
                try await LLMClient(endpoint: "http://invalid.test/v1", model: "test", apiKey: nil, additionalHeaders: invalidHeaders, session: session).ping()
                preconditionFailure("Invalid headers reached the network")
            } catch LLMError.invalidHeaders {}
        }
        precondition(MockLLMProtocol.log.all.count == beforeInvalid)
        let scope = LLMHTTPHeaders.account(provider: .custom, endpoint: "http://SERVER.test:80/v1/")
        precondition(scope == LLMHTTPHeaders.account(provider: .custom, endpoint: "http://server.test/v1"))
        precondition(scope != LLMHTTPHeaders.account(provider: .hf, endpoint: "http://server.test/v1"))
        precondition(scope != LLMHTTPHeaders.account(provider: .custom, endpoint: "http://other.test/v1"))
        precondition(scope != LLMHTTPHeaders.account(provider: .custom, endpoint: "http://server.test/v2"))
        let origin = URL(string: "https://server.test/v1")!
        precondition(LLMRedirectPolicy.sameOrigin(origin, URL(string: "https://SERVER.test:443/v2")!))
        for target in ["http://server.test/v1", "https://other.test/v1", "https://server.test:8080/v1"] {
            precondition(!LLMRedirectPolicy.sameOrigin(origin, URL(string: target)!))
        }
        print("PASS: header injection/duplicates/reserved fields rejected before I/O; endpoint/provider scopes and redirect origins isolated")
    }
}
