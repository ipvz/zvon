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

/// Live microphone via WhisperKit's `AudioProcessor`.
///
/// CRASH FIX (heap corruption / `POINTER_BEING_FREED_WAS_NOT_ALLOCATED` on stop): WhisperKit appends
/// to its `audioSamples: ContiguousArray<Float>` on the real-time audio thread (`processBuffer`) with
/// NO lock. Reading that array from the VAD actor via `Array(processor.audioSamples)` races the
/// append — a Swift array read while another thread appends can free/realloc the shared backing store
/// out from under the reader → SIGABRT. Same for `relativeEnergy`.
///
/// So we keep our OWN lock-protected buffer, fed by the `startRecordingLive` callback. That callback
/// is invoked synchronously inside `processBuffer`, on the audio thread, right after the chunk is
/// appended — so our buffer has a single writer (the audio thread, serialized by the input tap) and
/// is read by the actor only under the lock. We never touch `processor.audioSamples`/`relativeEnergy`
/// from any other thread; we bound WhisperKit's own (now unread) buffer via `purgeAudioSamples` inside
/// the callback, which is safe because it runs on the same thread as the append.
final class MicAudioSource: LiveAudioSource, @unchecked Sendable {
    private let processor: any AudioProcessing
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var energy: [Float] = []            // last ≤16 relative-energy frames for the level meter
    private static let internalCap = 240_000    // ~15 s @16 kHz — cap WhisperKit's own buffer growth

    init(_ processor: any AudioProcessing) {
        self.processor = processor
    }

    func start() throws {
        lock.lock(); buffer.removeAll(keepingCapacity: true); energy.removeAll(keepingCapacity: true); lock.unlock()
        // AVFAudio's installTapOnBus (inside startRecordingLive) raises an ObjC NSException when the mic
        // input is unavailable / the device changed / a tap is still attached from a too-fast restart.
        // Swift `try` can't catch that — it would abort the app. Bridge it to a Swift error instead so
        // the pipeline surfaces "микрофон недоступен" and the session ends cleanly.
        var swiftError: Error?
        let nsError = zvonCatchNSException {
            do {
                try self.processor.startRecordingLive { [weak self] chunk in
                    guard let self else { return }
                    // Audio thread, same call that appended `chunk` to the processor's own buffer.
                    self.lock.lock()
                    self.buffer.append(contentsOf: chunk)
                    var s: Float = 0; for v in chunk { s += v * v }
                    let rms = chunk.isEmpty ? 0 : (s / Float(chunk.count)).squareRoot()
                    self.energy.append(min(1, rms * 14))   // rough 0…1 level for the meters
                    if self.energy.count > 16 { self.energy.removeFirst(self.energy.count - 16) }
                    self.lock.unlock()
                    // Keep WhisperKit's internal (unread) buffer from growing all session — safe here.
                    self.processor.purgeAudioSamples(keepingLast: Self.internalCap)
                }
            } catch { swiftError = error }
        }
        if let nsError { throw nsError }
        if let swiftError { throw swiftError }
    }

    func stop() {
        processor.stopRecording()
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
