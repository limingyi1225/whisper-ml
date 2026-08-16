import AVFoundation
import AppKit
import Combine
import DictationKit
import ServiceManagement
import SwiftUI

// MARK: - Gate

/// Who is owed the first-run guide.
///
/// The decision is a pure function because the case that matters is the one that is
/// easy to get wrong: somebody who has been dictating for months and updates into the
/// build that introduced this window. On that launch the completion flag was written by
/// nobody, so credential plus Accessibility is the legacy evidence that they are already
/// working. Once the guide has actually appeared, an explicit owed marker replaces that
/// inference until the whole flow — microphone included — is completed.
enum OnboardingGate {
    private static let completedKey = "didCompleteOnboarding"
    private static let owedKey = "onboardingSetupOwed"
    private static let dismissedKey = "onboardingDismissed"

    static func shouldPresent(
        completed: Bool,
        owed: Bool,
        dismissed: Bool,
        hasCredential: Bool,
        hasAccessibility: Bool,
        hasMicrophone: Bool
    ) -> Bool {
        guard !completed else { return false }
        // Setup that is finished is finished, whichever way the window was closed.
        // Recognising only the 完成 button turned the red dot into a permanent
        // launch-time interruption: walk the whole guide, watch your sentence appear,
        // close the window the ordinary way, and it reopens — stealing focus — on
        // every launch for the rest of the install's life.
        if OnboardingRequirements.areSatisfied(
            hasCredential: hasCredential,
            hasAccessibility: hasAccessibility,
            hasMicrophone: hasMicrophone
        ) {
            return false
        }
        // The user closed the window on purpose while it was still unfinished.
        // Advancing stays gated — they cannot reach the demo without permissions —
        // but a step somebody *cannot* pass (a managed Mac where Accessibility is
        // denied by profile) must not hold the launch hostage forever. The guide
        // stays one click away in the menu bar.
        if dismissed { return false }
        // Once this walkthrough has actually begun, machine state can no longer stand
        // in for completion. The user may have granted Accessibility and saved a
        // credential before closing on the permissions page; that is still an
        // interrupted first run, and microphone may still be missing.
        if owed { return true }
        return !hasCredential || !hasAccessibility
    }

    /// Compatibility overload for callers and tests written before an explicit
    /// dismissal and the microphone took part in the decision.
    static func shouldPresent(
        completed: Bool,
        owed: Bool,
        hasCredential: Bool,
        hasAccessibility: Bool
    ) -> Bool {
        shouldPresent(
            completed: completed,
            owed: owed,
            dismissed: false,
            hasCredential: hasCredential,
            hasAccessibility: hasAccessibility,
            hasMicrophone: false
        )
    }

    /// Compatibility overload for the legacy-upgrade inference and its existing tests.
    /// A working install predating the guide has no owed marker, so credential plus
    /// Accessibility remains enough to avoid greeting it with a new wizard.
    static func shouldPresent(
        completed: Bool,
        hasCredential: Bool,
        hasAccessibility: Bool
    ) -> Bool {
        shouldPresent(
            completed: completed,
            owed: false,
            hasCredential: hasCredential,
            hasAccessibility: hasAccessibility
        )
    }

    /// Whether the mode the app will actually use has something to authenticate with.
    /// Deliberately per-mode rather than "any credential anywhere": a relay user with a
    /// stale API key in the Keychain is not set up, and neither is the reverse.
    static func hasCredential(for mode: ConnectionMode) -> Bool {
        switch mode {
        case .direct: return KeychainStore.hasAPIKey()
        case .relay: return KeychainStore.hasRelayToken()
        }
    }

    static var isCompleted: Bool { UserDefaults.standard.bool(forKey: completedKey) }
    static var isOwed: Bool { UserDefaults.standard.bool(forKey: owedKey) }
    static var isDismissed: Bool { UserDefaults.standard.bool(forKey: dismissedKey) }

    static func markOwed() { UserDefaults.standard.set(true, forKey: owedKey) }

