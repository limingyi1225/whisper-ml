import AppKit
import OSLog
import SwiftUI

private let log = Logger(subsystem: "com.mingyili.Whisper", category: "hud")

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
    /// A desktop switch is animated; the window server settles the new Space's window
    /// list only once it has finished.
    private static let spaceSettleDelay: TimeInterval = 0.4
    /// Waking takes longer to settle than a desktop switch: the login window comes and
    /// goes, and the desktops are rebuilt behind it.
    private static let wakeSettleDelay: TimeInterval = 1.5
    /// Rebuilding replaces the panel outright, which restarts whatever it was
    /// animating. A check that keeps failing must not be able to do that once a second.
    ///
    /// `nonisolated` because `placementRepair` is, and reading a `let` from one is only
    /// a warning today — it is an error under the Swift 6 language mode.
    nonisolated private static let rebuildCooldown: TimeInterval = 5

    /// The pill belongs to every desktop, sits above full-screen apps, and never joins
    /// Exposé or the window cycle.
    private static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .canJoinAllApplications,
        .fullScreenAuxiliary,
        .stationary,
        .ignoresCycle,
    ]

    private var panel: NSPanel?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var wakeObservers: [NSObjectProtocol] = []
    private var unlockObserver: NSObjectProtocol?
    private var isVisibilityRequested = false
    private var placementEpoch = 0
    /// When the check that is already scheduled will run, so that a later event cannot
    /// quietly pull it forward — see `verifyPlacement(after:)`.
    private var placementDeadline: Date?
    private var lastRebuiltAt: Date?

    private init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { RecordingHUDController.shared.reposition() }
        }

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                RecordingHUDController.shared.verifyPlacement(after: Self.spaceSettleDelay)
            }
        }

        // Coming back from sleep — the machine's or just the screen's — is what
        // actually strands the pill, and waiting for the next time the user happens
        // to put their cursor in a text field to notice is waiting too long.
        wakeObservers = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
        ].map { name in
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    RecordingHUDController.shared.verifyPlacement(after: Self.wakeSettleDelay)
                }
            }
        }

        // Waking is not the moment the desktops come back. On a Mac that asks for a
        // password — which is the machine this was written for — the login window is
        // still up when `didWake` arrives, every window of ours is legitimately absent
        // from it, and the check correctly declines to act. So the wake trigger on its
        // own does nothing here: what actually repaired the pill was unlocking, and
        // only because unlocking happens to change the active desktop too. Observe the
        // unlock itself rather than lean on that side effect.
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                RecordingHUDController.shared.verifyPlacement(after: Self.wakeSettleDelay)
            }
        }
    }

    func show() {
        isVisibilityRequested = true
        // Reposition only on first creation (and via the explicit calls when a
        // dictation arms or the screen layout changes) — repositioning on every
        // phase change would let the pill jump displays mid-dictation just because
        // the pointer drifted onto another screen.
        if panel == nil {
            panel = makePanel()
            reposition()
        }
        panel?.orderFrontRegardless()
        verifyPlacement(after: Self.spaceSettleDelay)
    }

    func hide() {
        isVisibilityRequested = false
        placementEpoch &+= 1
        // The epoch bump abandons the scheduled check, so the deadline it was holding
        // has to go with it. Leaving it behind would make the next `show()` decline to
        // schedule anything, on the strength of a check that is never going to run.
        placementDeadline = nil
        panel?.orderOut(nil)
    }

    /// The pill is created once and then only ordered in and out, which is normally
    /// enough because it belongs to every desktop. It does not always stay that way:
    /// a lock and wake can cost it that membership, and it is then left on whichever
    /// desktop was in front when the lid closed — the app still believes it is showing
    /// the HUD, and it is, just not where the user is. So every desktop switch, every
    /// wake and every time the pill is asked for re-checks and repairs.
    ///
    /// The delays are not interchangeable: a desktop switch settles in 0.4s, a wake or
    /// unlock takes 1.5s because the login window comes and goes and the desktops are
    /// rebuilt behind it. Both arrive together — unlocking changes the active desktop —
    /// so scheduling unconditionally, each call invalidating the last whatever it was
    /// waiting for, let the 0.4s replace the 1.5s and ran the check while the window
    /// server was still moving windows around. A pending check due to run later than
    /// this one therefore stands; only a later deadline supersedes it.
    private func verifyPlacement(after delay: TimeInterval) {
        let deadline = Date().addingTimeInterval(delay)
        guard Self.shouldReschedule(pendingDeadline: placementDeadline, to: deadline) else {
            return
        }
        placementEpoch &+= 1
        let epoch = placementEpoch
        placementDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.placementEpoch == epoch else { return }
                self.placementDeadline = nil
                self.restorePlacementIfMissing()
            }
        }
    }

    /// Whether a newly requested check should replace the one already scheduled. Kept
    /// separate from the scheduling so the rule can be tested without a real timer.
    nonisolated static func shouldReschedule(
        pendingDeadline: Date?,
        to deadline: Date
    ) -> Bool {
        guard let pendingDeadline else { return true }
        return deadline > pendingDeadline
    }

    private func restorePlacementIfMissing() {
        guard isVisibilityRequested, let panel else { return }
        let now = Date()
        switch Self.placementRepair(
            screenIsLocked: Self.screenIsLocked(),
            onScreenWindows: Self.onScreenWindows(),
            panelWindowNumber: panel.windowNumber,
            lastRebuiltAt: lastRebuiltAt,
            now: now
        ) {
        case .none:
            return
        case .reassertDesktops:
            log.warning("HUD still missing shortly after a rebuild; re-asserting its desktops")
            // The assignment has to be a change for AppKit to forward it, so the
            // single-desktop value goes on first — for the fraction of a frame before
            // the real one replaces it, the pill is where it already was.
            panel.collectionBehavior = Self.collectionBehavior.subtracting(.canJoinAllSpaces)
            panel.collectionBehavior = Self.collectionBehavior
            panel.orderFrontRegardless()
        case .rebuild:
            log.warning("HUD lost its place on the active desktop; rebuilding it")
            lastRebuiltAt = now
            rebuildPanel()
        }
    }

    enum PlacementRepair: Equatable {
        case none
        case reassertDesktops
        case rebuild
    }

    /// What to do about a pill the window server does not list on the active desktop.
    /// Separate from the doing, because the two answers that would make things worse —
    /// putting a brand new pill onto the lock screen, and replacing the panel over and
    /// over while some other cause keeps the check failing — are worth pinning down.
    nonisolated static func placementRepair(
        screenIsLocked: Bool,
        onScreenWindows: [[String: Any]],
        panelWindowNumber: Int,
        lastRebuiltAt: Date?,
        now: Date
    ) -> PlacementRepair {
        guard !screenIsLocked else { return .none }
        // An empty list means the query failed rather than that the pill is gone.
        guard !onScreenWindows.isEmpty,
              !containsWindow(number: panelWindowNumber, in: onScreenWindows) else {
            return .none
        }
        // A fresh panel has only just been put up and is already reported missing.
        // Taking it away again this soon would restart its animation for nothing, so
        // try the cheap nudge instead and leave the next check to decide.
        if let lastRebuiltAt, now.timeIntervalSince(lastRebuiltAt) < rebuildCooldown {
            return .reassertDesktops
        }
        return .rebuild
    }

    /// Re-assigning the collection behaviour does not bring a stranded pill back: the
    /// window server has already decided which desktop that window lives on, and it
    /// keeps it there however the flags are set afterwards. A window it has never seen
    /// carries no such history, so the repair is to build a new one — it opens on the
    /// desktop in front of the user, which is the whole point.
    private func rebuildPanel() {
        let previousFrame = panel?.frame
        if let panel {
            panel.orderOut(nil)
            // The old panel's SwiftUI view observes the dictation controller. Detach it
            // rather than leave it rendering into a window nobody can see.
            panel.contentView = nil
            panel.close()
        }

        let replacement = makePanel()
        panel = replacement
        // Keep the pill where it was, which mid-utterance is where the user was told to
        // look. A frame left behind by a display that has since been unplugged is the
        // one case where starting over is better.
        if let previousFrame, NSScreen.screens.contains(where: { $0.frame.intersects(previousFrame) }) {
            replacement.setFrameOrigin(previousFrame.origin)
        } else {
            reposition()
        }
        replacement.orderFrontRegardless()
    }

    /// A locked screen is its own desktop, and none of our windows belong to it. Asking
    /// where the pill is while the login window is up would answer "nowhere" every time,
    /// and rebuilding on that answer would put a brand new pill onto the lock screen.
    private nonisolated static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    /// The windows the window server currently draws on the active desktop.
    private nonisolated static func onScreenWindows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
    }

    nonisolated static func containsWindow(
        number: Int,
        in windows: [[String: Any]]
    ) -> Bool {
        windows.contains { ($0[kCGWindowNumber as String] as? Int) == number }
    }

    static func shouldShow(
        phase: DictationController.Phase,
        hasFocusedEditableInput: Bool,
        isShowingSettledMark: Bool,
        isRehearsing: Bool = false
    ) -> Bool {
        // The first-run guide's 试一下 shows a copy of this pill in its own window and
        // says that the bar at the bottom of the screen is the same thing. Nothing else
        // would put it there while the user reads that: keyboard focus is inside
        // Whisper's own window, which the focus monitor deliberately ignores.
        if isRehearsing {
            return true
        }
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
        panel.collectionBehavior = Self.collectionBehavior
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
        case .failed, .failedQuiet:
            FailurePill(
                failedAt: controller.lastErrorAt,
                message: state == .failedQuiet ? nil : (controller.lastError ?? "出错了")
            )
        default:
            content
                .frame(width: width, height: height)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color(white: 0.1).opacity(fillOpacity))
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(
                                    .white.opacity(restingOutlineOpacity),
                                    lineWidth: 0.75
                                )
                                .padding(-0.375)
                        }
                }
                .padding(.vertical, 1)
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
        // Both failure states draw themselves; `FailurePill` owns their whole
        // timeline, shell included, the way `PolishPill` owns the settled one.
        case .failed, .failedQuiet:
            Color.clear
        }
    }

    // MARK: - Appearance per state

    private enum HUDState: Equatable {
        case idle, arming, listening, transcribing, polishing, settled
        /// A failure with something to say: the words, and the same shake.
        case failed
        /// A failure with nothing to say — the shake alone.
        case failedQuiet
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
        case .error: return controller.lastErrorIsWordless ? .failedQuiet : .failed
        }
    }

    private var isFailed: Bool {
        state == .failed || state == .failedQuiet
    }

    private var fillOpacity: Double {
        switch state {
        case .idle, .arming, .listening, .transcribing:
            return 0.48 + 0.32 * Double(shellExpansion)
        case .polishing, .settled, .failed, .failedQuiet:
            return 0.8
        }
    }

    /// The pill is dark in both appearances, so the line that rims it is the same line
    /// in both: white, at the same strength. It used to be gated to dark mode.
    private var restingOutlineOpacity: Double {
        switch state {
        case .idle, .arming, .listening, .transcribing:
            let restingAmount = min(max(1 - shellExpansion, 0), 1)
            return 0.4 * Double(restingAmount)
        case .polishing, .settled, .failed, .failedQuiet:
            return 0
        }
    }

    private var width: CGFloat {
        switch state {
        case .idle, .arming, .listening, .transcribing:
            return 54 + 30 * shellExpansion
        case .polishing, .settled:
            return 84
        // Sized against the longest message the app can actually produce, measured
        // at this font — a truncated error is a message nobody can act on. Stays
        // inside the 260pt panel with room for the capsule's own margins.
        case .failed: return 230
        case .failedQuiet: return 84
        }
    }

    private var height: CGFloat {
        switch state {
        case .idle, .arming, .listening, .transcribing:
            return 5 + 7 * shellExpansion
        case .polishing, .settled:
            return 12
        case .failed: return 18
        case .failedQuiet: return 12
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
        case .failed, .failedQuiet:
            // The shell underneath is prepared at rest, so replacing the failure pill
            // when the error clears cannot jump back open — the wordless one has
            // already animated down to exactly this by then.
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
    private static let restingWidth: CGFloat = 54
    private static let restingHeight: CGFloat = 5
    // Never narrower than the resting line it releases into, or the spread is clipped
    // by the track's own capsule on the last frames before the shell takes over.
    private static let track: CGFloat = 54
    private static let hair: CGFloat = 2
    private static let light: CGFloat = 22
    private static let point: CGFloat = 8
    private static let period: Double = 1.05
    private static let gather: Double = 0.20
    private static let holdUntil: Double = 0.45
    private static let release: Double = 0.35

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

/// What a failed sentence looks like: one shake of the head, at the size the pill was
/// waiting at when the answer did not come.
///
/// The gesture is the same for both kinds of failure, because from the user's side they
/// are the same event — that sentence did not happen. What differs is whether anything
/// is owed afterwards. A failure they can act on keeps its words and holds them up
/// (`message`); one they cannot keeps nothing and comes to rest, so the last thing on
/// screen is the same resting line as always rather than a sentence about a service that
/// is already working again by the time it is read. See
/// `DictationController.failureIsWordless`.
///
/// Both timelines run off `failedAt` rather than SwiftUI transitions: two failures in a
/// row carrying the same words are one changed date and no changed view, and the shake
/// has to start again for the second one.
private struct FailurePill: View {
    let failedAt: Date?
    /// `nil` for a failure with nothing to say.
    let message: String?

    /// Where the pill waits for an answer — `.polishing`'s size, which is also where
    /// `.transcribing` has grown to by the time an answer is late.
    private static let openWidth: CGFloat = 84
    private static let openHeight: CGFloat = 12
    private static let restingWidth: CGFloat = 54
    private static let restingHeight: CGFloat = 5
    /// Sized for the longest message the app can produce, as the error pill always was.
    private static let spokenWidth: CGFloat = 230
    private static let spokenHeight: CGFloat = 18

    /// A damped swing, ~2.5 passes through centre. The amplitude is small on purpose:
    /// this happens at the bottom edge of vision while the user is looking somewhere
    /// else, and it only has to read as "no", not as an animation to wait out.
    private static let amplitude: CGFloat = 2.5
    private static let swingPeriod: Double = 0.17
    private static let decay: Double = 0.13
    private static let shakeDuration: Double = 0.44
    /// A wordless failure goes home once the shake has stopped moving.
    private static let settleAt: Double = 0.46
    private static let settleDuration: Double = 0.34
    /// A spoken one grows into its words instead. It used to arrive at full width in
    /// one frame, held open by a spring on the state change; the pill now owns its own
    /// timeline, so the opening is part of it.
    private static let openDuration: Double = 0.3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            let elapsed = failedAt.map { max(0, timeline.date.timeIntervalSince($0)) } ?? 0
            let settled = settleProgress(at: elapsed)
            let opened = openProgress(at: elapsed)

            label
                .opacity(opened)
                .frame(
                    width: width(settled: settled, opened: opened),
                    height: height(settled: settled, opened: opened)
                )
                .background {
                    Capsule(style: .continuous)
                        .fill(Color(white: 0.1).opacity(Self.mix(0.8, 0.48, settled)))
                        .overlay {
                            // Fades in to exactly the resting outline, so the swap back
                            // to the ordinary shell when the error clears is invisible.
                            Capsule(style: .continuous)
                                .stroke(.white.opacity(0.4 * settled), lineWidth: 0.75)
                                .padding(-0.375)
                        }
                }
                .offset(x: Self.shakeOffset(at: elapsed))
        }
    }

    @ViewBuilder
    private var label: some View {
        if let message {
            Text(message)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 10)
        } else {
            Color.clear
        }
    }

    /// 0 while the pill is still open, 1 once a wordless failure has come to rest. A
    /// spoken one never settles: its words stay up until the error clears.
    private func settleProgress(at elapsed: Double) -> Double {
        guard message == nil else { return 0 }
        let linear = min(1, max(0, (elapsed - Self.settleAt) / Self.settleDuration))
        return Self.easeInOut(linear)
    }

    /// 0 to 1 as a spoken failure grows from the waiting size into its words. A
    /// wordless one has nothing to open into and stays at 1 throughout.
    private func openProgress(at elapsed: Double) -> Double {
        guard message != nil else { return 1 }
        return Self.easeOut(min(1, max(0, elapsed / Self.openDuration)))
    }

    private func width(settled: Double, opened: Double) -> CGFloat {
        message == nil
            ? Self.mix(Self.openWidth, Self.restingWidth, settled)
            : Self.mix(Self.openWidth, Self.spokenWidth, opened)
    }

    private func height(settled: Double, opened: Double) -> CGFloat {
        message == nil
            ? Self.mix(Self.openHeight, Self.restingHeight, settled)
            : Self.mix(Self.openHeight, Self.spokenHeight, opened)
    }

    /// A decaying sine, which is what a head shake is: the first swing is the one that
    /// carries, and the rest is the pill agreeing to stop.
    static func shakeOffset(at elapsed: Double) -> CGFloat {
        guard elapsed >= 0, elapsed < shakeDuration else { return 0 }
        let envelope = exp(-elapsed / decay)
        return amplitude * CGFloat(envelope * sin(2 * .pi * elapsed / swingPeriod))
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
}
