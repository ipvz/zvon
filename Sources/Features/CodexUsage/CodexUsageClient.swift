import Foundation
import Darwin

/// Only initialize/account/read/account/rateLimits/read. No agent turn, credential copying,
/// session history access, or undocumented HTTP endpoints. A short-lived child owns auth refresh.
protocol CodexUsageReading: Sendable {
    func read() async throws -> CodexUsageSnapshot
}

struct CodexUsageClient: CodexUsageReading {
    var executable: URL? = nil
    var timeout: TimeInterval = 20

    static func locateExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["/Applications/Codex.app/Contents/Resources/codex",
                     "/Applications/ChatGPT.app/Contents/Resources/codex",
                     "\(home)/Applications/Codex.app/Contents/Resources/codex",
                     "\(home)/Applications/ChatGPT.app/Contents/Resources/codex",
                     "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex"]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    func read() async throws -> CodexUsageSnapshot {
        let request = CodexUsageRequest()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) {
                guard let url = executable ?? Self.locateExecutable() else { throw CodexUsageError.notInstalled }
                return try request.run(executable: url, timeout: timeout)
            }.value
        } onCancel: { request.cancel() }
    }
}

/// All I/O stays on the utility worker. poll bounds reads, output is capped, and cancellation is
/// lock-protected. EOF -> TERM -> KILL cleanup is bounded even for an unresponsive CLI version.
private final class CodexUsageRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }

    func run(executable: URL, timeout: TimeInterval) throws -> CodexUsageSnapshot {
        try checkCancellation()
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        // No project-local configuration or shell startup scripts are executed.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice // Never log responses, tokens, or account identity.
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                let deadline = ProcessInfo.processInfo.systemUptime + 0.25
                while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { process.terminate() }
                let stop = ProcessInfo.processInfo.systemUptime + 0.5
                while process.isRunning && ProcessInfo.processInfo.systemUptime < stop { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            if process.processIdentifier > 0 { process.waitUntilExit() }
            try? output.fileHandleForReading.close()
        }
        do { try process.run() } catch { throw CodexUsageError.notInstalled }
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "zvon_usage", "title": "ZVON", "version": "0.1.0"]]])
        var buffer = Data(), total = 0
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var expectedID = 1
        while ProcessInfo.processInfo.systemUptime < deadline {
            try checkCancellation()
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw CodexUsageError.invalidResponse }
                guard (object["id"] as? Int) == expectedID else { continue }
                if object["error"] != nil { throw CodexUsageError.unavailable }
                guard let result = object["result"] as? [String: Any] else { throw CodexUsageError.invalidResponse }
                switch expectedID {
                case 1:
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
                    expectedID = 2
                case 2:
                    guard let account = result["account"] as? [String: Any] else { throw CodexUsageError.signedOut }
                    guard account["type"] as? String == "chatgpt" else { throw CodexUsageError.unsupportedAccount }
                    try send(["id": 3, "method": "account/rateLimits/read"])
                    expectedID = 3
                default:
                    guard let response = try? JSONDecoder().decode(CodexUsageResponse.self, from: JSONSerialization.data(withJSONObject: result)) else { throw CodexUsageError.invalidResponse }
                    guard let bucket = response.codex else { throw CodexUsageError.invalidResponse }
                    return CodexUsageSnapshot(bucket: bucket, fetchedAt: Date())
                }
                continue
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let status = poll(&descriptor, 1, 100)
            if status < 0 { if errno == EINTR { continue }; throw CodexUsageError.unavailable }
            if status == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw CodexUsageError.unavailable }
            total += count
            guard total <= 1_048_576 else { throw CodexUsageError.invalidResponse }
            buffer.append(contentsOf: bytes.prefix(count))
        }
        throw CodexUsageError.timeout
    }
}
