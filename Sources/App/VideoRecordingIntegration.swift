import AppKit
import Combine
import KeyboardShortcuts
import ZVONScreenRecording

extension KeyboardShortcuts.Name {
    static let videoRegion = Self("videoRegion", default: .init(.v, modifiers: [.command, .shift]))
    static let videoStop = Self("videoStop", default: .init(.v, modifiers: [.command, .control, .shift]))
    static let videoPause = Self("videoPause", default: .init(.p, modifiers: [.command, .shift]))
}

@MainActor
final class VideoRecordingFeature {
    static let shared = VideoRecordingFeature()
    let controller = VideoRecordingController()
    private var registered = false
    private var phaseObserver: AnyCancellable?
    private var settingsObserver: AnyCancellable?
    func registerShortcuts() {
        guard !registered else { return }; registered = true
        if KeyboardShortcuts.getShortcut(for: .videoStop) == .init(.escape, modifiers: [.command, .control]) {
            KeyboardShortcuts.setShortcut(.init(.v, modifiers: [.command, .control, .shift]), for: .videoStop)
        }
        KeyboardShortcuts.onKeyUp(for: .videoRegion) { [weak self] in self?.region() }
        KeyboardShortcuts.onKeyUp(for: .videoStop) { [weak self] in self?.controller.stop() }
        KeyboardShortcuts.onKeyUp(for: .videoPause) { [weak self] in self?.controller.togglePause() }
        phaseObserver = controller.$phase.sink { [weak self] phase in self?.updateShortcuts(phase) }
        settingsObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }; self.updateShortcuts(self.controller.phase)
            }
    }
    private func updateShortcuts(_ phase: VideoRecordingController.Phase) {
        // Pause/stop must not steal other applications' shortcuts while no video is active.
        if phase == .starting || phase == .recording || phase == .paused { KeyboardShortcuts.enable(.videoStop) }
        else { KeyboardShortcuts.disable(.videoStop) }
        if phase == .recording || phase == .paused { KeyboardShortcuts.enable(.videoPause) }
        else { KeyboardShortcuts.disable(.videoPause) }
    }
    func region() {
        if controller.canStop { controller.stop(); return }
        ScreenshotFeature.shared.cancel(); controller.start()
    }
    func display() { ScreenshotFeature.shared.cancel(); controller.start(displayOnly: true) }
}
