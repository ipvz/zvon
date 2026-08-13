import AVFoundation
import Combine
import Foundation

/// Plays back a meeting's archived audio and reports where it is, so the transcript can follow
/// along and a line can jump straight to the moment it was said.
@MainActor
final class MeetingAudioPlayer: NSObject, ObservableObject {
    static let shared = MeetingAudioPlayer()

    @Published private(set) var sessionId: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    /// Seconds from the start of the recording — the same axis as `TranscriptLine.startSec`.
    @Published private(set) var position: Double = 0
    @Published private(set) var error: String?

    private var player: AVAudioPlayer?
    private var ticker: Timer?
    /// Set while the user drags the scrubber: the ticker must not fight the thumb.
    private var scrubbing = false

    var isLoaded: Bool { player != nil }

    /// Load a session's track, keeping the current position if it is already the one loaded.
    @discardableResult
    func load(sessionId id: UUID) -> Bool {
        if sessionId == id, player != nil { return true }
        stop()
        let url = MeetingAudioRecorder.url(sessionId: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            player = p
            sessionId = id
            duration = p.duration
            position = 0
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            DebugLog.log("audio player: load failed — \(error.localizedDescription)")
            return false
        }
    }

    /// Jump to a moment and start playing — what clicking a transcript line does.
    func play(sessionId id: UUID, at seconds: Double) {
        guard load(sessionId: id), let p = player else { return }
        // A line's stamp is the START of the utterance; a hair earlier so the first word isn't clipped.
        p.currentTime = clamp(seconds - 0.35)
        position = p.currentTime
        p.play()
        isPlaying = true
        startTicker()
    }

    func toggle() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); isPlaying = false; stopTicker() }
        else {
            // Reaching the end and pressing play again should replay, not sit at the end doing nothing.
            if p.currentTime >= p.duration - 0.05 { p.currentTime = 0; position = 0 }
            p.play(); isPlaying = true; startTicker()
        }
    }

    func seek(to seconds: Double) {
        guard let p = player else { return }
        p.currentTime = clamp(seconds)
        position = p.currentTime
    }

    func beginScrub() { scrubbing = true }
    func endScrub(to seconds: Double) {
        scrubbing = false
        seek(to: seconds)
    }

    func stop() {
        stopTicker()
        player?.stop()
        player = nil
        sessionId = nil
        isPlaying = false
        position = 0
        duration = 0
    }

    /// Index of the line that is playing right now, given each line's start offset.
    func activeLine(in starts: [Double]) -> Int? {
        guard isLoaded, !starts.isEmpty else { return nil }
        var found: Int?
        for (i, s) in starts.enumerated() where s <= position + 0.35 { found = i }
        return found
    }

    private func clamp(_ t: Double) -> Double { min(max(0, t), max(0, duration - 0.01)) }

    private func startTicker() {
        stopTicker()
        // 10 Hz: fine enough for the transcript to follow, coarse enough to be free.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, !self.scrubbing else { return }
                self.position = p.currentTime
            }
        }
    }

    private func stopTicker() { ticker?.invalidate(); ticker = nil }
}

extension MeetingAudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.position = self.duration
            self.stopTicker()
        }
    }
}
