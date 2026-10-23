import Foundation
import AVFoundation

/// Durable drafts stay until a verified export succeeds. Download names never overwrite files.
enum RecordingFiles {
    static var drafts: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parley/VideoDrafts", isDirectory: true)
    }
    static var downloads: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
    static func makeDraft() throws -> URL {
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return drafts.appendingPathComponent(UUID().uuidString + ".mov")
    }
    static func destination(in directory: URL = downloads) -> URL {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return directory.appendingPathComponent("ZVON \(formatter.string(from: Date())) \(UUID().uuidString.prefix(6)).mp4")
    }
    static func checkSpace(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let bytes = values.volumeAvailableCapacityForImportantUsage, bytes < 250_000_000 {
            throw RecordingFailure.message("На диске осталось меньше 250 МБ. Запись остановлена, чтобы сохранить видео.")
        }
    }
    static func export(_ draft: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: draft)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty, try await asset.load(.duration).seconds > 0 else {
            throw RecordingFailure.message("В записи нет видеокадров. Исходный файл сохранён для восстановления.")
        }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw RecordingFailure.message("Не удалось подготовить видео к сохранению.")
        }
        exporter.outputURL = destination; exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        await exporter.export()
        guard exporter.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw exporter.error ?? RecordingFailure.message("Не удалось сохранить MP4. Исходная запись сохранена.")
        }
        // Only remove a recoverable draft after checking the final container.
        let output = AVURLAsset(url: destination)
        guard try await output.load(.duration).seconds > 0,
              try await !output.loadTracks(withMediaType: .video).isEmpty else {
            throw RecordingFailure.message("Проверка готового видео не прошла. Исходная запись сохранена.")
        }
        try? FileManager.default.removeItem(at: draft)
    }
    static func recoverableDrafts() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: drafts, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "mov" }
    }
}
