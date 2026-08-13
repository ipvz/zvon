import AVFoundation
import Foundation

/// Writes the meeting to a single stereo track alongside the transcript, so a line can be played
/// back at the moment it was said. Left channel = you, right = the other party.
///
/// One file rather than two: a single player means the two sides can never drift apart at playback,
/// and the channel split still keeps the voices separable.
///
/// The catch is that the two capture streams are independent — separate clocks, separate start
/// moments, either one free to stall — while a stereo frame needs both channels for the SAME
/// instant. So nothing is written as it arrives. Each side accumulates, and a flusher emits frames
/// on a wall-clock grid running `writeLag` behind now: whoever is short is padded with silence,
/// whoever ran ahead is trimmed. That keeps file time equal to meeting time, which is the whole
/// point — `TranscriptLine.startSec` has to land on the right words an hour in, not just at the start.
final class MeetingAudioRecorder: @unchecked Sendable {
    /// Both capture sources already deliver 16 kHz mono, so there is no resampling anywhere in the
    /// path. Measured cost of the stereo AAC at these settings: ~22 MB per hour.
    static let sampleRate: Double = 16_000
    /// How far behind now the writer runs. Chunks arrive in bursts; without a lag the flusher would
    /// pad silence over audio that is about to show up a few tens of milliseconds later.
    private static let writeLag: TimeInterval = 0.6
    /// A stream that has run ahead by more than this is trimmed rather than allowed to lag forever.
    private static let maxBacklog = Int(sampleRate * 3)

    private let lock = NSLock()
    private let startedAt: Date
    private let sessionId: UUID
    private var pending: [Speaker: [Float]] = [.me: [], .them: []]
    private var writtenFrames: AVAudioFramePosition = 0
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var timer: DispatchSourceTimer?
    private var closed = false
    private var sawAudio = false

    init(sessionId: UUID, startedAt: Date) {
        self.sessionId = sessionId
        self.startedAt = startedAt
        try? FileManager.default.createDirectory(at: Self.recordingsDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.parley.audiorecorder"))
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.flush(final: false) }
        timer = t
        t.resume()
    }

    // MARK: - Locations

    static var recordingsDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Parley/Recordings", isDirectory: true)
    }

    /// Derived from the session id, so nothing has to be migrated into the database — the file
    /// existing IS the "this meeting has audio" flag.
    static func url(sessionId: UUID) -> URL {
        recordingsDirectory.appendingPathComponent("\(sessionId.uuidString).m4a")
    }

    static func hasAudio(sessionId: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(sessionId: sessionId).path)
    }

    static func deleteAudio(sessionId: UUID) {
        try? FileManager.default.removeItem(at: url(sessionId: sessionId))
    }

    // MARK: - Capture

    /// Feed one chunk of 16 kHz mono samples. Safe to call from an audio thread.
    func append(_ samples: [Float], from speaker: Speaker) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        pending[speaker, default: []].append(contentsOf: samples)
        sawAudio = true
    }

    /// Flush and close. Returns the file if any audio was captured.
    @discardableResult
    func finish() -> URL? {
        lock.lock()
        let hadAudio = sawAudio
        lock.unlock()

        timer?.cancel(); timer = nil
        flush(final: true)

        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return nil }
        closed = true
        let frames = writtenFrames
        file = nil                                    // closing the handle finalises the container
        guard hadAudio, frames > 0 else {
            Self.deleteAudio(sessionId: sessionId)
            return nil
        }
        DebugLog.log("audio: wrote \(Int(Double(frames) / Self.sampleRate))s stereo for \(sessionId.uuidString)")
        return Self.url(sessionId: sessionId)
    }

    /// Nothing worth keeping (empty or aborted session) — drop the file.
    func discard() {
        _ = finish()
        Self.deleteAudio(sessionId: sessionId)
    }

    // MARK: - Writing

    private func flush(final: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }

        let elapsed = Date().timeIntervalSince(startedAt) - (final ? 0 : Self.writeLag)
        let target = AVAudioFramePosition(max(0, elapsed) * Self.sampleRate)
        var needed = Int(target - writtenFrames)
        if final {
            // On the last pass, never cut audio that is still queued.
            needed = max(needed, pending.values.map(\.count).max() ?? 0)
        }
        guard needed > 0 else { return }

        // A stream that ran ahead is trimmed from the FRONT: dropping the oldest surplus keeps the
        // channel aligned to now, where keeping it would push that side permanently late.
        for speaker in Speaker.allCases {
            let surplus = (pending[speaker]?.count ?? 0) - needed - Self.maxBacklog
            if surplus > 0 {
                pending[speaker]?.removeFirst(surplus)
                DebugLog.log("audio: trimmed \(surplus) backlog frames on \(speaker.rawValue)")
            }
        }

        let left = take(.me, needed)
        let right = take(.them, needed)

        do {
            let (f, fmt) = try ensureFile()
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(needed)),
                  let ch = buf.floatChannelData else { return }
            left.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress!, count: needed) }
            right.withUnsafeBufferPointer { ch[1].update(from: $0.baseAddress!, count: needed) }
            buf.frameLength = AVAudioFrameCount(needed)
            try f.write(from: buf)
            writtenFrames += AVAudioFramePosition(needed)
        } catch {
            DebugLog.log("audio: write failed — \(error.localizedDescription)")
        }
    }

    /// Exactly `count` samples for one side, zero-padded when that side has nothing to say.
    private func take(_ speaker: Speaker, _ count: Int) -> [Float] {
        var out = pending[speaker] ?? []
        if out.count >= count {
            pending[speaker] = Array(out[count...])
            return Array(out[..<count])
        }
        pending[speaker] = []
        out.append(contentsOf: repeatElement(0, count: count - out.count))
        return out
    }

    private func ensureFile() throws -> (AVAudioFile, AVAudioFormat) {
        if let file, let format { return (file, format) }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                channels: 2, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 40_000,
        ]
        let url = Self.url(sessionId: sessionId)
        try? FileManager.default.removeItem(at: url)     // never append to a stale file
        let f = try AVAudioFile(forWriting: url, settings: settings,
                                commonFormat: .pcmFormatFloat32, interleaved: false)
        file = f; format = fmt
        return (f, fmt)
    }

    // MARK: - Retention

    /// Audio is by far the heaviest thing this app stores, and an archive nobody prunes grows
    /// without bound. `days <= 0` means keep everything.
    static func pruneOlderThan(days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: recordingsDirectory,
                                                      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                      options: [.skipsHiddenFiles]) else { return }
        var freed = 0
        for url in items {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let date = values?.contentModificationDate, date < cutoff else { continue }
            freed += values?.fileSize ?? 0
            try? fm.removeItem(at: url)
        }
        if freed > 0 { DebugLog.log("audio retention: freed \(freed / 1_048_576) MB") }
    }

    /// Total bytes on disk — surfaced in settings so the cost is visible rather than a surprise.
    static func diskUsage() -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: recordingsDirectory,
                                                      includingPropertiesForKeys: [.fileSizeKey],
                                                      options: [.skipsHiddenFiles]) else { return 0 }
        return items.reduce(0) { $0 + (((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0) }
    }
}
