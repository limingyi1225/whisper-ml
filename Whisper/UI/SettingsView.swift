import AVFoundation
import Combine
import DictationKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let controller: DictationController
    @State private var selectedTab = SettingsTab.dictation

    private enum SettingsTab: Hashable {
        case dictation
        case setup
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DictationSettingsTab(controller: controller)
                .tabItem { Label("听写", systemImage: "waveform") }
                .tag(SettingsTab.dictation)
            SetupSettingsTab(controller: controller)
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(SettingsTab.setup)
        }
        .frame(width: 500, height: selectedTab == .dictation ? 600 : 280)
        .animation(.snappy(duration: 0.2), value: selectedTab)
    }
}

// MARK: - Dictation

private struct DictationSettingsTab: View {
    let controller: DictationController
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("连接", selection: $settings.connectionMode) {
                    ForEach(ConnectionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.connectionMode) { controller.reconnect() }

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

                if settings.transcriptionModel.supportsLiveTyping {
                    Picker("延迟", selection: $settings.transcriptionDelay) {
                        ForEach(TranscriptionDelay.allCases) { delay in
                            Text(delay.displayName).tag(delay)
                        }
                    }
                    .onChange(of: settings.transcriptionDelay) { controller.reconnect() }
                }

                Toggle("繁体转简体", isOn: $settings.simplifyChinese)
            }

            Section("整理") {
                Toggle("自动去口头禅、补标点", isOn: $settings.polishEnabled)
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

    @Bindable private var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @State private var accessibilityGranted = Permissions.hasAccessibility
    @State private var microphoneStatus = Permissions.microphoneStatus

    @State private var apiKeyField = ""
    @State private var apiKeyStored = KeychainStore.hasAPIKey()
    @State private var isEditingAPIKey = false
    @State private var apiKeyError: String?

    @State private var relayTokenField = ""
    @State private var relayTokenStored = KeychainStore.hasRelayToken()
    @State private var isEditingRelayToken = false
    @State private var relayTokenError: String?

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
            }

            switch settings.connectionMode {
            case .direct:
                Section("OpenAI") { directCredentialEditor }
            case .relay:
                Section("代理") { relayCredentialEditor }
            }
        }
        .formStyle(.grouped)
        .defaultScrollAnchor(.top)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            apiKeyStored = KeychainStore.hasAPIKey()
            relayTokenStored = KeychainStore.hasRelayToken()
        }
        .onReceive(refresh) { _ in
            accessibilityGranted = Permissions.hasAccessibility
            microphoneStatus = Permissions.microphoneStatus
        }
    }

    @ViewBuilder
    private var directCredentialEditor: some View {
        if apiKeyStored && !isEditingAPIKey {
            savedCredentialRow(title: "API Key") {
                apiKeyField = ""
                apiKeyError = nil
                isEditingAPIKey = true
            }
        } else {
            HStack(spacing: 8) {
                SecureField("API Key", text: $apiKeyField, prompt: Text("sk-proj-…"))
                    .onChange(of: apiKeyField) { apiKeyError = nil }
                    .onSubmit { saveAPIKey() }

                if apiKeyStored {
                    Button("取消") {
                        apiKeyField = ""
                        apiKeyError = nil
                        isEditingAPIKey = false
                    }
                }

                Button(apiKeyStored ? "更新" : "保存", action: saveAPIKey)
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let apiKeyError {
                Label(apiKeyError, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
        }
    }

    @ViewBuilder
    private var relayCredentialEditor: some View {
        if relayTokenStored && !isEditingRelayToken {
            savedCredentialRow(title: "设备 Token") {
                relayTokenField = ""
                relayTokenError = nil
                isEditingRelayToken = true
            }
        } else {
            HStack(spacing: 8) {
                SecureField("设备 Token", text: $relayTokenField, prompt: Text("relay_…"))
                    .onChange(of: relayTokenField) { relayTokenError = nil }
                    .onSubmit { saveRelayToken() }

                if relayTokenStored {
                    Button("取消") {
                        relayTokenField = ""
                        relayTokenError = nil
                        isEditingRelayToken = false
                    }
                }

                Button(relayTokenStored ? "更新" : "保存", action: saveRelayToken)
                    .buttonStyle(.borderedProminent)
                    .disabled(relayTokenField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let relayTokenError {
                Label(relayTokenError, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
        }
    }

    private func savedCredentialRow(
        title: String,
        replace: @escaping () -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                    .accessibilityLabel("已保存")
                Button("更换…", action: replace)
                    .controlSize(.small)
            }
        }
    }

    private func saveAPIKey() {
        let key = apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard KeychainStore.saveAPIKey(key) else {
            apiKeyError = "无法写入钥匙串"
            return
        }
        apiKeyField = ""
        apiKeyStored = true
        isEditingAPIKey = false
        apiKeyError = nil
        controller.reconnect()
    }

    private func saveRelayToken() {
        let token = relayTokenField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        guard KeychainStore.saveRelayToken(token) else {
            relayTokenError = "无法写入钥匙串"
            return
        }
        relayTokenField = ""
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
