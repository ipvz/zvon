import AppKit

/// The only app-facing object. Audio, transcripts and application state are deliberately absent.
@MainActor
public final class ScreenshotController {
    private let capture: any ScreenshotCapturing
    private let selector = ScreenshotSelectionController()
    private var captureTask: Task<Void, Never>?

    public init() { capture = ScreenshotCaptureService() }
    init(capture: any ScreenshotCapturing) { self.capture = capture }

    public func start(_ mode: ScreenshotCaptureMode = .region) {
        guard captureTask == nil else { return }
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer { captureTask = nil }
            do {
                // Let menus/popovers disappear before collecting a frozen frame.
                try await Task.sleep(for: .milliseconds(180))
                let environment = try await capture.prepare()
                try await selector.run(mode: mode, environment: environment, captureWindow: capture.capture)
            } catch is CancellationError {} catch {
                showError(error)
            }
        }
    }

    public func cancelCapture() { captureTask?.cancel(); selector.cancel() }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Не удалось сделать снимок"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if case ScreenshotError.permission = error {
            alert.addButton(withTitle: "Открыть настройки")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
