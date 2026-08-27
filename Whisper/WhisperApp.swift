import DictationKit
import AVFoundation
import AppKit
import SwiftUI

@main
struct WhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let controller = DictationController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: controller, updater: appDelegate.updater)
        } label: {
            MenuBarLabel(controller: controller, updater: appDelegate.updater)
        }

        Settings {
            SettingsView(controller: controller, updater: appDelegate.updater)
        }
        .windowResizability(.contentSize)
    }
}

/// Keeps first-launch routing and the Settings prompt on the same contract: the relay
/// is the only route, so activation is simply "this Mac has no device token yet".
enum InviteEnrollmentOnboarding {
    static func shouldPresentInvite(
        inviteEnrollmentEnabled: Bool,
        hasRelayToken: Bool
    ) -> Bool {
        inviteEnrollmentEnabled && !hasRelayToken
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let updater = AppUpdater()
    private let focusedInputMonitor = FocusedInputMonitor()
    private var windowCloseObserver: NSObjectProtocol?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var workspaceWakeObserver: NSObjectProtocol?
    private var previousApplication: NSRunningApplication?
    var systemWakeHandler: () -> Void = {
        DictationController.shared.systemDidWake()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // DictationKit reads settings through a protocol rather than reaching
        // back into the app, so it has to be handed the real object. First
        // thing, and outside the XCTest guard below: the tests exercise
        // ServiceRoute, which reads it, and its fallback would answer with
        // different values than AppSettings does.
        DictationEnvironment.settings = AppSettings.shared

        // Unit tests use this app as their host process. Starting the real
        // pipeline there would install an event tap, spin up audio, and pop
        // permission prompts in the middle of a test run.
        if ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("XCTest") }) {
            return
        }

        // A measurement run against another app's accessibility behaviour. Starts
        // nothing else, so it cannot disturb the copy the user has running.
        if let delay = InjectionSelfTest.requestedDelay {
            NSApp.setActivationPolicy(.accessory)
            InjectionSelfTest.run(after: delay)
            return
        }

        // Direct mode no longer exists. Remove the upstream OpenAI key older builds
        // stored before opening any network path; the relay device token is untouched.
        let hadLegacyUpstreamCredential = KeychainStore.hasLegacyUpstreamCredential()
        _ = KeychainStore.deleteLegacyUpstreamCredentials()
        updater.start()
        // Before `controller.start()`, which opens the socket: a personalised build
        // should come up already connected rather than showing 「还没有设置设备 Token」
        // and reconnecting a moment later. No-op in an ordinary build.
        //
        // A seed is either the first run ever or a rotation replacing this app's own
        // earlier token. No-op in an ordinary build.
        KeychainStore.seedBundledRelayTokenIfNeeded()
        OnboardingGate.scheduleLegacyCredentialRecoveryIfNeeded(
            hadLegacyCredential: hadLegacyUpstreamCredential,
            hasRelayToken: KeychainStore.hasRelayToken()
        )

        // Menu-bar only; LSUIElement already keeps us out of the Dock, but be explicit
        // so the app never steals focus from whatever the user is typing into.
        NSApp.setActivationPolicy(.accessory)
        rememberCurrentFrontmostApplication()
        observeApplicationActivation()
        observeSystemWake()
        observeWindowClosing()

        let controller = DictationController.shared
        controller.start()

        // A fresh install is walked through activation, permissions and a first
        // sentence instead of being left to discover the menu bar on its own.
        let isOnboarding = OnboardingController.shared.presentIfNeeded(
            controller: controller,
            appDelegate: self
        )

        // Ask for microphone access up front so the first dictation is not the thing
        // that triggers a permission sheet mid-sentence. Both prompts belong to the
        // guide's 权限 step while it is on screen: firing them here would put two
        // system sheets in front of a user who has not yet read a single word, and the
        // one they dismiss out of reflex is the one nothing works without.
        if !isOnboarding {
            if Permissions.microphoneStatus == .notDetermined {
                Task { _ = await Permissions.requestMicrophone() }
            }

            if !Permissions.hasAccessibility {
                Permissions.promptForAccessibility()
            }
        }

        focusedInputMonitor.onChange = { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.updateHUD(controller)
        }
        focusedInputMonitor.start()
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

    func observeSystemWake() {
        workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemWakeHandler()
            }
        }
    }

    func restorePreviousApplicationIfNeeded() {
        let previous = previousApplication
        previousApplication = nil

        DispatchQueue.main.async {
            // During `NSWindow.willClose` AppKit can already report the accessory app
            // inactive while WindowServer still considers it frontmost. The old
            // `NSApp.isActive` guard then discarded the remembered app and left Whisper
            // owning the menu bar with no window. Conversely, if the user has already
            // switched elsewhere, never pull them back merely because a delayed close
            // callback fired.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == ProcessInfo.processInfo.processIdentifier else { return }
            guard let previous, !previous.isTerminated else {
                NSApp.deactivate()
                return
            }
            NSApp.yieldActivation(to: previous)
            _ = previous.activate(from: .current, options: [])
        }
    }

    /// Idle visibility follows editable keyboard focus. Once a dictation starts, the
    /// pill remains visible until its final result/error/settled mark has completed,
    /// even if focus moves during the asynchronous tail of the utterance.
    private func observeHUD(_ controller: DictationController) {
        updateHUD(controller)

        func track() {
            withObservationTracking {
                _ = controller.phase
                _ = controller.settledAt
                _ = controller.isRehearsing
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
        let shouldShow = RecordingHUDController.shouldShow(
            phase: controller.phase,
            hasFocusedEditableInput: focusedInputMonitor.hasFocusedEditableInput,
            isShowingSettledMark: controller.settledAt != nil,
            isRehearsing: controller.isRehearsing
        )
        if shouldShow {
            RecordingHUDController.shared.show()
        } else {
            RecordingHUDController.shared.hide()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        focusedInputMonitor.stop()
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
        if let workspaceWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceWakeObserver)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