    /// The window was closed while setup was still unfinished. Recorded so the guide
    /// stops presenting itself at launch; it does not mean setup succeeded.
    static func markDismissed() { UserDefaults.standard.set(true, forKey: dismissedKey) }

    static func markCompleted() {
        let store = UserDefaults.standard
        store.set(true, forKey: completedKey)
        store.removeObject(forKey: owedKey)
        store.removeObject(forKey: dismissedKey)
    }

    /// Reopening the guide by hand restarts it as a real first run: whatever made the
    /// user come back, another silent auto-dismissal is not what they asked for.
    static func clearDismissal() { UserDefaults.standard.removeObject(forKey: dismissedKey) }

    enum ShowAgainRequest {
        /// Show the guide against this Mac's real state.
        case real
        /// Show it as a brand-new Mac sees it — no credential, no permissions granted —
        /// without touching either. The only way to review the first run someone else
        /// will get, short of wiping your own Keychain item and revoking Accessibility.
        case preview
    }

    /// A way back in:
    ///
    ///     defaults write com.mingyili.Whisper showOnboarding -bool YES
    ///     defaults write com.mingyili.Whisper showOnboarding preview
    ///
    /// Consumed on read rather than left standing, so a forgotten key cannot turn into a
    /// welcome screen on every launch forever.
    static func consumeShowAgainRequest() -> ShowAgainRequest? {
        let store = UserDefaults.standard
        defer { store.removeObject(forKey: showAgainKey) }
        // Checked before `bool(forKey:)`, which reads "preview" as false.
        if let raw = store.string(forKey: showAgainKey)?.lowercased(),
           raw == "preview" || raw == "fresh" {
            return .preview
        }
        return store.bool(forKey: showAgainKey) ? .real : nil
    }

    private static let showAgainKey = "showOnboarding"
}

enum OnboardingRequirements {
    static func areSatisfied(
        hasCredential: Bool,
        hasAccessibility: Bool,
        hasMicrophone: Bool
    ) -> Bool {
        hasCredential && hasAccessibility && hasMicrophone
    }
}

enum OnboardingPresentationPolicy {
    /// An explicit real-state walkthrough is sometimes setup and sometimes review.
    /// If this install would have opened the guide without the override, it still owes
    /// completion. A completed install — or a legacy install already proven usable by
    /// credential plus Accessibility — is merely looking again and must not acquire a
    /// permanent setup debt just because its old build never wrote the completion key.
    static func shouldTrackCompletion(preview: Bool, normallyNeedsSetup: Bool) -> Bool {
        !preview && normallyNeedsSetup
    }
}

// MARK: - Window

@MainActor
final class OnboardingController {
    static let shared = OnboardingController()

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var isPreview = false
    private weak var appDelegate: AppDelegate?

    /// Shows the guide on a fresh install, and returns whether it took over the launch.
    ///
    /// The caller uses the answer to stay out of the way: the microphone and
    /// Accessibility prompts it would otherwise fire belong to the 权限 step, because a
    /// system permission sheet that appears before the user has read a single word is
    /// the one thing a first run must not do.
    @discardableResult
    func presentIfNeeded(
        controller: DictationController,
        appDelegate: AppDelegate
    ) -> Bool {
        self.appDelegate = appDelegate
        let completed = OnboardingGate.isCompleted
        let owed = OnboardingGate.isOwed
        let hasCredential = OnboardingGate.hasCredential(
            for: AppSettings.shared.connectionMode
        )
        let hasAccessibility = Permissions.hasAccessibility
        let normallyNeedsSetup = OnboardingGate.shouldPresent(
            completed: completed,
            owed: owed,
            dismissed: OnboardingGate.isDismissed,
            hasCredential: hasCredential,
            hasAccessibility: hasAccessibility,
            hasMicrophone: Permissions.microphoneStatus == .authorized
        )

        if let request = OnboardingGate.consumeShowAgainRequest() {
            let preview = request == .preview
            present(
                controller: controller,
                preview: preview,
                tracksCompletion: OnboardingPresentationPolicy.shouldTrackCompletion(
                    preview: preview,
                    normallyNeedsSetup: normallyNeedsSetup
                )
            )
            return true
        }
        guard normallyNeedsSetup else {
            // An install that is already working has effectively been through it.
            // Recording that now means a later revoked permission cannot resurrect
            // the wizard in the middle of somebody's working day.
            OnboardingGate.markCompleted()
            return false
        }
        present(controller: controller, tracksCompletion: true)
        return true
    }

