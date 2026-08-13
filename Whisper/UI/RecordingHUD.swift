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

    static func shouldShow(
        phase: DictationController.Phase,
        hasFocusedEditableInput: Bool,
        isShowingSettledMark: Bool
    ) -> Bool {
        if phase != .idle || isShowingSettledMark {
            return true
        }
        return hasFocusedEditableInput
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
    @State private var shellExpansion: CGFloat = 0
    @State private var waveformVisible = false

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            pill
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: isFailed)
        .onChange(of: state, initial: true) { _, newState in
            animate(to: newState)
        }
    }

    // MARK: - Pill

    /// Deliberately minimal. While dictating, the transcript is already appearing in the
    /// app the user is typing into, so repeating it here would just be noise — the pill
    /// only ever answers "is it listening?", and after that "is it still working on the
    /// sentence?".
    @ViewBuilder
    private var pill: some View {
        switch state {
        case .polishing, .settled:
            PolishPill(landedAt: controller.settledAt)
        default:
            content
                .frame(width: width, height: height)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color(white: 0.1).opacity(fillOpacity))
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .arming:
            // Not `EmptyView`: SwiftUI does not render one at all, and takes the
            // `.frame` and `.background` hung off it down with it. These two states
            // are nothing *but* their background, so for as long as this said
            // `EmptyView` the resting line was never drawn — the pill blinked into
            // existence when you spoke and vanished when it was done, and every
            // attempt to make the end of an utterance read as coming to rest was
            // animating towards a destination that was not on screen.
            Color.clear
        // The tail of the transcript is still arriving in `.transcribing`, and the
        // meter says so on its own by going quiet: same pill, bars flat. It used to
        // get an animation of its own, which made a state that lasts half a second
        // into a third thing to recognise.
        case .listening, .transcribing:
            WaveformView(level: controller.level)
                .frame(height: 8)
                .scaleEffect(
                    x: waveformVisible ? 1 : 0.82,
                    y: waveformVisible ? 1 : 0.2
                )
                .opacity(waveformVisible ? 1 : 0)
        case .polishing, .settled:
            Color.clear
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
        case idle, arming, listening, transcribing, polishing, settled, failed
    }

    private var state: HUDState {
        switch controller.phase {
        case .idle: return controller.settledAt == nil ? .idle : .settled
        case .arming: return controller.settledAt == nil ? .arming : .settled
        case .recording: return .listening
        // Waiting for the tail of the transcript and cleaning it up are both
        // `.finalizing`, but they feel nothing alike from the user's side: the
        // first is over in a blink, the second takes long enough to wonder about
        // and ends by rewriting text that is already on screen.
        case .finalizing: return controller.isPolishing ? .polishing : .transcribing
        case .error: return .failed
        }
    }

    private var isFailed: Bool {
        if case .failed = state { true } else { false }
    }

    private var fillOpacity: Double {
        switch state {
        case .idle, .arming, .listening, .transcribing:
            return 0.32 + 0.48 * Double(shellExpansion)
        case .polishing, .settled, .failed:
            return 0.8
        }
    }

    private var width: CGFloat {
        switch state {
        case .idle, .arming, .listening, .transcribing:
            return 46 + 38 * shellExpansion
        case .polishing, .settled:
            return 84
        // Sized against the longest message the app can actually produce, measured
        // at this font — a truncated error is a message nobody can act on. Stays
        // inside the 260pt panel with room for the capsule's own margins.
        case .failed: return 230
        }
    }

    private var height: CGFloat {
        switch state {
        case .idle, .arming, .listening, .transcribing:
            return 4 + 8 * shellExpansion
        case .polishing, .settled:
            return 12
        case .failed: return 18
        }
    }

    /// Opening is deliberately staged: the shell gets a head start, then the meter
    /// grows into the space it made. A single implicit animation made the meter swap
    /// and the resize happen on the same frame, which read as a jump.
    private func animate(to state: HUDState) {
        switch state {
        case .listening:
            withAnimation(.timingCurve(0.2, 0.75, 0.25, 1, duration: 0.38)) {
                shellExpansion = 1
            }
            withAnimation(.easeOut(duration: 0.2).delay(0.1)) {
                waveformVisible = true
            }
        case .transcribing:
            shellExpansion = 1
            waveformVisible = true
        case .polishing:
            shellExpansion = 1
            waveformVisible = false
        case .settled:
            // `PolishPill` owns the visible release. Prepare the ordinary resting
            // shell underneath so replacing it after 1.2 s cannot jump back open.
            shellExpansion = 0
            waveformVisible = false
        case .idle, .arming:
            withAnimation(.easeOut(duration: 0.12)) {
                waveformVisible = false
            }
            withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.34)) {
                shellExpansion = 0
            }
        case .failed:
            shellExpansion = 0
            waveformVisible = false
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
        let maxHeight: Float = 8
        return CGFloat(minHeight + (maxHeight - minHeight) * min(1, level * weight * 1.4))
    }
}

