import AppKit
import CoreGraphics
import OSLog

/// Stamped onto every synthetic event we post so the event tap can tell our own
/// injected keystrokes apart from the user's and not react to them. Read from the
/// event tap callback, which is not actor-isolated.
nonisolated let kWhisperSyntheticMarker: Int64 = 0x5748_5052  // 'WHPR'

private let log = Logger(subsystem: "com.mingyili.Whisper", category: "hotkey")

/// Watches a single modifier key and reports press / long-press / release.
///
/// `flagsChanged` cannot distinguish left from right modifiers via `CGEventFlags`,
/// so we read the device-dependent bits (`NX_DEVICE…KEYMASK`) out of the raw flags.
@MainActor
final class HotKeyMonitor {
    enum Event {
        enum CancellationCause {
            /// An ordinary modifier tap or chord; no dictation should be produced.
            case userGesture
            /// Monitoring disappeared after the gesture had begun. The controller must
            /// finalize or visibly fail captured speech rather than treating it as a tap.
            case monitoringLost(String)
        }

        /// Key went down. Nothing is committed yet — we may still turn out to be a shortcut.
        case armed
        /// Held past the threshold: this is a dictation gesture.
        case longPressBegan
        /// Released after a long press. Finish the utterance.
        case released
        /// Released early, or the user pressed another key: abandon without transcribing.
        case cancelled(CancellationCause)
    }

    var onEvent: ((Event) -> Void)?

    private(set) var isTapEnabled = false
    /// True while the trigger key is physically down.
    private(set) var isTriggerHeld = false
    /// True while an un-cancelled dictation gesture is in progress. Distinct from
    /// `isTriggerHeld`: after a chord abandons the gesture, the key may still be
    /// physically down, but no `.released` will ever follow — treating that as
    /// "still dictating" would start a recording nothing can stop.
    var isGestureActive: Bool { isKeyDown }
    /// When the user last typed or clicked something themselves — our own synthetic
    /// keystrokes do not count. Used to tell whether the caret is still where we left
    /// it before rewriting already-typed text.
    private(set) var lastForeignInputAt: Date?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var holdTimer: Timer?
    private var isKeyDown = false
    private var didLongPress = false

    private var trigger: TriggerKey { AppSettings.shared.triggerKey }

    /// How long the trigger key must be held before it counts as dictation rather than
    /// an ordinary modifier press. Was briefly a three-tier setting; the middle tier is
    /// the only one anyone wanted, and a shortcut typed with this key cancels the arm
    /// anyway, so the other two bought nothing worth a row in Settings.
    private let threshold: TimeInterval = 0.3

    /// The real tap state, rather than the optimistic bookkeeping flag. TCC changes
    /// and Secure Event Input can invalidate or disable the Mach port underneath us.
    var isOperational: Bool {
        guard Permissions.hasAccessibility,
              !Permissions.isSecureInputEnabled,
              let tap,
              CFMachPortIsValid(tap) else {
            return false
        }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    // MARK: - Lifecycle

    /// Installs the tap. Requires Accessibility permission; returns false if denied.
    @discardableResult
    func start() -> Bool {
        if isOperational {
            isTapEnabled = true
            return true
        }
        if tap != nil { stop() }
        guard Permissions.hasAccessibility else {
            log.error("accessibility permission not granted; tap not installed")
            return false
        }
        guard !Permissions.isSecureInputEnabled else {
            log.info("Secure Event Input is active; delaying hotkey installation")
            return false
        }

        // Mouse-down is watched only to timestamp it: a click moves the caret, which
        // makes it unsafe to rewrite text we typed earlier.
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)

        // `.listenOnly`: we never swallow events, so the key keeps working normally
        // as a modifier for ordinary shortcuts.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: whisperEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("CGEvent.tapCreate failed")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        self.isTapEnabled = true
        log.info("event tap installed")
        return true
    }

