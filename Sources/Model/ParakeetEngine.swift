import Foundation
import FluidAudio

/// NVIDIA Parakeet TDT via FluidAudio (CoreML/ANE) — Ultra, a post-trained v3 (same 25 languages,
/// same speed and memory), falling back to plain v3 if Ultra cannot be loaded. Multilingual incl.
/// Russian, ~100× realtime on Apple Silicon — decoding a whole utterance is effectively instant, which is what makes the
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

    /// Which model is actually serving, for the log and the settings screen.
    private(set) var loadedVersion = "none"

    /// Ultra measured on 150 Russian FLEURS phrases against v3, same decode path as here:
    /// WER 4.57 % vs 5.68 % (paired bootstrap Δ 1.11 pp, 95 % CI [0.39, 1.85]), CER 1.6 vs 2.1,
    /// 13.9 s vs 13.8 s for the set, peak footprint 111 vs 105 MB. Costs ~150 MB more on disk.
    func load() async throws {
        guard manager == nil else { return }
        for (name, version) in [("ultra", AsrModelVersion.ultra), ("v3", .v3)] {
            do {
                let models = try await AsrModels.downloadAndLoad(version: version)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                self.manager = manager
                loadedVersion = name
                DebugLog.log("Parakeet model: \(name)")
                return
            } catch {
                DebugLog.log("Parakeet \(name) failed to load: \(error.localizedDescription)")
                if name == "v3" { throw error }
            }
        }
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
                // confidence = mean token softmax prob (0.1…1.0), for GER gating
                return (Self.repairDashes(r.text), r.confidence)
            }
            return ("", 1)
        }
        tail = Task { _ = await work.value }
        return await work.value
    }
}

extension ParakeetEngine {
    /// Ultra sometimes emits " ? " where a dash belongs ("Апиа ? столица Самоа"; 6 of 150 phrases).
    /// A real question mark is attached to its word, so a lone one with spaces on both sides inside
    /// a sentence is that dash.
    static func repairDashes(_ text: String) -> String {
        text.replacingOccurrences(of: " ? ", with: " — ")
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
