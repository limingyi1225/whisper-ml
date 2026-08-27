import AVFoundation
import Combine
import DictationKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let controller: DictationController
    let updater: AppUpdater
    @State private var selectedTab = InviteEnrollmentOnboarding.shouldPresentInvite(
        inviteEnrollmentEnabled: KeychainStore.inviteEnrollmentEnabled,
        hasRelayToken: KeychainStore.hasRelayToken()
    ) ? SettingsTab.setup : .dictation

    private enum SettingsTab: Hashable {
        case dictation
        case setup
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DictationSettingsTab(controller: controller)
                .tabItem { Label("听写", systemImage: "waveform") }
                .tag(SettingsTab.dictation)
            SetupSettingsTab(controller: controller, updater: updater)
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(SettingsTab.setup)
        }
        .frame(width: 500, height: 600)
    }
}

// MARK: - Dictation

private struct DictationSettingsTab: View {
    let controller: DictationController
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("触发键", selection: $settings.triggerKey) {
                    ForEach(TriggerKey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .onChange(of: settings.triggerKey) { controller.restartHotKey() }
            } header: {
                HStack(spacing: 6) {
                    Text("听写")
                    Spacer(minLength: 12)
                    Circle()
                        .fill(connectionTint)
                        .frame(width: 6, height: 6)
                    Text(connectionLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("转写") {
                Picker("模型", selection: $settings.transcriptionModel) {
                    ForEach(TranscriptionModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .onChange(of: settings.transcriptionModel) { controller.reconnect() }

                if settings.transcriptionModel.supportsTranscriptionDelay {
                    Picker("延迟", selection: $settings.transcriptionDelay) {
                        ForEach(TranscriptionDelay.allCases) { delay in
                            Text(delay.displayName).tag(delay)
                        }
                    }
                    .onChange(of: settings.transcriptionDelay) { controller.reconnect() }
                }
            }

            Section("文本") {
                Toggle("去掉句尾句号", isOn: $settings.stripTrailingPeriod)
            }

            Section("常用词汇") {
                VocabularyEditor(vocabulary: $settings.vocabulary)
            }
        }
        .formStyle(.grouped)
        .defaultScrollAnchor(.top)
    }

    private var connectionLabel: String {
        switch controller.connectionStatus {
        case .ready: return "已连接"
        case .connecting: return "连接中"
        case .disconnected: return "未连接"
        case .failed: return "连接失败"
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

private struct VocabularyEditor: View {
    @Binding var vocabulary: String
    @State private var draft = ""

    var body: some View {
        if !terms.isEmpty {
            WrappingFlowLayout(spacing: 6) {
                ForEach(terms, id: \.self) { term in
                    HStack(spacing: 5) {
                        Text(term)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 180)
                        Button {
                            remove(term)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除 \(term)")
                    }
                    .padding(.leading, 9)
                    .padding(.trailing, 7)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                }
            }
            .padding(.vertical, 2)
        }

        if terms.count < AppSettings.vocabularyTermLimit {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    TextField("添加词汇", text: $draft)
                        .textFieldStyle(.plain)
                        .onSubmit(submitDraft)

                    Button("添加", action: submitDraft)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(trimmedDraft.isEmpty || validationMessage != nil)
                }

                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                }
            }
        }
    }

    private var terms: [String] {
        AppSettings.parseVocabulary(vocabulary)
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationMessage: String? {
        guard !trimmedDraft.isEmpty else { return nil }
        if trimmedDraft.utf16.count > AppSettings.vocabularyTermLengthLimit {
            return "最多 \(AppSettings.vocabularyTermLengthLimit) 个字符"
        }
        if trimmedDraft.contains(where: { $0 == "<" || $0 == ">" }) {
            return "不能包含 < 或 >"
        }
        if terms.contains(trimmedDraft) {
            return "已经添加"
        }
        return nil
    }

    private func submitDraft() {
        guard !trimmedDraft.isEmpty, validationMessage == nil else { return }
        add([trimmedDraft])
        draft = ""
    }

    private func add(_ candidates: [String]) {
        let combined = (terms + candidates).joined(separator: "\n")
        vocabulary = AppSettings.parseVocabulary(combined).joined(separator: "\n")
    }

    private func remove(_ term: String) {
        vocabulary = terms.filter { $0 != term }.joined(separator: "\n")
    }
}

private struct WrappingFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(subviews: subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(subviews: subviews, width: bounds.width)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }

    private func layout(subviews: Subviews, width: CGFloat) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }

        return (
            CGSize(width: width.isFinite ? width : usedWidth, height: y + rowHeight),
            points
        )
    }
}

// MARK: - Setup

private struct SetupSettingsTab: View {
    let controller: DictationController
    let updater: AppUpdater

    @Bindable private var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @State private var accessibilityGranted = Permissions.hasAccessibility
    @State private var microphoneStatus = Permissions.microphoneStatus

    @State private var inviteCodeField = ""
    @State private var legacyRelayTokenField = ""
    @State private var relayTokenStored = KeychainStore.hasRelayToken()
    @State private var isEditingRelayToken = false
    @State private var isActivatingRelay = false
    @State private var relayTokenError: String?
    @State private var relayEnrollmentTask: Task<Void, Never>?
    @State private var relayEnrollmentAttemptID: UUID?

    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("系统") {
                Toggle("登录时启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }

                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                }

                permissionRow(title: "辅助功能", granted: accessibilityGranted) {
                    Permissions.promptForAccessibility()
                    Permissions.openAccessibilitySettings()
                }

                permissionRow(
                    title: "麦克风",
                    granted: microphoneStatus == .authorized,
                    actionTitle: microphoneStatus == .notDetermined ? "允许…" : "打开设置…"
                ) {
                    if microphoneStatus == .notDetermined {
                        Task { _ = await Permissions.requestMicrophone() }
                    } else {
                        Permissions.openMicrophoneSettings()
                    }
                }

                relayCredentialEditor
            }

            UpdateSettingsSection(controller: controller, updater: updater)
        }
        .formStyle(.grouped)
        .defaultScrollAnchor(.top)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            relayTokenStored = KeychainStore.hasRelayToken()
        }
        .onReceive(refresh) { _ in
            accessibilityGranted = Permissions.hasAccessibility
            microphoneStatus = Permissions.microphoneStatus
        }
        .onDisappear {
            relayEnrollmentTask?.cancel()
            relayEnrollmentTask = nil
            relayEnrollmentAttemptID = nil
            isActivatingRelay = false
        }
    }

    /// The saved row is not decoration, and it is not safe to drop once the device is
    /// activated. `relayTokenStored` only asks whether the keychain holds an item, not
    /// whether the relay still honours it, and a token can be revoked from the server
    /// (`script/revoke_token.sh`). A revoked device therefore still counts as stored,
    /// so the enrollment field never comes back on its own — "更换…" is the only way
    /// back to the invite field. Without it that Mac has no route to re-activate at
    /// all, while transcription and cleanup both fail. It is also the only place in
    /// relay mode that says the device is set up; removing it leaves the section blank.
    @ViewBuilder
    private var relayCredentialEditor: some View {
        if relayTokenStored && !isEditingRelayToken {
            // "设备" alone left the noun hanging — the row read "设备 ⟨更换…⟩ ✓" beside
            // "辅助功能" and "麦克风", which name what they are reporting on.
            savedCredentialRow(title: "设备授权") {
                inviteCodeField = ""
                legacyRelayTokenField = ""
                relayTokenError = nil
                isEditingRelayToken = true
            }
        } else if KeychainStore.inviteEnrollmentEnabled {
            inviteEnrollmentEditor
        } else {
            legacyRelayTokenEditor
        }
    }

    private var inviteEnrollmentEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SecureField("邀请码", text: $inviteCodeField, prompt: Text("WHISPER-…"))
                    .textContentType(.oneTimeCode)
                    .onChange(of: inviteCodeField) { relayTokenError = nil }
                    .onSubmit { activateRelay() }
                    .disabled(isActivatingRelay)

                if relayTokenStored {
                    Button("取消") {
                        inviteCodeField = ""
                        relayTokenError = nil
                        isEditingRelayToken = false
                    }
                    .disabled(isActivatingRelay)
                }

                Button(action: activateRelay) {
                    if isActivatingRelay {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(relayTokenStored ? "重新激活" : "激活")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    inviteCodeField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || isActivatingRelay
                )
            }

            relayCredentialError
        }
    }

    /// Plain and personalised builds predate public invite enrollment and still need
    /// their original manual-token recovery path. Hiding it behind the public-build
    /// flag keeps the generic DMG invite-only without breaking those release formats.
    private var legacyRelayTokenEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SecureField("设备 Token", text: $legacyRelayTokenField, prompt: Text("relay_…"))
                    .onChange(of: legacyRelayTokenField) { relayTokenError = nil }
                    .onSubmit { saveLegacyRelayToken() }

                if relayTokenStored {
                    Button("取消") {
                        legacyRelayTokenField = ""
                        relayTokenError = nil
                        isEditingRelayToken = false
                    }
                }

                Button(relayTokenStored ? "更新" : "保存", action: saveLegacyRelayToken)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        legacyRelayTokenField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }

            relayCredentialError
        }
    }

    @ViewBuilder
    private var relayCredentialError: some View {
        if let relayTokenError {
            Label(relayTokenError, systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.red)
        }
    }

    private func savedCredentialRow(
        title: String,
        replace: @escaping () -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Button("更换…", action: replace)
                    .controlSize(.small)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                    .accessibilityLabel("已保存")
            }
        }
    }

    private func activateRelay() {
        let invite = inviteCodeField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !invite.isEmpty, !isActivatingRelay else { return }
        guard RelayEnrollmentClient.isPlausibleInviteCode(invite) else {
            relayTokenError = "邀请码格式不正确"
            return
        }
        isActivatingRelay = true
        relayTokenError = nil
        let attemptID = UUID()
        relayEnrollmentAttemptID = attemptID
        relayEnrollmentTask = Task {
            defer {
                // A cancelled task can finish after this view reappears and starts a
                // newer activation. It may clean up only its own attempt; otherwise it
                // would enable the button and discard the new task's cancellation handle.
                if relayEnrollmentAttemptID == attemptID {
                    isActivatingRelay = false
                    relayEnrollmentTask = nil
                    relayEnrollmentAttemptID = nil
                }
            }
            do {
                try await RelayEnrollmentClient().enroll(inviteCode: invite)
                guard !Task.isCancelled else { return }
                inviteCodeField = ""
                relayTokenStored = true
                isEditingRelayToken = false
                controller.reconnect()
            } catch {
                guard !Task.isCancelled else { return }
                relayTokenError = error.localizedDescription
            }
        }
    }

    private func saveLegacyRelayToken() {
        let token = legacyRelayTokenField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        guard KeychainStore.isGeneratedRelayToken(token) else {
            relayTokenError = "设备 Token 格式不正确"
            return
        }
        guard KeychainStore.saveRelayToken(token) else {
            relayTokenError = "无法写入钥匙串"
            return
        }
        legacyRelayTokenField = ""
        relayTokenStored = true
        isEditingRelayToken = false
        relayTokenError = nil
        controller.reconnect()
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        actionTitle: String = "打开设置…",
        action: @escaping () -> Void
    ) -> some View {
        LabeledContent(title) {
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                    .accessibilityLabel("\(title)已授权")
            } else {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let currentlyEnabled = SMAppService.mainApp.status == .enabled
        guard enabled != currentlyEnabled else {
            launchAtLoginError = nil
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginError = "设置失败：\(error.localizedDescription)"
        }
    }
}

