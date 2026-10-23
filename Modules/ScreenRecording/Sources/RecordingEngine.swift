import AppKit
import AVFoundation
import ScreenCaptureKit
import ZVONScreenshots

struct RecordingProgress: Sendable {
    var elapsed: Double
    var frames: Int
    var dropped: Int
    var microphone: Float
    var system: Float
}

/// UI/lifetime on MainActor; capture, conversion, mixing and file writes on one serial queue.
/// A second audio-only SCStream intentionally captures all Mac audio even for a single window.
@MainActor
final class RecordingEngine {
    private let sink = RecordingSampleSink()
    private var videoStream: SCStream?
    private var audioStream: SCStream?
    private var microphoneSession: AVCaptureSession?
    private var timer: DispatchSourceTimer?
    private var stopping = false
    private var started = false
    var onProgress: ((RecordingProgress) -> Void)?
    var onFailure: ((Error) -> Void)?
    private(set) var draft: URL?
    private(set) var microphoneDeviceID: String?

    func start(target: ScreenCaptureTarget, options: RecordingOptions) async throws {
        guard !started else { throw RecordingFailure.message("Запись уже запущена.") }
        started = true
        if options.microphone {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { throw RecordingFailure.message("Разреши доступ к микрофону в настройках macOS или выключи его перед записью.") }
        }
        try Task.checkCancellation()
        try RecordingFiles.checkSpace(at: RecordingFiles.downloads)
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
            throw RecordingFailure.message("Выбранный монитор отключён. Выбери источник заново.")
        }
        // Exclude our application, allowing only existing document windows back in.
        // Enumerating panels alone races WindowServer when the HUD was just ordered in,
        // and cannot exclude panels that appear later in the recording.
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let documentIDs = Set(NSApp.windows.compactMap { window -> CGWindowID? in
            guard !(window is NSPanel) else { return nil }
            return ScreenCaptureTarget.validWindowID(window.windowNumber)
        })
        let includedDocuments = content.windows.filter { documentIDs.contains($0.windowID) }
        let filter: SCContentFilter
        var pixels = target.pixelSize
        if let id = target.windowID {
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw RecordingFailure.message("Выбранное окно уже закрыто. Выбери другое окно.")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            pixels = CGSize(width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
                            height: filter.contentRect.height * CGFloat(filter.pointPixelScale))
        } else { filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: includedDocuments) }
        // H.264 dimensions stay fixed throughout recording, including window resizes.
        let size = Self.outputSize(pixels)
        let config = SCStreamConfiguration()
        config.width = Int(size.width); config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.framesPerSecond))
        config.queueDepth = 3; config.showsCursor = options.showsCursor
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.itur_709
        config.scalesToFit = true; config.preservesAspectRatio = true
        config.ignoreShadowsSingleWindow = true; config.ignoreGlobalClipSingleWindow = true
        if #available(macOS 14.2, *) { config.includeChildWindows = true }
        if target.kind == .region { config.sourceRect = target.rect }
        let draft = try RecordingFiles.makeDraft(); self.draft = draft
        try await sink.perform {
            let writer = try RecordingWriter(url: draft, width: Int(size.width), height: Int(size.height),
                audioEnabled: options.microphone || options.systemAudio, fps: options.framesPerSecond)
            self.sink.writer = writer
            self.sink.accepting = true
            writer.onFailure = { [weak self] error in Task { @MainActor in self?.onFailure?(error) } }
        }
        sink.failed = { [weak self] error in Task { @MainActor in self?.onFailure?(error) } }
        do {
            if options.microphone {
                let device: AVCaptureDevice?
                if let id = options.microphoneID { device = AVCaptureDevice(uniqueID: id) }
                else { device = AVCaptureDevice.default(for: .audio) }
                guard let device else { throw RecordingFailure.message("Выбранный микрофон недоступен. Выбери другое устройство.") }
                microphoneDeviceID = device.uniqueID
                let session = AVCaptureSession()
                session.beginConfiguration()
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureAudioDataOutput()
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    session.commitConfiguration(); throw RecordingFailure.message("Не удалось подключить микрофон.")
                }
                session.addInput(input); session.addOutput(output)
                output.setSampleBufferDelegate(sink, queue: sink.queue)
                session.commitConfiguration(); microphoneSession = session
                await sink.performNonthrowing { session.startRunning() }
                guard session.isRunning else { throw RecordingFailure.message("Микрофон не начал запись.") }
            }
            try Task.checkCancellation()
            if options.systemAudio {
                let audioConfig = SCStreamConfiguration()
                audioConfig.width = 2; audioConfig.height = 2; audioConfig.queueDepth = 3
                audioConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                audioConfig.capturesAudio = true; audioConfig.sampleRate = 48_000; audioConfig.channelCount = 2
                audioConfig.excludesCurrentProcessAudio = true
                let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: audioConfig, delegate: sink)
                try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
                audioStream = stream; try await stream.startCapture()
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: sink)
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            videoStream = stream; try await stream.startCapture()
            try Task.checkCancellation()
            let sink = sink
            let timer = DispatchSource.makeTimerSource(queue: sink.queue)
            let began = RecordingWriter.now
            var lastSpaceCheck = began
            timer.schedule(deadline: .now(), repeating: 0.2)
            timer.setEventHandler { [weak self] in
                guard let writer = sink.writer, sink.accepting else { return }
                writer.tick()
                let progress = RecordingProgress(elapsed: writer.elapsed, frames: writer.videoFrames,
                    dropped: writer.droppedFrames, microphone: writer.micLevel, system: writer.systemLevel)
                Task { @MainActor in self?.onProgress?(progress) }
                if RecordingWriter.now - began > 8, writer.videoFrames == 0 {
                    sink.report(RecordingFailure.message("Источник не присылает изображение. Проверь разрешение записи экрана."))
                }
                if RecordingWriter.now - lastSpaceCheck > 5 {
                    lastSpaceCheck = RecordingWriter.now
                    do { try RecordingFiles.checkSpace(at: draft.deletingLastPathComponent()) }
                    catch { sink.report(error) }
                }
            }
            self.timer = timer; timer.resume()
        } catch {
            _ = try? await stop()
            throw error
        }
    }

    func pause(_ paused: Bool) async {
        await sink.performNonthrowing { if paused { self.sink.writer?.pause() } else { self.sink.writer?.resume() } }
    }
    func muteMicrophone(_ muted: Bool) async { await sink.performNonthrowing { self.sink.writer?.micMuted = muted } }
    func muteSystem(_ muted: Bool) async { await sink.performNonthrowing { self.sink.writer?.systemMuted = muted } }

    func stop() async throws -> URL {
        guard !stopping else { throw RecordingFailure.message("Видео уже сохраняется.") }
        stopping = true; timer?.cancel(); timer = nil
        await sink.performNonthrowing { self.sink.writer?.pause(); self.sink.accepting = false }
        let video = videoStream, audio = audioStream, microphone = microphoneSession
        videoStream = nil; audioStream = nil; microphoneSession = nil
        async let stopVideo: Void? = try? video?.stopCapture()
        async let stopAudio: Void? = try? audio?.stopCapture()
        await sink.performNonthrowing { microphone?.stopRunning() }
        _ = await (stopVideo, stopAudio)
        return try await withCheckedThrowingContinuation { continuation in
            sink.queue.async {
                guard let writer = self.sink.writer else {
                    continuation.resume(throwing: RecordingFailure.message("Запись не успела начаться.")); return
                }
                writer.finish(on: self.sink.queue) { result in continuation.resume(with: result) }
                self.sink.writer = nil
            }
        }
    }
    static func outputSize(_ size: CGSize) -> CGSize {
        let scale = min(1, 3840 / max(size.width, size.height))
        return CGSize(width: max(2, floor(size.width * scale / 2) * 2),
                      height: max(2, floor(size.height * scale / 2) * 2))
    }
}

private final class RecordingSampleSink: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.zvon.video.media", qos: .userInitiated)
    var writer: RecordingWriter?
    var accepting = false
    var failed: ((Error) -> Void)?
    private var reported = false
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting else { return }
        if type == .screen {
            if let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let status = info.first?[.status] as? Int,
               status == SCFrameStatus.suspended.rawValue || status == SCFrameStatus.stopped.rawValue {
                report(RecordingFailure.message("Окно больше не передаёт изображение. Запись завершена.")); return
            }
            writer?.receiveVideo(sampleBuffer)
        }
        else if type == .audio { writer?.receiveAudio(sampleBuffer, microphone: false) }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard accepting else { return }; writer?.receiveAudio(sampleBuffer, microphone: true)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { queue.async { if self.accepting { self.report(error) } } }
    func report(_ error: Error) { guard !reported else { return }; reported = true; failed?(error) }
    func perform(_ action: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { do { try action(); c.resume() } catch { c.resume(throwing: error) } }
        }
    }
    func performNonthrowing(_ action: @escaping () -> Void) async { try? await perform(action) }
}