    func present(
        controller: DictationController,
        preview: Bool = false,
        tracksCompletion: Bool
    ) {
        // Persist before creating the real window. A crash, force-quit, red close, or
        // “以后再说” must all reopen an unfinished first run even if credential and AX
        // later become valid enough to resemble a legacy working installation. Showing
        // an already-completed walkthrough again is review, not a new setup debt.
        if tracksCompletion {
            OnboardingGate.markOwed()
        }
        if !preview {
            // Opening the guide by hand is a request to be walked through it again,
            // so an earlier dismissal stops suppressing the launch-time presentation.
            OnboardingGate.clearDismissal()
        }

        // Opening a window from a menu-bar accessory app takes focus explicitly. Keep
        // the app that owned it so every exit path can hand it back; startup already
        // records this, but `present` is also the reusable show-again entry point.
        appDelegate?.rememberCurrentFrontmostApplication()

        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        isPreview = preview
        let hosting = NSHostingController(rootView: OnboardingView(
            controller: controller,
            preview: preview,
            finish: { [weak self] in self?.finish() },
            dismiss: { [weak self] in self?.dismiss() }
        ))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // Above other apps, and on every desktop: the guide is a short errand that
        // sends the user into System Settings and back, and it should still be where
        // they left it when they return.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
        self.window = window
        observeClosing(window)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Only 完成 closes the guide for good. The red button leaves the flag alone on
    /// purpose: a setup abandoned halfway is not a setup, and the next launch should
    /// offer to finish it rather than pretend it happened. A preview never writes it
    /// either — it is a rehearsal of somebody else's first run, not this Mac's.
    private func finish() {
        close(reason: .completed)
    }

    /// Leaves setup owed. Used by “以后再说”: postponing activation must not walk the
    /// user into a demo that cannot connect, or write a permanent completion marker.
    private func dismiss() {
        close(reason: .postponed)
    }

    private func close(reason: OnboardingExitReason) {
        if OnboardingCompletionPolicy.shouldMarkCompleted(reason: reason, preview: isPreview) {
            OnboardingGate.markCompleted()
        }
        window?.close()
    }
}

extension OnboardingController {
    /// Every way out of the window ends here, including the red button, which
    /// `finish()` never sees. Leaving the rehearsal switch on would strand the pill on
    /// screen for the rest of the session and make the next dictation at Whisper's own
    /// window silently type nothing.
    private func observeClosing(_ window: NSWindow) {
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                DictationController.shared.isRehearsing = false
                guard let self else { return }
                // Any exit that is not completion — the red button included — records
                // that the user chose to close this window, so the next launch does
                // not open it again over whatever they are doing. Preview is a
                // rehearsal of somebody else's first run and must leave no trace.
                if !self.isPreview, !OnboardingGate.isCompleted {
                    OnboardingGate.markDismissed()
                }
                self.appDelegate?.restorePreviousApplicationIfNeeded()
                if let observer = self.closeObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.closeObserver = nil
                }
                self.window = nil
            }
        }
    }
}

// MARK: - Flow

enum OnboardingStep: Int, CaseIterable, Comparable {
    case welcome
    case connection
    case permissions
    case practice

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var next: Self? { Self(rawValue: rawValue + 1) }

    var skipAction: OnboardingSkipAction? {
        self == .connection ? .dismissOwed : nil
    }
}

