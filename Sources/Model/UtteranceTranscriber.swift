import Foundation

/// VAD-segmented real-time transcription (Wispr Flow / WhisperLiveKit style), with the VAD loop
/// DECOUPLED from decoding. Emits `TranscriptionEvent`s for ONE audio stream; the pipeline tags
/// each stream with a `Speaker` (mic = me, system = them).
///
/// - A fast VAD loop (~12 Hz) tracks speech/silence with an adaptive, gain-robust energy
///   threshold and never calls the model, so it can't be blinded while decoding.
/// - A single serial worker decodes captured utterance slices in order: `.final` (a complete
///   utterance on a pause) and `.interim` (a best-effort preview of the current utterance).
/// - Empty output and canonical silence hallucinations are dropped.
actor UtteranceTranscriber {
    struct Config {
        var tick: Double = 0.08
        var endpointSilence: Float = 0.5
        var minUtterance: Float = 0.35
        var maxUtterance: Float = 18
        var preRoll: Float = 0.30   // rewind before onset so the word's attack + lead-in context is kept
                                    // (helps both first-word clipping and the model's accuracy on it)
        var showInterim: Bool = true
        var interimEvery: Double = 0.6
        var interimMinLen: Float = 0.5
        var isDictation = false     // push-to-talk: relax min-length/energy gates + flush on key-release

        /// Push-to-talk dictation: the key-release ends the utterance, so allow long thinking-pauses
        /// (≈1.6s) before auto-endpointing — a mid-sentence pause must not split the phrase. Also
        /// relaxes the min-length/energy gates so a quick short word («Алло») isn't dropped.
        static let dictation = Config(endpointSilence: 1.6, minUtterance: 0.15, maxUtterance: 45, isDictation: true)
    }

    private enum Job { case interim([Float]); case final([Float], Double) }

    private let decodeFn: @Sendable ([Float]) async -> (text: String, confidence: Float)
    private let source: LiveAudioSource
    private let onEvent: @Sendable (TranscriptionEvent) -> Void
    private let cfg: Config
    private let sr: Float = 16000

    private var running = false
    private var windowStartSample = 0
    private var utteranceStartAbs = 0
    private var inSpeech = false
    private var speechRun = 0          // consecutive speech ticks — confirms an onset (anti-spike)
    private var silenceRun: Float = 0
    private var noiseFloor: Float = 0.0010
    private var peakRMS: Float = 0.02
    private var utterancePeakRMS: Float = 0
    private var vadTick = 0
    private var lastInterimWall: Double = 0
    private var interimInFlight = false
    private var jobCont: AsyncStream<Job>.Continuation?

    private static let hallucinations = [
        "продолжение следует", "спасибо за просмотр", "спасибо за внимание",
        "субтитры", "редактор субтитров", "субтитры создавал", "субтитры делал",
        "субтитры сделал", "субтитры добавил", "корректор",
        "добро пожаловать", "подписывайтесь", "ставьте лайк", "не забудьте подписаться",
        "всем пока", "звучит музыка", "музыка играет", "аплодисменты",
        "thanks for watching", "thank you for watching", "please subscribe", "subtitles by",
    ]

    init(
        decode: @escaping @Sendable ([Float]) async -> (text: String, confidence: Float),
        source: LiveAudioSource,
        config: Config = Config(),
        onEvent: @escaping @Sendable (TranscriptionEvent) -> Void
    ) {
        self.decodeFn = decode
        self.source = source
        self.cfg = config
        self.onEvent = onEvent
    }

    func stop() { running = false }

    func run() async throws {
        try source.start()
        running = true
        DebugLog.log("utterance loop start")

        let (stream, cont) = AsyncStream<Job>.makeStream()
        jobCont = cont
        let worker = Task { [weak self] in
            for await job in stream { await self?.process(job) }
        }

        var lastWall = monotonicSeconds()
        // Observe cancellation: when a sibling stream throws, the task group cancels this one. Without
        // the isCancelled checks the `try?`-swallowed sleep would busy-spin at 100% CPU, leak the audio
        // tap (source.stop() below never runs), and hang the group so the real error is never surfaced.
        while running && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 40_000_000)
            if !running || Task.isCancelled { break }
            let now = monotonicSeconds()
            let dt = Float(now - lastWall)
            guard dt >= Float(cfg.tick) else { continue }
            lastWall = now

            let samples = source.snapshotSamples()
            let energy = source.snapshotEnergy()
            let nowAbs = windowStartSample + samples.count
            guard samples.count > Int(0.2 * sr) else { onEvent(.meter(energy)); continue }

            let rms = Self.rms(of: samples, lastSeconds: 0.18, sr: sr)
            peakRMS = max(peakRMS * powf(0.5, dt), rms)
            let threshold = max(0.0026, noiseFloor + (peakRMS - noiseFloor) * 0.16)
            let speech = rms > threshold
            vadTick += 1
            if vadTick % 6 == 0 {
                DebugLog.trace("vad dt=\(String(format: "%.2f", dt)) rms=\(String(format: "%.4f", rms)) thr=\(String(format: "%.4f", threshold)) speech=\(speech) sil=\(String(format: "%.2f", silenceRun))")
            }

            if speech {
                speechRun += 1
                // Confirm the onset over ≥2 ticks so a single spike / click / keystroke can't
                // start a false utterance. preRoll below rewinds to include the confirming ticks.
                if !inSpeech, speechRun >= 2 {
                    inSpeech = true
                    let backTicks = cfg.preRoll + Float(speechRun) * Float(cfg.tick)
                    utteranceStartAbs = max(utteranceStartAbs, nowAbs - Int(backTicks * sr))
                    utterancePeakRMS = 0
                }
                if inSpeech {
                    silenceRun = 0
                    utterancePeakRMS = max(utterancePeakRMS, rms)

                    let uttLen = Float(nowAbs - utteranceStartAbs) / sr
                    if cfg.showInterim, uttLen >= cfg.interimMinLen, !interimInFlight, now - lastInterimWall >= cfg.interimEvery {
                        if let slice = sliceOf(from: utteranceStartAbs, to: nowAbs, window: samples) {
                            interimInFlight = true
                            lastInterimWall = now
                            jobCont?.yield(.interim(slice))
                        }
                    }
                    if uttLen >= cfg.maxUtterance { endpoint(endAbs: nowAbs, window: samples) }
                }
            } else {
                speechRun = 0
                noiseFloor = max(0.0002, noiseFloor + (rms - noiseFloor) * min(1, dt * 0.5))
                silenceRun += dt
                if inSpeech && silenceRun >= cfg.endpointSilence {
                    endpoint(endAbs: nowAbs - Int(silenceRun * sr), window: samples)
                } else if !inSpeech {
                    // Nobody speaking (endpoint() only purges while inSpeech): roll the buffer so a
                    // quiet room / listening-only participant can't grow the window unbounded.
                    let windowSec = Float(nowAbs - windowStartSample) / sr
                    if windowSec > cfg.preRoll + 2.0 {
                        let keep = Int((cfg.preRoll + 1.0) * sr)
                        if keep < samples.count {
                            source.purge(keepingLast: keep)
                            windowStartSample = nowAbs - keep
                            utteranceStartAbs = max(utteranceStartAbs, windowStartSample)
                        }
                    }
                }
            }
            onEvent(.meter(energy))
        }

        let tail = source.snapshotSamples()
        // On key-release / stop, flush the tail. For dictation flush even if the VAD never latched
        // onset, so a short/quiet word said during the hold isn't lost (push-to-talk boundary = key).
        // A cancelled stream (sibling failed) must not emit a spurious final from its aborted tail.
        if !Task.isCancelled, inSpeech || cfg.isDictation { endpoint(endAbs: windowStartSample + tail.count, window: tail) }
        jobCont?.finish()
        await worker.value
        source.stop()
        onEvent(.ended)
        DebugLog.log("utterance loop end")
    }

    // MARK: - Endpoint (energy-gated) → job

    private func endpoint(endAbs: Int, window samples: [Float]) {
        let start = utteranceStartAbs
        let peak = utterancePeakRMS
        inSpeech = false
        silenceRun = 0
        utterancePeakRMS = 0
        utteranceStartAbs = max(utteranceStartAbs, endAbs)

        let lenSec = Float(endAbs - start) / sr
        guard lenSec >= cfg.minUtterance, let slice = sliceOf(from: start, to: endAbs, window: samples) else {
            purgeProcessedAudio(currentWindowCount: samples.count); return
        }
        // Energy gate. Meetings: strict peak-vs-noise-floor to reject room noise. Dictation: the user
        // deliberately held the key, so measure the slice directly with a low floor — a quiet short
        // word still passes; only true silence is dropped.
        let energyOK: Bool
        if cfg.isDictation {
            var sum: Float = 0; for v in slice { sum += v * v }
            let e = slice.isEmpty ? 0 : (sum / Float(slice.count)).squareRoot()
            energyOK = e > 0.0025
        } else {
            energyOK = peak > max(0.0045, noiseFloor * 2.0)
        }
        if energyOK { jobCont?.yield(.final(slice, Double(start) / Double(sr))) }
        purgeProcessedAudio(currentWindowCount: samples.count)
    }

    // MARK: - Serial decode worker

    private func process(_ job: Job) async {
        switch job {
        case .interim(let slice):
            let text = await decode(slice).text
            interimInFlight = false
            if inSpeech, !text.isEmpty { onEvent(.interim(text)) }
        case .final(let slice, let startSec):
            let r = await decode(slice)
            if r.text.isEmpty || Self.isLikelyNoise(r.text, r.confidence, dictation: cfg.isDictation) {
                if !r.text.isEmpty {
                    DebugLog.log("final DROPPED (noise) conf=\(String(format: "%.2f", r.confidence)): «\(r.text.prefix(24))»")
                }
                onEvent(.interim(""))   // clear a stale preview if the final was rejected
            } else {
                DebugLog.log("final +\(r.text.count) @\(String(format: "%.1f", startSec))s conf=\(String(format: "%.2f", r.confidence))")
                onEvent(.final(text: r.text, startSec: startSec, confidence: r.confidence))
            }
        }
    }

    /// Reject background-noise hallucinations by the ASR's own confidence (mean token softmax, 0.1…1.0).
    /// CONSERVATIVE so real speech is never lost: hard-drop only very-uncertain text, and short blips only
    /// when uncertain AND not a common short reply. Doesn't touch the audio → zero effect on real quality.
    private static let shortWhitelist: Set<String> = [
        "да", "нет", "ок", "окей", "угу", "ага", "хорошо", "точно", "верно", "понятно",
        "привет", "пока", "спасибо", "конечно", "именно", "возможно", "супер", "отлично",
    ]
    private static func isLikelyNoise(_ text: String, _ confidence: Float, dictation: Bool = false) -> Bool {
        // Real speech logs at 0.83–0.99, so these floors keep a huge margin — they only catch
        // near-certain garbage and never eat a real word.
        if confidence < 0.20 { return true }
        // The short-word blip rule guards against ambient meeting noise; in push-to-talk the user
        // deliberately spoke, so don't drop a short word like «Алло» just because it's brief.
        if !dictation, confidence < 0.30, text.count <= 5, !shortWhitelist.contains(text.lowercased()) { return true }
        return false
    }

    private func decode(_ slice: [Float]) async -> (text: String, confidence: Float) {
        let r = await decodeFn(slice)
        return (Self.clean(r.text), r.confidence)
    }

    private static func clean(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        // No letters/digits at all → pure punctuation artifact ("…", ".", "-") → drop.
        guard text.rangeOfCharacter(from: .alphanumerics) != nil else { return "" }
        let low = text.lowercased()
        for phrase in hallucinations where low == phrase || low.contains(phrase) { return "" }
        return text
    }

    // MARK: - Helpers

    private func sliceOf(from: Int, to: Int, window samples: [Float]) -> [Float]? {
        let lo = max(0, from - windowStartSample)
        let hi = min(samples.count, to - windowStartSample)
        guard hi - lo > Int((cfg.isDictation ? 0.1 : 0.2) * sr) else { return nil }
        return Array(samples[lo..<hi])
    }

    private func purgeProcessedAudio(currentWindowCount: Int) {
        let keepFrom = max(windowStartSample, utteranceStartAbs - Int(0.3 * sr))
        guard keepFrom > windowStartSample else { return }
        let total = windowStartSample + currentWindowCount
        let keepCount = total - keepFrom
        guard keepCount > 0, keepCount < currentWindowCount else { return }
        source.purge(keepingLast: keepCount)
        windowStartSample = keepFrom
    }

    private static func rms(of samples: [Float], lastSeconds: Float, sr: Float) -> Float {
        let n = min(samples.count, Int(lastSeconds * sr))
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for x in samples.suffix(n) { sum += x * x }
        return (sum / Float(n)).squareRoot()
    }

    private func monotonicSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
