import AppKit
import UniformTypeIdentifiers

@MainActor
enum ScreenshotExporter {
    static func copy(_ document: ScreenshotDocument) async throws {
        let image = try await document.flattened()
        let data = try await Task.detached(priority: .userInitiated) { try ScreenshotRenderer.encoded(image) }.value
        try Task.checkCancellation()
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setData(data, forType: .png) else { throw ScreenshotError.export }
    }

    static func save(_ document: ScreenshotDocument, parent: NSWindow) async throws -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "ZVON \(formatter.string(from: Date())).png"
        let response = await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: parent) { continuation.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return false }
        try Task.checkCancellation()
        let image = try await document.flattened()
        let type: UTType = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
        try await Task.detached(priority: .userInitiated) {
            let data = try ScreenshotRenderer.encoded(image, type: type)
            try data.write(to: url, options: .atomic)
        }.value
        return true
    }
}
