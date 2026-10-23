import AppKit
import AVFoundation

@main
struct RecordingTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func imageSample(at time: Double, blue: Bool = false) -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        let p = pixel!
        CVPixelBufferLockBaseAddress(p, [])
        let bytes = CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<180 { for x in 0..<320 {
            let offset = y * CVPixelBufferGetBytesPerRow(p) + x * 4
            bytes[offset] = blue ? 220 : 20; bytes[offset + 1] = 50; bytes[offset + 2] = blue ? 20 : 220; bytes[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(p, [])
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: p, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: p, formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample)
        return sample!
    }
    static func tone(frequency: Double, start: Int, frames: Int = 4800) -> [Float] {
        (0..<frames).flatMap { i -> [Float] in
            let value = Float(sin(Double(start + i) * 2 * .pi * frequency / 48_000)) * 0.2
            return [value, value]
        }
    }
    static func pcm44100(at host: Double, start: Int) throws -> CMSampleBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        buffer.frameLength = 4410
        for i in 0..<4410 { buffer.floatChannelData![0][i] = Float(sin(Double(start + i) * 2 * .pi * 440 / 44_100)) * 0.2 }
        var sample: CMSampleBuffer?
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description!, sampleCount: 4410,
            presentationTimeStamp: CMTime(seconds: host, preferredTimescale: 48_000), packetDescriptions: nil, sampleBufferOut: &sample)
        CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: buffer.audioBufferList)
        CMSampleBufferSetDataReady(sample!)
        return sample!
    }
    static func main() async throws {
        if CommandLine.arguments.count > 2 {
            let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("interrupted.mov")
            try? FileManager.default.removeItem(at: url)
            var now = 100.0
            let writer = try RecordingWriter(url: url, width: 320, height: 180, audioEnabled: false, fps: 30, clock: { now })
            for i in 0..<150 {
                now = 100 + Double(i) / 30
                writer.receiveVideo(imageSample(at: now, blue: i > 75))
                try await Task.sleep(for: .milliseconds(15))
            }
            try await Task.sleep(for: .milliseconds(500))
            _exit(0) // Simulate process death: no finishWriting, no destructors.
        }

        var timeline = RecordingTimeline(); timeline.begin(at: 100)
        timeline.pause(at: 101); require(timeline.timestamp(102) == nil, "Paused data must be excluded")
        timeline.resume(at: 103); require(abs(timeline.seconds(at: 104) - 2) < 0.001, "Pause must remove exactly two seconds")
        for i in 0..<100 { let now = 110 + Double(i) * 2; timeline.pause(at: now); timeline.resume(at: now + 1) }
        require(timeline.removed == 102, "Repeated pauses must not drift")
        var mixer = RecordingAudioMixer()
        mixer.append([0.2, 0.3, 0.4, 0.5], at: 0); mixer.append([0.1, 0.1], at: 1)
        let mixed = mixer.take(frames: 3)
        require(abs(mixed[2] - 0.5) < 0.001 && mixed[4] == 0, "Sources must align and missing samples must be silent")
        mixer.append([1, 1], at: -1); mixer.append([1, 1], at: 1_000_000)
        require(mixer.dropped == 2, "Late/future audio is bounded")
        print("PASS: common timeline, 100 pauses, aligned bounded audio mixing")

        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for mode in 0..<5 {
            var now = 100.0
            let draft = directory.appendingPathComponent("mode-\(mode).mov")
            try? FileManager.default.removeItem(at: draft)
            let writer = try RecordingWriter(url: draft, width: 320, height: 180, audioEnabled: mode != 0, fps: 30, clock: { now })
            for step in 0..<20 {
                if step == 10 { now = 101; writer.pause(); now = 103; writer.resume() }
                now = 100 + Double(step) / 10 + (step >= 10 ? 2 : 0)
                let frame = imageSample(at: now, blue: step >= 10)
                var retries = 0
                let old = writer.videoFrames
                while writer.videoFrames == old, retries < 200 {
                    writer.receiveVideo(frame); retries += 1
                    if writer.videoFrames == old { try await Task.sleep(for: .milliseconds(5)) }
                }
                require(writer.videoFrames > old, "Video encoder must accept frames: mode=\(mode) step=\(step) error=\(String(describing: writer.error))")
                if mode == 4 { writer.receiveAudio(try pcm44100(at: now, start: step * 4410), microphone: true) }
                if mode & 1 != 0 { writer.receiveAudio(try RecordingWriter.pcmSample(tone(frequency: 440, start: step * 4800), firstFrame: Int(now * 48_000)), microphone: true) }
                if mode & 2 != 0 { writer.receiveAudio(try RecordingWriter.pcmSample(tone(frequency: 880, start: step * 4800), firstFrame: Int(now * 48_000)), microphone: false) }
                writer.tick()
                try await Task.sleep(for: .milliseconds(10))
            }
            now = 104
            try await Task.sleep(for: .milliseconds(100))
            let finished: URL = try await withCheckedThrowingContinuation { continuation in writer.finish { continuation.resume(with: $0) } }
            let output = directory.appendingPathComponent("mode-\(mode).mp4")
            try? FileManager.default.removeItem(at: output)
            try await RecordingFiles.export(finished, to: output)
            let asset = AVURLAsset(url: output)
            let duration = try await asset.load(.duration).seconds
            require(abs(duration - 2) < 0.12, "Video must exclude pause: \(duration)")
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            require(audioTracks.count == (mode == 0 ? 0 : 1), "Both sources must be mixed into one playable track")
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            for (time, blue) in [(0.2, false), (1.5, true)] {
                let image = try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
                require(image.width == 320 && image.height == 180, "Output dimensions")
                let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                let p = context.data!.assumingMemoryBound(to: UInt8.self)
                require(blue ? p[2] > p[0] : p[0] > p[2], "Actual encoded image must match frame before/after pause")
            }
            if let track = audioTracks.first {
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
                reader.add(output); reader.startReading()
                var values: [Float] = []
                while let sample = output.copyNextSampleBuffer(), let block = sample.dataBuffer {
                    let count = CMBlockBufferGetDataLength(block) / 4
                    var chunk = [Float](repeating: 0, count: count)
                    _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress!) }
                    values.append(contentsOf: stride(from: 0, to: chunk.count, by: 2).map { chunk[$0] })
                }
                require(values.count > 80_000, "Audio duration must follow video")
                func strength(_ frequency: Double) -> Double {
                    var real = 0.0, imaginary = 0.0
                    for i in 6000..<42000 {
                        let phase = Double(i) * 2 * .pi * frequency / 48_000
                        real += Double(values[i]) * cos(phase); imaginary += Double(values[i]) * sin(phase)
                    }
                    return hypot(real, imaginary) / 36000
                }
                require((strength(440) > 0.02) == (mode == 4 || mode & 1 != 0), "Decoded microphone tone presence: mode=\(mode), 440=\(strength(440)), 880=\(strength(880)), samples=\(values.count)")
                require((strength(880) > 0.02) == (mode & 2 != 0), "Decoded system tone presence: mode=\(mode), 440=\(strength(440)), 880=\(strength(880))")
            }
            print("PASS: mode \(mode), decoded H.264 pixels, audio frequencies, MP4 and pause duration \(duration)")
        }
        // A stationary display must keep its full recorded duration and a valid final frame.
        var now = 100.0
        let draft = directory.appendingPathComponent("still.mov"); try? FileManager.default.removeItem(at: draft)
        let writer = try RecordingWriter(url: draft, width: 320, height: 180, audioEnabled: false, fps: 30, clock: { now })
        writer.receiveVideo(imageSample(at: now))
        for i in 1...5 { now = 100 + Double(i); writer.tick(); try await Task.sleep(for: .milliseconds(30)) }
        let final: URL = try await withCheckedThrowingContinuation { c in writer.finish { c.resume(with: $0) } }
        let asset = AVURLAsset(url: final)
        let duration = try await asset.load(.duration).seconds
        require(abs(duration - 5) < 0.1, "Static screen must not produce a zero-length file")
        print("PASS: stationary screen duration \(duration), fragmented MOV remains readable")
        let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = [directory.path, "interrupt"]
        try child.run(); child.waitUntilExit()
        require(child.terminationStatus == 0, "Interrupted recorder fixture")
        let interrupted = directory.appendingPathComponent("interrupted.mov")
        let recovered = directory.appendingPathComponent("recovered.mp4")
        try? FileManager.default.removeItem(at: recovered)
        try await RecordingFiles.export(interrupted, to: recovered)
        let recoveredDuration = try await AVURLAsset(url: recovered).load(.duration).seconds
        require(recoveredDuration >= 2, "Completed fragments must survive process death")
        print("PASS: recovered playable MP4 after process death, duration \(recoveredDuration)")

    }
}
