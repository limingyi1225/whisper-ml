import AVFoundation
import AppKit
import SwiftUI

@main
struct WhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let controller = DictationController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: controller)
        } label: {
            MenuBarLabel(controller: controller)
        }

        Settings {
            SettingsView(controller: controller)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowCloseObserver: NSObjectProtocol?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var previousApplication: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests use this app as their host process. Starting the real
        // pipeline there would install an event tap, spin up audio, and pop
        // permission prompts in the middle of a test run.
        if ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("XCTest") }) {
            return
        }
        // Before `controller.start()`, which opens the socket: a personalised build
        // should come up already connected rather than showing 「还没有设置设备 Token」
        // and reconnecting a moment later. No-op in an ordinary build.
        //
        // A seed is either the first run ever or a rotation replacing this app's own
        // earlier token. Only a user who has never chosen a mode gets moved to 代理:
        // the token itself always lands in the keychain, but rerouting someone's audio
        // and billing is a decision that is theirs once they have made it.
        //
        // The earlier test — "was there no relay token before the seed?" — got this
        // wrong for the most ordinary existing user there is: 直连 with their own API
        // key and no relay token looks identical to a brand-new Mac, and installing a
        // personalised build silently switched them to the relay.
        let modeWasChosen = AppSettings.connectionModeWasChosen
        if KeychainStore.seedBundledRelayTokenIfNeeded(), !modeWasChosen {
            AppSettings.shared.connectionMode = .relay
        }

        // Menu-bar only; LSUIElement already keeps us out of the Dock, but be explicit
        // so the app never steals focus from whatever the user is typing into.
        NSApp.setActivationPolicy(.accessory)
        rememberCurrentFrontmostApplication()
        observeApplicationActivation()
        observeWindowClosing()

        let controller = DictationController.shared
        controller.start()

        // Ask for microphone access up front so the first dictation is not the thing
        // that triggers a permission sheet mid-sentence.
        if Permissions.microphoneStatus == .notDetermined {
            Task { _ = await Permissions.requestMicrophone() }
        }

        if !Permissions.hasAccessibility {
            Permissions.promptForAccessibility()
        }

        observeHUD(controller)
    }

    func rememberCurrentFrontmostApplication() {
        guard let candidate = NSWorkspace.shared.frontmostApplication,
              candidate.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        previousApplication = candidate
    }

    private func observeApplicationActivation() {
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rememberCurrentFrontmostApplication()
            }
        }
    }

    private func observeWindowClosing() {
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let window = notification.object as? NSWindow,
                      !(window is NSPanel),
                      window.level == .normal,
                      window.styleMask.contains(.titled) else {
                    return
                }
                self.restorePreviousApplicationIfNeeded()
            }
        }
    }

    private func restorePreviousApplicationIfNeeded() {
        let previous = previousApplication
        previousApplication = nil
        guard NSApp.isActive else { return }

        DispatchQueue.main.async {
            guard NSApp.isActive else { return }
            guard let previous, !previous.isTerminated else {
                NSApp.deactivate()
                return
            }
            NSApp.yieldActivation(to: previous)
            _ = previous.activate(from: .current, options: [])
        }
    }

    /// The pill sits at the bottom of the screen permanently; re-fronting it on every
    /// phase change keeps it above whatever appeared since. Which screen it lives on
    /// is driven by the hotkey's `.armed` event in `DictationController` — queued
    /// gestures never pass through `.arming`, so a phase observer cannot see them.
    private func observeHUD(_ controller: DictationController) {
        updateHUD(controller)

        func track() {
            withObservationTracking {
                _ = controller.phase
            } onChange: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.updateHUD(controller)
                        track()
                    }
                }
            }
        }
        track()
    }

    private func updateHUD(_ controller: DictationController) {
        RecordingHUDController.shared.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
