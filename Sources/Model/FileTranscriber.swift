import AVFoundation
import AppKit
import Foundation
import FluidAudio

/// Transcribe an audio or video file that was never recorded here — a call someone else captured,
/// a webinar, a voice memo. The result is stored as an ordinary record, so it inherits the search,
/// export, recipes and spaces that already exist rather than becoming a second kind of thing.
@MainActor
final class FileTranscriber: ObservableObject {
    static let shared = FileTranscriber()

    @Published private(set) var isRunning = false
    @Published private(set) var progress: Double = 0        // 0…1
    @Published private(set) var stage: String?              // what it is doing right now
    @Published var error: String?
    @Published var finished: UUID?                          // the new record, for the UI to open
    /// One import, kept whether it worked or not — a failure is exactly the thing you come back to
    /// this screen to understand. Held beside the archive rather than as a third `SessionRecord`
    /// kind: half the app splits records into meeting-or-dictation with a bare `else`, so a new
    /// case would quietly file every import under dictation.
    struct Entry: Codable, Identifiable {
        var id = UUID()
        var fileName: String
        var importedAt: Date
        var audioSec: Double
        var elapsedSec: Double        // how long the machine actually took
        var recordId: UUID?           // nil when it failed
        var failure: String?

        /// Every field tolerates being absent — the lesson from the space list, where one new
        /// non-optional key made the whole array undecodable and the list came back empty.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? "—"
            importedAt = try c.decodeIfPresent(Date.self, forKey: .importedAt) ?? Date()
            audioSec = try c.decodeIfPresent(Double.self, forKey: .audioSec) ?? 0
            elapsedSec = try c.decodeIfPresent(Double.self, forKey: .elapsedSec) ?? 0
            recordId = try c.decodeIfPresent(UUID.self, forKey: .recordId)
            failure = try c.decodeIfPresent(String.self, forKey: .failure)
        }
        init(fileName: String, importedAt: Date, audioSec: Double, elapsedSec: Double,
             recordId: UUID?, failure: String?) {
            self.fileName = fileName; self.importedAt = importedAt
            self.audioSec = audioSec; self.elapsedSec = elapsedSec
            self.recordId = recordId; self.failure = failure
        }

