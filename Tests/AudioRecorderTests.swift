import Foundation
import AVFoundation

enum DebugLog { static func log(_ message: String) {} }

@main struct AudioRecorderTests {
    static func main() throws {
        let id = UUID()
        defer { MeetingAudioRecorder.deleteAudio(sessionId: id) }
        let recorder = MeetingAudioRecorder(sessionId: id, startedAt: Date().addingTimeInterval(-1))
        recorder.append([Float](repeating: 0.05, count: 16_000), from: .me)
        recorder.append([Float](repeating: 0.025, count: 16_000), from: .them)
        guard let url = recorder.finish() else { preconditionFailure("missing recording") }
        let file = try AVAudioFile(forReading: url)
        precondition(file.processingFormat.channelCount == 2)
        precondition(file.length >= 16_000 && file.length < 20_000)
        precondition(recorder.finish() == nil, "second close must be harmless")
        // A late capture callback must not reopen or extend a finalized file.
        recorder.append([Float](repeating: 1, count: 16_000), from: .me)
        let reopened = try AVAudioFile(forReading: url)
        precondition(reopened.length == file.length)
        print("PASS: stereo recording flushes, closes once, and ignores late audio")
    }
}
