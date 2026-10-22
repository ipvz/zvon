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
    }
}