    func stop(
        cancellationCause: Event.CancellationCause = .monitoringLost("热键监听中断，录音已提前结束")
    ) {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isTapEnabled = false
        cancelHold()

        // If the trigger is physically down right now (the user switched trigger keys
        // or restarted the monitor mid-hold), its release will arrive under the new
        // configuration and match nothing — the gesture would be stranded with the
        // controller armed and the microphone capturing indefinitely. Cancel it.
        if isKeyDown || isTriggerHeld {
            isKeyDown = false
            didLongPress = false
            isTriggerHeld = false
            onEvent?(.cancelled(cancellationCause))
        }
    }

    /// A disabled tap may never deliver the trigger's key-up. Cancel the gesture before
    /// attempting recovery so neither a hold timer nor the microphone can be stranded.
    fileprivate func handleDisabledTap() {
        let hadGesture = isKeyDown || isTriggerHeld
        cancelHold()
        isKeyDown = false
        didLongPress = false
        isTriggerHeld = false
        if hadGesture {
            onEvent?(.cancelled(.monitoringLost("热键监听被系统中断，录音已提前结束")))
        }

        guard Permissions.hasAccessibility,
              !Permissions.isSecureInputEnabled,
              let tap,
              CFMachPortIsValid(tap) else {
            isTapEnabled = false
            return
        }
        log.warning("event tap was disabled by the system; re-enabling")
        CGEvent.tapEnable(tap: tap, enable: true)
        isTapEnabled = CGEvent.tapIsEnabled(tap: tap)
    }

    // MARK: - Event handling

    fileprivate func handleFlagsChanged(keyCode: Int64, rawFlags: UInt64) {
        guard keyCode == trigger.keyCode else {
            // A different modifier changed while we were armed → it's a chord, not dictation.
            if isKeyDown, rawFlags & trigger.foreignModifierMask != 0 { abandon() }
            return
        }

        let isDown = rawFlags & trigger.deviceMask != 0
        isTriggerHeld = isDown
        if isDown {
            guard !isKeyDown else { return }
            // Other modifiers already held when the trigger goes down mean a chord
            // (⇧⌘-something) is being typed, not a dictation — never arm.
            guard rawFlags & trigger.foreignModifierMask == 0 else { return }
            isKeyDown = true
            didLongPress = false
            onEvent?(.armed)

            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: threshold, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isKeyDown, !self.didLongPress else { return }
                    self.didLongPress = true
                    self.onEvent?(.longPressBegan)
                }
            }
        } else {
            guard isKeyDown else { return }
            isKeyDown = false
            holdTimer?.invalidate()
            holdTimer = nil
            if didLongPress {
                didLongPress = false
                onEvent?(.released)
            } else {
                // Tapped, not held — an ordinary modifier press. Never transcribe it.
                onEvent?(.cancelled(.userGesture))
            }
        }
    }

    /// Any real keystroke while the trigger is held means the user is doing ⌘C / ⌘V / etc.
    fileprivate func handleKeyDown() {
        lastForeignInputAt = Date()
        guard isKeyDown else { return }
        abandon()
    }

    fileprivate func handleMouseDown() {
        lastForeignInputAt = Date()
    }

    private func abandon() {
        isKeyDown = false
        didLongPress = false
        cancelHold()
        onEvent?(.cancelled(.userGesture))
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
    }
}

// MARK: - C callback

/// Runs on the main run loop (that is where we attached the source), so it is safe to
/// hop straight onto the main actor. Keep this fast: a slow tap gets disabled by the OS.
private nonisolated func whisperEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { monitor.handleDisabledTap() }
        return Unmanaged.passUnretained(event)
    }

    // Ignore the keystrokes we synthesize ourselves.
    guard event.getIntegerValueField(.eventSourceUserData) != kWhisperSyntheticMarker else {
        return Unmanaged.passUnretained(event)
    }

    // Copy out primitives before hopping actors — CGEvent is not Sendable.
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let rawFlags = event.flags.rawValue

    switch type {
    case .flagsChanged:
        MainActor.assumeIsolated { monitor.handleFlagsChanged(keyCode: keyCode, rawFlags: rawFlags) }
    case .keyDown:
        MainActor.assumeIsolated { monitor.handleKeyDown() }
    case .leftMouseDown, .rightMouseDown:
        MainActor.assumeIsolated { monitor.handleMouseDown() }
    default:
        break
    }

    return Unmanaged.passUnretained(event)
}
