import DictationKit
import SwiftUI

struct MenuBarLabel: View {
    let controller: DictationController
    @Environment(\.openSettings) private var openSettings
    @AppStorage("didPresentInviteEnrollment") private var didPresentInviteEnrollment = false

    var body: some View {
        // `.bottomTrailing` is for the 5pt error dot. The slash has to sit in the
        // icon's own overlay instead of sharing that alignment: it is a full-height
        // 18pt bar, so bottom-trailing pins it to the right edge and the -44° rotation
        // then swings roughly 40% of it past the 19pt frame, where the menu bar clips
        // it into a stub in the top-right corner rather than a line across the icon.
        ZStack(alignment: .bottomTrailing) {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(.primary)
                .opacity(iconOpacity)
                .overlay {
                    if showsDisconnectedSlash {
                        Capsule()
                            .fill(.primary)
                            .frame(width: 1.6, height: 18)
                            .rotationEffect(.degrees(-44))
                    }
                }

            if case .error = controller.phase {
                Circle()
                    .fill(Color.red)
                    .frame(width: 5, height: 5)
                    .overlay {
                        Circle().stroke(.background, lineWidth: 1)
                    }
                    .offset(x: 1, y: 1)
            }
        }
        .frame(width: 19, height: 18)
        .accessibilityLabel(accessibilityLabel)
        .task {
            guard InviteEnrollmentOnboarding.shouldPresentInvite(
                inviteEnrollmentEnabled: KeychainStore.inviteEnrollmentEnabled,
                hasRelayToken: KeychainStore.hasRelayToken(),
                hasAPIKey: KeychainStore.hasAPIKey(),
                connectionModeWasChosen: AppSettings.connectionModeWasChosen,
                connectionMode: AppSettings.shared.connectionMode
            ),
                  !didPresentInviteEnrollment else { return }
            (NSApp.delegate as? AppDelegate)?.rememberCurrentFrontmostApplication()
            NSApp.activate(ignoringOtherApps: true)
            openSettings()

            // Settings creation is asynchronous. One dispatch to the next run-loop
            // turn is usually enough but is not a contract; on a cold first launch it
            // could miss the window and permanently set the "presented" marker. Give
            // SwiftUI a short bounded interval and persist the marker only after the
            // window actually exists.
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                NSApp.activate(ignoringOtherApps: true)
                let settingsWindow = NSApp.windows.first {
                    $0.identifier?.rawValue.hasPrefix("com_apple_SwiftUI_Settings") == true
                } ?? NSApp.windows.first {
                    !($0 is NSPanel) && $0.styleMask.contains(.titled) && $0.level == .normal
                }
                if let settingsWindow {
                    settingsWindow.makeKeyAndOrderFront(nil)
                    settingsWindow.orderFrontRegardless()
                    didPresentInviteEnrollment = true
                    return
                }
            }
        }
    }

    private var iconOpacity: Double {
        switch controller.phase {
        case .recording: return 1
        case .finalizing: return 0.62
        case .error: return 0.82
        case .arming: return 0.78
        case .idle: return controller.connectionStatus.isReady ? 1 : 0.5
        }
    }

    private var showsDisconnectedSlash: Bool {
        switch controller.phase {
        case .recording, .finalizing, .error:
            return false
        case .idle, .arming:
            return !controller.connectionStatus.isReady
        }
    }

    private var accessibilityLabel: String {
        switch controller.phase {
        case .recording: return "Whisper 正在录音"
        case .finalizing: return controller.isPolishing ? "Whisper 正在整理" : "Whisper 正在转写"
        case .error: return "Whisper 出错"
        case .arming: return "Whisper 正在准备录音"
        case .idle:
            return controller.connectionStatus.isReady ? "Whisper 已就绪" : "Whisper 未连接"
        }
    }
}

struct MenuBarView: View {
    let controller: DictationController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let contextualStatus {
            Text(contextualStatus)
        }

        if !Permissions.hasAccessibility {
            Button("授予辅助功能权限…") {
                Permissions.promptForAccessibility()
                Permissions.openAccessibilitySettings()
            }
        } else if !controller.isHotKeyActive {
            Text(Permissions.isSecureInputEnabled
                ? "安全输入启用中，听写暂停"
                : "热键监听未启动")
        }

        if showsContext {
            Divider()
        }

        if !controller.history.isEmpty {
            Menu("最近转写") {
                ForEach(controller.history.prefix(5)) { entry in
                    Button(truncate(entry.text)) {
                        TextInjector.copyToClipboard(entry.text)
                    }
                }
            }
        }

        Button("设置…") {
            // Accessory apps never activate on their own, so a bare SettingsLink
            // opens the window underneath whatever app is frontmost. Activating is
            // not enough either: cooperative activation can be denied, and the
            // window is created asynchronously — so front the window itself once
            // it exists.
            (NSApp.delegate as? AppDelegate)?.rememberCurrentFrontmostApplication()
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let settingsWindow = NSApp.windows.first {
                    $0.identifier?.rawValue.hasPrefix("com_apple_SwiftUI_Settings") == true
                } ?? NSApp.windows.first {
                    !($0 is NSPanel) && $0.styleMask.contains(.titled) && $0.level == .normal
                }
                if let settingsWindow {
                    settingsWindow.makeKeyAndOrderFront(nil)
                    settingsWindow.orderFrontRegardless()
                }
            }
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("退出 Whisper") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var contextualStatus: String? {
        switch controller.phase {
        case .recording: return "● 正在录音"
        case .finalizing: return controller.isPolishing ? "正在整理…" : "正在转写…"
        case .error(let message): return "出错：\(message)"
        case .idle, .arming:
            switch controller.connectionStatus {
            case .ready: return nil
            case .connecting: return "正在连接…"
            case .disconnected: return "未连接"
            case .failed(let message): return "连接失败：\(DictationController.friendlyMessage(message))"
            }
        }
    }

    private var showsContext: Bool {
        contextualStatus != nil || !Permissions.hasAccessibility || !controller.isHotKeyActive
    }

    private func truncate(_ text: String) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return singleLine.count > 36 ? String(singleLine.prefix(36)) + "…" : singleLine
    }
}