enum OnboardingSkipAction: Equatable {
    case dismissOwed
}

enum OnboardingExitReason: Equatable {
    case completed
    case postponed
}

enum OnboardingCompletionPolicy {
    static func shouldMarkCompleted(reason: OnboardingExitReason, preview: Bool) -> Bool {
        reason == .completed && !preview
    }
}

private enum CredentialChoice {
    case invite
    case apiKey
}

enum OnboardingLaunchAtLoginAction: Equatable {
    case none
    case register
    case unregister

    static func required(currentlyEnabled: Bool, desired: Bool) -> Self {
        guard currentlyEnabled != desired else { return .none }
        return desired ? .register : .unregister
    }
}

enum OnboardingTriggerSelectionPolicy {
    static func initialValue(preview: Bool, persisted: TriggerKey) -> TriggerKey {
        // Preview drives the real rehearsal pipeline, whose event tap continues to use
        // the persisted trigger. Showing that same key keeps the instruction truthful.
        persisted
    }

    static func isEditable(preview: Bool) -> Bool {
        !preview
    }

    static func appliesToApplication(preview: Bool) -> Bool {
        isEditable(preview: preview)
    }
}

private struct OnboardingView: View {
    let controller: DictationController
    /// Renders the whole flow as an unconfigured Mac sees it, and touches nothing
    /// while doing it: the buttons that would grant a permission or save a credential
    /// only move the guide's own copy of that state.
    ///
    /// Simulating them is the point rather than a shortcut. A preview whose 允许 does
    /// nothing looks broken — and a preview that reported the real thing would jump
    /// straight back to the ✓ this machine already has, which is the screen a new user
    /// never sees and therefore the one that needed reviewing.
    let preview: Bool
    let finish: () -> Void
    let dismiss: () -> Void

    @Bindable private var settings = AppSettings.shared
    @State private var step: OnboardingStep = .welcome

    @State private var hasCredential = false
    /// Which credential the 激活 step is asking for. Local to the guide, and always
    /// starts on the invite code: that is how nearly everyone gets in, and the stored
    /// connection mode cannot answer the question anyway — a fresh install has never
    /// chosen one. Nothing is written to settings until an activation actually works.
    @State private var credentialChoice = CredentialChoice.invite
    @State private var inviteField = ""
    @State private var apiKeyField = ""
    @State private var isActivating = false
    @State private var credentialError: String?
    @State private var activationTask: Task<Void, Never>?
    @State private var credentialAdvanceTask: Task<Void, Never>?

    @State private var accessibilityGranted = false
    @State private var microphoneStatus = AVAuthorizationStatus.notDetermined

