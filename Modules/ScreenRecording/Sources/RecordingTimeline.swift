import CoreMedia
import Foundation

/// One monotonic media clock for video and all audio sources; pauses remove the same
/// interval from every track. Never derive media time from wall clock or arrival order.
struct RecordingTimeline {
    var start: Double?
    private(set) var pauseStart: Double?
    private(set) var removed: Double = 0
    mutating func begin(at time: Double) { if start == nil { start = time } }
    mutating func pause(at time: Double) { if pauseStart == nil { pauseStart = time } }
    mutating func resume(at time: Double) {
        if let pauseStart { removed += max(0, time - pauseStart); self.pauseStart = nil }
    }
    func seconds(at time: Double) -> Double {
        guard let start else { return 0 }
        return max(0, min(time, pauseStart ?? time) - start - removed)
    }
    func timestamp(_ time: Double) -> Double? {
        guard let start, time >= start, pauseStart == nil else { return nil }
        return max(0, time - start - removed)
    }
}

/// Fixed-size stereo mix ring. Two sources add into the same media time slots.
/// No accumulated arrays or deferred tasks per callback, including when audio stalls.
struct RecordingAudioMixer {
    static let rate = 48_000
    private let capacity = 48_000 * 3
    private var samples = [Float](repeating: 0, count: 48_000 * 3 * 2)
    private(set) var cursor = 0
    private(set) var dropped = 0
    mutating func append(_ input: [Float], at firstFrame: Int, gain: Float = 1) {
        for frame in 0..<(input.count / 2) {
            let index = firstFrame + frame
            guard index >= cursor, index < cursor + capacity else { dropped += 1; continue }
            let slot = (index % capacity) * 2
            samples[slot] += input[frame * 2] * gain
            samples[slot + 1] += input[frame * 2 + 1] * gain
        }
    }
    mutating func take(frames: Int) -> [Float] {
        precondition(frames >= 0 && frames <= capacity)
        var result = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let slot = ((cursor + frame) % capacity) * 2
            result[frame * 2] = max(-1, min(1, samples[slot]))
            result[frame * 2 + 1] = max(-1, min(1, samples[slot + 1]))
            samples[slot] = 0; samples[slot + 1] = 0
        }
        cursor += frames
        return result
    }
}

public struct RecordingOptions: Sendable {
    public var microphone = false
    public var systemAudio = true
    public var microphoneID: String?
    public var showsCursor = true
    public var framesPerSecond = 30
    public init() {}
}

public enum RecordingFailure: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
