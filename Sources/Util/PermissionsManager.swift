import Foundation
import AVFoundation
import AppKit
import ApplicationServices
import EventKit

enum PermState { case granted, denied, notDetermined, unknown }

/// Tracks the OS permissions Parley needs and drives the onboarding + settings status rows.
/// Mic and Accessibility are queryable; system-audio (Core Audio process taps) has no public
/// preflight — it prompts on first capture — so it's informational/optional here.
@MainActor
final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    @Published var mic: PermState = .notDetermined
    @Published var accessibility: PermState = .notDetermined
    @Published var screen: PermState = .notDetermined
    @Published var calendar: PermState = .notDetermined
    @Published var reminders: PermState = .notDetermined
    @Published var error: String?

    func refresh() {
        mic = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        accessibility = AXIsProcessTrusted() ? .granted : .notDetermined
        screen = CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        calendar = Self.map(EKEventStore.authorizationStatus(for: .event))
        reminders = Self.map(EKEventStore.authorizationStatus(for: .reminder))
    }

    /// Native mic prompt (no-op if already decided → then only System Settings can change it).
    func requestMic() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        mic = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// Accessibility can't be granted programmatically — show the system prompt + open the pane.
    func requestAccessibility() {
        TextInserter.requestAccessibility()
        openSettings(.accessibility)
    }

    func requestScreen() {
        if !CGRequestScreenCaptureAccess() { openSettings(.screen) }
        refresh()
    }

    func requestCalendar() async { await requestEventAccess(.event) }
    func requestReminders() async { await requestEventAccess(.reminder) }

    private func requestEventAccess(_ type: EKEntityType) async {
        error = nil
        if Self.map(EKEventStore.authorizationStatus(for: type)) == .denied {
            openSettings(type == .event ? .calendar : .reminders); return
        }
        let store = EKEventStore()
        do {
            if type == .event { _ = try await store.requestFullAccessToEvents() }
            else { _ = try await store.requestFullAccessToReminders() }
        } catch { self.error = error.localizedDescription }
        refresh()
    }

    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
        case screen = "Privacy_ScreenCapture"
        case calendar = "Privacy_Calendars"
        case reminders = "Privacy_Reminders"
    }
    func openSettings(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func map(_ s: AVAuthorizationStatus) -> PermState {
        switch s {
        case .authorized:   return .granted
        case .denied:       return .denied
        case .restricted:   return .denied
        case .notDetermined: return .notDetermined
        @unknown default:   return .unknown
        }
    }
    private static func map(_ status: EKAuthorizationStatus) -> PermState {
        switch status {
        case .fullAccess: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined, .writeOnly: return .notDetermined
        @unknown default: return .unknown
        }
    }
}
