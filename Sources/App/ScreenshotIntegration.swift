import AppKit
import KeyboardShortcuts
import ZVONScreenshots

extension KeyboardShortcuts.Name {
    static let screenshotRegion = Self("screenshotRegion", default: .init(.a, modifiers: [.command, .shift]))
    static let screenshotDisplay = Self("screenshotDisplay", default: .init(.three, modifiers: [.command, .option]))
}

/// App integration only: the screenshot module owns its windows, capture and documents.
@MainActor
final class ScreenshotFeature {
    static let shared = ScreenshotFeature()
    private let controller = ScreenshotController()
    private var registered = false

    func registerShortcuts() {
        guard !registered else { return }
        registered = true
        let migration = "screenshotShortcutCommandShiftAMigrated"
        if !UserDefaults.standard.bool(forKey: migration) {
            // Upgrade the previous default once, without resetting later user customization.
            if KeyboardShortcuts.getShortcut(for: .screenshotRegion) == .init(.four, modifiers: [.command, .option]) {
                KeyboardShortcuts.setShortcut(.init(.a, modifiers: [.command, .shift]), for: .screenshotRegion)
            }
            UserDefaults.standard.set(true, forKey: migration)
        }
        KeyboardShortcuts.onKeyDown(for: .screenshotRegion) { [weak self] in self?.region(fromShortcut: true) }
        KeyboardShortcuts.onKeyDown(for: .screenshotDisplay) { [weak self] in self?.display(fromShortcut: true) }
    }
    func cancel() { controller.cancelCapture() }
    func region(fromShortcut: Bool = false) {
        guard !VideoRecordingFeature.shared.controller.isBusy else { return }
        controller.start(.region, afterMenuDismissal: !fromShortcut)
    }
    func display(fromShortcut: Bool = false) {
        guard !VideoRecordingFeature.shared.controller.isBusy else { return }
        controller.start(.display, afterMenuDismissal: !fromShortcut)
    }
}
