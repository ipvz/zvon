import AVFoundation
import ScreenCaptureKit

/// All methods run on the capture engine's serial queue. The only retained video
/// surface is the last frame, used to preserve duration when the desktop is static.
final class RecordingWriter: @unchecked Sendable {
    let url: URL
    let writer: AVAssetWriter
    private let clock: () -> Double
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private var timeline = RecordingTimeline()
    private var mixer = RecordingAudioMixer()
    private var converters: [String: AVAudioConverter] = [:]
    private var conversionNext: [String: Double] = [:]
    private var conversionInputEnd: [String: Double] = [:]
    private var lastFrame: CMSampleBuffer?
    private var lastVideoTime = -1.0
    private var audioEnd = 0.0
    private var audioResumeHost = 0.0
    private(set) var videoFrames = 0
    private(set) var droppedFrames = 0
    private(set) var finishing = false
    private(set) var error: Error?
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    var micMuted = false
    var systemMuted = false
    var onFailure: ((Error) -> Void)?
    static var now: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    init(url: URL, width: Int, height: Int, audioEnabled: Bool, fps: Int, clock: @escaping () -> Double = { RecordingWriter.now }) throws {
        self.clock = clock
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, min(30_000_000, width * height * 5)),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                       AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                       AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw RecordingFailure.message("Этот размер видео не поддерживается кодировщиком.") }
        writer.add(video)
        if audioEnabled {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecordingFailure.message("Не удалось настроить звук видео.") }
            writer.add(input); audio = input
        } else { audio = nil }
        guard writer.startWriting() else { throw writer.error ?? RecordingFailure.message("Не удалось открыть файл записи.") }
        writer.startSession(atSourceTime: .zero)
    }

    var elapsed: Double { timeline.seconds(at: clock()) }
    var isPaused: Bool { timeline.pauseStart != nil }

    func receiveVideo(_ sample: CMSampleBuffer) {
        guard !finishing, error == nil, !isPaused, sample.isValid, CMSampleBufferGetImageBuffer(sample) != nil else { return }
        if let info = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = info.first?[.status] as? Int, raw != SCFrameStatus.complete.rawValue { return }
        let host = sample.presentationTimeStamp.seconds
        guard host.isFinite else { return }
        timeline.begin(at: host)
        guard let time = timeline.timestamp(host), time > lastVideoTime else { return }
        guard video.isReadyForMoreMediaData else { droppedFrames += 1; return }
        do {
            let copy = try retimed(sample, seconds: time)
            guard video.append(copy) else { throw writer.error ?? RecordingFailure.message("Кодировщик перестал принимать кадры.") }
            lastFrame = sample; lastVideoTime = time; videoFrames += 1
        } catch { fail(error) }
    }

    func receiveAudio(_ sample: CMSampleBuffer, microphone: Bool) {
        guard audio != nil, !finishing, error == nil, !isPaused, timeline.start != nil else { return }
        let host = sample.presentationTimeStamp.seconds
        guard host.isFinite, host >= audioResumeHost, timeline.timestamp(host) != nil else { return }
        do {
            let key = microphone ? "mic" : "system"
            if let last = conversionInputEnd[key], abs(host - last) > 0.05 {
                converters[key]?.reset(); conversionNext[key] = nil
            }
            // Preserve the converter's buffered latency while following each source's
            // host timestamp. Device clock drift must not accumulate over long recordings.
            let buffered = max(0, (conversionInputEnd[key] ?? host) - (conversionNext[key] ?? host))
            let convertedHost = host - buffered
            let samples = try convert(sample, key: key)
            conversionNext[key] = convertedHost + Double(samples.count / 2) / 48_000
            conversionInputEnd[key] = host + sample.duration.seconds
            guard let convertedTime = timeline.timestamp(convertedHost) else { return }
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            if microphone { micLevel = peak } else { systemLevel = peak }
            if microphone ? micMuted : systemMuted { return }
            // Headroom for concurrent sources. A mono mic is duplicated to both channels.
            mixer.append(samples, at: Int((convertedTime * 48_000).rounded()), gain: 0.8)
        } catch { fail(error) }
    }

    func pause() {
        guard !finishing, !isPaused else { return }
        let now = clock()
        flushAudio(until: timeline.seconds(at: now))
        extendLastFrame(to: max(0, timeline.seconds(at: now) - 1.0 / 600))
        timeline.pause(at: now); micLevel = 0; systemLevel = 0
    }
    func resume() {
        guard !finishing, isPaused else { return }
        audioResumeHost = clock()
        timeline.resume(at: audioResumeHost)
        converters.values.forEach { $0.reset() }; conversionNext.removeAll(); conversionInputEnd.removeAll()
    }
    func tick() {
        guard !finishing, error == nil, !isPaused else { return }
        flushAudio(until: timeline.seconds(at: clock() - 0.25))
        // The desktop may not produce another frame for minutes. Advance its last image
        // periodically so fragment recovery and the final video include stationary time.
        if elapsed - lastVideoTime > 1 { extendLastFrame(to: elapsed - 0.1) }
    }
    private func extendLastFrame(to seconds: Double) {
        guard let lastFrame, seconds > lastVideoTime, video.isReadyForMoreMediaData else { return }
        do {
            guard video.append(try retimed(lastFrame, seconds: seconds)) else {
                throw writer.error ?? RecordingFailure.message("Не удалось завершить видеокадр.")
            }
            lastVideoTime = seconds
        } catch { fail(error) }
    }
    private func flushAudio(until seconds: Double) {
        guard let audio, timeline.start != nil else { return }
        let target = max(0, Int(seconds * 48_000))
        if target - mixer.cursor > 48_000 * 2 {
            fail(RecordingFailure.message("Диск или кодировщик не успевает сохранять звук. Запись остановлена.")); return
        }
        while mixer.cursor < target, audio.isReadyForMoreMediaData {
            let first = mixer.cursor
            let frames = min(4800, target - first)
            let floats = mixer.take(frames: frames)
            do {
                let sample = try Self.pcmSample(floats, firstFrame: first)
                guard audio.append(sample) else { throw writer.error ?? RecordingFailure.message("Не удалось сохранить звук.") }
                audioEnd = Double(first + frames) / 48_000
            } catch { fail(error); return }
        }
    }

    func finish(on queue: DispatchQueue = DispatchQueue(label: "com.zvon.video.finalize"),
                completion: @escaping (Result<URL, Error>) -> Void) {
        guard !finishing else {
            completion(.failure(RecordingFailure.message("Файл уже завершается."))); return
        }
        guard writer.status == .writing else {
            finishing = true; lastFrame = nil
            completion(.failure(writer.error ?? error ?? RecordingFailure.message("Запись прервана. Черновик сохранён."))); return
        }
        let end = elapsed
        finishing = true
        guard videoFrames > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(.failure(error ?? RecordingFailure.message("Источник не прислал видеокадры. Запись не началась."))); return
        }
        let deadline = Self.now + 4
        func drain() {
            self.flushAudio(until: end)
            self.extendLastFrame(to: max(0, end - 1.0 / 600))
            let audioReady = self.audio == nil || self.audioEnd >= end - 1.0 / 48_000
            let videoReady = self.lastVideoTime >= end - 1.0 / 300
            if (!audioReady || !videoReady), self.writer.status == .writing, Self.now < deadline {
                queue.asyncAfter(deadline: .now() + 0.01) { drain() }; return
            }
            self.lastFrame = nil; self.converters.removeAll()
            self.video.markAsFinished(); self.audio?.markAsFinished()
            self.writer.endSession(atSourceTime: CMTime(seconds: max(self.lastVideoTime, self.audioEnd), preferredTimescale: 48_000))
            self.writer.finishWriting { [self] in
                if writer.status == .completed { completion(.success(url)) }
                else { completion(.failure(writer.error ?? error ?? RecordingFailure.message("Не удалось завершить файл. Черновик сохранён."))) }
            }
        }
        drain()
    }
    private func fail(_ failure: Error) {
        guard error == nil else { return }
        error = failure; onFailure?(failure)
    }
    private func retimed(_ sample: CMSampleBuffer, seconds: Double) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var output: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &output)
        guard status == noErr, let output else { throw RecordingFailure.message("Ошибка временной шкалы видео: \(status).") }
        return output
    }
    private func convert(_ sample: CMSampleBuffer, key: String) throws -> [Float] {
        guard let description = sample.formatDescription else {
            throw RecordingFailure.message("Не удалось прочитать формат аудиоустройства.")
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)) else {
            throw RecordingFailure.message("Не удалось прочитать формат аудиоустройства.")
        }
        input.frameLength = input.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(input.frameLength), into: input.mutableAudioBufferList)
        guard status == noErr else { throw RecordingFailure.message("Не удалось прочитать звук: \(status).") }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let converter: AVAudioConverter
        if let existing = converters[key], existing.inputFormat == format { converter = existing }
        else {
            guard let created = AVAudioConverter(from: format, to: target) else { throw RecordingFailure.message("Неподдерживаемый формат микрофона.") }
            created.primeMethod = .none
            converter = created; converters[key] = created
        }
        let count = AVAudioFrameCount(ceil(Double(input.frameLength) * 48_000 / format.sampleRate) + 32)
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: count)!
        var fed = false, failure: NSError?
        if format.sampleRate == target.sampleRate {
            try converter.convert(to: output, from: input)
        } else {
            converter.convert(to: output, error: &failure) { _, state in
                if fed { state.pointee = .noDataNow; return nil }
                fed = true; state.pointee = .haveData; return input
            }
        }
        if let failure { throw failure }
        guard let channels = output.floatChannelData else { return [] }
        var result = [Float](repeating: 0, count: Int(output.frameLength) * 2)
        for i in 0..<Int(output.frameLength) { result[i * 2] = channels[0][i]; result[i * 2 + 1] = channels[1][i] }
        return result
    }
    static func pcmSample(_ floats: [Float], firstFrame: Int) throws -> CMSampleBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        var description: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        var block: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: floats.count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: floats.count * 4, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block, let description else { throw RecordingFailure.message("Не удалось подготовить аудиобуфер.") }
        status = floats.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: Int64(firstFrame), timescale: 48_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?, size = 8
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
            sampleCount: floats.count / 2, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw RecordingFailure.message("Не удалось собрать звук: \(status).") }
        return sample
    }
}
