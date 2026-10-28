import AVFoundation
import Foundation

// Exercise the production conversion and teardown without microphone permissions by default.
enum DebugLog { static func log(_ message: String) {} }

final class MicrophoneFixture: MicrophoneEngine, @unchecked Sendable {
    let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 96000, channels: 1, interleaved: false)!
    var receiver: ((AVAudioPCMBuffer) -> Void)?
    var running = false, failStart = false
    var stops = 0, removals = 0, starts = 0
    var onRemove: (() -> Void)?
    func installTap(format: AVAudioFormat, _ receive: @escaping (AVAudioPCMBuffer) -> Void) {
        precondition(receiver == nil && !running)
        receiver = receive
    }
    func prepare() {}
    func start() throws {
        starts += 1
        if failStart { throw NSError(domain: "fixture", code: 1) }
        running = true
    }
    func stop() { running = false; stops += 1 }
    func removeTap() {
        precondition(!running, "Never remove the tap while hardware I/O is running")
        receiver = nil; removals += 1
        onRemove?()
    }
    func buffer() -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4096)!
        b.frameLength = b.frameCapacity
        for i in 0..<Int(b.frameLength) { b.floatChannelData![0][i] = Float(sin(Double(i) * 0.1)) * 0.1 }
        return b
    }
}

@main struct MicrophoneLifecycleTests {
    static func main() throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) { fputs("FAIL: microphone lifecycle timed out\n", stderr); exit(1) }
        if CommandLine.arguments.contains("--native") { try native(); return }
        for _ in 0..<100 {
            let driver = MicrophoneFixture()
            var source: MicAudioSource? = MicAudioSource(engine: driver, inputAvailable: { true })
            weak var released = source
            var previous: ((AVAudioPCMBuffer) -> Void)?
            for _ in 0..<3 {
                try source!.start(); try source!.start()
                previous?(driver.buffer())
                precondition(source!.snapshotSamples().isEmpty, "A previous run's callback must not feed a restarted source")
                let late = driver.receiver!
                late(driver.buffer())
                let count = source!.snapshotSamples().count
                precondition(count > 0, "96 kHz source must produce 16 kHz samples")
                source!.stop(); source!.stop()
                late(driver.buffer())
                precondition(source!.snapshotSamples().count == count, "Late callbacks must not append after stop")
                previous = late
            }
            precondition(driver.starts == 3 && driver.stops == 3 && driver.removals == 3, "Start/stop must be idempotent")
            source = nil
            precondition(released == nil && driver.stops == 3, "Stopped sources release without stopping hardware twice")
        }
        let failedDriver = MicrophoneFixture(); failedDriver.failStart = true
        let failed = MicAudioSource(engine: failedDriver, inputAvailable: { true })
        do { try failed.start(); preconditionFailure("Expected failed start") } catch {}
        precondition(failedDriver.starts == 3 && failedDriver.stops == 3 && failedDriver.removals == 3)
        failed.stop()
        precondition(failedDriver.stops == 3, "Failed starts must clean up before retry")

        let driver = MicrophoneFixture(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0), delivered = DispatchSemaphore(value: 0)
        let source = MicAudioSource(engine: driver, inputAvailable: { true })
        source.onSamples = { _ in entered.signal(); release.wait() }
        try source.start()
        let callback = driver.receiver!, samples = driver.buffer()
        DispatchQueue.global().async { callback(samples); delivered.signal() }
        precondition(entered.wait(timeout: .now() + 2) == .success)
        DispatchQueue.global().async { source.stop(); stopped.signal() }
        precondition(stopped.wait(timeout: .now() + 0.05) == .timedOut, "Stop must wait for in-flight conversion/archive callback")
        release.signal()
        precondition(delivered.wait(timeout: .now() + 2) == .success)
        precondition(stopped.wait(timeout: .now() + 2) == .success)
        let count = source.snapshotSamples().count
        callback(samples)
        precondition(source.snapshotSamples().count == count)
        // Drop the external owner while its callback is active. The callback's final release must
        // schedule HAL cleanup elsewhere, not stop the audio engine from its own audio thread.
        let orphanDriver = MicrophoneFixture(), callbackEntered = DispatchSemaphore(value: 0)
        let callbackReleased = DispatchSemaphore(value: 0), cleaned = DispatchSemaphore(value: 0)
        let ioQueue = DispatchQueue(label: "test.audio.callback")
        let ioKey = DispatchSpecificKey<Bool>(); ioQueue.setSpecific(key: ioKey, value: true)
        orphanDriver.onRemove = {
            precondition(DispatchQueue.getSpecific(key: ioKey) == nil, "HAL teardown must run off the callback queue")
            cleaned.signal()
        }
        var orphan: MicAudioSource? = MicAudioSource(engine: orphanDriver, inputAvailable: { true })
        orphan!.onSamples = { _ in callbackEntered.signal(); callbackReleased.wait() }
        try orphan!.start()
        let lastCallback = orphanDriver.receiver!, lastBuffer = orphanDriver.buffer()
        ioQueue.async { lastCallback(lastBuffer) }
        precondition(callbackEntered.wait(timeout: .now() + 2) == .success)
        orphan = nil; callbackReleased.signal()
        precondition(cleaned.wait(timeout: .now() + 2) == .success)
        print("PASS: 300 microphone restart cycles, 96→16 kHz conversion, stop-before-remove, idempotent teardown, partial-start cleanup, callback drain, stale-generation rejection and release off the audio thread")
    }

    static func native() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            print("SKIP: native microphone test needs existing microphone permission"); exit(77)
        }
        var heard = 0
        for index in 0..<40 {
            try autoreleasepool {
                let source = MicAudioSource()
                try source.start()
                if index % 4 == 0 {
                    let deadline = Date().addingTimeInterval(2)
                    while source.snapshotSamples().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                    precondition(!source.snapshotSamples().isEmpty, "Native microphone did not deliver samples")
                    heard += 1
                } else { Thread.sleep(forTimeInterval: Double(index % 3) * 0.01) }
                source.stop(); source.stop()
                let count = source.snapshotSamples().count
                Thread.sleep(forTimeInterval: 0.01)
                precondition(source.snapshotSamples().count == count)
            }
        }
        print("PASS: 40 native microphone start/stop cycles, \(heard) confirmed sample streams, no audio persisted")
    }
}
