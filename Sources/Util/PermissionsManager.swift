import Foundation
import AVFoundation
import AppKit
import ApplicationServices

enum PermState { case granted, denied, notDetermined, unknown }

/// Tracks the OS permissions Parley needs and drives the onboarding + settings status rows.
/// Mic and Accessibility are queryable; system-audio (Core Audio process taps) has no public
/// preflight — it prompts on first capture — so it's informational/optional here.
@MainActor
final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    @Published var mic: PermState = .notDetermined
    @Published var accessibility: PermState = .notDetermined

    func refresh() {
        mic = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        accessibility = AXIsProcessTrusted() ? .granted : .notDetermined
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

    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
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
}