private struct UpdateSettingsSection: View {
    let controller: DictationController
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Section("软件更新") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Whisper \(AppUpdater.displayVersion)")

                    statusView
                        .frame(height: 16, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if updater.preparedUpdateVersion != nil {
                    Button(
                        updater.isInstallingPreparedUpdate ? "正在重启…" : "重启并更新",
                        action: updater.installPreparedUpdate
                    )
                    .controlSize(.small)
                    .disabled(!canRestartForUpdate || updater.isInstallingPreparedUpdate)
                } else if updater.availableUpdateVersion != nil {
                    Button(
                        updater.isDownloadingUpdate ? "正在下载…" : "立即更新",
                        action: updater.installAvailableUpdate
                    )
                    .controlSize(.small)
                    .disabled(!canRestartForUpdate || updater.isDownloadingUpdate)
                } else {
                    Button("检查更新", action: updater.checkForUpdates)
                        .controlSize(.small)
                        .disabled(!updater.canCheckForUpdates || updater.isCheckingForUpdates)
                }
            }

            Toggle(
                isOn: Binding(
                    get: { updater.automaticUpdatesEnabled },
                    set: updater.setAutomaticUpdatesEnabled
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动检查更新")
                    Text("每天自动检查；发现更新时弹窗提醒")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if let version = updater.preparedUpdateVersion {
            Label("版本 \(version) 已下载，等待安装", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
        } else if let version = updater.availableUpdateVersion, updater.isDownloadingUpdate {
            HStack(spacing: 5) {
                if let progress = updater.downloadProgress {
                    ProgressView(value: progress)
                        .frame(width: 54)
                    Text("正在下载版本 \(version)…")
                } else {
                    ProgressView()
                        .controlSize(.mini)
                    Text("正在准备版本 \(version)…")
                }
            }
            .foregroundStyle(Color.accentColor)
        } else {
            checkStatusView
        }
    }

    @ViewBuilder
    private var checkStatusView: some View {
        switch updater.checkState {
        case .idle:
            Text("当前版本")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("正在检查…")
            }
            .foregroundStyle(.secondary)
        case .upToDate:
            Label("已是最新版本", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
        case .updateAvailable:
            Label("发现新版本", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
        case let .failure(message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(Color.red)
        }
    }

    private var canRestartForUpdate: Bool {
        switch controller.phase {
        case .recording, .finalizing, .arming:
            return false
        case .idle, .error:
            return true
        }
    }
}
