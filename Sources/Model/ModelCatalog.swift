import Foundation

/// A WhisperKit CoreML model variant offered to the user.
struct ModelInfo: Identifiable, Equatable {
    /// Folder name in the `argmaxinc/whisperkit-coreml` repo — used verbatim by WhisperKit.
    let id: String
    let title: String
    let sizeMB: Int
    let multilingual: Bool
    let recommended: Bool
    let note: String
}

/// Curated shortlist. Kept small on purpose — the full repo has dozens of variants,
/// most irrelevant for a Russian-speaking, Apple-Silicon meeting assistant.
enum ModelCatalog {
    static let all: [ModelInfo] = [
        ModelInfo(
            id: "openai_whisper-large-v3-v20240930_turbo_632MB",
            title: "Large v3 Turbo",
            sizeMB: 632, multilingual: true, recommended: true,
            note: "Лучший баланс: русский + скорость"
        ),
        ModelInfo(
            id: "openai_whisper-large-v3-v20240930_turbo",
            title: "Large v3 Turbo (полная)",
            sizeMB: 1560, multilingual: true, recommended: false,
            note: "Максимум качества, тяжелее и медленнее"
        ),
        ModelInfo(
            id: "openai_whisper-small",
            title: "Small",
            sizeMB: 216, multilingual: true, recommended: false,
            note: "Лёгкая и быстрая, качество ниже"
        ),
        ModelInfo(
            id: "openai_whisper-base",
            title: "Base",
            sizeMB: 145, multilingual: true, recommended: false,
            note: "Самая лёгкая, для быстрой проверки"
        ),
        ModelInfo(
            id: "distil-whisper_distil-large-v3_turbo_600MB",
            title: "Distil Large v3 Turbo",
            sizeMB: 600, multilingual: false, recommended: false,
            note: "Только английский, очень быстро"
        ),
    ]

    static let defaultModelID = all[0].id

    static func info(_ id: String) -> ModelInfo? { all.first { $0.id == id } }
}

/// Where WhisperKit stores downloaded models. Mirrors WhisperKit's default layout so we can
/// detect already-present models without touching the network.
enum ModelPaths {
    static let repo = "argmaxinc/whisperkit-coreml"

    static var downloadBase: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface")
    }

    static func folder(for variant: String) -> URL {
        downloadBase.appendingPathComponent("models/\(repo)/\(variant)")
    }

    /// A model counts as present once its CoreML compute units are on disk.
    static func isDownloaded(_ variant: String) -> Bool {
        let marker = folder(for: variant).appendingPathComponent("AudioEncoder.mlmodelc")
        return FileManager.default.fileExists(atPath: marker.path)
    }

    static func sizeOnDiskMB(for variant: String) -> Int? {
        let url = folder(for: variant)
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        var total = 0
        for case let file as URL in en {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total > 0 ? total / 1_000_000 : nil
    }
}
