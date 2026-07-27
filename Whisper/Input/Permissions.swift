import AVFoundation
import AppKit
import ApplicationServices
import Carbon

@MainActor
enum Permissions {
    /// Needed for both the global event tap and for posting synthetic keystrokes.
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system's "grant Accessibility access" prompt.
    static func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var hasMicrophone: Bool { microphoneStatus == .authorized }

    /// Secure Event Input is enabled by password fields and similar protected controls.
    /// Global hotkeys and synthetic keyboard events are deliberately blocked while it
    /// is active, so starting capture would create a recording that cannot be stopped
    /// or delivered reliably.
    static var isSecureInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