    @State private var practiceBaseline = 0
    @State private var heardText: String?
    @State private var launchAtLogin = false
    @State private var launchAtLoginError: String?
    @State private var isSynchronizingLaunchAtLogin = false
    /// Preview owns this copy. Binding its picker to `AppSettings.shared` would write
    /// UserDefaults and restart the real event tap merely by reviewing the walkthrough.
    @State private var selectedTriggerKey: TriggerKey = .rightCommand

    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(
        controller: DictationController,
        preview: Bool,
        finish: @escaping () -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.controller = controller
        self.preview = preview
        self.finish = finish
        self.dismiss = dismiss
        // Seeded rather than filled in on appear, so the first frame is already the
        // truth — otherwise a configured Mac flashes the 邀请码 field before the
        // 已激活 row replaces it.
        _hasCredential = State(initialValue: preview
            ? false
            : OnboardingGate.hasCredential(for: AppSettings.shared.connectionMode))
        _accessibilityGranted = State(initialValue: preview ? false : Permissions.hasAccessibility)
        _microphoneStatus = State(initialValue: preview ? .notDetermined : Permissions.microphoneStatus)
        _launchAtLogin = State(initialValue: SMAppService.mainApp.status == .enabled)
        _selectedTriggerKey = State(initialValue: OnboardingTriggerSelectionPolicy.initialValue(
            preview: preview,
            persisted: AppSettings.shared.triggerKey
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .id(step)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 8)),
                    removal: .opacity
                ))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .animation(.easeInOut(duration: 0.22), value: step)

            Divider()

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(width: 460, height: 450)
        .onReceive(refresh) { _ in readSystemState() }
        .onDisappear {
            activationTask?.cancel()
            activationTask = nil
            credentialAdvanceTask?.cancel()
            credentialAdvanceTask = nil
            isActivating = false
            controller.isRehearsing = false
        }
    }

    /// Real mode follows the machine; preview mode keeps the state the walkthrough
    /// has been simulating.
    private func readSystemState() {
        guard !preview else { return }
        hasCredential = OnboardingGate.hasCredential(for: settings.connectionMode)
        accessibilityGranted = Permissions.hasAccessibility
        microphoneStatus = Permissions.microphoneStatus
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .connection: connectionStep
        case .permissions: permissionsStep
        case .practice: practiceStep
        }
    }

    // MARK: 欢迎

    /// A cover, not a feature list. Everything it could say about what the app does is
    /// either in the sentence under the name or is a claim the user already bought by
    /// downloading it — and the progress dots say how far there is to go without a line
    /// of prose announcing it. Centred rather than top-aligned, so a page this short
    /// reads as a title page instead of an unfinished one.
    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 8) {
                Text("欢迎使用 Whisper")
                    .font(.title2.weight(.semibold))
                Text("按住 \(selectedTriggerKey.displayName) 说话，松手出字。中文、英文、中英混说都行。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 激活

    private var connectionStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeading("激活", systemImage: "key.fill", tint: .accentColor)

            if hasCredential {
                activatedSummary
                    .transition(.opacity)
            } else {
                switch credentialChoice {
                case .invite: inviteEditor.transition(.opacity)
                case .apiKey: apiKeyEditor.transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: hasCredential)
        .animation(.easeInOut(duration: 0.18), value: credentialChoice)
    }

    private var activatedSummary: some View {
        HStack(spacing: 10) {
            Label(
                activatedThroughRelay ? "已激活" : "已保存 API Key",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(Color.green)

            Spacer(minLength: 12)

            Circle()
                .fill(connectionTint)
                .frame(width: 6, height: 6)
            Text(connectionLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var inviteEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            credentialCard(label: "邀请码") {
                SecureField("邀请码", text: $inviteField, prompt: Text("WHISPER-…"))
                    .textContentType(.oneTimeCode)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onChange(of: inviteField) { credentialError = nil }
                    .onSubmit(activateInvite)
                    .disabled(isActivating)

                Button(action: activateInvite) {
                    if isActivating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("激活")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(inviteField.trimmed.isEmpty || isActivating)
            }

            credentialErrorLabel

            Button("用自己的 OpenAI API Key") {
                credentialChoice = .apiKey
                credentialError = nil
            }
            .buttonStyle(.link)
            .disabled(isActivating)
        }
    }

    private var apiKeyEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            credentialCard(label: "API Key") {
                SecureField("API Key", text: $apiKeyField, prompt: Text("sk-proj-…"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onChange(of: apiKeyField) { credentialError = nil }
                    .onSubmit(saveAPIKey)

                Button("保存", action: saveAPIKey)
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKeyField.trimmed.isEmpty)
            }

            credentialErrorLabel

            Button("用邀请码激活") {
                credentialChoice = .invite
                credentialError = nil
            }
            .buttonStyle(.link)
        }
    }

    /// In preview the stored connection mode is this Mac's real one, which would
    /// mislabel a simulated activation; the editor the user just used is the honest
    /// answer there.
    private var activatedThroughRelay: Bool {
        preview ? credentialChoice == .invite : settings.connectionMode == .relay
    }

    private func credentialCard(
        label: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var credentialErrorLabel: some View {
        if let credentialError {
            Label(credentialError, systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 权限

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeading("权限", systemImage: "hand.raised.fill", tint: .accentColor)

            VStack(spacing: 14) {
                permissionRow(
                    title: "麦克风",
                    systemImage: "mic.fill",
                    tint: .orange,
                    granted: microphoneStatus == .authorized,
                    actionTitle: microphoneStatus == .notDetermined ? "允许…" : "打开设置…"
                ) {
                    if preview {
                        microphoneStatus = .authorized
                    } else if microphoneStatus == .notDetermined {
                        Task { _ = await Permissions.requestMicrophone() }
                    } else {
                        Permissions.openMicrophoneSettings()
                    }
                }

                Divider()

                permissionRow(
                    title: "辅助功能",
                    systemImage: "accessibility",
                    tint: .blue,
                    granted: accessibilityGranted,
                    actionTitle: "打开设置…"
                ) {
                    guard !preview else {
                        accessibilityGranted = true
                        return
                    }
                    Permissions.promptForAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 14)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10))

            // Not a permission, but the same kind of decision and the same page it
            // belongs to in Settings — and putting it here leaves the last step with
            // nothing on it but the demo.
            VStack(alignment: .leading, spacing: 4) {
                Toggle("登录时启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        if isSynchronizingLaunchAtLogin {
                            isSynchronizingLaunchAtLogin = false
                            return
                        }
                        setLaunchAtLogin(enabled)
                    }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                }
            }
            .padding(.top, 2)
        }
        .animation(.easeInOut(duration: 0.2), value: accessibilityGranted)
    }

    private func permissionRow(
        title: String,
        systemImage: String,
        tint: Color,
        granted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 19, height: 19)
                .background(tint, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(title)
            Spacer(minLength: 12)
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                    .accessibilityLabel("\(title)已授权")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: granted)
    }

    // MARK: 试一下

    /// The last step is a demonstration, so it is built like one: the title and the one
    /// control that can change it stay out of the way at the top, and everything else is
    /// the stage at the bottom — the sentence, and the pill itself.
    private var practiceStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("试一下")
                    .font(.title2.weight(.semibold))
                Spacer(minLength: 16)
                Picker("触发键", selection: $selectedTriggerKey) {
                    ForEach(TriggerKey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 150)
                .disabled(!OnboardingTriggerSelectionPolicy.isEditable(preview: preview))
                .onChange(of: selectedTriggerKey) { _, key in
                    guard OnboardingTriggerSelectionPolicy.appliesToApplication(
                        preview: preview
                    ) else { return }
                    settings.triggerKey = key
                    controller.restartHotKey()
                }
            }

            if preview {
                Text("预览使用当前触发键，不会更改设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            practiceStage

            // Low, but not sitting on the divider: the stage wants air under it as well
            // as over it, and the bare bottom edge read as a layout accident.
            Spacer(minLength: 0)
                .frame(maxHeight: 64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            practiceBaseline = controller.history.count
            // Speaking at Whisper's own window is normally refused for want of anywhere
            // to type. For this step it becomes a rehearsal instead — see
            // `DictationController.isRehearsing`.
            controller.isRehearsing = true
        }
        .onDisappear { controller.isRehearsing = false }
        .onChange(of: controller.history.count) { _, count in
            guard count > practiceBaseline, let latest = controller.history.first else { return }
            heardText = latest.text
        }
    }

    /// The sentence, then the real pill under it — the same view the HUD puts at the
    /// bottom of the screen, driven by the same state, so it widens and settles in step
    /// with the one down there. That is the whole introduction: a caption saying "the
    /// bar at the bottom of your screen is this" beats any description of it.
    ///
    /// Nothing announces that a sentence arrived. The sentence is on screen, in the
    /// place the user is already looking; a 「听到了」 above it would be the app
    /// congratulating itself for something the user can plainly see.
    private var practiceStage: some View {
        VStack(spacing: 16) {
            Text(spokenText ?? "按住 \(selectedTriggerKey.displayName) 说话")
                .font(.title3)
                .foregroundStyle(spokenText == nil ? .secondary : .primary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 48, alignment: .bottom)
                .animation(.easeOut(duration: 0.2), value: spokenText == nil)

            RecordingHUDView(controller: controller)
                .frame(width: 250, height: 24)

            practiceFootnote
        }
        .frame(maxWidth: .infinity)
    }

    /// 权限 is a hard gate, so arriving here without Accessibility is not something the
    /// user chose and the old line — "还没给辅助功能权限" — was usually a lie by the time
    /// anyone read it. What actually silences the hot key at this point is secure input:
    /// some other app has a password field focused, and macOS stops delivering key
    /// events to everyone. Same wording as the menu, because it is the same condition.
    @ViewBuilder
    private var practiceFootnote: some View {
        if !hasCredential {
            HStack(spacing: 8) {
                Text("激活信息不见了，暂时不能试说。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("去激活") { withAnimation { step = .connection } }
                    .controlSize(.small)
            }
        } else if microphoneStatus != .authorized {
            HStack(spacing: 8) {
                Text("麦克风权限被关掉了，暂时不能试说。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("去开") { withAnimation { step = .permissions } }
                    .controlSize(.small)
            }
        } else if !accessibilityGranted {
            HStack(spacing: 8) {
                Text("辅助功能权限被关掉了，热键收不到。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("去开") { withAnimation { step = .permissions } }
                    .controlSize(.small)
            }
        } else if !controller.isHotKeyActive {
            Text(Permissions.isSecureInputEnabled
                ? "安全输入启用中，热键暂停。"
                : "热键监听未启动。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            // The error case needs no line of its own: a failed dictation is already
            // spelled out inside the pill above, both here and on the real one.
            Text("屏幕底部那根小条就是它。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The live deltas while they are arriving, then the finished sentence. Reading both
    /// from the same place is what keeps the text on screen through the moment between
    /// the last delta and the cleaned-up result.
    private var spokenText: String? {
        controller.partialText.isEmpty ? heardText : controller.partialText
    }

    // MARK: 页脚

    private var footer: some View {
        HStack(spacing: 14) {
            if preview {
                Text("预览")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quinary, in: Capsule())
            }

            HStack(spacing: 5) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { each in
                    Capsule()
                        .fill(Color.secondary.opacity(each == step ? 0.85 : 0.22))
                        .frame(width: each == step ? 12 : 5, height: 5)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: step)

            if let skipTitle {
                Button(skipTitle, action: performSkip)
                    .buttonStyle(.link)
            }

            Spacer(minLength: 0)

            if step > .welcome {
                Button("上一步") {
                    withAnimation { step = OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome }
                }
                    .disabled(isActivating)
            }

            Button(primaryTitle, action: primaryAction)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdvance)
        }
    }

    /// The step's own requirement, and the only thing 下一步 waits for.
    private var canAdvance: Bool {
        switch step {
        case .welcome: return true
        case .connection: return hasCredential && !isActivating
        case .permissions, .practice: return setupRequirementsAreSatisfied
        }
    }

    private var setupRequirementsAreSatisfied: Bool {
        OnboardingRequirements.areSatisfied(
            hasCredential: hasCredential,
            hasAccessibility: accessibilityGranted,
            hasMicrophone: microphoneStatus == .authorized
        )
    }

    /// Only 激活 can be put off, because an invite may genuinely still be in somebody
    /// else's hands. “以后再说” closes the guide and leaves it owed; it does not advance
    /// into a practice step whose network route cannot exist yet. Permissions remain a
    /// hard gate once activation has succeeded.
    private var skipTitle: String? {
        switch step {
        case .welcome, .permissions, .practice: return nil
        case .connection: return canAdvance ? nil : "以后再说"
        }
    }

    private func performSkip() {
        guard step.skipAction == .dismissOwed else { return }
        dismiss()
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "开始"
        case .practice: return "完成"
        case .connection, .permissions: return "下一步"
        }
    }

    private func primaryAction() {
        guard step != .practice else {
            complete()
            return
        }
        advance()
    }

    /// Swaps the field for the ✓ and moves on a beat later.
    ///
    /// Advancing the instant the request returns skipped the only confirmation this step
    /// has: the user pressed 激活 and the page vanished from under their hands, with
    /// nothing anywhere saying it had worked.
    private func credentialLanded() {
        hasCredential = true
        credentialAdvanceTask?.cancel()
        credentialAdvanceTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            // They may have gone back, or closed the window, while it was landing.
            guard step == .connection else { return }
            advance()
        }
    }

    private func advance() {
        guard let next = step.next else { return }
        credentialError = nil
        withAnimation { step = next }
    }

    private func complete() {
        // The timer keeps the page current, but completion is the persistence boundary:
        // re-read the machine synchronously so a permission revoked in the last second
        // cannot clear the owed marker using stale SwiftUI state.
        readSystemState()
        guard setupRequirementsAreSatisfied else {
            withAnimation { step = hasCredential ? .permissions : .connection }
            return
        }
        finish()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard !preview else { return }
        let currentlyEnabled = SMAppService.mainApp.status == .enabled
        do {
            switch OnboardingLaunchAtLoginAction.required(
                currentlyEnabled: currentlyEnabled,
                desired: enabled
            ) {
            case .none:
                break
            case .register:
                try SMAppService.mainApp.register()
            case .unregister:
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            // Return the control to the service's real state; otherwise it would claim
            // success and the failure would only become visible after a reboot.
            let actual = SMAppService.mainApp.status == .enabled
            if launchAtLogin != actual {
                isSynchronizingLaunchAtLogin = true
                launchAtLogin = actual
            }
            launchAtLoginError = "设置失败：\(error.localizedDescription)"
        }
    }

    // MARK: 动作

    private func activateInvite() {
        let invite = inviteField.trimmed
        guard !invite.isEmpty, !isActivating else { return }
        guard !preview else {
            inviteField = ""
            credentialLanded()
            return
        }
        guard RelayEnrollmentClient.isPlausibleInviteCode(invite) else {
            credentialError = "邀请码格式不正确"
            return
        }
        isActivating = true
        credentialError = nil
        activationTask = Task {
            defer {
                isActivating = false
                activationTask = nil
            }
            do {
                try await RelayEnrollmentClient().enroll(inviteCode: invite)
                guard !Task.isCancelled else { return }
                inviteField = ""
                // Written here rather than when the user picked the tab: until an
                // activation succeeds there is nothing to route, and a half-finished
                // guide should not leave the app pointed at a credential it does not have.
                settings.connectionMode = .relay
                controller.reconnect()
                credentialLanded()
            } catch {
                guard !Task.isCancelled else { return }
                credentialError = error.localizedDescription
            }
        }
    }

    private func saveAPIKey() {
        let key = apiKeyField.trimmed
        guard !key.isEmpty else { return }
        guard !preview else {
            apiKeyField = ""
            credentialLanded()
            return
        }
        guard KeychainStore.saveAPIKey(key) else {
            credentialError = "无法写入钥匙串"
            return
        }
        apiKeyField = ""
        credentialError = nil
        settings.connectionMode = .direct
        controller.reconnect()
        credentialLanded()
    }

    // MARK: 零件

    private func stepHeading(
        _ title: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(
                    tint.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
            Text(title)
                .font(.title2.weight(.semibold))
        }
    }

    private var connectionLabel: String {
        switch controller.connectionStatus {
        case .ready: return "已连接"
        case .connecting: return "连接中…"
        case .disconnected: return "未连接"
        case .failed(let message): return "连接失败：\(DictationController.friendlyMessage(message))"
        }
    }

    private var connectionTint: Color {
        switch controller.connectionStatus {
        case .ready: return .green
        case .connecting: return .orange
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
