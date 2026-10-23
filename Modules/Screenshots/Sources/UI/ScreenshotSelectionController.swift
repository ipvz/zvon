import AppKit

@MainActor
final class ScreenshotSelectionController {
    private var panels: [ScreenshotSelectionPanel] = []
    private var continuation: CheckedContinuation<Void, Error>?
    private var sessionID: UUID?

    func run(mode: ScreenshotCaptureMode, environment: ScreenshotEnvironment,
             captureWindow: @escaping (ScreenshotWindow) async throws -> CGImage,
             targetToolbar: ((@escaping () -> Void) -> NSView)? = nil,
             selectedTarget: ((ScreenCaptureTarget) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        let sessionID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(); return }
                self.continuation = continuation
                self.sessionID = sessionID
                for display in environment.displays {
                    let panel = ScreenshotSelectionPanel(contentRect: display.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    panel.identifier = NSUserInterfaceItemIdentifier("zvon.screenshot.selection")
                    panel.level = .screenSaver
                    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                    panel.isOpaque = true; panel.hasShadow = false
                    panel.acceptsMouseMovedEvents = true; panel.isReleasedWhenClosed = false
                    let view = ScreenshotSelectionView(display: display, mode: mode, windows: environment.windows)
                    view.captureWindow = captureWindow
                    view.targetToolbarFactory = targetToolbar
                    view.selectedTarget = { [weak self] target in
                        selectedTarget?(target); self?.finish(sessionID: sessionID)
                    }
                    view.finish = { [weak self] in self?.finish(sessionID: sessionID) }
                    view.didSelect = { [weak self, weak view] in
                        guard let self else { return }
                        for panel in panels {
                            if let other = panel.contentView as? ScreenshotSelectionView, other !== view { other.resetSelection() }
                        }
                    }
                    view.saving = { [weak self] saving in
                        for panel in self?.panels ?? [] { panel.level = saving ? .floating : .screenSaver }
                    }
                    panel.contentView = view; panel.setFrame(display.frame, display: true)
                    panels.append(panel); panel.orderFrontRegardless()
                }
                let active = panels.first { $0.frame.contains(NSEvent.mouseLocation) } ?? panels.first
                active?.makeKey(); active?.makeFirstResponder(active?.contentView)
                for panel in panels {
                    guard let view = panel.contentView as? ScreenshotSelectionView else { continue }
                    view.updateHover(globalPoint: NSEvent.mouseLocation)
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(sessionID: sessionID) } }
    }

    func cancel() { finish() }
    func bringForward() {
        // Repeated shortcuts recover focus without activating the application or
        // replacing the selection, annotations, or an in-progress text edit.
        for panel in panels { panel.orderFrontRegardless() }
        let active = panels.first { $0.frame.contains(NSEvent.mouseLocation) } ?? panels.first
        if active?.isKeyWindow == false { active?.makeKey() }
    }
    private func finish(sessionID expected: UUID? = nil) {
        if let expected, expected != sessionID { return }
        guard let continuation else { return }
        self.continuation = nil; sessionID = nil
        for panel in panels {
            (panel.contentView as? ScreenshotSelectionView)?.resetSelection()
            panel.orderOut(nil); panel.contentView = nil; panel.close()
        }
        panels.removeAll()
        continuation.resume()
    }
}

final class ScreenshotSelectionPanel: NSPanel {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        // A key nonactivating panel receives typing without raising the app's
        // document windows or switching away from the user's current Space.
        super.init(contentRect: contentRect, styleMask: styleMask.union(.nonactivatingPanel), backing: backing, defer: flag)
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        // Control shortcuts are not consistently delivered as AppKit key equivalents.
        // Handle them at the panel boundary, including when a SwiftUI control has focus.
        if handleScreenshotShortcut(event) { return }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleScreenshotShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    private func handleScreenshotShortcut(_ event: NSEvent) -> Bool {
        guard ScreenshotShortcut(event) != nil else { return false }
        // Command C/Z remain normal text-editing commands. Control C explicitly
        // copies the screenshot, committing the draft through the normal export path.
        if firstResponder is NSText, !ScreenshotShortcut.isControlCopy(event) { return false }
        return (contentView as? ScreenshotSelectionView)?.handleCommand(event) ?? false
    }
}

/// Hardware key positions keep shortcuts stable across English/Russian input sources.
enum ScreenshotShortcut {
    case copy, save, undo, redo

    init?(_ event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (event.keyCode, modifiers) {
        case (8, .control), (8, .command): self = .copy
        case (1, .command): self = .save
        case (6, .command): self = .undo
        case (6, [.command, .shift]): self = .redo
        default: return nil
        }
    }

    static func isControlCopy(_ event: NSEvent) -> Bool {
        ScreenshotShortcut(event) == .copy && event.modifierFlags.contains(.control)
    }
}
