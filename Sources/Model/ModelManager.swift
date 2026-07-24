import Foundation
import WhisperKit

/// Tracks which models are on disk and downloads missing ones with progress.
/// Single source of truth for both the Settings UI and the recording flow.
@MainActor
final class ModelManager: ObservableObject {
    enum DownloadState: Equatable {
        case notDownloaded
        case downloading(Double)   // 0…1
        case downloaded
    }

    @Published private(set) var states: [String: DownloadState] = [:]
    @Published private(set) var errors: [String: String] = [:]

    init() {
        refresh()
    }

    /// Re-scan the disk for every catalog model.
    func refresh() {
        for model in ModelCatalog.all {
            states[model.id] = ModelPaths.isDownloaded(model.id) ? .downloaded : .notDownloaded
        }
    }

    func state(_ id: String) -> DownloadState { states[id] ?? .notDownloaded }
    func isDownloaded(_ id: String) -> Bool { state(id) == .downloaded }

    /// Ensures the model is on disk, downloading it if needed. Returns the model folder.
    /// `onProgress` is called on the main actor (used by the recording flow's status line);
    /// the published `states` drive the Settings UI simultaneously.
    @discardableResult
    func ensureDownloaded(_ id: String, onProgress: ((Double) -> Void)? = nil) async throws -> URL {
        if ModelPaths.isDownloaded(id) {
            states[id] = .downloaded
            onProgress?(1)
            return ModelPaths.folder(for: id)
        }

        errors[id] = nil
        states[id] = .downloading(0)
        onProgress?(0)
        do {
            let url = try await WhisperKit.download(
                variant: id,
                downloadBase: ModelPaths.downloadBase
            ) { progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    self.states[id] = .downloading(fraction)
                    onProgress?(fraction)
                }
            }
            states[id] = .downloaded
            onProgress?(1)
            return url
        } catch {
            states[id] = .notDownloaded
            errors[id] = error.localizedDescription
            throw error
        }
    }

    /// Fire-and-forget download for the Settings "Скачать" button.
    func startDownload(_ id: String) {
        Task { try? await ensureDownloaded(id) }
    }
}
