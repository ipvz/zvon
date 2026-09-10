import AVFoundation
import Foundation
import WhisperKit

/// The audio input seam. Everything `StreamingTranscriber` needs from a capture source,
/// so the exact same transcription loop can be driven by the live microphone in the app OR
/// by a WAV replayed in simulated real-time in the headless harness (deterministic testing).
///
/// This is the Ф3 vendor/capture seam from the architecture doc, introduced here first because
/// it is the only way to reproduce and fix live-only real-time defects off a real microphone.
protocol LiveAudioSource: AnyObject, Sendable {
    func start() throws
    func stop()

    /// 16 kHz mono Float samples in the current (post-purge) window.
    func snapshotSamples() -> [Float]

    /// Relative-energy frames on WhisperKit's 0…1 scale (VAD + level meter).
    func snapshotEnergy() -> [Float]

    /// Drop all but the last `keepCount` samples from the window.
    func purge(keepingLast keepCount: Int)
}

/// Live microphone on our own `AVAudioEngine` tap.
///
/// Not WhisperKit's `AudioProcessor`: it builds a fixed capture format and gives up when the input
/// does not fit, which the built-in MacBook Pro microphone now does not — macOS exposes that mic
/// array as THREE channels at 96 kHz, and every start died with "Failed to create node format".
/// Retrying could not help; the device is simply shaped that way.
///
/// Here the tap is installed with whatever format the node reports and an `AVAudioConverter` brings
/// it down to the 16 kHz mono the transcriber wants. Channel count and sample rate stop mattering,
/// which is the same approach the system-audio tap already takes.
///
/// Owning the buffer also removes the heap corruption that came from reading WhisperKit's
/// `audioSamples` array while its audio thread appended to it: there is one writer here, the tap,
/// and readers take the lock.
final class MicAudioSource: LiveAudioSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var monoFormat: AVAudioFormat?
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var energy: [Float] = []            // last ≤16 relative-energy frames for the level meter
    private var tapped = false
    /// What the transcriber consumes, regardless of what the hardware hands us.
    private static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                              channels: 1, interleaved: false)!
    /// Optional tap for archiving the audio. Called on the audio thread with the converted chunk,
    /// before any VAD or windowing, so the recording is continuous and gap-free regardless of what
    /// the transcriber decides to keep.
    var onSamples: (@Sendable ([Float]) -> Void)?

    init() {}

    /// Retried, because a start can also fail for a genuinely transient reason: ending a meeting
    /// destroys the aggregate device the system tap was built on, and while CoreAudio settles the
    /// default input can briefly report nothing usable. A device arriving or leaving does the same.
    func start() throws {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                try startOnce()
                if attempt > 1 { DebugLog.log("mic start recovered on attempt \(attempt)") }
                return
            } catch {
                lastError = error
                DebugLog.log("mic start attempt \(attempt) failed: \(error.localizedDescription) — \(Self.inputDescription())")
                stop()
                if attempt < 3 { Thread.sleep(forTimeInterval: 0.4) }
            }
        }
        throw lastError ?? NSError(domain: "ZVON", code: -1,
                                   userInfo: [NSLocalizedDescriptionKey: "Микрофон недоступен"])
    }

    /// The input as CoreAudio sees it right now — logged on failure, because "Failed to create node
    /// format" on its own never said which device was wrong or what it claimed to be.
    private static func inputDescription() -> String {
        let f = AVAudioEngine().inputNode.inputFormat(forBus: 0)
        return "input \(Int(f.sampleRate)) Hz \(f.channelCount) ch"
    }

    private func startOnce() throws {
        lock.lock(); buffer.removeAll(keepingCapacity: true); energy.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "ZVON", code: -2, userInfo: [NSLocalizedDescriptionKey:
                "Микрофон недоступен — система не сообщает формат входа."])
        }
        // Channels are folded by hand and only the SAMPLE RATE is left to the converter. Handing it
        // a multi-channel source instead produces frames of pure silence: a mic array reports a
        // discrete channel layout, for which no downmix is defined, so the converter has nothing to
        // mix and emits nothing. Measured: 3 ch and 2 ch both came out at peak 0.000, mono did not.
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
                                       channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: Self.target) else {
            throw NSError(domain: "ZVON", code: -3, userInfo: [NSLocalizedDescriptionKey:
                "Не удалось привести формат микрофона (\(Int(inputFormat.sampleRate)) Гц, \(inputFormat.channelCount) кан.)."])
        }
        self.converter = converter
        self.monoFormat = mono
        DebugLog.log("mic tap: \(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) ch → 16000 Hz mono")

        // installTapOnBus raises an ObjC NSException when a tap is still attached from a too-fast
        // restart or the device vanished mid-call. Swift `try` cannot catch that — it would abort
        // the process — so it is bridged to a Swift error.
        let nsError = zvonCatchNSException {
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buf, _ in
                self?.ingest(buf)
            }
            self.tapped = true
            self.engine.prepare()
        }
        if let nsError { throw nsError }
        try engine.start()
    }

    /// Fold whatever the hardware sent to one channel — the converter is only asked to change the
    /// sample rate, which it does reliably for any device.
    private static func downmix(_ buf: AVAudioPCMBuffer) -> [Float] {
        let n = Int(buf.frameLength), channels = Int(buf.format.channelCount)
        guard let data = buf.floatChannelData, n > 0, channels > 0 else { return [] }
        if channels == 1 { return Array(UnsafeBufferPointer(start: data[0], count: n)) }
        if channels == 2 {
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n { out[i] = (data[0][i] + data[1][i]) * 0.5 }
            return out
        }
        // More than stereo means a microphone array: the channels are physically spaced capsules,
        // so averaging them comb-filters the voice. Take the first, which is a plain mic feed.
        return Array(UnsafeBufferPointer(start: data[0], count: n))
    }

    /// Convert one hardware buffer to 16 kHz mono and publish it. Runs on the audio thread.
    private func ingest(_ buf: AVAudioPCMBuffer) {
        guard let converter, let monoFormat else { return }
        let folded = Self.downmix(buf)
        guard !folded.isEmpty,
              let source = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(folded.count)),
              let src = source.floatChannelData?[0] else { return }
        source.frameLength = AVAudioFrameCount(folded.count)
        folded.withUnsafeBufferPointer { src.update(from: $0.baseAddress!, count: folded.count) }

        let ratio = Self.target.sampleRate / monoFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(folded.count) * ratio) + 64
        guard capacity > 0, let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return source
        }
        guard error == nil, out.frameLength > 0, let ch = out.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))

        lock.lock()
        self.buffer.append(contentsOf: chunk)
        var sum: Float = 0; for v in chunk { sum += v * v }
        let rms = chunk.isEmpty ? 0 : (sum / Float(chunk.count)).squareRoot()
        energy.append(min(1, rms * 14))          // rough 0…1 level for the meters
        if energy.count > 16 { energy.removeFirst(energy.count - 16) }
        lock.unlock()

        onSamples?(chunk)
    }

    func stop() {
        if tapped {
            _ = zvonCatchNSException { self.engine.inputNode.removeTap(onBus: 0) }
            tapped = false
        }
        if engine.isRunning { engine.stop() }
        converter = nil
        monoFormat = nil
    }

    func snapshotSamples() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    func snapshotEnergy() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return energy
    }

    func purge(keepingLast keepCount: Int) {
        lock.lock(); defer { lock.unlock() }
        if keepCount < buffer.count { buffer.removeFirst(buffer.count - keepCount) }
    }
}
