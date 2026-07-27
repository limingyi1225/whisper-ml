import SwiftUI

struct MenuBarLabel: View {
    let controller: DictationController

    var body: some View {
        Image(systemName: symbolName)
            .symbolRenderingMode(.hierarchical)
    }

    private var symbolName: String {
        switch controller.phase {
        case .recording: return "mic.fill"
        case .finalizing: return "waveform"
        case .error: return "exclamationmark.triangle.fill"
        case .idle, .arming:
            return controller.connectionStatus.isReady ? "mic" : "mic.slash"
        }
    }
}

struct MenuBarView: View {
    let controller: DictationController
    let settings = AppSettings.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(statusLine)

        Divider()

        Text("长按 \(settings.triggerKey.displayName) 开始说话")

        if !controller.history.isEmpty {
            Divider()
            Section("最近转写") {
                ForEach(controller.history.prefix(5)) { entry in
                    Button(truncate(entry.text)) {
                        TextInjector.copyToClipboard(entry.text)
                    }
                }
            }
        }

        Divider()

        if !Permissions.hasAccessibility {
            Button("授予辅助功能权限…") {
                Permissions.promptForAccessibility()
                Permissions.openAccessibilitySettings()
            }
        } else if !controller.isHotKeyActive {
            // Accessibility is fine; the hotkey is paused for another reason —
            // in practice Secure Event Input (a focused password field).
            Text("安全输入启用中，听写暂停")
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

        Button("退出 Whisper") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var statusLine: String {
        switch controller.phase {
        case .recording: return "● 正在录音"
        case .finalizing: return "正在转写…"
        case .error(let message): return "出错：\(message)"
        case .idle, .arming:
            switch controller.connectionStatus {
            case .ready: return "就绪"
            case .connecting: return "正在连接…"
            case .disconnected: return "未连接"
            case .failed(let message): return "连接失败：\(DictationController.friendlyMessage(message))"
            }
        }
    }

    private func truncate(_ text: String) -> String {
        text.count > 32 ? String(text.prefix(32)) + "…" : text
    }
}