/// The cleanup sweep and its completion are one continuous timeline:
/// gather into a short point, hold, then spread into the resting line while the shell
/// contracts around it. Keeping the shell and the mark here prevents two unrelated
/// SwiftUI transitions from drifting apart.
private struct PolishPill: View {
    let landedAt: Date?

    private static let expandedWidth: CGFloat = 84
    private static let expandedHeight: CGFloat = 12
    private static let restingWidth: CGFloat = 46
    private static let restingHeight: CGFloat = 4
    private static let track: CGFloat = 52
    private static let hair: CGFloat = 2
    private static let light: CGFloat = 22
    private static let point: CGFloat = 8
    private static let period: Double = 1.05
    private static let gather: Double = 0.25
    private static let holdUntil: Double = 0.75
    private static let release: Double = 0.45

    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            let motion = motion(at: timeline.date)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.12 * motion.trackOpacity))
                    .frame(width: Self.track, height: Self.hair)
                Capsule()
                    .fill(motion.isSolid ? AnyShapeStyle(.white.opacity(0.95)) : AnyShapeStyle(Self.beam))
                    .frame(width: motion.markWidth, height: Self.hair)
                    .offset(x: motion.markX)
                    .opacity(motion.markOpacity)
            }
            .frame(width: Self.track, height: Self.hair)
            .clipShape(Capsule())
            .frame(width: motion.pillWidth, height: motion.pillHeight)
            .background {
                Capsule(style: .continuous)
                    .fill(Color(white: 0.1).opacity(motion.fillOpacity))
            }
        }
    }

    private struct Motion {
        let pillWidth: CGFloat
        let pillHeight: CGFloat
        let fillOpacity: Double
        let trackOpacity: Double
        let markWidth: CGFloat
        let markX: CGFloat
        let markOpacity: Double
        let isSolid: Bool
    }

    private func motion(at date: Date) -> Motion {
        guard let landedAt else {
            return Motion(
                pillWidth: Self.expandedWidth,
                pillHeight: Self.expandedHeight,
                fillOpacity: 0.8,
                trackOpacity: 1,
                markWidth: Self.light,
                markX: Self.sweepX(at: date, since: start),
                markOpacity: 1,
                isSolid: false
            )
        }

        let elapsed = max(0, date.timeIntervalSince(landedAt))
        let sweptTo = Self.sweepX(at: landedAt, since: start)

        if elapsed < Self.gather {
            let progress = Self.easeOut(elapsed / Self.gather)
            let markWidth = Self.mix(Self.light, Self.point, progress)
            let startCenter = sweptTo + Self.light / 2
            let center = Self.mix(startCenter, Self.track / 2, progress)
            return Motion(
                pillWidth: Self.expandedWidth,
                pillHeight: Self.expandedHeight,
                fillOpacity: 0.8,
                trackOpacity: 1 - progress,
                markWidth: markWidth,
                markX: center - markWidth / 2,
                markOpacity: 1,
                isSolid: true
            )
        }

        if elapsed < Self.holdUntil {
            return Motion(
                pillWidth: Self.expandedWidth,
                pillHeight: Self.expandedHeight,
                fillOpacity: 0.8,
                trackOpacity: 0,
                markWidth: Self.point,
                markX: (Self.track - Self.point) / 2,
                markOpacity: 1,
                isSolid: true
            )
        }

        let linear = min(1, (elapsed - Self.holdUntil) / Self.release)
        let collapse = Self.easeInOut(linear)
        let markWidth = Self.mix(Self.point, Self.restingWidth, collapse)
        return Motion(
            pillWidth: Self.mix(Self.expandedWidth, Self.restingWidth, collapse),
            pillHeight: Self.mix(Self.expandedHeight, Self.restingHeight, collapse),
            fillOpacity: Self.mix(0.8, 0.32, collapse),
            trackOpacity: 0,
            markWidth: markWidth,
            markX: (Self.track - markWidth) / 2,
            markOpacity: 1 - Self.easeOut(collapse),
            isSolid: true
        )
    }

    private static func sweepX(at date: Date, since start: Date) -> CGFloat {
        let phase = date.timeIntervalSince(start)
            .truncatingRemainder(dividingBy: period) / period
        return -light + (track + light) * phase
    }

    private static func easeOut(_ value: Double) -> Double {
        1 - pow(1 - value, 3)
    }

    private static func easeInOut(_ value: Double) -> Double {
        value < 0.5
            ? 4 * value * value * value
            : 1 - pow(-2 * value + 2, 3) / 2
    }

    private static func mix(_ from: CGFloat, _ to: CGFloat, _ progress: Double) -> CGFloat {
        from + (to - from) * CGFloat(progress)
    }

    private static func mix(_ from: Double, _ to: Double, _ progress: Double) -> Double {
        from + (to - from) * progress
    }

    private static let beam = LinearGradient(
        colors: [.white.opacity(0), .white.opacity(0.9), .white.opacity(0)],
        startPoint: .leading,
        endPoint: .trailing
    )
}
