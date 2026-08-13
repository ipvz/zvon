import Foundation
import WhisperKit   // AudioProcessor (standalone mic capture)
import FluidAudio   // Language

/// Owns the speech engine (Parakeet TDT v3) and drives one or two VAD-segmented streams:
/// the microphone (Speaker.me) always, and — when capturing a call — system audio (Speaker.them)
/// via ScreenCaptureKit. A system-capture failure never takes down the mic stream.
///
/// Legacy `variant`/`folder`/`compute` args are ignored (kept so call sites are unchanged).
actor SpeechPipeline {
    private let onStatus: @Sendable (PipelineStatus) -> Void
    private let onEvent: @Sendable (Speaker, TranscriptionEvent) -> Void

    private var engine: ParakeetEngine?
    private var micStreamer: UtteranceTranscriber?
    private var sysStreamer: UtteranceTranscriber?

    init(
        onStatus: @escaping @Sendable (PipelineStatus) -> Void,
        onEvent: @escaping @Sendable (Speaker, TranscriptionEvent) -> Void
    ) {
        self.onStatus = onStatus
        self.onEvent = onEvent
    }

    func prepare(variant: String, folder: URL, compute: ComputePreference) async throws {
        _ = try await ensureEngine()
    }

    func start(variant: String, modelFolder: URL, language: String?, compute: ComputePreference,
               captureSystem: Bool, dictation: Bool = false,
               recorder: MeetingAudioRecorder? = nil) async throws {
        let engine = try await ensureEngine()
        await engine.setLanguage(language.flatMap(Language.parley))

        let onEvent = self.onEvent
        let micSource = MicAudioSource(AudioProcessor())
        if let recorder { micSource.onSamples = { recorder.append($0, from: .me) } }
        let mic = UtteranceTranscriber(
            decode: { await engine.decode($0) },
            source: micSource,
            // Dictation: tolerate longer thinking-pauses before ending the utterance (the key-release
            // closes it anyway) so a mid-sentence pause isn't mistaken for the end.
            config: dictation ? .dictation : UtteranceTranscriber.Config(),
            onEvent: { event in onEvent(.me, event) }
        )
        micStreamer = mic

        var sys: UtteranceTranscriber?
        if captureSystem, #available(macOS 14.2, *) {
            let sysSource = SystemAudioSource()
            if let recorder { sysSource.onSamples = { recorder.append($0, from: .them) } }
            sys = UtteranceTranscriber(
                decode: { await engine.decode($0) },
                source: sysSource,
                onEvent: { event in onEvent(.them, event) }
            )
            sysStreamer = sys
        }

        onStatus(.listening)
        DebugLog.log("pipeline.start → streams (mic\(sys != nil ? " + system" : ""))")

        // The mic is essential: propagate its failure (e.g. denied microphone permission) so the
        // store surfaces an error instead of hanging on "Слушаю" forever. System audio stays
        // isolated — its failure must never take the mic down.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await mic.run() }
            if let sys { group.addTask { try? await sys.run() } }
            try await group.waitForAll()
        }
        DebugLog.log("pipeline.start → streams ended")
    }

    func stop() async {
        DebugLog.log("pipeline.stop")
        await micStreamer?.stop()
        await sysStreamer?.stop()
        micStreamer = nil
        sysStreamer = nil
        onStatus(.idle)
    }

    func evictAll() {
        engine = nil
    }

    private func ensureEngine() async throws -> ParakeetEngine {
        if let engine { return engine }
        onStatus(.loadingModel)
        DebugLog.log("Parakeet load begin")
        let engine = ParakeetEngine(language: .russian)
        try await engine.load()
        DebugLog.log("Parakeet load done")
        self.engine = engine
        return engine
    }
}
