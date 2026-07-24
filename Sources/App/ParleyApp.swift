import SwiftUI
import Combine
import AppKit

@main
struct ParleyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = TranscriptStore.shared

    private var scheme: ColorScheme? {
        switch store.themePref {
        case .light: return .light
        case .dark:  return .dark
        case .auto:  return nil
        }
    }

    var body: some Scene {
        Window("Parley", id: "main") {
            ZStack {
                MeetingView()
                    .environmentObject(store)
                    .environmentObject(store.models)
                if !store.onboardingDone {
                    OnboardingView().environmentObject(store)
                }
            }
            .preferredColorScheme(scheme)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1040, height: 680)
        .commands {
            // Settings live INSIDE the main window (no separate window). Replace the default
            // "Settings…" (⌘,) so it just switches the main window to the settings page.
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") { openSettingsInWindow() }.keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    private func openSettingsInWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.identifier?.rawValue == "main" { w.makeKeyAndOrderFront(nil) }
        store.pendingOpenSettings = true
    }
}

/// Owns the AppKit surfaces the SwiftUI App can't express: the menu-bar item and the floating widget.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var widget: FloatingWidgetController?
    private var dictationHUD: DictationHUDController?
    private var dictationHold: DictationHoldController?
    private var spaceMonitor: Any?
    private var themeCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = TranscriptStore.shared
        menuBar = MenuBarController(store: store)
        widget = FloatingWidgetController(store: store)
        dictationHUD = DictationHUDController(store: store)
        dictationHold = DictationHoldController(store: store)

        // Apply the Тема preference app-wide (SwiftUI scenes + every AppKit-hosted panel/popover).
        themeCancellable = store.$themePref.sink { pref in
            NSApplication.shared.appearance = pref == .auto ? nil
                : NSAppearance(named: pref == .dark ? .darkAqua : .aqua)
        }

        // Space = pause/resume while the main window is focused (spec §6) — but never when the
        // user is typing in a text field.
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49, store.isRecording,   // 49 = Space
                  let w = NSApp.keyWindow, w.identifier?.rawValue == "main",
                  !(w.firstResponder is NSText) else { return event }
            store.togglePause()
            return nil   // consume
        }
    }

    /// Closing the window keeps the app alive in the menu bar + floating widget (and any active
    /// recording). Reopen from the menu-bar popover / dock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
