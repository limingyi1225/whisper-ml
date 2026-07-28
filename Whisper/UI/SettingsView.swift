import AVFoundation
import Combine
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let controller: DictationController

    var body: some View {
        TabView {
            GeneralSettingsTab(controller: controller)
                .tabItem { Label("通用", systemImage: "slider.horizontal.3") }
            AccountSettingsTab(controller: controller)
                .tabItem { Label("账号与权限", systemImage: "lock.shield") }
        }
        // Shorter than it was: cutting the explanatory footers took roughly 150pt of
        // text out of the 通用 tab, and leaving the old height behind an empty gap.
        .frame(width: 500, height: 420)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    let controller: DictationController
    @Bindable private var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section {
                Picker("连接方式", selection: $settings.connectionMode) {
                    ForEach(ConnectionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.connectionMode) {
                    controller.reconnect()
                }

                LabeledContent("连接状态") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(connectionTint)
                            .frame(width: 6, height: 6)
                        Text(connectionLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("连接")
            } footer: {
                Text(settings.connectionMode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("热键") {
                Picker("按住哪个键", selection: $settings.triggerKey) {
                    ForEach(TriggerKey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .onChange(of: settings.triggerKey) { controller.restartHotKey() }
            }

            Section {
                Picker("转写模型", selection: $settings.transcriptionModel) {
                    ForEach(TranscriptionModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .onChange(of: settings.transcriptionModel) { controller.reconnect() }

                if settings.transcriptionModel.supportsLiveTyping {
                    Picker("出字前先听多久", selection: $settings.transcriptionDelay) {
                        ForEach(TranscriptionDelay.allCases) { delay in
                            Text(delay.displayName).tag(delay)
                        }
                    }
                    .onChange(of: settings.transcriptionDelay) { controller.reconnect() }
                }

                Toggle("繁体自动转简体", isOn: $settings.simplifyChinese)
            } header: {
                Text("文字")
            } footer: {
                Text(settings.transcriptionModel.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("松手后整理") {
                Toggle("自动去掉口头禅、补标点", isOn: $settings.polishEnabled)
                Toggle("去掉句尾的句号", isOn: $settings.stripTrailingPeriod)
            }

            Section {
                TextEditor(text: $settings.vocabulary)
                    .font(.body.monospaced())
                    .frame(height: 96)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    .disabled(!settings.polishEnabled)
                    .opacity(settings.polishEnabled ? 1 : 0.5)
            } header: {
                Text("常用词汇")
            } footer: {
                Text(vocabularyStatus)
                    .font(.caption)
                    .foregroundStyle(settings.polishEnabled ? .secondary : Color.orange)
            }

            Section {
                Toggle("登录时自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(Color.red)
                }
            } header: {
                Text("启动")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    /// The single line under the editor. It says what to type only while there is
    /// nothing to report; once there is, it reports. The parser drops lines rather
    /// than truncating them, so a line that will never reach the model has to show
    /// up here — otherwise the user sits waiting for a fix that cannot come.
    private var vocabularyStatus: String {
        guard settings.polishEnabled else { return "需要先打开上面的整理开关。" }
        let accepted = AppSettings.parseVocabulary(settings.vocabulary).count
        let written = settings.vocabulary
            .split(whereSeparator: \.isNewline)
            .count { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard written > 0 else { return "一行一个：同事的名字、内部术语、项目代号。" }
        guard written > accepted else { return "已采用 \(accepted) 个词。" }
        return "已采用 \(accepted) 个词，忽略了 \(written - accepted) 行（重复、过长或超出上限）。"
    }

    private var connectionLabel: String {
        switch controller.connectionStatus {
        case .ready: return "已连接"
        case .connecting: return "连接中"
        case .disconnected: return "未连接"
        case .failed(let message): return DictationController.friendlyMessage(message)
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

    private func setLaunchAtLogin(_ enabled: Bool) {
        // The toggle can fire from our own revert below; only touch the service
        // when its state actually differs.
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

// MARK: - Account & permissions

private struct AccountSettingsTab: View {
    let controller: DictationController

    @Bindable private var settings = AppSettings.shared
    @State private var apiKeyField = ""
    @State private var apiKeySavedNotice = false
    @State private var apiKeySaveFailed = false
    @State private var relayTokenField = ""
    @State private var relayTokenSavedNotice = false
    @State private var relayTokenSaveFailed = false
    @State private var accessibilityGranted = Permissions.hasAccessibility
    @State private var microphoneStatus = Permissions.microphoneStatus
    @State private var secureInputEnabled = Permissions.isSecureInputEnabled

    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("系统权限") {
                permissionRow(
                    title: "辅助功能",
                    detail: "监听热键、把文字打进其它 App",
                    granted: accessibilityGranted
                ) {
                    Permissions.promptForAccessibility()
                    Permissions.openAccessibilitySettings()
                }

                permissionRow(
                    title: "麦克风",
                    detail: nil,
                    granted: microphoneStatus == .authorized
                ) {
                    if microphoneStatus == .notDetermined {
                        Task { _ = await Permissions.requestMicrophone() }
                    } else {
                        Permissions.openMicrophoneSettings()
                    }
                }
            }

            // Only the credential the current mode actually uses. Showing both invites
            // filling in the wrong one and then wondering why nothing connects.
            switch settings.connectionMode {
            case .direct:
                Section {
                    directCredentialEditor
                } header: {
                    Text("OpenAI API Key")
                } footer: {
                    Text("只在直接连接 OpenAI 时使用，保存在本机钥匙串中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .relay:
                Section {
                    relayCredentialEditor
                } header: {
                    Text("设备 Token")
                } footer: {
                    Text("在服务器上跑 `npm run generate-token` 生成，粘贴一次即可。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("诊断") {
                LabeledContent("热键监听") {
                    Text(controller.isHotKeyActive ? "运行中" : "未启动")
                        .foregroundStyle(controller.isHotKeyActive ? Color.green : Color.orange)
                }
                LabeledContent("安全输入") {
                    Text(secureInputEnabled ? "已启用，听写暂停" : "未启用")
                        .foregroundStyle(secureInputEnabled ? Color.orange : Color.secondary)
                }
                Button("重新启动热键监听") { controller.restartHotKey() }
            }
        }
        .formStyle(.grouped)
        .onReceive(refresh) { _ in
            accessibilityGranted = Permissions.hasAccessibility
            microphoneStatus = Permissions.microphoneStatus
            secureInputEnabled = Permissions.isSecureInputEnabled
        }
    }

    @ViewBuilder
    private var directCredentialEditor: some View {
        SecureField("API Key", text: $apiKeyField, prompt: Text("sk-proj-…"))
            .onChange(of: apiKeyField) { _, newValue in
                // Saving clears the field, which must not clear the success notice.
                if !newValue.isEmpty {
                    apiKeySavedNotice = false
                    apiKeySaveFailed = false
                }
            }
        HStack {
            Button("保存并连接") {
                // The keychain can genuinely refuse the write; claiming success then
                // would leave the old (or no) key in use.
                if KeychainStore.saveAPIKey(apiKeyField) {
                    apiKeyField = ""
                    apiKeySavedNotice = true
                    controller.reconnect()
                } else {
                    apiKeySaveFailed = true
                }
            }
            .disabled(apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            credentialStatus(
                saveFailed: apiKeySaveFailed,
                savedNotice: apiKeySavedNotice,
                hasStoredValue: KeychainStore.hasAPIKey()
            )
        }
    }

    /// The relay's device token is a credential like any other, so it is entered here
    /// rather than installed out of band. Writing it from inside the app also gives the
    /// keychain item an ACL that names this app — an item created by the `security` CLI
    /// carries an ACL that does not, and reading it back would prompt or fail outright.
    @ViewBuilder
    private var relayCredentialEditor: some View {
        SecureField("设备 Token", text: $relayTokenField, prompt: Text("relay_…"))
            .onChange(of: relayTokenField) { _, newValue in
                if !newValue.isEmpty {
                    relayTokenSavedNotice = false
                    relayTokenSaveFailed = false
                }
            }
        HStack {
            Button("保存并连接") {
                if KeychainStore.saveRelayToken(relayTokenField) {
                    relayTokenField = ""
                    relayTokenSavedNotice = true
                    controller.reconnect()
                } else {
                    relayTokenSaveFailed = true
                }
            }
            .disabled(relayTokenField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            credentialStatus(
                saveFailed: relayTokenSaveFailed,
                savedNotice: relayTokenSavedNotice,
                hasStoredValue: KeychainStore.hasRelayToken()
            )
        }
    }

    @ViewBuilder
    private func credentialStatus(
        saveFailed: Bool,
        savedNotice: Bool,
        hasStoredValue: Bool
    ) -> some View {
        if saveFailed {
            Text("写入钥匙串失败").font(.caption).foregroundStyle(Color.red)
        } else if savedNotice {
            Text("已存入钥匙串").font(.caption).foregroundStyle(Color.green)
        } else if hasStoredValue {
            Text("钥匙串中已有").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("尚未设置").font(.caption).foregroundStyle(Color.orange)
        }
    }

    private func permissionRow(
        title: String,
        detail: String?,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !granted {
                Button("去授权", action: action)
            }
        }
    }
}
