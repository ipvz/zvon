import Foundation

// Standalone capture seam: exercise the production transcriber without opening a microphone
// or loading CoreML. Run with scripts/test-capture-lifecycle.sh.
protocol LiveAudioSource: AnyObject, Sendable {
    func start() throws
    func stop()
    func snapshotSamples() -> [Float]
    func snapshotEnergy() -> [Float]
    func purge(keepingLast: Int)
}

enum DebugLog {
    static func log(_ message: String) {}
    static func trace(_ message: @autoclosure () -> String) {}
}

final class FakeAudioSource: LiveAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var samples: [Float]
    let onStart: @Sendable () -> Void

    init(samples: [Float] = [], onStart: @escaping @Sendable () -> Void = {}) {
        self.samples = samples
        self.onStart = onStart
    }

    func start() throws {
        lock.lock(); starts += 1; lock.unlock()
        onStart()
    }
    func stop() { lock.lock(); stops += 1; lock.unlock() }
    func snapshotSamples() -> [Float] {
        lock.lock(); defer { lock.unlock() }; return samples
    }
    func snapshotEnergy() -> [Float] { [0.4] }
    func purge(keepingLast count: Int) {
        lock.lock(); defer { lock.unlock() }
        samples = Array(samples.suffix(count))
    }
    var counts: (starts: Int, stops: Int) {
        lock.lock(); defer { lock.unlock() }; return (starts, stops)
    }
}

final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var finals: [String] = []
    private var readyCount = 0
    func ready() { lock.lock(); readyCount += 1; lock.unlock() }
    var readiness: Int { lock.lock(); defer { lock.unlock() }; return readyCount }
    func receive(_ event: TranscriptionEvent) {
        if case .final(let text, _, _) = event {
            lock.lock(); finals.append(text); lock.unlock()
        }
    }
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return finals }
}

@main struct CaptureLifecycleTests {
    static func main() async throws {
        // A broken stop-before-run implementation loops forever. Fail independently of the
        // cooperative task executor, rather than using a task-group timeout that also hangs.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            fputs("FAIL: capture did not stop within 10 seconds\n", stderr)
            exit(1)
        }

        try await TimeoutTests.run()

        let stoppedSource = FakeAudioSource()
        let stopped = UtteranceTranscriber(decode: { _ in ("", 1) }, source: stoppedSource, onEvent: { _ in })
        await stopped.stop()
        try await stopped.run()
        precondition(stoppedSource.counts.starts == 0, "stop before run must not open the mic")
        print("PASS: stop before run stays stopped")

        let earlySession = CaptureSession()
        earlySession.stop()
        let earlySource = FakeAudioSource()
        let early = UtteranceTranscriber(decode: { _ in ("", 1) }, source: earlySource,
                                         session: earlySession, onEvent: { _ in })
        try await early.run()
        precondition(earlySource.counts.starts == 0)
        print("PASS: stop before stream construction stays stopped")

        let emptySession = CaptureSession()
        let emptySource = FakeAudioSource()
        let emptyEvents = Events()
        let empty = UtteranceTranscriber(decode: { _ in ("", 1) }, source: emptySource,
            session: emptySession, onReady: { emptyEvents.ready() }, onEvent: { event in
                if case .meter = event { emptySession.stop() }
            })
        try await empty.run()
        precondition(emptyEvents.readiness == 0, "An opened device without audio must never report listening")
        print("PASS: microphone readiness waits for actual samples")

        for _ in 0..<100 {
            let session = CaptureSession()
            let source = FakeAudioSource(onStart: { session.stop() })
            let stream = UtteranceTranscriber(decode: { _ in ("", 1) }, source: source,
                                              session: session, onEvent: { _ in })
            try await stream.run()
            precondition(source.counts.starts == 1 && source.counts.stops == 1)
        }
        print("PASS: 100 releases during microphone startup terminate and close the source")

