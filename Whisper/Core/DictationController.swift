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

    var connectionStatus: RealtimeClient.Status { client.status }

    @ObservationIgnored private let hotKey = HotKeyMonitor()
    @ObservationIgnored private let audio = AudioCapture()
    @ObservationIgnored private let client = RealtimeClient()
    @ObservationIgnored private let polisher = TranscriptPolisher()

    /// What we have actually typed into the target app this utterance.
    @ObservationIgnored private var injectedText = ""
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
    /// Set when a new dictation is waiting for the previous transcript to land.
    @ObservationIgnored private var startWhenSettled = false
    /// Dictations that were spoken and released before the previous one settled, in
    /// the order they were spoken. Frozen at release time: the audio because the
    /// pre-roll buffer is shared with whatever gesture comes next, and the anchor and
    /// output mode because they describe where and how the *user spoke*, not whatever
    /// app or settings happen to be current when the queue finally drains. One
    /// element per hotkey gesture, so each dictation stays its own utterance.
    private enum QueuedUtterance {
        case captured(audio: Data, anchor: InjectionAnchor?)
        case failed(message: String)
    }
    @ObservationIgnored private var queuedUtterances: [QueuedUtterance] = []
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
    /// Guards the 3s auto-dismiss of an error banner, so a newer error is not
    /// dismissed early by the previous error's timer.
    @ObservationIgnored private var errorEpoch = 0
    @ObservationIgnored private var deferredStartTimer: Timer?
    @ObservationIgnored private var hotKeyHealthTimer: Timer?

    /// Identifies the app and input state we typed into, so a late rewrite can tell
    /// whether it is still addressing the same place.
    private struct InjectionAnchor: Equatable {
        let processIdentifier: pid_t?
        let lastForeignInputAt: Date?
    }

    /// The AX element the deltas were typed into. The anchor above is PID-level:
    /// it cannot see a *programmatic* focus move inside the same app (a dialog, a
    /// web page shifting fields) because neither the frontmost app nor the
    /// foreign-input timestamp changes. Deleting text is the one operation where
    /// that blindness is destructive, so `reconcile` additionally requires this
    /// element to still hold focus before it backspaces.
    @ObservationIgnored private var injectionElement: AXUIElement?

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
        guard Permissions.hasAccessibility, !Permissions.isSecureInputEnabled else {
            hotKey.stop()
            isHotKeyActive = false
            return
        }
        if !hotKey.isOperational {
            hotKey.stop()
            isHotKeyActive = hotKey.start()
        } else {
            isHotKeyActive = true
        }
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
        hotKey.stop()
        refreshHotKeyHealth()
    }

    /// Called after the API key, model or prompt changes.
    func reconnect() {
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
                // been buffering since `.armed`; it joins the queue.
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
                    } else {
                        queuedUtterances.append(.captured(
                            audio: stopped.audio,
                            anchor: currentAnchor()
                        ))
                    }
                }
                queuedGestureFailureMessage = nil
                gestureOwnsCapture = false
                gestureCaptureGeneration = nil
                return
            }
            guard phase == .recording else { return }
            gestureOwnsCapture = false
            endRecording()

        case .cancelled:
            switch phase {
            case .arming:
                cancelCurrentGestureCapture()
                phase = .idle
            case .finalizing:
                // Was a shortcut after all; drop the speculative capture and let the
                // cleanup that is still running finish normally.
                cancelCurrentGestureCapture()
            case .recording:
                cancelCurrentGestureCapture()
                client.cancelUtterance()
                stopMaxDurationTimer()
                phase = .idle
                partialText = ""
                injectedText = ""
            case .idle, .error:
                // `phase` may have changed underneath a speculative gesture when the
                // previous utterance completed or failed during the hold threshold.
                // Capture ownership, not phase, decides whether the engine must stop.
                cancelCurrentGestureCapture()
            }
        }
    }

    private func cancelCurrentGestureCapture() {
        gestureOwnsCapture = false
        gestureCaptureGeneration = nil
        queuedGestureFailureMessage = nil
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

    private func beginRecording() {
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
        // Without a key the client cannot even open a socket, and nothing downstream
        // would ever deliver a result or an error — recording into that void would
        // leave the app showing "转写中" forever.
        guard KeychainStore.loadAPIKey() != nil else {
            audio.stop()
            gestureOwnsCapture = false
            gestureCaptureGeneration = nil
            showError("还没有设置 API Key")
            return
        }
        guard let targetAnchor = currentAnchor() else {
            audio.stop()
            gestureOwnsCapture = false
            gestureCaptureGeneration = nil
            showError("请先切回需要输入文字的 App")
            return
        }

        cancelPolish()
        phase = .recording
        partialText = ""
        injectedText = ""
        pendingRawText = nil
        // A fresh start clears a capture-failure marker from a gesture whose queue
        // was dissolved before the marker was consumed; the engine is retried from
        // scratch below and will re-report if the microphone is still gone.
        queuedGestureFailureMessage = nil
        utteranceGeneration += 1
        utteranceStart = Date()
        utteranceTypesWhileSpeaking = settings.typesWhileSpeaking
        // Taken once, at the start. Refreshing it as each delta lands would let an
        // edit the user made mid-sentence be masked by the next delta, and the later
        // rewrite would then chew through their change.
        injectionAnchor = targetAnchor
        injectionElement = targetAnchor.processIdentifier.flatMap {
            TextInjector.captureFocusedElement(expectedPID: $0)
        }
        injectionAbandoned = false

        client.beginUtterance()

        // No-op if `.armed` already started it; a safety net if that path was skipped.
        if let generation = audio.beginPreroll() {
            gestureCaptureGeneration = generation
        }
        let preroll = audio.startStreaming(includePreroll: true)
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

        // The service tends to open an utterance with a leading space. Whether that
        // space is wanted depends on the language at the caret — see
        // `normalizeLeadingSpace`, which `normalize` mirrors so the final transcript
        // and the typed deltas never disagree about character zero (a mismatch there
        // would make `reconcile` rewrite the entire sentence).
        var text = delta
        if partialText.isEmpty {
            text = Self.normalizeLeadingSpace(text)
            if text.isEmpty { return }
        }

        partialText += text
        guard utteranceTypesWhileSpeaking, !injectionAbandoned else { return }

        // Deltas keep arriving for ~700ms after the key is released. If the user has
        // clicked elsewhere or started typing in that window, the caret is no longer
        // ours and the rest of the sentence would land in the wrong place — so stop
        // injecting rather than scattering text across their document.
        guard let injectionAnchor,
              let current = currentAnchor(),
              injectionAnchor == current else {
            injectionAbandoned = true
            log.info("focus moved mid-utterance; stopping injection for this sentence")
            return
        }

        TextInjector.type(text)
        injectedText += text
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
        cancelPolish()
        polishTask = Task { [weak self] in
            guard let self else { return }
            let polished = await self.polisher.polish(final)
            guard !Task.isCancelled,
                  self.utteranceGeneration == generation,
                  self.pendingRawText == final else {
                log.info("cleanup finished after the utterance was already settled; discarding")
                return
            }
            self.polishTask = nil
            self.pendingRawText = nil
            var result = polished ?? final
            // The polisher trims outer whitespace, which would undo the deliberate
            // leading space kept by `normalizeLeadingSpace` and glue the sentence
            // to the word before the caret.
            if final.hasPrefix(" "), !result.hasPrefix(" ") { result = " " + result }
            self.finish(with: result)
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

        // No deadline of our own — the client already fails an utterance whose
        // transcript never arrives, and that path releases the queued dictation.
        // This is only a backstop in case nothing fires at all.
        deferredStartTimer?.invalidate()
        // `.common`, not the default mode: this backstop must keep ticking while
        // the menu-bar menu is open (menu tracking suspends `.default`).
        let timer = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.startWhenSettled else { return }
                log.warning("previous utterance never settled; releasing the queued one")
                self.client.cancelUtterance()
                self.pendingRawText = nil
                self.phase = .idle
                self.startDeferredIfPending()
            }
        }
        deferredStartTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Starts the dictation that was held back, provided the key is still down.
    private func startDeferredIfPending() {
        guard startWhenSettled else { return }
        startWhenSettled = false
        deferredStartTimer?.invalidate()
        deferredStartTimer = nil

        if !queuedUtterances.isEmpty {
            // Already spoken and released — settle the oldest outcome in FIFO order.
            // A capture failure is an outcome too; keeping it in the queue prevents a
            // later healthy gesture from erasing or inheriting that failure.
            let next = queuedUtterances.removeFirst()
            switch next {
            case .captured:
                commitQueuedUtterance(next)
                if !queuedUtterances.isEmpty || hotKey.isGestureActive
                    || queuedGestureFailureMessage != nil {
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

        audio.setPrerollCapacity(seconds: 1)
        if let failureMessage = queuedGestureFailureMessage {
            // Capture for this gesture failed while it was being spoken; its audio
            // is gone. Now that the previous utterance has settled, say so.
            queuedGestureFailureMessage = nil
            handleFailure(failureMessage)
            return
        }
        guard hotKey.isGestureActive else {
            // No live gesture — either never spoken (key went up before the long
            // press confirmed) or abandoned by a chord, in which case the physical
            // key may still be down but its release will never be reported.
            audio.stop()
            gestureCaptureGeneration = nil
            return
        }
        beginRecording()
    }

    /// A queued gesture can wait behind several already-frozen turns, each with its
    /// own response timeout. Size the current pre-roll for the full 120 s gesture plus
    /// that queueing delay instead of silently retaining only the last 30 seconds.
    private var queuedPrerollCapacitySeconds: Int {
        min(600, 150 + queuedUtterances.count * 40)
    }

    /// Sends a fully captured utterance straight to the transcriber.
    ///
    /// Unlike `beginRecording` this never touches the microphone pipeline: the audio
    /// was frozen when the key was released, and both the engine and the pre-roll
    /// buffer may already belong to the next dictation. The anchor was frozen at
    /// the same moment, so the text goes where the user was when they spoke — if
    /// they have switched apps since, the anchor mismatch downstream keeps it out
    /// of the wrong window. The output mode is deliberately *not* frozen: it must
    /// match the session that will transcribe this audio, which is whatever is
    /// current now (a settings change mid-queue reconnects at the settle boundary,
    /// right before this call) — a mode frozen at release time would expect deltas
    /// from a model that no longer streams them, or vice versa.
    private func commitQueuedUtterance(_ utterance: QueuedUtterance) {
        guard case .captured(let audio, let anchor) = utterance else {
            return
        }
        cancelPolish()
        partialText = ""
        injectedText = ""
        pendingRawText = nil
        utteranceGeneration += 1
        utteranceStart = Date()
        injectionAnchor = anchor
        // Captured now, not at release: this is where live deltas are about to
        // land, and where a later rewrite would delete from.
        injectionElement = anchor?.processIdentifier.flatMap {
            TextInjector.captureFocusedElement(expectedPID: $0)
        }
        utteranceTypesWhileSpeaking = settings.typesWhileSpeaking
        injectionAbandoned = false
        phase = .finalizing

        client.beginUtterance()
        if !audio.isEmpty { client.appendAudio(audio) }
        client.commitUtterance()
        log.info("committed a queued utterance of \(audio.count) bytes")
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
    }

    /// Emits the finished text and returns to idle.
    private func finish(with text: String?) {
        defer {
            partialText = ""
            injectedText = ""
            phase = .idle
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
        if !canPostSyntheticEvents {
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
            TextInjector.paste(text, targetPID: targetPID)
        } else {
            // The transcript takes a second or two to arrive after the key goes up.
            // If the user has ⌘Tab'd away in that window, pasting would drop the
            // sentence into the wrong app — put it on the clipboard instead, one ⌘V
            // away. Only the app is compared: clicking around inside the same app
            // still means "paste it where my caret is".
            log.info("frontmost app changed since dictation; copying instead of pasting")
            TextInjector.copyToClipboard(text)
        }

        history.insert(TranscriptEntry(text: text, date: Date()), at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
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
              injectionAnchor == current else {
            log.info("focus moved since the text was typed; full transcript copied to clipboard")
            TextInjector.copyToClipboard(final)
            return
        }

        let shared = commonPrefixLength(typed, final)
        let deleteCount = typed.count - shared
        let addition = String(Array(final)[shared...])
        log.info("rewriting from char \(shared): -\(deleteCount) +\(addition.count)")

        if deleteCount > 0 {
            // The PID-level anchor above cannot see a focus move *within* the
            // app (programmatic, or a click — no foreign keystroke involved).
            // Backspacing into whatever control is focused now would eat its
            // content, so deletion also requires the element the deltas were
            // typed into to still hold focus.
            if let injectionElement, !TextInjector.elementIsStillFocused(injectionElement) {
                log.warning("focus moved to another element in the same app; copying corrected transcript")
                TextInjector.copyToClipboard(final)
                return
            }
            switch TextInjector.matchesTextImmediatelyBeforeCaret(typed) {
            case false:
                // The target app transformed our keystrokes (smart quotes/dashes,
                // autocorrect, input-method composition). Backspacing by our original
                // count could cross into the user's pre-existing text.
                log.warning("typed text no longer matches the document; copying corrected transcript")
                TextInjector.copyToClipboard(final)
                return
            case nil:
                // Some Electron/WebView controls do not expose text ranges through AX.
                // Keep the established behavior there; focus/foreign-input guards above
                // still protect against the common caret-movement cases.
                log.info("target does not expose AX text ranges; reconciling with anchor checks only")
            case true:
                break
            }
            TextInjector.deleteBackward(count: deleteCount)
        }
        if !addition.isEmpty {
            TextInjector.type(addition)
        }
    }

    private func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
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
    private static func normalizeLeadingSpace(_ text: String) -> String {
        let stripped = String(text.drop(while: { $0 == " " || $0 == "\t" }))
        guard stripped.count < text.count else { return text }
        if let first = stripped.first, first.isASCII, first.isLetter || first.isNumber {
            return " " + stripped
        }
        return stripped
    }

    private func handleFailure(_ message: String) {
        log.error("dictation failed: \(message)")
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
        injectedText = ""
        pendingRawText = nil
        showError(Self.friendlyMessage(message))
        let epoch = errorEpoch

        // Do not strand a dictation queued behind the one that just failed — but
        // drain the queue only after the error has been on screen for a beat.
        // Draining synchronously would flip the phase away in the same frame, and
        // with a non-live model the failed sentence would vanish without any trace
        // at all: no text, no history entry, no visible error.
        if startWhenSettled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.errorEpoch == epoch else { return }
                    self.startDeferredIfPending()
                }
            }
        }
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

private extension String {
    /// Used to decide whether a rewrite is worth the visible churn.
    var ignoringWhitespace: String {
        filter { !$0.isWhitespace }
    }
}
