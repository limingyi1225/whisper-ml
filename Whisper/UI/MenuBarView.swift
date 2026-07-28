import DictationKit
import SwiftUI

struct MenuBarLabel: View {
    let controller: DictationController

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
        case .finalizing: return "Whisper 正在转写"
        case .error: return "Whisper 出错"
        case .arming: return "Whisper 正在准备录音"
        case .idle:
            return controller.connectionStatus.isReady ? "Whisper 已就绪" : "Whisper 未连接"
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