        /// Realtime factor — the number people actually want to know.
        var speedup: Double { elapsedSec > 0 ? audioSec / elapsedSec : 0 }
    }

    @Published private(set) var log: [Entry] = []
    private static let logKey = "importLog"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.logKey) {
            do { log = try JSONDecoder().decode([Entry].self, from: data) }
            catch { DebugLog.log("import log: decode failed — \(error)") }
        }
    }

    /// The record behind an entry, or nil once it has been deleted from the library — which is the
    /// source of truth, so a removed record simply stops resolving here.
    func record(for entry: Entry) -> SessionRecord? {
        guard let id = entry.recordId else { return nil }
        return SessionStore.shared.sessions.first { $0.id == id }
    }

    private func remember(_ entry: Entry) {
        log.insert(entry, at: 0)
        if log.count > 200 { log.removeLast(log.count - 200) }
        if let d = try? JSONEncoder().encode(log) { UserDefaults.standard.set(d, forKey: Self.logKey) }
    }

    func clearLog() {
        log = []
        UserDefaults.standard.removeObject(forKey: Self.logKey)
    }

    /// Seconds of audio handed to the model at once. Long files are not fed whole.
    private static let window: Double = 90
    /// How far from a window edge to hunt for a quiet moment to cut on.
    private static let cutSearch: Double = 4
    private static let rate: Double = 16_000

    func pickAndTranscribe(language: String) {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .audiovisualContent, .movie, .mpeg4Movie, .mp3, .wav, .aiff]
        panel.allowsOtherFileTypes = true          // .webm and friends: ffmpeg reads what AVFoundation won't
        panel.allowsMultipleSelection = false
        panel.prompt = L("Транскрибировать", "Transcribe")
        panel.message = L("Аудио или видео — распознавание пройдёт на этом Mac",
                          "Audio or video — recognition runs on this Mac")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transcribe(url, language: language)
    }

    /// True while nothing else is holding the model.
    var canStart: Bool { !isRunning && !TranscriptStore.shared.isRecording && !TranscriptStore.shared.isDictating }

    func transcribe(_ url: URL, language: String) {
        guard !isRunning else { return }
        isRunning = true; progress = 0; error = nil; finished = nil
        stage = L("Читаю файл…", "Reading the file…")

        let started = Date()
        Task { [weak self] in
            do {
                let samples = try await Self.loadSamples(url)
                let duration = Double(samples.count) / Self.rate
                guard duration > 0.5 else { throw Fault.empty }

                await MainActor.run { self?.stage = L("Готовлю модель…", "Loading the model…") }
                let engine = ParakeetEngine(language: Language.parley(language))
                try await engine.load()

                let cuts = Self.cutPoints(samples)
                var lines: [String] = []
                for i in 0..<(cuts.count - 1) {
                    let a = cuts[i], b = cuts[i + 1]
                    guard b > a else { continue }
                    let (text, _) = await engine.decode(Array(samples[a..<b]))
                    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        // Same shape as a recorded archive, with an explicit speaker label so the
                        // reader never mistakes a colon inside the sentence for the role separator.
                        lines.append("[\(Self.clock(Double(a) / Self.rate))] \(L("Запись", "Recording")): \(clean)")
                    }
                    let done = Double(b) / Self.rate
                    await MainActor.run {
                        self?.progress = min(1, done / duration)
                        self?.stage = L("Распознаю \(Self.clock(done)) из \(Self.clock(duration))…",
                                        "Transcribing \(Self.clock(done)) of \(Self.clock(duration))…")
                    }
                }

                guard !lines.isEmpty else { throw Fault.noSpeech }
                let id = UUID()
                let title = url.deletingPathExtension().lastPathComponent
                let elapsed = Date().timeIntervalSince(started)
                await MainActor.run {
                    SessionStore.shared.addMeeting(id: id, title: String(title.prefix(80)), date: Date(),
                                                   durationSec: duration, hasSummary: false,
                                                   transcript: lines.joined(separator: "\n"),
                                                   noteSummary: nil)
                    self?.remember(Entry(fileName: url.lastPathComponent, importedAt: Date(),
                                         audioSec: duration, elapsedSec: elapsed,
                                         recordId: id, failure: nil))
                    self?.finished = id
                    self?.isRunning = false; self?.stage = nil; self?.progress = 1
                }
                DebugLog.log(String(format: "import: %@ — %.0fs audio in %.1fs (%.0f× realtime)",
                                    url.lastPathComponent, duration, elapsed, elapsed > 0 ? duration / elapsed : 0))
            } catch {
                let msg = (error as? Fault)?.text ?? error.localizedDescription
                DebugLog.log("import failed: \(msg)")
                await MainActor.run {
                    // A failure is logged too — it is the thing you come back to this screen about.
                    self?.remember(Entry(fileName: url.lastPathComponent, importedAt: Date(),
                                         audioSec: 0, elapsedSec: Date().timeIntervalSince(started),
                                         recordId: nil, failure: msg))
                    self?.error = msg; self?.isRunning = false; self?.stage = nil
                }
            }
        }
    }

    enum Fault: Error {
        case empty, noSpeech, unreadable(String)
        var text: String {
            switch self {
            case .empty: return L("В файле нет звука.", "The file has no audio.")
            case .noSpeech: return L("Речь не распознана — возможно, в файле только музыка или тишина.",
                                     "No speech found — the file may be music or silence.")
            case .unreadable(let f):
                return L("macOS не читает этот формат (\(f)). Установите ffmpeg — `brew install ffmpeg` — и повторите.",
                         "macOS cannot read this format (\(f)). Install ffmpeg — `brew install ffmpeg` — and try again.")
            }
        }
    }

    // MARK: - Audio

    /// 16 kHz mono via AVFoundation, falling back to ffmpeg for the containers it refuses (webm,
    /// mkv and friends), which is most of what a video actually arrives in.
    private static func loadSamples(_ url: URL) async throws -> [Float] {
        if let s = try? await readWithAVFoundation(url), !s.isEmpty { return s }
        guard let ffmpeg = ffmpegPath() else { throw Fault.unreadable(url.pathExtension) }
        return try readWithFFmpeg(url, ffmpeg: ffmpeg)
    }

    private static func readWithAVFoundation(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw Fault.empty }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        guard reader.canAdd(output) else { throw Fault.unreadable(url.pathExtension) }
        reader.add(output)
        guard reader.startReading() else { throw Fault.unreadable(url.pathExtension) }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let p = pointer else { continue }
            p.withMemoryRebound(to: Float.self, capacity: length / MemoryLayout<Float>.size) {
                samples.append(contentsOf: UnsafeBufferPointer(start: $0, count: length / MemoryLayout<Float>.size))
            }
        }
        if reader.status == .failed { throw Fault.unreadable(url.pathExtension) }
        return samples
    }

    private static func ffmpegPath() -> String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func readWithFFmpeg(_ url: URL, ffmpeg: String) throws -> [Float] {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zvon-import-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-y", "-i", url.path, "-vn", "-ac", "1",
                       "-ar", String(Int(rate)), "-c:a", "pcm_f32le", tmp.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Fault.unreadable(url.pathExtension) }
        let file = try AVAudioFile(forReading: tmp)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buf)
        guard let ch = buf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
    }

    /// Window edges nudged to the quietest 100 ms nearby, so a cut never lands inside a word.
    static func cutPoints(_ samples: [Float]) -> [Int] {
        let w = Int(window * rate), r = Int(cutSearch * rate), probe = Int(0.1 * rate)
        guard samples.count > w else { return [0, samples.count] }
        var points = [0]
        var target = w
        while target < samples.count {
            let lo = max(points.last! + probe, target - r)
            let hi = min(samples.count - probe, target + r)
            var best = target, bestEnergy = Float.greatestFiniteMagnitude
            if lo < hi {
                var i = lo
                while i < hi {
                    var e: Float = 0
                    for j in i..<(i + probe) { e += samples[j] * samples[j] }
                    if e < bestEnergy { bestEnergy = e; best = i + probe / 2 }
                    i += probe
                }
            }
            points.append(min(best, samples.count))
            target = best + w
        }
        if points.last! < samples.count { points.append(samples.count) }
        return points
    }

    static func clock(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
