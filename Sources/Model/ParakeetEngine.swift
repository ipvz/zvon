import Foundation
import FluidAudio

/// NVIDIA Parakeet TDT v3 via FluidAudio (CoreML/ANE). Multilingual incl. Russian, ~200× realtime
/// on Apple Silicon — decoding a whole utterance is effectively instant, which is what makes the
/// live transcription feel immediate. Batch decode per utterance (fresh decoder state each call).
actor ParakeetEngine {
    private var manager: AsrManager?
    private var language: Language?
    /// Serial chain so overlapping mic+system utterances never call `transcribe` concurrently.
    /// Actor isolation alone isn't enough: `decode` suspends at the `await`, letting a second
    /// caller reenter and race the same `AsrManager` buffers. We queue instead.
    private var tail: Task<Void, Never>?

    init(language: Language? = .russian) {
        self.language = language
    }

    var isLoaded: Bool { manager != nil }

    func setLanguage(_ language: Language?) { self.language = language }

    func load() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v3)   // multilingual
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    /// Transcribe a complete utterance (16 kHz mono). Returns "" on failure.
    /// Decodes are serialized through `tail`: a new call waits for the previous one to finish
    /// before touching the shared `AsrManager`, so mic and system streams can't corrupt each other.
    func decode(_ samples: [Float]) async -> (text: String, confidence: Float) {
        guard let manager else { return ("", 1) }
        let language = language
        let previous = tail
        let work = Task<(String, Float), Never> {
            _ = await previous?.value   // wait for the in-flight decode
            var state = TdtDecoderState.make()
            if let r = try? await manager.transcribe(samples, decoderState: &state, language: language) {
                return (r.text, r.confidence)   // confidence = mean token softmax prob (0.1…1.0), for GER gating
            }
            return ("", 1)
        }
        tail = Task { _ = await work.value }
        return await work.value
    }
}

extension Language {
    /// Map the app's language code to a Parakeet language (nil = auto-detect).
    static func parley(_ code: String) -> Language? {
        switch code {
        case "ru": return .russian
        case "en": return .english
        default: return nil
        }
    }
}
