import Foundation
import FluidAudio   // Language

/// Owns the speech engine (Parakeet TDT v3) and drives one or two VAD-segmented streams:
/// the microphone (Speaker.me) always, and — when capturing a call — system audio (Speaker.them)
/// via ScreenCaptureKit. A system-capture failure never takes down the mic stream.
///
/// Legacy `variant`/`folder`/`compute` args are ignored (kept so call sites are unchanged).
actor SpeechPipeline {
    private let onStatus: @Sendable (PipelineStatus) async -> Void
    private let onEvent: @Sendable (Speaker, TranscriptionEvent) async -> Void

    private var engine: ParakeetEngine?
    private var engineLoad: (id: UUID, task: Task<ParakeetEngine, Error>)?
    private var engineGeneration = 0

    init(
        onStatus: @escaping @Sendable (PipelineStatus) async -> Void,
        onEvent: @escaping @Sendable (Speaker, TranscriptionEvent) async -> Void
    ) {
        self.onStatus = onStatus
        self.onEvent = onEvent
    }

    func prepare(variant: String, folder: URL, compute: ComputePreference) async throws {
        _ = try await ensureEngine()
    }

    func start(variant: String, modelFolder: URL, language: String?, compute: ComputePreference,
               captureSystem: Bool, dictation: Bool = false,
               session: CaptureSession,
               recorder: MeetingAudioRecorder? = nil) async throws {
        guard !session.isStopped else { return }
        let engine = try await ensureEngine()
        guard !session.isStopped else { return }
        await engine.setLanguage(language.flatMap(Language.parley))
        guard !session.isStopped else { return }

        let onEvent = self.onEvent, onStatus = self.onStatus
        let micSource = MicAudioSource()
        if let recorder { micSource.onSamples = { recorder.append($0, from: .me) } }
        let mic = UtteranceTranscriber(
            decode: { await engine.decode($0) },
            source: micSource,
            // Dictation: tolerate longer thinking-pauses before ending the utterance (the key-release
            // closes it anyway) so a mid-sentence pause isn't mistaken for the end.
            config: dictation ? .dictation : UtteranceTranscriber.Config(),
            session: session,
            onReady: { await onStatus(.listening) },
            onEvent: { event in await onEvent(.me, event) }
        )

        var sys: UtteranceTranscriber?
        if captureSystem, #available(macOS 14.2, *) {
            let sysSource = SystemAudioSource()
            if let recorder { sysSource.onSamples = { recorder.append($0, from: .them) } }
            sys = UtteranceTranscriber(
                decode: { await engine.decode($0) },
                source: sysSource,
                session: session,
                onEvent: { event in await onEvent(.them, event) }
            )
        }

        DebugLog.log("pipeline.start → streams (mic\(sys != nil ? " + system" : ""))")

        // The mic is essential: propagate its failure (e.g. denied microphone permission) so the
        // store surfaces an error instead of hanging on "Слушаю" forever. System audio stays
        // isolated — its failure must never take the mic down.
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await mic.run() }
                if let sys {
                    group.addTask {
                        do { try await sys.run() }
                        catch { DebugLog.log("system capture failed: \(error.localizedDescription)") }
                    }
                }
                // next() throws as soon as a stream fails. waitForAll() waits for the still-live
                // sibling first and can therefore hide a microphone error indefinitely.
                while try await group.next() != nil {}
            }
        } catch {
            await onStatus(.idle)
            throw error
        }
        await onStatus(.idle)
        DebugLog.log("pipeline.start → streams ended")
    }

    func evictAll() {
        engineGeneration += 1
        engine = nil
        // Do not spawn a second CoreML compilation if the old one is still running.
    }

    private func ensureEngine() async throws -> ParakeetEngine {
        if let engine { return engine }
        let generation = engineGeneration
        let load: (id: UUID, task: Task<ParakeetEngine, Error>)
        if let engineLoad {
            load = engineLoad
        } else {
            let task = Task {
                DebugLog.log("Parakeet load begin")
                let engine = ParakeetEngine(language: .russian)
                try await engine.load()
                DebugLog.log("Parakeet load done")
                return engine
            }
            load = (UUID(), task)
            engineLoad = load
        }
        await onStatus(.loadingModel)
        do {
            let loaded = try await load.task.value
            guard generation == engineGeneration else { throw CancellationError() }
            engine = loaded
            if engineLoad?.id == load.id { engineLoad = nil }
            return loaded
        } catch {
            if engineLoad?.id == load.id { engineLoad = nil }
            throw error
        }
    }
}
