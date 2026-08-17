import Foundation

/// Reliable file-based logging (os_log info level isn't consistently visible via `log show`
/// for ad-hoc dev builds). Owner-only file under the app's Application Support — NOT world-readable
/// /tmp — since transcript/LLM diagnostics can be sensitive.
enum DebugLog {
    static let url: URL = {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Parley", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("parley.log")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        return file
    }()
    private static let queue = DispatchQueue(label: "com.parley.debuglog")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Roll over at 8 MB, keeping one previous file. Unbounded growth is not a tidiness issue — it made
    /// a real incident hard to read, because the interesting twenty lines sat inside 35 MB of VAD
    /// telemetry. One generation back is enough to cover "it broke a moment ago".
    private static let maxBytes = 8 * 1_048_576
    private static var written = 0

    /// Per-frame telemetry (VAD, level meters) — off unless someone is actually chasing a capture
    /// bug. It was the overwhelming majority of the file and is worthless after the fact.
    static var verboseCapture = UserDefaults.standard.bool(forKey: "debugVerboseCapture")

    static func trace(_ message: @autoclosure () -> String) {
        guard verboseCapture else { return }
        log(message())
    }

    static func log(_ message: String) {
        let stamp = formatter.string(from: Date())
        let line = "\(stamp) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            rotateIfNeeded(adding: data.count)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                written += data.count
            } else {
                try? data.write(to: url)
                written = data.count
            }
        }
        #if DEBUG
        print("[parley] \(message)")
        #endif
    }

    /// Called on `queue`, so the size check and the swap can't interleave with a write.
    private static func rotateIfNeeded(adding bytes: Int) {
        if written == 0 {
            written = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int).flatMap { $0 } ?? 0
        }
        guard written + bytes > maxBytes else { return }
        let previous = url.deletingLastPathComponent().appendingPathComponent("parley.previous.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        written = 0
    }
}
