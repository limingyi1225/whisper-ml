import DictationKit
import AVFoundation
import AppKit
import OSLog

private let log = Logger(subsystem: "com.mingyili.Whisper", category: "dictation")

struct TranscriptEntry: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let date: Date
}

/// Wires the hotkey, the microphone, the Realtime session and the text output together.
@Observable
@MainActor
final class DictationController {
    static let shared = DictationController()

    enum Phase: Equatable {
        /// Waiting for the hotkey.
        case idle
        /// Key is down but the long-press threshold has not elapsed yet.
        case arming
        /// Actively capturing and streaming.
        case recording
        /// Key released; waiting for the tail of the transcript.
        case finalizing
        case error(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var level: Float = 0
    /// Transcript for the utterance in progress, for the HUD.
    private(set) var partialText: String = ""
    private(set) var history: [TranscriptEntry] = []
    private(set) var lastError: String?
    private(set) var isHotKeyActive = false
    /// True while the cleanup pass is running, as opposed to merely waiting for the
    /// tail of the transcript. From the outside the two look identical — nothing on
    /// screen moves during either — but cleanup is the one that takes a second or
    /// more and then rewrites what was already typed, so the HUD says which is which.
    private(set) var isPolishing = false
    /// When a cleaned-up sentence was delivered, for as long as the pill is marking
    /// the end of it. The *moment* rather than a flag: the mark animates from wherever
    /// the sweeping light had got to, which only the elapsed time since this can say.
    private(set) var settledAt: Date?

    var connectionStatus: RealtimeClient.Status { client.status }

    /// Set while the first-run guide is showing its 试一下 step.
    ///
    /// Dictation normally refuses to start when Whisper itself is frontmost, because
    /// there is no other app to type into and saying so is the only useful answer. The
    /// guide asks the user to try dictating at its own window, so for that one step the
    /// same moment becomes a rehearsal instead: hotkey, microphone, connection and
    /// cleanup all run for real, and only the injection is left out — the guide shows
    /// the sentence itself. It is scoped to "Whisper is frontmost": speaking into any
    /// other app while the guide is open still types there, exactly as it always did.
    ///
    /// Observed, not ignored: the HUD's visibility depends on it, and the guide flips it
    /// from a view body that the HUD's own observer has to hear about.
    var isRehearsing = false

    @ObservationIgnored private let hotKey = HotKeyMonitor()
    @ObservationIgnored private let audio = AudioCapture()
    @ObservationIgnored private let client = RealtimeClient()
    @ObservationIgnored private let polisher = TranscriptPolisher()

    /// What we have actually typed into the target app this utterance.
    @ObservationIgnored private var injectedText = ""
    /// The deltas accumulated for the current utterance. Kept as a whole so leading
    /// whitespace normalization sees the beginning of the sentence on every update.
    @ObservationIgnored private var accumulatedPartial = ""
    @ObservationIgnored private var utteranceStart: Date?
    @ObservationIgnored private var maxDurationTimer: Timer?
    /// Bumped per utterance so a cleanup call that is still in flight when the user
    /// moves on cannot deliver its result into the next one.
    @ObservationIgnored private var utteranceGeneration = 0
    @ObservationIgnored private var polishTask: Task<Void, Never>?
    /// The raw transcript held while cleanup runs, so it can still be emitted if the
    /// user starts speaking again before cleanup finishes.
    @ObservationIgnored private var pendingRawText: String?
    /// Where the text went, captured when the key is released. Rewriting already-typed
    /// text is only safe if the caret is still there.
    @ObservationIgnored private var injectionAnchor: InjectionAnchor?
    /// Set once the caret has demonstrably moved away; nothing more is typed or
    /// rewritten for this utterance.
    @ObservationIgnored private var injectionAbandoned = false
    /// Whether this utterance is the guide's rehearsal, decided when it starts. Frozen
    /// per utterance rather than read from `isRehearsing` later: the guide can be
    /// finished while a sentence is still in flight, and that sentence must not
    /// suddenly acquire a target it never had.
    @ObservationIgnored private var utteranceIsRehearsal = false
    /// Set when a new dictation is waiting for the previous transcript to land.
    @ObservationIgnored private var startWhenSettled = false
    /// Dictations that were spoken and released before the previous one settled, in
    /// the order they were spoken. Audio is frozen at release because the pre-roll
    /// buffer is shared with whatever gesture comes next. Target/rehearsal identity is
    /// frozen earlier, when the long press becomes a confirmed dictation, because the
    /// guide or focused field may change while the user is still holding the key.
    private enum QueuedUtterance {
        case captured(
            audio: Data,
            anchor: InjectionAnchor?,
            target: TextInjectionTarget?,
            isRehearsal: Bool,
            interruptionNotice: String?
        )
        case failed(message: String)
    }
    @ObservationIgnored private var queuedUtterances: [QueuedUtterance] = []
    /// The target/rehearsal identity of the confirmed queued gesture currently being
    /// held. Never recaptured on key-up: a guide dismissal or same-app focus change
    /// during the hold must not retarget already-spoken audio.
    @ObservationIgnored private var queuedGestureIdentity: QueuedGestureIdentity?
    /// Non-nil when the queued gesture currently being spoken has already failed —
    /// the microphone died mid-capture, or Secure Event Input blocked capture from
    /// ever starting. Its audio is truncated or gone; the release must not enqueue
    /// it as audio, and the failure is surfaced with this message once the
    /// utterance in flight settles (the phase — and the HUD — belong to that
    /// utterance until then).
    @ObservationIgnored private var queuedGestureFailureMessage: String?
    /// A gesture can own speculative pre-roll while `phase` still describes the
    /// previous utterance. Track that ownership independently so an idle/error race
    /// cannot make `.cancelled` forget to stop the microphone.
    @ObservationIgnored private var gestureOwnsCapture = false
    /// Identifies the AudioCapture run owned by the current physical gesture. Failure
    /// callbacks cross threads; the id prevents a late callback from an old run from
    /// cancelling a rapidly-started new dictation.
    @ObservationIgnored private var gestureCaptureGeneration: UInt64?
    /// Output mode frozen per utterance. Reading `settings.typesWhileSpeaking` live
    /// would let a model switch mid-utterance flip the mode halfway through — deltas
    /// already typed, then the final text pasted again on top.
    @ObservationIgnored private var utteranceTypesWhileSpeaking = false
    /// Same route the Realtime socket uses for this utterance. The cleanup pass keeps
    /// this snapshot even if the user switches connection mode while speaking.
    @ObservationIgnored private var utteranceRoute: ServiceRoute?
    /// Guards the 3s auto-dismiss of an error banner, so a newer error is not
    /// dismissed early by the previous error's timer.
    @ObservationIgnored private var errorEpoch = 0
    /// Guards the settle blink the same way, so a fast second sentence does not have
    /// its confirmation cut short by the previous one's timer.
    @ObservationIgnored private var settleEpoch = 0
    /// The cleanup failure already shown. A blocked region or a dead key fails on
    /// every single sentence; telling the user once is information, telling them
    /// every time is noise. Cleared by the next successful cleanup.
    @ObservationIgnored private var reportedPolishNotice: String?
    @ObservationIgnored private var deferredStartTimer: Timer?
    @ObservationIgnored private var hotKeyHealthTimer: Timer?

    /// Identifies the app and input state we typed into, so a late rewrite can tell
    /// whether it is still addressing the same place.
    struct InjectionAnchor: Equatable {
        let processIdentifier: pid_t?
        let lastForeignInputAt: Date?
    }

    struct QueuedGestureIdentity {
        let anchor: InjectionAnchor?
        let target: TextInjectionTarget?
        let isRehearsal: Bool
    }

    enum RecordingStart {
        /// A long press that became confirmed without waiting behind another utterance.
        case freshGesture
        /// A confirmed queued long press whose identity and pre-roll already belong to it.
        case promoteCapturedPrefix(QueuedGestureIdentity)
    }

    /// What remains of a held gesture when the utterance ahead of it settles.
    ///
    /// `promoteCapturedPrefix` is deliberately distinct from a fresh start: the long
    /// press was already confirmed, its target/rehearsal identity was already frozen,
    /// and the microphone has already captured the beginning of the sentence into
    /// pre-roll. The transition must consume all three together instead of looking at
    /// the now-current guide/focus state. An active gesture without a frozen identity
    /// is only an ordinary press still waiting to cross the long-press threshold.
    enum DeferredGestureDisposition {
        case inactive
        case awaitingLongPress
        case startRecording(RecordingStart)
    }

    /// Exact AX element and selection captured for the utterance. PID-level identity is
    /// not enough: two fields in one app share it, and asynchronous deltas/final text may
    /// arrive after focus moves between them. Every synthetic write proves this snapshot
    /// is still current; unavailable AX state fails closed to the clipboard.
    @ObservationIgnored private var injectionTarget: TextInjectionTarget?

    /// A recording can be cut short because Accessibility/Secure Event Input makes the
    /// hotkey monitor disappear. The audio captured so far is still finalized; this
    /// notice is shown afterwards so the truncation is not mistaken for a successful
    /// full-length sentence.
    @ObservationIgnored private var captureInterruptionNotice: String?

    /// Hard stop so a stuck key cannot stream forever.
    private let maxUtteranceDuration: TimeInterval = 120

    private var settings: AppSettings { AppSettings.shared }

    private init() {
        audio.onChunk = { [weak self] data in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.client.appendAudio(data) }
            }
        }
        audio.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.level = level }
        }
        // Async on purpose: `beginPreroll` can fail synchronously from inside
        // `beginRecording`, and handling the failure re-entrantly would interleave
        // with the state it is still setting up.
        audio.onCaptureFailure = { [weak self] generation in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleCaptureFailure(generation: generation)
                }
            }
        }

        hotKey.onEvent = { [weak self] event in
            self?.handleHotKey(event)
        }

        client.onDelta = { [weak self] delta in
            self?.handleDelta(delta)
        }
        client.onCompleted = { [weak self] transcript in
            self?.handleCompleted(transcript)
        }
        client.onFailure = { [weak self] message in
            self?.handleFailure(message)
        }
    }

    // MARK: - Lifecycle

    func start() {
        startHotKeyHealthMonitor()
        refreshHotKeyHealth()
        client.connectIfNeeded()
    }

    private func startHotKeyHealthMonitor() {
        hotKeyHealthTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshHotKeyHealth()
            }
        }
        hotKeyHealthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshHotKeyHealth() {
        guard Permissions.hasAccessibility else {
            hotKey.stop(cancellationCause: .monitoringLost(
                "辅助功能权限中断，录音已提前结束"
            ))
            isHotKeyActive = false
            return
        }
        guard !Permissions.isSecureInputEnabled else {
            hotKey.stop(cancellationCause: .monitoringLost(
                "安全输入已开启，录音已提前结束"
            ))
            isHotKeyActive = false
            return
        }
        if !hotKey.isOperational {
            hotKey.stop(cancellationCause: .monitoringLost(
                "热键监听中断，录音已提前结束"
            ))
            isHotKeyActive = hotKey.start()
        } else {
            isHotKeyActive = true
        }
    }

    /// Whether an utterance with this target is the guide's rehearsal.
    ///
    /// Both halves are load-bearing. Without a target there is nowhere to type, but that
    /// alone must never mean "throw the sentence away": outside the guide it is the
    /// clipboard-fallback case, where the user spoke into an app and then switched away
    /// before the transcript came back. Only the guide asking for a rehearsal turns a
    /// missing target into a sentence nobody was ever going to receive.
    static func isRehearsal(hasTarget: Bool, isRehearsing: Bool) -> Bool {
        !hasTarget && isRehearsing
    }

    /// Release consumes the identity frozen when the long press was confirmed. This
    /// intentionally takes no live guide/focus input, so a UI transition during the
    /// hold cannot turn a rehearsal into a real injection (or retarget real speech).
    static func rehearsalAtQueuedRelease(_ identity: QueuedGestureIdentity) -> Bool {
        identity.isRehearsal
    }

    /// Live deltas intentionally depend on ordered input/focus evidence, not an
    /// immediate caret acknowledgement: CGEvent.post is asynchronous, so the target
    /// app may still report the pre-delta caret when the next network delta arrives.
    static func canContinueLiveInjection(
        anchorUnchanged: Bool,
        exactElementFocused: Bool?
    ) -> Bool {
        // `nil` is a control that publishes no focused element to compare — the answer
        // Electron and WebView editors give — and it is deliberately not disproof. The
        // optional is resolved here rather than at the call site so a test can pin it;
        // the three times this rule was inverted, it was inverted at a call site no
        // test could reach.
        anchorUnchanged && exactElementFocused != false
    }

    /// Whether the destructive half of a cleanup rewrite may post its backspaces.
    ///
    /// Two independent kinds of evidence, both optional, because most targets publish
    /// neither and absent evidence is not disproof.
    ///
    /// `typedTextStillBeforeCaret` outranks the other. `false` is a control that
    /// answered and contradicted us: our keystrokes are no longer what sits before the
    /// caret, so backspacing by our own count would cross into the user's text. `true`
    /// is positive proof that the caret is exactly where the deltas left it, and it
    /// settles the question on its own — in particular it overrides an element mismatch,
    /// because an app that rebuilt its accessibility tree around the text we just typed
    /// vends a fresh object for the very field we are still correctly addressing.
    ///
    /// `sameElementStillFocused` only decides the remaining case: a control that
    /// exposes no text range at all. There, `false` — the system naming some *other*
    /// element — is the only signal left that focus moved within the app, and
    /// backspacing would eat that other control's content. `nil` is the system naming
    /// nothing, which is not the same thing; refusing on it leaves the raw deltas on
    /// screen and strands the corrected sentence on the clipboard, which is what the
    /// whole cleanup feature looks like when it is broken.
    static func rewriteMayDelete(
        typedTextStillBeforeCaret: Bool?,
        sameElementStillFocused: Bool?
    ) -> Bool {
        if let typedTextStillBeforeCaret { return typedTextStillBeforeCaret }
        return sameElementStillFocused != false
    }

    /// Ownership, not the previous utterance's presentation phase, decides whether a
    /// monitoring loss must preserve a queued recording. In particular `handleFailure`
    /// moves the HUD to `.error` for 1.2 s while this gesture is still capturing.
    static func shouldPreserveInterruptedQueuedGesture(
        phase _: Phase,
        startWhenSettled: Bool,
        gestureOwnsCapture: Bool,
        hasFrozenIdentity: Bool
    ) -> Bool {
        startWhenSettled && gestureOwnsCapture && hasFrozenIdentity
    }

    static func deferredGestureDisposition(
        isGestureActive: Bool,
        frozenIdentity: QueuedGestureIdentity?
    ) -> DeferredGestureDisposition {
        guard isGestureActive else { return .inactive }
        guard let frozenIdentity else { return .awaitingLongPress }
        return .startRecording(.promoteCapturedPrefix(frozenIdentity))
    }

    /// Resolves where a recording belongs. `captureFresh` is lazy by contract: a
    /// promoted queued gesture must not even ask AX or the guide for their current state.
    static func recordingIdentity(
        for start: RecordingStart,
        captureFresh: () -> QueuedGestureIdentity
    ) -> QueuedGestureIdentity {
        switch start {
        case .freshGesture:
            return captureFresh()
        case .promoteCapturedPrefix(let frozenIdentity):
            return frozenIdentity
        }
    }

    private func captureCurrentGestureIdentity() -> QueuedGestureIdentity {
        let anchor = currentAnchor()
        let target = anchor?.processIdentifier.flatMap {
            TextInjector.captureTarget(expectedPID: $0)
        }
        return QueuedGestureIdentity(
            anchor: anchor,
            target: target,
            isRehearsal: Self.isRehearsal(
                hasTarget: anchor != nil,
                isRehearsing: isRehearsing
            )
        )
    }

    private func freezeQueuedGestureIdentity() {
        guard queuedGestureIdentity == nil else { return }
        queuedGestureIdentity = captureCurrentGestureIdentity()
    }

    /// Snapshot of where synthetic text is currently going.
    private func currentAnchor() -> InjectionAnchor? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        return InjectionAnchor(
            processIdentifier: frontmost.processIdentifier,
            lastForeignInputAt: hotKey.lastForeignInputAt
        )
    }

    /// Called after the user grants Accessibility, or changes the trigger key.
    func restartHotKey() {
        hotKey.stop(cancellationCause: .monitoringLost(
            "热键设置发生变化，录音已提前结束"
        ))
        refreshHotKeyHealth()
    }

    /// Called after the API key, model or prompt changes.
    func reconnect() {
        client.reconnectNow()
    }

    /// A WebSocket that crossed system sleep is not trusted even if Foundation still
    /// reports it as open. Replacing it on wake prevents the first later dictation from
    /// being the liveness probe. `reconnectNow` already defers safely at an utterance
    /// boundary if the machine somehow wakes while one is active.
    func systemDidWake() {
        client.reconnectNow()
    }

    // MARK: - Hotkey

    private func handleHotKey(_ event: HotKeyMonitor.Event) {
        switch event {
        case .armed:
            // Also armed while still finalizing: cleanup takes ~1.5s, which is easily
            // short enough for the user to start their next sentence before it lands.
            // Start capturing so nothing is lost, but leave the phase alone — this
            // press may yet turn out to be an ordinary ⌘C.
            guard phase == .idle || isErrorPhase || phase == .finalizing else { return }
            // The user is about to speak *here* — move the pill to whichever screen
            // they are on. This event is the one signal that also covers queued
            // gestures, which never pass through `.arming`.
            RecordingHUDController.shared.reposition()
            guard !Permissions.isSecureInputEnabled else {
                gestureOwnsCapture = false
                let message = "当前输入框启用了安全输入，无法听写"
                if phase == .finalizing || startWhenSettled {
                    // The phase (and HUD) belong to the utterance in flight, and no
                    // capture ever starts for this gesture. Mark it as a failed
                    // outcome so the queue surfaces the real reason in FIFO order —
                    // admitting it as audio would freeze an empty buffer, commit
                    // zero bytes, and misreport the sentence as "录音太短".
                    queuedGestureFailureMessage = message
                } else {
                    showError(message)
                }
                return
            }
            // While a queue is draining, the phase (and the HUD) belong to the
            // utterance in flight — overwriting its `.error` with `.arming` here
            // would strand `.arming` on screen until the queue settles, because
            // `.longPressBegan` joins the queue without ever touching the phase.
            if phase != .finalizing, !startWhenSettled {
                phase = .arming
                lastError = nil
            }
            gestureOwnsCapture = true
            queuedGestureFailureMessage = nil
            queuedGestureIdentity = nil
            if startWhenSettled {
                audio.setPrerollCapacity(seconds: queuedPrerollCapacitySeconds)
            }
            // Capture from the instant the key goes down so the first syllable is
            // never clipped; the audio is discarded if this turns out to be a tap.
            gestureCaptureGeneration = audio.beginPreroll()

        case .longPressBegan:
            // Now we know it is dictation and not a shortcut.
            if startWhenSettled {
                // A queue is already waiting on the previous utterance (the phase
                // may meanwhile be showing that utterance's error). This press has
                // been buffering since `.armed`; freeze its identity now, not when
                // the key eventually comes up.
                freezeQueuedGestureIdentity()
                return
            }
            if phase == .finalizing {
                if pendingRawText != nil {
                    // The transcript is in hand and only cleanup is outstanding —
                    // emit the un-cleaned text now rather than making the user wait.
                    settleImmediately()
                } else {
                    // The transcript itself is still in flight (~0.3s). Throwing it
                    // away here would silently lose a whole sentence in the modes
                    // where nothing has been typed yet, so wait for it instead. The
                    // pre-roll buffer is already capturing, so no audio is lost.
                    freezeQueuedGestureIdentity()
                    waitForPreviousUtterance()
                    return
                }
            }
            // `.error` is accepted too: a gesture armed while the previous utterance
            // was finalizing keeps its phase untouched, so if that utterance fails
            // in the 200–500ms before the long press confirms, the phase is
            // `.error` here — rejecting it would silently drop this whole sentence.
            guard phase == .arming || phase == .idle || isErrorPhase else { return }
            beginRecording()

        case .released:
            // A dictation queued behind an unfinished one never reached `.recording`,
            // so the phase check below would drop this release on the floor and the
            // whole sentence with it. Freeze its audio out of the pre-roll buffer
            // right now: the buffer belongs to whatever gesture comes next, and a
            // later tap or shortcut must not be able to destroy a finished sentence.
            if startWhenSettled {
                // If capture failed mid-gesture (microphone died, or Secure Event
                // Input blocked it from starting) the audio is truncated or absent —
                // retain a failure marker in FIFO order instead of letting a later
                // gesture clear a global flag and silently erase this one.
                if let failureMessage = queuedGestureFailureMessage {
                    audio.stop()
                    queuedUtterances.append(.failed(message: failureMessage))
                } else {
                    let stopped = audio.stopAndDrainPreroll()
                    if stopped.captureFailed {
                        queuedUtterances.append(.failed(message: "麦克风不可用，录音已中断"))
                    } else if let identity = queuedGestureIdentity {
                        queuedUtterances.append(.captured(
                            audio: stopped.audio,
                            anchor: identity.anchor,
                            target: identity.target,
                            isRehearsal: Self.rehearsalAtQueuedRelease(identity),
                            interruptionNotice: nil
                        ))
                    } else {
                        // `.released` should only follow a confirmed long press. If the
                        // monitor violates that contract, preserve a visible outcome
                        // instead of inventing an identity at this later focus state.
                        queuedUtterances.append(.failed(message: "无法确认排队听写的原始输入位置"))
                    }
                }
                queuedGestureFailureMessage = nil
                queuedGestureIdentity = nil
                gestureOwnsCapture = false
                gestureCaptureGeneration = nil
                return
            }
            guard phase == .recording else { return }
            gestureOwnsCapture = false
            endRecording()

        case .cancelled(let cause):
            let monitoringLoss: String?
            switch cause {
            case .userGesture:
                monitoringLoss = nil
            case .monitoringLost(let message):
                monitoringLoss = message
            }
            if let monitoringLoss,
               preserveInterruptedQueuedGestureIfNeeded(message: monitoringLoss) {
                return
            }
            switch phase {
            case .arming:
                cancelCurrentGestureCapture()
                if let monitoringLoss {
                    showError(monitoringLoss)
                } else {
                    phase = .idle
                }
            case .finalizing:
                // Was a shortcut after all; drop the speculative capture and let the
                // cleanup that is still running finish normally. A confirmed queued
                // gesture was already consumed by the ownership check above.
                cancelCurrentGestureCapture()
            case .recording:
                if let monitoringLoss {
                    // The release event is gone, but the audio already captured is valid.
                    // Finalize that prefix so non-live output reaches the clipboard and
                    // show why it may be truncated once the transcript settles.
                    captureInterruptionNotice = monitoringLoss
                    endRecording()
                } else {
                    cancelCurrentGestureCapture()
                    client.cancelUtterance()
                    stopMaxDurationTimer()
                    phase = .idle
                    partialText = ""
                    accumulatedPartial = ""
                    injectedText = ""
                    utteranceRoute = nil
                    injectionTarget = nil
                    utteranceIsRehearsal = false
                }
            case .idle, .error:
                // `phase` may have changed underneath a speculative gesture when the
                // previous utterance completed or failed during the hold threshold.
                // Capture ownership, not phase, decides whether the engine must stop.
                cancelCurrentGestureCapture()
            }
        }
    }

    /// Freezes a confirmed queued gesture when the monitor disappears, regardless of
    /// whether the previous utterance is still `.finalizing`, currently showing
    /// `.error`, or has briefly reached `.idle` before its delayed drain runs.
    private func preserveInterruptedQueuedGestureIfNeeded(message: String) -> Bool {
        guard Self.shouldPreserveInterruptedQueuedGesture(
            phase: phase,
            startWhenSettled: startWhenSettled,
            gestureOwnsCapture: gestureOwnsCapture,
            hasFrozenIdentity: queuedGestureIdentity != nil
        ), let identity = queuedGestureIdentity else {
            return false
        }

        gestureOwnsCapture = false
        gestureCaptureGeneration = nil
        queuedGestureFailureMessage = nil
        queuedGestureIdentity = nil
        let stopped = audio.stopAndDrainPreroll()
        if stopped.captureFailed {
            queuedUtterances.append(.failed(message: "麦克风不可用，录音已中断"))
        } else {
            queuedUtterances.append(.captured(
                audio: stopped.audio,
                anchor: identity.anchor,
                target: identity.target,
                isRehearsal: Self.rehearsalAtQueuedRelease(identity),
                interruptionNotice: message
            ))
        }
        return true
    }

    private func cancelCurrentGestureCapture() {
        gestureOwnsCapture = false
        gestureCaptureGeneration = nil
        queuedGestureFailureMessage = nil
        queuedGestureIdentity = nil
        if startWhenSettled, queuedUtterances.isEmpty {
            // Only the in-progress gesture is abandoned. Frozen queue entries belong
            // to earlier releases and must still drain in order.
            startWhenSettled = false
            deferredStartTimer?.invalidate()
            deferredStartTimer = nil
            audio.setPrerollCapacity(seconds: 1)
        }
        audio.stop()
    }

    private func beginRecording(from start: RecordingStart = .freshGesture) {
        // `.armed` already has the engine capturing into the pre-roll buffer. Every
        // failure exit below must stop it, or the microphone stays on until quit —
        // `.released` won't stop it either, because the phase will be `.error`.
        guard !Permissions.isSecureInputEnabled else {
            audio.stop()
            gestureOwnsCapture = false
            gestureCaptureGeneration = nil
            showError("当前输入框启用了安全输入，无法听写")
            return
        }
        guard Permissions.hasMicrophone || Permissions.microphoneStatus == .notDetermined else {
            audio.stop()
            gestureOwnsCapture = false
            gestureCaptureGeneration = nil
            showError("没有麦克风权限")
            return
        }
        // Reject an incomplete direct or relay configuration before capture begins;
        // otherwise no socket can ever deliver a result and the recording would sit
        // buffered until its connection timeout.
        let route: ServiceRoute
        do {
            route = try client.routeForNextUtterance()
        } catch {
            audio.stop()
            gestureOwnsCapture = false
            gestureCaptureGeneration = nil
            showError(error.localizedDescription)
            return
        }
        let identity = Self.recordingIdentity(for: start) {
            // Only an ordinary newly-confirmed gesture reads live guide/focus state.
            self.captureCurrentGestureIdentity()
        }
        guard identity.anchor != nil || identity.isRehearsal else {
            audio.stop()
            gestureOwnsCapture = false
            gestureCaptureGeneration = nil
            showError("请先切回需要输入文字的 App")
            return
        }

        // A new utterance supersedes any completion mark still finishing its release.
        if settledAt != nil {
            settleEpoch += 1
            settledAt = nil
        }
        cancelPolish()
        phase = .recording
        partialText = ""
        accumulatedPartial = ""
        injectedText = ""
        pendingRawText = nil
        captureInterruptionNotice = nil
        // A fresh start clears a capture-failure marker from a gesture whose queue
        // was dissolved before the marker was consumed; the engine is retried from
        // scratch below and will re-report if the microphone is still gone.
        queuedGestureFailureMessage = nil
        utteranceGeneration += 1
        utteranceStart = Date()
        utteranceIsRehearsal = identity.isRehearsal
        // A rehearsal types nothing, so it must not stream deltas either — that is the
        // path that puts characters on screen before the key is even released.
        utteranceTypesWhileSpeaking = !utteranceIsRehearsal && settings.typesWhileSpeaking
        utteranceRoute = route
        // Taken once, at the start. Refreshing it as each delta lands would let an
        // edit the user made mid-sentence be masked by the next delta, and the later
        // rewrite would then chew through their change.
        injectionAnchor = identity.anchor
        injectionTarget = identity.target
        injectionAbandoned = false

        client.beginUtterance()

        switch start {
        case .freshGesture:
            // No-op when `.armed` already started capture; a safety net if that path
            // was skipped. A deferred start must not call this because its buffered
            // prefix is already owned by the confirmed queued gesture.
            if let generation = audio.beginPreroll() {
                gestureCaptureGeneration = generation
            }
        case .promoteCapturedPrefix:
            break
        }
        // Both the long-press threshold and any wait behind the previous utterance are
        // part of this sentence. Promote, rather than restart, that captured prefix.
        let preroll = audio.startStreaming(
            includePreroll: true,
            nextPrerollCapacitySeconds: 1
        )
        if !preroll.isEmpty { client.appendAudio(preroll) }

        startMaxDurationTimer()
        log.info("recording started")
    }

    private func endRecording() {
        gestureOwnsCapture = false
        let stopped = audio.stop()
        let captureFailed = stopped.captureFailed
            && stopped.generation == gestureCaptureGeneration
        gestureCaptureGeneration = nil
        stopMaxDurationTimer()
        if captureFailed {
            client.cancelUtterance()
            handleFailure("麦克风不可用，录音已中断")
            return
        }
        phase = .finalizing
        // The meter is the only thing on the pill while the tail of the transcript
        // arrives, so it has to stop reading the last level it saw before the
        // microphone went away — flat bars are what says "not listening any more".
        level = 0
        // Audio chunks cross from the capture thread to the main queue; any that were
        // already enqueued when the key went up would land *after* an immediate
        // commit, and the server drops them from the turn (commit clears its buffer).
        // Hop through the same queue so the commit runs behind every one of them —
        // otherwise a busy main thread eats the last syllable.
        let generation = utteranceGeneration
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.utteranceGeneration == generation else { return }
                self.client.commitUtterance()
            }
        }
        log.info("recording stopped after \(Date().timeIntervalSince(self.utteranceStart ?? Date()))s")
    }

    private func startMaxDurationTimer() {
        stopMaxDurationTimer()
        // `.common`, not the default mode: a safety backstop must keep ticking
        // while the menu-bar menu is open (menu tracking suspends `.default`).
        let timer = Timer(timeInterval: maxUtteranceDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .recording else { return }
                log.warning("hit max utterance duration; finalizing")
                self.endRecording()
            }
        }
        maxDurationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopMaxDurationTimer() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
    }

    // MARK: - Transcript

    private func handleDelta(_ delta: String) {
        guard phase == .recording || phase == .finalizing else { return }
        accumulatedPartial += delta
        emitPartial()
    }

    /// Types whatever part of the utterance is now settled but not yet on screen.
    private func emitPartial() {
        var text = accumulatedPartial
        // The service tends to open an utterance with a leading space. Whether that
        // space is wanted depends on the language at the caret — see
        // `normalizeLeadingSpace`, which `normalize` mirrors so the final transcript
        // and the typed deltas never disagree about character zero (a mismatch there
        // would make `reconcile` rewrite the entire sentence).
        text = Self.normalizeLeadingSpace(text)

        guard text.count > partialText.count else { return }
        let addition = String(Array(text)[partialText.count...])
        partialText = text
        guard utteranceTypesWhileSpeaking, !injectionAbandoned else { return }

        // Deltas keep arriving for ~700ms after the key is released. If the user has
        // clicked elsewhere or started typing in that window, the caret is no longer
        // ours and the rest of the sentence would land in the wrong place — so stop
        // injecting rather than scattering text across their document.
        //
        // The frozen AX element sharpens that check when the control publishes one, and
        // is deliberately not required. A system-wide focused-element read answers
        // `kAXErrorNoValue` for whole classes of editors; making it a precondition
        // abandoned injection on the first delta of every sentence in those apps and
        // sent the transcript to the clipboard instead.
        guard let injectionAnchor,
              let current = currentAnchor(),
              Self.canContinueLiveInjection(
                anchorUnchanged: injectionAnchor == current,
                exactElementFocused: injectionTarget.map(TextInjector.targetIsStillFocused)
              ) else {
            injectionAbandoned = true
            log.info("the frozen field moved or foreign input arrived; stopping injection")
            return
        }

        TextInjector.type(addition)
        injectedText += addition
    }

    private func handleCompleted(_ transcript: String) {
        let final = normalize(transcript)

        // The completed transcript is authoritative — when it comes back empty,
        // provisional deltas already typed are overridden and must come back out,
        // the same rule the stripped-trailing-period path applies in `finish`.
        // Leaving them would strand text in the document that neither the final
        // result nor history accounts for. Deleting the *whole* sentence is the
        // maximal destructive case though, so unlike a partial rewrite it demands
        // positive AX proof that exactly our ghost text sits before the caret in
        // the app we typed it into — targets that cannot prove it (no AX ranges)
        // keep the ghost text, which the user can delete by hand; text destroyed
        // by unverified backspaces cannot be brought back.
        if final.isEmpty, utteranceTypesWhileSpeaking, !injectedText.isEmpty,
           Permissions.hasAccessibility, !Permissions.isSecureInputEnabled {
            if TextInjector.matchesTextImmediatelyBeforeCaret(
                injectedText,
                expectedProcessIdentifier: injectionAnchor?.processIdentifier
            ) == true {
                reconcile(with: "")
            } else {
                log.warning("empty final transcript, but the ghost deltas cannot be verified; leaving them")
            }
        }

        // Someone is already speaking the next sentence: emit this one as-is rather
        // than spending another 1.5s on cleanup while they wait.
        if startWhenSettled {
            finish(with: final.isEmpty ? nil : final)
            startDeferredIfPending()
            return
        }

        guard !final.isEmpty else {
            log.info("empty transcript; nothing to insert")
            finish(with: nil)
            return
        }

        guard settings.polishEnabled else {
            finish(with: final)
            return
        }

        // Stay in `.finalizing` while cleaning up, so the HUD keeps showing that
        // something is still happening.
        pendingRawText = final
        let generation = utteranceGeneration
        guard let route = utteranceRoute else {
            pendingRawText = nil
            finish(with: final)
            reportPolishFailure("当前听写没有可用的网络路由")
            return
        }
        cancelPolish()
        isPolishing = true
        polishTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.polisher.polish(final, route: route)
            guard !Task.isCancelled,
                  self.utteranceGeneration == generation,
                  self.pendingRawText == final else {
                log.info("cleanup finished after the utterance was already settled; discarding")
                return
            }
            self.polishTask = nil
            self.pendingRawText = nil

            var result = final
            var notice: String?
            var cleanupSucceeded = false
            switch outcome {
            case .cleaned(let text):
                result = text
                cleanupSucceeded = true
                // Working again — so if it breaks a second time, say so a second time.
                self.reportedPolishNotice = nil
            case .unchanged(let reason):
                notice = reason
            }

            // The polisher trims outer whitespace, which would undo the deliberate
            // leading space kept by `normalizeLeadingSpace` and glue the sentence
            // to the word before the caret.
            if final.hasPrefix(" "), !result.hasPrefix(" ") { result = " " + result }
            let captureWasInterrupted = self.captureInterruptionNotice != nil
            self.finish(with: result, confirmsCleanup: cleanupSucceeded)
            // After `finish`, never before: its `defer` resets the phase, which would
            // wipe the notice off the pill in the same frame it went up.
            if let notice, !captureWasInterrupted { self.reportPolishFailure(notice) }
        }
    }

    /// Holds the new dictation until the previous transcript lands, then starts it.
    ///
    /// Deliberately does not cancel the previous utterance to protect the pre-roll:
    /// in paste and clipboard modes nothing has been emitted yet, so cancelling would
    /// silently lose that whole sentence. Growing the buffer costs a little memory;
    /// cancelling costs the user their words.
    private func waitForPreviousUtterance() {
        audio.setPrerollCapacity(seconds: queuedPrerollCapacitySeconds)
        guard !startWhenSettled else { return }
        startWhenSettled = true
        log.info("previous transcript still in flight; holding the new utterance")

        armDeferredStartBackstop()
    }

    /// Keeps the controller-level backstop behind the client's current legal deadline.
    /// The client can extend that deadline when a slow connection becomes ready or when
    /// the server acknowledges a long upload, so every firing re-checks and reschedules.
    private func armDeferredStartBackstop() {
        deferredStartTimer?.invalidate()
        let delay = Self.deferredBackstopDelay(
            clientDeadline: client.currentUtteranceTimeoutDeadline,
            now: Date()
        )
        // `.common`, not the default mode: this backstop must keep ticking while
        // the menu-bar menu is open (menu tracking suspends `.default`).
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.startWhenSettled else { return }
                if let deadline = self.client.currentUtteranceTimeoutDeadline,
                   deadline > Date() {
                    self.armDeferredStartBackstop()
                    return
                }
                log.warning("previous utterance exceeded its authoritative timeout")
                self.client.cancelUtterance()
                self.pendingRawText = nil
                // Visible, unlike the old direct phase reset: if the client's own
                // timeout callback vanished, the sentence must not disappear silently.
                self.handleFailure("等待上一句转写结果超时")
            }
        }
        deferredStartTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    static func deferredBackstopDelay(
        clientDeadline: Date?,
        now: Date,
        minimumDelay: TimeInterval = 30
    ) -> TimeInterval {
        guard let clientDeadline else { return minimumDelay }
        // One second ensures the client's authoritative timer and failure callback get
        // the first chance to settle the utterance when both live on the main run loop.
        return max(minimumDelay, clientDeadline.timeIntervalSince(now) + 1)
    }

    /// Starts the dictation that was held back, provided the key is still down.
    private func startDeferredIfPending() {
        guard startWhenSettled else { return }
        startWhenSettled = false
        deferredStartTimer?.invalidate()
        deferredStartTimer = nil

        if !queuedUtterances.isEmpty {
            // Committing a queued utterance has exactly one way to fail — resolving the
            // route — and that failure is never per-sentence: a credential deleted, or a
            // connection mode switched to one that has none, breaks every entry behind
            // this one too. So probe before dequeuing. Dequeuing first and discovering
            // it afterwards destroyed already-spoken audio one entry at a time and put
            // the same error pill on screen once per sentence, 1.2 s apart. The audio
            // still cannot go anywhere — it is raw PCM with no transcript, so there is
            // nothing to fall back to the clipboard with — but say it once, and say how
            // many sentences went with it.
            if case .captured = queuedUtterances[0], let reason = queuedRouteFailure() {
                let lost = queuedUtterances.count
                queuedUtterances.removeAll()
                let hasAnotherGesture = hotKey.isGestureActive
                    || queuedGestureFailureMessage != nil
                if hasAnotherGesture {
                    startWhenSettled = true
                    audio.setPrerollCapacity(seconds: queuedPrerollCapacitySeconds)
                } else {
                    audio.setPrerollCapacity(seconds: 1)
                }
                handleFailure(lost > 1 ? "\(reason)（排队的 \(lost) 句听写已丢弃）" : reason)
                return
            }

            // Already spoken and released — settle the oldest outcome in FIFO order.
            // A capture failure is an outcome too; keeping it in the queue prevents a
            // later healthy gesture from erasing or inheriting that failure.
            let next = queuedUtterances.removeFirst()
            switch next {
            case .captured:
                let hasAnotherGesture = !queuedUtterances.isEmpty
                    || hotKey.isGestureActive
                    || queuedGestureFailureMessage != nil
                if let message = commitQueuedUtterance(next) {
                    if hasAnotherGesture {
                        startWhenSettled = true
                        audio.setPrerollCapacity(seconds: queuedPrerollCapacitySeconds)
                    } else {
                        audio.setPrerollCapacity(seconds: 1)
                    }
                    handleFailure(message)
                } else if hasAnotherGesture {
                    waitForPreviousUtterance()
                } else {
                    audio.setPrerollCapacity(seconds: 1)
                    audio.stop()
                    gestureCaptureGeneration = nil
                }
            case .failed(let message):
                let hasAnotherGesture = !queuedUtterances.isEmpty
                    || hotKey.isGestureActive
                    || queuedGestureFailureMessage != nil
                if hasAnotherGesture {
                    startWhenSettled = true
                    audio.setPrerollCapacity(seconds: queuedPrerollCapacitySeconds)
                } else {
                    audio.setPrerollCapacity(seconds: 1)
                }
                handleFailure(message)
            }
            return
        }

        if let failureMessage = queuedGestureFailureMessage {
            // Capture for this gesture failed while it was being spoken; its audio
            // is gone. Now that the previous utterance has settled, say so.
            queuedGestureFailureMessage = nil
            audio.setPrerollCapacity(seconds: 1)
            handleFailure(failureMessage)
            return
        }
        switch Self.deferredGestureDisposition(
            isGestureActive: hotKey.isGestureActive,
            frozenIdentity: queuedGestureIdentity
        ) {
        case .inactive:
            // No live gesture — either never spoken (key went up before the long
            // press confirmed) or abandoned by a chord, in which case the physical
            // key may still be down but its release will never be reported.
            audio.setPrerollCapacity(seconds: 1)
            audio.stop()
            gestureCaptureGeneration = nil
            return
        case .awaitingLongPress:
            // The preceding utterance settled during this gesture's hold threshold.
            // Keep its existing pre-roll, but do not turn a tap/shortcut into dictation.
            // If the threshold is crossed, `.longPressBegan` follows the ordinary
            // `.arming` path and captures identity at that confirmation moment.
            audio.setPrerollCapacity(seconds: 1)
            phase = .arming
            lastError = nil
            return
        case .startRecording(let start):
            // Consume the frozen identity exactly once. Key-up now follows the normal
            // `.recording` path and cannot enqueue the same gesture a second time.
            queuedGestureIdentity = nil
            beginRecording(from: start)
            // Successful promotion already reset this atomically after detaching the
            // full prefix. This also restores the ordinary cap on an early failure,
            // where `beginRecording` stopped capture before reaching that transition.
            audio.setPrerollCapacity(seconds: 1)
        }
    }

    /// A queued gesture can wait behind several already-frozen turns, each with its
    /// own response timeout. Size the current pre-roll for the full 120 s gesture plus
    /// that queueing delay instead of silently retaining only the last 30 seconds.
    private var queuedPrerollCapacitySeconds: Int {
        min(600, 150 + queuedUtterances.count * 40)
    }

    /// Why no queued utterance can be committed right now, or nil if one can.
    ///
    /// Cheap: with a socket already up this returns the live route without touching the
    /// Keychain, and it is only consulted on the queued path.
    private func queuedRouteFailure() -> String? {
        do {
            _ = try client.routeForNextUtterance()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Sends a fully captured utterance straight to the transcriber.
    ///
    /// Unlike `beginRecording` this never touches the microphone pipeline: the audio
    /// was frozen when the key was released, and both the engine and the pre-roll
    /// buffer may already belong to the next dictation. The anchor was frozen when
    /// the long press was confirmed, so the text goes where the user began speaking —
    /// if they have switched apps since, the anchor mismatch downstream keeps it out
    /// of the wrong window. The output mode is deliberately *not* frozen: it must
    /// match the session that will transcribe this audio, which is whatever is
    /// current now (a settings change mid-queue reconnects at the settle boundary,
    /// right before this call) — a mode frozen at release time would expect deltas
    /// from a model that no longer streams them, or vice versa.
    private func commitQueuedUtterance(_ utterance: QueuedUtterance) -> String? {
        guard case .captured(
            let audio,
            let anchor,
            let target,
            let isRehearsal,
            let interruptionNotice
        ) = utterance else {
            return "排队的听写内容无效"
        }
        let route: ServiceRoute
        do {
            route = try client.routeForNextUtterance()
        } catch {
            return error.localizedDescription
        }
        cancelPolish()
        partialText = ""
        accumulatedPartial = ""
        injectedText = ""
        pendingRawText = nil
        utteranceGeneration += 1
        utteranceStart = Date()
        utteranceRoute = route
        injectionAnchor = anchor
        // The target and rehearsal identity describe where this sentence was spoken.
        // Re-capturing either now would let a later focus move or guide close retarget it.
        injectionTarget = target
        utteranceIsRehearsal = isRehearsal
        utteranceTypesWhileSpeaking = !utteranceIsRehearsal && settings.typesWhileSpeaking
        injectionAbandoned = false
        captureInterruptionNotice = interruptionNotice
        phase = .finalizing

        client.beginUtterance()
        if !audio.isEmpty { client.appendAudio(audio) }
        client.commitUtterance()
        log.info("committed a queued utterance of \(audio.count) bytes")
        return nil
    }

    /// Settles the utterance now, without waiting for cleanup to come back.
    private func settleImmediately() {
        guard phase == .finalizing else { return }
        cancelPolish()
        // Invalidate the in-flight cleanup so its result cannot arrive later and
        // rewrite text that by then belongs to a different sentence.
        utteranceGeneration += 1
        let raw = pendingRawText
        pendingRawText = nil
        if raw == nil {
            // The transcript itself had not arrived yet. Tell the client to stop
            // expecting it; in live-typing mode the deltas are already on screen.
            client.cancelUtterance()
        }
        finish(with: raw)
    }

    private func cancelPolish() {
        polishTask?.cancel()
        polishTask = nil
        isPolishing = false
    }

    /// Emits the finished text and returns to idle.
    private func finish(with text: String?, confirmsCleanup: Bool = false) {
        let interruptionNotice = captureInterruptionNotice
        defer {
            partialText = ""
            accumulatedPartial = ""
            injectedText = ""
            utteranceRoute = nil
            injectionTarget = nil
            utteranceIsRehearsal = false
            captureInterruptionNotice = nil
            isPolishing = false
            phase = .idle
            if let interruptionNotice {
                showError(interruptionNotice)
            }
        }

        guard var text, !text.isEmpty else { return }

        // Strip at the very end only, and only one: "3.14" and "U.S." mid-sentence
        // stay intact. Question and exclamation marks are deliberate and kept. In
        // live-typing mode the period is already on screen; `reconcile` below sees
        // the one-character difference and deletes just it.
        if settings.stripTrailingPeriod, text.last == "。" || text.last == "." {
            text.removeLast()
            if text.isEmpty {
                // The whole utterance was a single period. In live-typing mode it is
                // already on screen — reconciling against nothing takes it back out.
                if utteranceTypesWhileSpeaking { reconcile(with: "") }
                return
            }
        }

        let canPostSyntheticEvents = Permissions.hasAccessibility
            && !Permissions.isSecureInputEnabled
        if utteranceIsRehearsal {
            // 试一下 in the first-run guide. Nothing is typed and nothing is put on the
            // clipboard either: there is no sentence at risk here, only a sample the
            // guide is about to show, and quietly replacing the user's clipboard with
            // it would be a side effect nobody asked for.
            log.info("rehearsal finished; showing the transcript in the guide only")
        } else if !canPostSyntheticEvents {
            // TCC can be revoked, or the same app can enter a password field, while
            // the transcript/cleanup is still in flight. Synthetic paste/backspace
            // is then discarded by macOS. Keep the sentence recoverable instead of
            // reporting it in history while putting it nowhere.
            log.warning("text injection became unavailable while finalizing; copying transcript")
            TextInjector.copyToClipboard(text)
        } else if utteranceTypesWhileSpeaking {
            reconcile(with: text)
        } else if let targetPID = injectionAnchor?.processIdentifier,
                  targetPID != ProcessInfo.processInfo.processIdentifier,
                  targetPID == NSWorkspace.shared.frontmostApplication?.processIdentifier {
            // `paste` revalidates the app, and the frozen element and caret wherever the
            // control publishes them, immediately before mutating the pasteboard or
            // posting ⌘V. Failure keeps the full transcript on the clipboard.
            TextInjector.paste(text, targetPID: targetPID)
        } else {
            // The transcript takes a second or two to arrive after the key goes up.
            // If the user has ⌘Tab'd away in that window, pasting would drop the
            // sentence into the wrong app — put it on the clipboard instead.
            log.info("frontmost app changed since dictation; copying instead of pasting")
            TextInjector.copyToClipboard(text)
        }

        history.insert(TranscriptEntry(text: text, date: Date()), at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
        if confirmsCleanup { markSettled() }
    }

    /// Says that cleanup is done, for a beat after it is.
    ///
    /// Only on the cleanup path, and only where text was actually emitted. Without
    /// cleanup the whole thing is over in the time it takes to lift a finger, and
    /// nobody waiting that long needs to be told it finished.
    private func markSettled() {
        settleEpoch += 1
        let epoch = settleEpoch
        settledAt = Date()
        // 0.2 s gather + 0.25 s hold + 0.35 s release.
        log.info("cleanup settled; holding the mark")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.settleEpoch == epoch else { return }
                self.settledAt = nil
            }
        }
    }

    /// Fixes up already-typed text if the final text differs from what the deltas typed.
    ///
    /// Keystrokes can only delete backwards from the caret, so any difference forces
    /// retyping everything from that point on. A change in the first few characters
    /// therefore rewrites the whole sentence, which the user sees as a flash.
    private func reconcile(with final: String) {
        let typed = injectedText
        guard typed != final else { return }

        // The realtime model emits a space after Chinese punctuation and the cleanup
        // pass takes it back out. That lands a difference near the start of the
        // sentence and would rewrite the entire line for a change nobody asked for —
        // so whitespace-only differences are left alone. Checked before the anchor:
        // nothing meaningful is missing, so it should not touch the clipboard either.
        guard typed.ignoringWhitespace != final.ignoringWhitespace else {
            log.info("whitespace-only difference; leaving typed text as is")
            return
        }

        // Cleanup runs asynchronously, and in that window the user may have clicked
        // elsewhere, kept typing, or switched app. Backspacing then would chew through
        // text that is not ours. When in doubt, leave the un-cleaned text alone — but
        // what is on screen is incomplete or unpolished (`typed != final` here), so
        // put the full transcript on the clipboard rather than losing the tail.
        guard !injectionAbandoned,
              let injectionAnchor,
              let current = currentAnchor(),
              let targetPID = injectionAnchor.processIdentifier,
              injectionAnchor == current,
              injectionTarget.map(TextInjector.targetIsStillFocused) ?? true else {
            log.info("focus moved since the text was typed; full transcript copied to clipboard")
            TextInjector.copyToClipboard(final)
            return
        }

        // A live model is allowed to produce no deltas. In that case use the proven
        // paste path rather than unacknowledged Unicode typing for the entire result.
        if typed.isEmpty {
            TextInjector.paste(final, targetPID: targetPID)
            return
        }

        let shared = Self.commonPrefixLength(typed, final)
        let deleteCount = typed.count - shared
        let addition = String(Array(final)[shared...])
        log.info("rewriting from char \(shared): -\(deleteCount) +\(addition.count)")

        if deleteCount > 0 {
            // The PID-level anchor above cannot see a focus move *within* the app
            // (programmatic, or a click — no foreign keystroke involved), so deletion
            // needs evidence about the field itself. Both sources are optional; see
            // `rewriteMayDelete` for why the text outranks the element identity.
            let typedTextProof = TextInjector.matchesTextImmediatelyBeforeCaret(
                typed,
                expectedProcessIdentifier: targetPID
            )
            guard Self.rewriteMayDelete(
                typedTextStillBeforeCaret: typedTextProof,
                sameElementStillFocused: injectionTarget.flatMap {
                    TextInjector.focusedElementMatches($0.element)
                }
            ) else {
                // Either the target app transformed our keystrokes (smart quotes,
                // autocorrect, input-method composition) so backspacing by our original
                // count would cross into the user's text, or the control offers no text
                // proof and the system says a different element holds focus.
                log.warning("the document no longer agrees that our text is before the caret; copying corrected transcript")
                TextInjector.copyToClipboard(final)
                return
            }
            if typedTextProof == nil {
                // The anchor and focus guards are all that protect this path for
                // controls that expose no range at all.
                log.info("target does not expose AX text ranges; reconciling with anchor checks only")
            }
            // The AX text query above can block for its full messaging timeout. Confirm
            // the field did not move while it did, immediately before posting the
            // destructive key events.
            guard Self.rewriteMayDelete(
                typedTextStillBeforeCaret: typedTextProof,
                sameElementStillFocused: injectionTarget.flatMap {
                    TextInjector.focusedElementMatches($0.element)
                }
            ) else {
                log.warning("focus moved while the document was being read; copying corrected transcript")
                TextInjector.copyToClipboard(final)
                return
            }
            TextInjector.deleteBackward(count: deleteCount)
        }
        if !addition.isEmpty {
            TextInjector.type(addition)
        }
    }


    static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        var left = lhs.startIndex
        var right = rhs.startIndex
        while left < lhs.endIndex, right < rhs.endIndex, lhs[left] == rhs[right] {
            count += 1
            left = lhs.index(after: left)
            right = rhs.index(after: right)
        }
        return count
    }

    private func normalize(_ text: String) -> String {
        var result = text
        while let last = result.last, last.isWhitespace || last.isNewline {
            result.removeLast()
        }
        return Self.normalizeLeadingSpace(result)
    }

    /// We cannot see what sits before the caret, so language is the best signal for
    /// whether the service's habitual leading space is load-bearing: Latin text
    /// needs it (dictating "world" right after "Hello" must not produce
    /// "Helloworld"), CJK never does. Kept as exactly one space when kept.
    static func normalizeLeadingSpace(_ text: String) -> String {
        let stripped = String(text.drop(while: { $0 == " " || $0 == "\t" }))
        guard stripped.count < text.count else { return text }
        if let first = stripped.first, first.isASCII, first.isLetter || first.isNumber {
            return " " + stripped
        }
        return stripped
    }

    private func handleFailure(_ message: String) {
        log.error("dictation failed: \(message)")
        let displayMessage = captureInterruptionNotice ?? Self.friendlyMessage(message)
        captureInterruptionNotice = nil
        cancelPolish()
        // Only stop capture when no next dictation is using the pipeline. It may be
        // queued (`startWhenSettled`), or still speculative — armed while this
        // utterance was finalizing, not yet past the long-press threshold. A gesture
        // during `.recording` is this utterance's own; that one does stop.
        let nextGestureOwnsAudio = startWhenSettled
            || (phase == .finalizing && hotKey.isGestureActive)
        if !nextGestureOwnsAudio {
            gestureOwnsCapture = false
            audio.stop()
            gestureCaptureGeneration = nil
        }
        stopMaxDurationTimer()
        partialText = ""
        accumulatedPartial = ""
        injectedText = ""
        pendingRawText = nil
        utteranceRoute = nil
        injectionTarget = nil
        utteranceIsRehearsal = false
        showError(displayMessage)
        let epoch = errorEpoch

        // Do not strand a dictation queued behind the one that just failed — but
        // drain the queue only after the error has been on screen for a beat.
        // Draining synchronously would flip the phase away in the same frame, and
        // with a non-live model the failed sentence would vanish without any trace
        // at all: no text, no history entry, no visible error.
        if startWhenSettled {
            deferredStartTimer?.invalidate()
            deferredStartTimer = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.errorEpoch == epoch else { return }
                    self.startDeferredIfPending()
                }
            }
        }
    }

    /// Says once that cleanup is failing for a reason that will keep failing.
    ///
    /// Deliberately *not* on the failure path: the sentence itself was delivered,
    /// just un-tidied, so this reuses the error pill only as a place to put words.
    /// It runs after `finish`, so nothing about the transcript depends on it.
    private func reportPolishFailure(_ message: String) {
        let display = "整理没生效：\(Self.friendlyMessage(message))"
        guard reportedPolishNotice != display else { return }
        reportedPolishNotice = display
        log.error("cleanup is failing persistently: \(message, privacy: .public)")
        showError(display)
    }

    /// Puts an error on the HUD and schedules its dismissal. Every `.error` phase
    /// must be set through here (or `handleFailure`) — a bare `phase = .error(...)`
    /// assignment never auto-dismisses, leaving the error pill and the menu-bar
    /// warning icon up until the next key press.
    private func showError(_ display: String) {
        lastError = display
        phase = .error(display)
        errorEpoch += 1
        let epoch = errorEpoch

        // Fall back to idle so the next press works normally. Epoch-guarded so a
        // newer error is not dismissed early by this error's timer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.errorEpoch == epoch, self.isErrorPhase else { return }
                self.phase = .idle
            }
        }
    }

    /// The engine failed to start or died mid-capture (device unplugged, restart
    /// failed). No more audio is coming — fail the utterance visibly instead of
    /// letting a half-recorded sentence commit as if it were complete, or letting
    /// the HUD show a recording that is not happening.
    private func handleCaptureFailure(generation: UInt64) {
        guard generation == gestureCaptureGeneration else {
            log.info("ignoring capture failure from an older gesture")
            return
        }
        if phase == .arming || phase == .recording {
            gestureOwnsCapture = false
            gestureCaptureGeneration = nil
            client.cancelUtterance()
            audio.stop()
            handleFailure("麦克风不可用，录音已中断")
            return
        }
        // The next-gesture window opens at `.armed`, before the long press confirms
        // and sets `startWhenSettled` — a capture death during `.finalizing` with a
        // live gesture is that next sentence dying, in either half of the window.
        if hotKey.isGestureActive, startWhenSettled || phase == .finalizing {
            // The next sentence is being spoken into a pre-roll that just died.
            // Stop the dead capture and remember to surface the failure once the
            // utterance in flight settles — enqueueing the truncated audio would
            // silently lose the rest of the sentence.
            audio.stop()
            gestureOwnsCapture = false
            gestureCaptureGeneration = nil
            queuedGestureFailureMessage = "麦克风不可用，录音已中断"
            log.error("capture died while a queued dictation was being spoken")
            return
        }
        if gestureOwnsCapture {
            gestureOwnsCapture = false
            gestureCaptureGeneration = nil
            audio.stop()
            handleFailure("麦克风不可用，录音已中断")
            return
        }
        // A speculative capture died with nothing depending on it; the frozen queue
        // segments are safe, and the next gesture retries the engine from scratch.
        log.warning("capture failed outside an active recording; ignoring")
    }

    /// The UI is all-Chinese; translate the server errors people actually hit.
    /// Also used by the menu bar and settings pane for connection failures.
    static func friendlyMessage(_ message: String) -> String {
        // Already Chinese — our own messages ("还没有设置 API Key") or ones framed
        // like "连接中断：…". Matching English keywords against them would
        // mistranslate exactly those.
        guard message.range(of: "\\p{Han}", options: .regularExpression) == nil else {
            return message
        }
        if message.localizedCaseInsensitiveContains("buffer too small") {
            return "录音太短，没有听到内容"
        }
        if message.localizedCaseInsensitiveContains("api key")
            || message.localizedCaseInsensitiveContains("authentication")
            || message.localizedCaseInsensitiveContains("unauthorized") {
            return "API Key 无效或没有权限"
        }
        if message.localizedCaseInsensitiveContains("quota")
            || message.localizedCaseInsensitiveContains("billing")
            || message.localizedCaseInsensitiveContains("insufficient") {
            return "OpenAI 额度不足，去检查账单"
        }
        if message.localizedCaseInsensitiveContains("rate limit") {
            return "请求太频繁，稍等几秒再试"
        }
        // Seen for real: the proxy only covers TCP, so a request that got upgraded
        // to HTTP/3 leaves over un-proxied UDP and arrives from an IP OpenAI blocks.
        // Same host, same key — transcription's WebSocket is TCP and stays fine,
        // which is exactly why this is worth naming rather than calling it a network
        // error.
        if message.localizedCaseInsensitiveContains("country, region, or territory")
            || message.localizedCaseInsensitiveContains("unsupported_country") {
            return "OpenAI 不支持这个地区"
        }
        return message
    }

    private var isErrorPhase: Bool {
        if case .error = phase { return true }
        return false
    }
}

extension DictationController.Phase {
    var isBusy: Bool {
        self == .recording || self == .finalizing
    }
}

extension String {
    /// Used to decide whether a rewrite is worth the visible churn.
    var ignoringWhitespace: String {
        filter { !$0.isWhitespace }
    }
}