        let activeSession = CaptureSession()
        let activeSource = FakeAudioSource(samples: [Float](repeating: 0.03, count: 8_000))
        let events = Events()
        let active = UtteranceTranscriber(decode: { samples in
            precondition(activeSource.counts.stops == 1, "mic must close before final decoding")
            precondition(samples.count == 8_000, "release must retain the entire short utterance")
            return ("Проверка записи", 0.99)
        }, source: activeSource, config: .dictation, session: activeSession,
        onReady: {
            precondition(activeSource.counts.starts == 1 && !activeSource.snapshotSamples().isEmpty)
            events.ready()
        }, onEvent: { event in
            if case .final = event { try? await Task.sleep(nanoseconds: 100_000_000) }
            events.receive(event)
            if case .meter = event { activeSession.stop() }
        })
        try await active.run()
        precondition(events.texts == ["Проверка записи"])
        precondition(activeSource.counts.stops == 1)
        precondition(events.readiness == 1)
        print("PASS: normal release waits for slow final delivery and closes capture before decoding")

        let longSession = CaptureSession()
        let longSource = FakeAudioSource(samples: [Float](repeating: 0.03, count: 16_000))
        let longEvents = Events()
        let longStream = UtteranceTranscriber(decode: { samples in
            precondition(longSource.counts.stops == 1, "dictation must not waste work on invisible previews")
            precondition(samples.count == 16_000, "Delayed VAD onset must retain the prefix captured from key press")
            return ("Длинная фраза", 0.99)
        }, source: longSource, config: .dictation, session: longSession, onEvent: { longEvents.receive($0) })
        let release = Task {
            try await Task.sleep(nanoseconds: 850_000_000)
            longSession.stop()
        }
        try await longStream.run()
        try await release.value
        precondition(longEvents.texts == ["Длинная фраза"])
        print("PASS: dictation avoids repeated previews and still emits the complete final")

        let delayedSession = CaptureSession()
        let prefix = [Float](repeating: 0.03, count: 8_000)
        let delayedSource = FakeAudioSource(samples: prefix + [Float](repeating: 0, count: 56_000))
        let delayedEvents = Events()
        let delayed = UtteranceTranscriber(decode: { samples in
            precondition(samples.count == 64_000 && Array(samples.prefix(8_000)) == prefix,
                         "A short first word must survive even if the first VAD observation sees only later silence")
            return ("Первое слово", 0.99)
        }, source: delayedSource, config: .dictation, session: delayedSession, onEvent: { event in
            delayedEvents.receive(event)
            if case .meter = event { delayedSession.stop() }
        })
        try await delayed.run()
        precondition(delayedEvents.texts == ["Первое слово"])
        print("PASS: first word retained across delayed VAD and trailing silence")

        let silentSession = CaptureSession()
        let silentSource = FakeAudioSource(samples: [Float](repeating: 0, count: 48_000))
        var bounded = UtteranceTranscriber.Config.dictation
        bounded.maxUtterance = 1
        let silent = UtteranceTranscriber(decode: { _ in
            preconditionFailure("Silence must not be sent to the model")
        }, source: silentSource, config: bounded, session: silentSession, onEvent: { event in
            if case .meter = event {
                precondition(silentSource.snapshotSamples().count <= 4_801, "Silent dictation must retain only bounded overlap")
                silentSession.stop()
            }
        })
        try await silent.run()
        print("PASS: silence-only dictation stays bounded without decoding noise")

        let freshSession = CaptureSession()
        let freshSource = FakeAudioSource(onStart: { freshSession.stop() })
        let fresh = UtteranceTranscriber(decode: { _ in ("", 1) }, source: freshSource,
                                         session: freshSession, onEvent: { _ in })
        try await fresh.run()
        precondition(freshSource.counts.starts == 1 && freshSource.counts.stops == 1)
        print("PASS: the next session opens and closes independently of the previous release")
    }
}
