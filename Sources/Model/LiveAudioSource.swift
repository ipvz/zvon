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

/// Live microphone via WhisperKit's `AudioProcessor` — the proven capture path.
final class MicAudioSource: LiveAudioSource, @unchecked Sendable {
    private let processor: any AudioProcessing

    init(_ processor: any AudioProcessing) {
        self.processor = processor
    }

    func start() throws {
        try processor.startRecordingLive(callback: nil)
    }

    func stop() {
        processor.stopRecording()
    }

    func snapshotSamples() -> [Float] {
        Array(processor.audioSamples)
    }

    func snapshotEnergy() -> [Float] {
        // WhisperKit's relativeEnergy is an O(n) map over an array it never trims, so it grows for
        // the whole session. Only the tail is ever consumed (VAD + meters), so bound it here — this
        // keeps `levels`/`levelsThem` tiny and every downstream .animation(value:) diff cheap.
        Array(processor.relativeEnergy.suffix(16))
    }

    func purge(keepingLast keepCount: Int) {
        processor.purgeAudioSamples(keepingLast: keepCount)
    }
}
