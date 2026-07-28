import AppKit
import SwiftUI

/// A small pill that lives at the bottom-centre of the screen all the time, staying out
/// of the way until you speak — then it grows into a live transcript readout.
///
/// It must never take key focus: the whole point is that keystrokes keep flowing into
/// whatever app the user was already typing in. Hence a non-activating panel shown with
/// `orderFrontRegardless()` rather than `makeKeyAndOrderFront(_:)`, with mouse events
/// passed straight through.
@MainActor
final class RecordingHUDController {
    static let shared = RecordingHUDController()

    /// Fixed panel big enough for the widest state; the pill animates inside it, which
    /// is far smoother than resizing an NSWindow every frame.
    private static let panelSize = NSSize(width: 260, height: 48)
    /// Gap between the pill and the bottom of the usable screen area (above the Dock).
    private static let bottomInset: CGFloat = 10

    private var panel: NSPanel?
    private var screenObserver: NSObjectProtocol?

    private init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { RecordingHUDController.shared.reposition() }
        }
    }

    func show() {
        // Reposition only on first creation (and via the explicit calls when a
        // dictation arms or the screen layout changes) — repositioning on every
        // phase change would let the pill jump displays mid-dictation just because
        // the pointer drifted onto another screen.
        if panel == nil {
            panel = makePanel()
            reposition()
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Moves the pill to whichever screen the pointer is on. Called when dictation
    /// starts so it shows up where the user is actually working.
    func reposition() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        panel.setFrameOrigin(NSPoint(
            x: frame.midX - Self.panelSize.width / 2,
            y: frame.minY + Self.bottomInset
        ))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let host = NSHostingView(rootView: RecordingHUDView(controller: DictationController.shared))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }
}

struct RecordingHUDView: View {
    let controller: DictationController

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            pill
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: state)
    }

    // MARK: - Pill

    /// Deliberately minimal. While dictating, the transcript is already appearing in the
    /// app the user is typing into, so repeating it here would just be noise — the pill
    /// only ever answers "is it listening?". Errors are the one exception, since those
    /// need words.
    private var pill: some View {
        content
            .frame(width: width, height: height)
            .background {
                Capsule(style: .continuous)
                    .fill(Color(white: 0.1).opacity(state == .idle ? 0.42 : 0.8))
            }
            .opacity(state == .idle ? 0.75 : 1)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .arming:
            EmptyView()
        case .listening:
            WaveformView(level: controller.level)
                .frame(height: 10)
        case .transcribing:
            BreathingDots()
        case .failed:
            Text(controller.lastError ?? "出错了")
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 10)
        }
    }

    // MARK: - Appearance per state

    private enum HUDState: Equatable {
        case idle, arming, listening, transcribing, failed
    }

    private var state: HUDState {
        switch controller.phase {
        case .idle: return .idle
        case .arming: return .arming
        case .recording: return .listening
        case .finalizing: return .transcribing
        case .error: return .failed
        }
    }

    private var width: CGFloat {
        switch state {
        case .idle: return 46
        case .arming: return 56
        case .listening, .transcribing: return 84
        // Sized against the longest message the app can actually produce, measured
        // at this font — a truncated error is a message nobody can act on. Stays
        // inside the 260pt panel with room for the capsule's own margins.
        case .failed: return 230
        }
    }

    private var height: CGFloat {
        switch state {
        case .idle: return 4
        case .arming: return 5
        case .listening, .transcribing: return 14
        case .failed: return 18
        }
    }
}

/// Five bars that react to input level, with fixed per-bar weights so the shape reads as
/// a meter rather than five identical bars moving in lockstep.
private struct WaveformView: View {
    let level: Float

    private let weights: [Float] = [0.5, 0.8, 1.0, 0.75, 0.45]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(weights.enumerated()), id: \.offset) { _, weight in
                Capsule()
                    .fill(.white.opacity(0.85))
                    .frame(width: 2, height: height(for: weight))
            }
        }
        .animation(.easeOut(duration: 0.09), value: level)
    }

    private func height(for weight: Float) -> CGFloat {
        let minHeight: Float = 2
        let maxHeight: Float = 10
        return CGFloat(minHeight + (maxHeight - minHeight) * min(1, level * weight * 1.4))
    }
}

/// Waiting indicator for the short gap between releasing the key and the last words
/// arriving. Deliberately quieter than the recording meter.
private struct BreathingDots: View {
    private static let period = 1.05

    var body: some View {
        // A `repeatForever` animation on the opacity modifier cannot drive this:
        // SwiftUI interpolates the modifier's endpoint values, and the sine is
        // periodic — identical at phase 0 and 1 — so the dots would never move.
        // TimelineView re-evaluates the curve every frame instead.
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.period) / Self.period
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(.white.opacity(0.75))
                        .frame(width: 3, height: 3)
                        .opacity(0.35 + 0.65 * pulse(index, phase: phase))
                }
            }
        }
    }

    private func pulse(_ index: Int, phase: Double) -> Double {
        let offset = Double(index) / 3
        return (sin((phase - offset) * 2 * .pi) + 1) / 2
    }
}
