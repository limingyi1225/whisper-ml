import Foundation
import OSLog

private let log = Logger(subsystem: "com.mingyili.Whisper", category: "realtime")

/// A long-lived connection to the selected realtime transcription provider.
///
/// Connecting and configuring a session measures ~2 s end to end, which is far too slow
/// to do on keypress. So the socket is opened at launch, kept warm with pings, refreshed
/// before the session expires, and reconnected with backoff after any failure. If a
/// dictation starts while the socket is still coming up, audio is buffered locally and
/// flushed the moment the session is ready — nothing is lost, it just lands late.
@Observable
public final class RealtimeClient {
    public struct ClientAuditIdentity: Equatable, Sendable {
        public let client: String
        public let version: String

        public nonisolated init(client: String, version: String) {
            self.client = client
            self.version = version
        }
    }

    public init() {}
    public enum Status: Equatable {
        case disconnected
        case connecting
        case ready
        case failed(String)

        public var isReady: Bool { self == .ready }
    }

    public private(set) var status: Status = .disconnected

    /// Incremental transcript text, append-only. Only providers whose protocol is
    /// genuinely incremental drive this; a revisable snapshot cannot be expressed
    /// through it, so Gemini reports through `onPartialSnapshot` alone.
    public var onDelta: ((String) -> Void)?
    /// The provider's latest complete interim hypothesis. Unlike `onDelta`, earlier
    /// characters may change between calls.
    public var onPartialSnapshot: ((String) -> Void)?
    /// The authoritative transcript for the utterance.
    public var onCompleted: ((String) -> Void)?
    /// Utterance could not be transcribed. The argument is user-facing.
    public var onFailure: ((String) -> Void)?

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    /// Route owned by `socket`. The controller snapshots this per utterance so its
    /// cleanup request cannot jump to another endpoint after a mid-sentence settings
    /// change; it also keeps relay failures from being mislabeled as a local key issue.
    @ObservationIgnored private var activeRoute: ServiceRoute?
    @ObservationIgnored private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    /// Bumped on every (re)connect so callbacks from a dead socket are ignored.
    @ObservationIgnored private var generation = 0

    @ObservationIgnored private var pendingAudio: [Data] = []
    @ObservationIgnored private var pendingBytes = 0
    @ObservationIgnored private var utteranceActive = false
    @ObservationIgnored private var commitPending = false
    /// `beginUtterance` happened before the current session became ready, so its
    /// provider-side activity boundary still has to be sent. This cannot be inferred
    /// from `pendingAudio`: the handshake may finish before the first capture callback.
    @ObservationIgnored private var turnStartPending = false
    @ObservationIgnored private var currentPartialSnapshot = ""
    /// Client event ids encode a local turn sequence. Realtime `error` events echo
    /// the offending client event's id when applicable; without this correlation, a
    /// delayed error from a cancelled turn can abort the sentence currently being
    /// spoken on the same long-lived socket.
    @ObservationIgnored private var nextTurnSequence = 0
    @ObservationIgnored private var currentTurnSequence: Int?
    @ObservationIgnored private var nextClientEventSequence = 0
    /// Events carry the `item_id` of the turn they belong to, and completions across
    /// turns are not guaranteed to arrive in order. `input_audio_buffer.committed` is
    /// the authoritative source for the current turn's id; before the commit lands we
    /// adopt the id of the first transcription event provisionally.
    @ObservationIgnored private var currentItemID: String?
    /// Turns we have given up on. Without this a straggling event from a timed-out
    /// turn could arrive before the new turn's own events and get adopted as the new
    /// turn's id — ending the new recording with the old sentence's text and throwing
    /// the real result away. Kept in full for the socket's lifetime (a cap would let
    /// eviction re-open exactly the hole this exists to close; churn is one entry
    /// per cancel/timeout and sessions refresh every ~30 min) and cleared on every
    /// reconnect, where the generation guard already isolates old-socket events.
    @ObservationIgnored private var retiredItemIDs: Set<String> = []
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var sessionExpiry: Date?
    /// A settings/model change (or session refresh) arrived while an utterance
    /// was in flight. Queue draining is a *synchronous* chain — completion event
    /// → controller callback → next `beginUtterance` — so `refreshWhenIdle`'s
    /// polling timer never observes an idle gap while the user keeps queueing;
    /// without this flag a continuously-used app would keep transcribing on the
    /// old session's model indefinitely. Applied at the settle boundary, before
    /// the callback that may start the next turn.
    @ObservationIgnored private var pendingSettingsRefresh = false

    /// Transcription fields the server rejected for the current model, so the next
    /// `session.update` can leave them out. Reset on every reconnect.
    @ObservationIgnored private var unsupportedFields: Set<String> = []
    @ObservationIgnored private var sessionConfigRetries = 0

    @ObservationIgnored private var keepAliveTimer: Timer?
    /// `URLSessionWebSocketTask` can wait forever without completing either `send`,
    /// `receive`, or `sendPing` after sleep/wake or a network-path change. These two
    /// watchdogs make "no callback" a failure too; transport callbacks alone cannot.
    @ObservationIgnored private var connectionTimeoutTimer: Timer?
    @ObservationIgnored private var keepAliveTimeoutTimer: Timer?
    @ObservationIgnored private var keepAlivePingSequence = 0
    @ObservationIgnored private var keepAlivePingInFlight: Int?
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var responseTimeoutTimer: Timer?
    /// The deadline currently governing the active utterance. Exposed read-only so the
    /// controller's queue backstop can stay behind the client's real, length-aware
    /// timeout instead of cancelling a legitimate long transcription at a fixed 30 s.
    @ObservationIgnored private var responseTimeoutDeadline: Date?
    @ObservationIgnored private var reconnectWorkItem: DispatchWorkItem?

    /// Cap on locally buffered audio while the socket is not ready. Must cover a
    /// whole utterance — a smaller cap would silently drop the *beginning* of the
    /// sentence during a slow reconnect and upload only the tail, which reads as
    /// success with the head missing. Live recordings hard-stop at 120 s, but a
    /// *queued* gesture has no such limit: the controller sizes its pre-roll up to
    /// 600 s and hands the frozen audio over in one call. ~29 MB worst case, held
    /// only while disconnected mid-utterance — a fine price for never losing words.
    private let pendingCapacityBytes = AudioCapture.bytesPerSecond * 610
    /// Raw-PCM size of a single `input_audio_buffer.append`. A queued multi-minute
    /// utterance arrives as one blob; sent whole, its base64 could exceed the
    /// server's per-event size limit, and buffered whole, the capacity eviction in
    /// `appendAudio` could only drop it wholesale. ~21 s of audio per chunk.
    private static let appendChunkBytes = 1 << 20
    /// How long to wait for `…transcription.completed` after committing.
    private static let responseTimeout: TimeInterval = 20
    /// Extra budget while the commit is queued behind a connection that is still
    /// coming up. The reconnect ladder legally waits up to 30 s between attempts
    /// and `waitsForConnectivity` sits silently through all of it — timing out
    /// at the bare transcription budget would evict a perfectly good utterance
    /// seconds before the socket comes back. Hard connection *failures* are not
    /// prolonged by this: they fail the utterance immediately through the
    /// send/receive/ping error paths.
    private static let connectionGrace: TimeInterval = 35
    /// Normal setup takes ~2 s. `timeoutIntervalForRequest` is not a reliable bound for
    /// a WebSocket waiting for connectivity, so own the deadline at the state-machine
    /// level and replace a generation that never reaches `session.updated`.
    private static let connectionSetupTimeout: TimeInterval = 30
    /// A ping whose completion never arrives is indistinguishable from a live ping to
    /// URLSession, but not to us. Ten seconds is comfortably above ordinary RTT while
    /// still replacing a dead idle socket well before the next utterance begins.
    private static let keepAliveResponseTimeout: TimeInterval = 10
    /// Assumed worst-case sustained upload throughput, in raw PCM bytes per
    /// second. Base64 inflates the wire size by ~4/3, so 75 KB/s of PCM is about
    /// 100 KB/s (~0.8 Mbit/s) on the wire — slow enough to cover weak Wi-Fi
    /// without hiding a dead link (dead sockets already fail fast through the
    /// send/ping error paths, not through this timer).
    private static let assumedUploadBytesPerSecond = 75_000
    /// Raw PCM bytes handed to the socket for the current utterance. Sizes the
    /// upload allowance in the response timeout: a queued multi-minute utterance
    /// can still be uploading long after the commit is enqueued locally.
    @ObservationIgnored private var utteranceUploadedBytes = 0
    private var settings: any DictationSettingsProviding { DictationEnvironment.settings }

    /// The active utterance's authoritative timeout, if one has been armed. A WebSocket
    /// send completion is deliberately not represented here as remote progress:
    /// Foundation only promises that those bytes reached the local kernel. The deadline
    /// therefore keeps its upload allowance until the server itself acknowledges
    /// `input_audio_buffer.committed`.
    public var currentUtteranceTimeoutDeadline: Date? {
        utteranceActive ? responseTimeoutDeadline : nil
    }

    // MARK: - Connection lifecycle

    /// A controlled label for Relay lifecycle diagnostics. It is deliberately derived
    /// from the signed app's bundle rather than supplied by settings, and the server
    /// independently allowlists it before logging. Unknown package/test hosts stay
    /// useful without gaining a path to write arbitrary values into journald.
    public nonisolated static func clientAuditIdentity(
        bundleIdentifier: String?,
        version: String?
    ) -> ClientAuditIdentity {
        let client = switch bundleIdentifier {
        case "com.mingyili.Whisper": "whisper"
        case "com.wink.Wink": "wink"
        default: "unknown"
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")
        let safeVersion: String
        if let version,
           !version.isEmpty,
           version.utf8.count <= 32,
           version.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            safeVersion = version
        } else {
            safeVersion = "unknown"
        }
        return ClientAuditIdentity(client: client, version: safeVersion)
    }

    /// Opens the socket if it is not already up. Safe to call repeatedly.
    public func connectIfNeeded(resetRetryBudget: Bool = false) {
        if resetRetryBudget { reconnectAttempt = 0 }
        guard socket == nil else { return }
        let route: ServiceRoute
        do {
            route = try ServiceRoute.current()
        } catch {
            status = .failed(error.localizedDescription)
            return
        }

        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        generation += 1
        let generation = self.generation
        status = .connecting
        // A fresh connection reads the current settings below, so it satisfies
        // any refresh that was waiting for an idle moment.
        pendingSettingsRefresh = false
        unsupportedFields.removeAll()
        sessionConfigRetries = 0
        // Item ids are per-session; the generation guard already drops events from
        // the old socket, so its retired ids are dead weight here.
        retiredItemIDs.removeAll()

        var request = URLRequest(url: route.realtimeURL)
        request.setValue("Bearer \(route.credential)", forHTTPHeaderField: "Authorization")
        let identity = Self.clientAuditIdentity(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
        request.setValue(identity.client, forHTTPHeaderField: "X-Whisper-Client")
        request.setValue(identity.version, forHTTPHeaderField: "X-Whisper-Version")
        request.setValue(
            UUID().uuidString.lowercased(),
            forHTTPHeaderField: "X-Whisper-Connection-ID"
        )

        let task = urlSession.webSocketTask(with: request)
        socket = task
        activeRoute = route
        task.resume()
        receive(generation: generation)
        sendSessionUpdate()
        startKeepAlive()
        startConnectionTimeout(generation: generation)
        log.info("connecting via relay (generation \(generation))")
    }

    /// Tears down the socket. Pass `retry: true` to schedule a reconnect with backoff.
    public func disconnect(retry: Bool = false, reason: String? = nil) {
        generation += 1
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        activeRoute = nil
        keepAliveTimer?.invalidate(); keepAliveTimer = nil
        connectionTimeoutTimer?.invalidate(); connectionTimeoutTimer = nil
        keepAliveTimeoutTimer?.invalidate(); keepAliveTimeoutTimer = nil
        keepAlivePingInFlight = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        clearResponseTimeout()
        sessionExpiry = nil
        resetPartialState()

        // Buffered audio belongs to the session that just died. Carrying it into the
        // next one would transcribe an utterance the user has already moved on from.
        utteranceActive = false
        commitPending = false
        turnStartPending = false
        currentItemID = nil
        currentTurnSequence = nil
        pendingAudio.removeAll()
        pendingBytes = 0

        if let reason {
            status = .failed(reason)
            log.error("disconnected: \(reason)")
        } else {
            status = .disconnected
        }

        if retry { scheduleReconnect() }
    }

    /// Drops and reopens the connection, e.g. after the API key or model changed.
    public func reconnectNow() {
        guard !utteranceActive else {
            // A dictation is in flight; tearing the socket down now would silently
            // strand it — the commit would go nowhere and no timeout would fire,
            // leaving the app on "转写中" forever. The new settings can wait the
            // second or two until the utterance settles; the retry loop below
            // re-checks every few seconds.
            refreshWhenIdle()
            return
        }
        reconnectAttempt = 0
        disconnect()
        connectIfNeeded()
    }

    private func scheduleReconnect() {
        reconnectWorkItem?.cancel()
        reconnectAttempt = min(reconnectAttempt + 1, 6)
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 30)
        log.info("reconnecting in \(delay)s (attempt \(self.reconnectAttempt))")

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.connectIfNeeded() }
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Utterance API

    /// The route a new utterance will actually use. An already-open socket wins over
    /// live settings: this utterance's audio is going down that socket whatever the
    /// picker now says, so its cleanup request has to follow the socket. Only the
    /// reconnect at the next idle boundary moves the route.
    public func routeForNextUtterance() throws -> ServiceRoute {
        if let activeRoute, socket != nil { return activeRoute }
        return try ServiceRoute.current()
    }

    public func beginUtterance() {
        // Keep-alive is an idle-only probe. A ping started just before this call may
        // legitimately wait behind relay backpressure once the audio burst begins;
        // its old 10 s deadline must not tear down the utterance that now owns the
        // socket. Clearing the sequence also makes its eventual callback a no-op.
        clearKeepAliveProbe()
        nextTurnSequence += 1
        currentTurnSequence = nextTurnSequence
        utteranceActive = true
        commitPending = false
        turnStartPending = !status.isReady
        currentItemID = nil
        pendingAudio.removeAll()
        pendingBytes = 0
        utteranceUploadedBytes = 0
        resetPartialState()
        clearResponseTimeout()

        if status.isReady {
            send(["type": "input_audio_buffer.clear"])
        } else {
            // Not warm yet — get a socket going so the buffered audio has somewhere to land.
            // This is a new user action, not an automatic backoff callback. If the
            // previous ladder exhausted itself, give this utterance a fresh budget.
            connectIfNeeded(resetRetryBudget: true)
        }
    }

    public func appendAudio(_ data: Data) {
        guard utteranceActive else { return }
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(
                offset,
                offsetBy: Self.appendChunkBytes,
                limitedBy: data.endIndex
            ) ?? data.endIndex
            appendAudioChunk(data.subdata(in: offset..<end))
            offset = end
        }
    }

    private func appendAudioChunk(_ data: Data) {
        guard status.isReady else {
            pendingAudio.append(data)
            pendingBytes += data.count
            while pendingBytes > pendingCapacityBytes, let first = pendingAudio.first {
                pendingAudio.removeFirst()
                pendingBytes -= first.count
            }
            return
        }
        transmitAudioChunk(data)
    }

    private func transmitAudioChunk(_ data: Data) {
        utteranceUploadedBytes += data.count
        send(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
    }

    /// Ends the utterance. The transcript arrives later via `onCompleted`.
    public func commitUtterance() {
        guard utteranceActive else { return }
        guard status.isReady else {
            // Still connecting: remember to commit as soon as the buffer is flushed.
            // Arm the timeout now — if the connection never comes up, the utterance
            // must fail visibly rather than leave the app on "转写中" forever. The
            // timer is re-armed when the commit actually goes out.
            commitPending = true
            scheduleResponseTimeout(after: transcriptionBudget + Self.connectionGrace)
            return
        }
        sendCommit()
    }

    /// Sends the commit and arms the response timeout so that the 20 s budget
    /// covers *transcription*, not upload. The audio ahead of the commit may take
    /// far longer than 20 s to transmit (a queued multi-minute utterance) —
    /// timing out mid-upload would drop a perfectly good completion later, which
    /// for the non-streaming models means the whole sentence vanishes. So: arm an
    /// upload-aware backstop now, then re-arm the plain budget only when the server
    /// acknowledges it (`input_audio_buffer.committed`). URLSession's send completion
    /// only proves that the frame was written to the local kernel; treating that as a
    /// remote acknowledgement cuts off working slow links and relay backpressure.
    private func sendCommit() {
        send(["type": "input_audio_buffer.commit"])
        startResponseTimeout()
    }

    /// Abandons the utterance without transcribing (early key release, cancelled gesture).
    public func cancelUtterance() {
        guard utteranceActive else { return }
        utteranceActive = false
        commitPending = false
        turnStartPending = false
        pendingAudio.removeAll()
        pendingBytes = 0
        resetPartialState()
        clearResponseTimeout()
        guard status.isReady else {
            // Nothing ever reached the server; the local buffers above were the
            // whole utterance.
            currentItemID = nil
            applyPendingRefreshIfSettled()
            return
        }

        let provider = activeRoute?.provider ?? settings.transcriptionModel.provider
        switch Self.cancellationStrategy(
            provider: provider,
            hasKnownItemID: currentItemID != nil
        ) {
        case .clearCurrentTurn:
            retireCurrentTurn()
            send(["type": "input_audio_buffer.clear"])
            applyPendingRefreshIfSettled()
        case .replaceSession:
            // Gemini completions cannot be retired by item id. OpenAI also needs this
            // path when no event has named the turn yet: a late delta could otherwise
            // be adopted as the next turn's provisional id. Only a fresh session
            // closes both holes. Reopen immediately so the next gesture finds a warm
            // connection instead of waiting for Relay's close/backoff cycle.
            disconnect()
            reconnectAttempt = 0
            connectIfNeeded()
        }
    }

    enum CancellationStrategy: Equatable {
        case clearCurrentTurn
        case replaceSession
    }

    /// Gemini finals do not identify the turn they belong to. Once any audio has
    /// reached that provider, only a fresh session can prove that a late completion
    /// is not from the cancelled sentence. Reconnect locally and immediately instead
    /// of waiting for Relay to close the socket after a clear. OpenAI events do carry
    /// item ids, so a known turn can still be retired in place.
    static func cancellationStrategy(
        provider: TranscriptionProvider,
        hasKnownItemID: Bool
    ) -> CancellationStrategy {
        if provider == .gemini { return .replaceSession }
        return hasKnownItemID ? .clearCurrentTurn : .replaceSession
    }

    enum ResponseTimeoutStrategy: Equatable {
        case discardPendingCommit
        case retireCurrentTurn
        case replaceSession
    }

    /// A Gemini `item_id` is synthesized by Relay for client correlation; it does not
    /// prove that Google's activity ended. If its final never arrives, retiring that id
    /// only locally leaves Relay's turn open and makes the next activity boundary tear
    /// down the socket. Replace and preheat the session immediately instead. OpenAI's
    /// authoritative item ids still allow a known turn to be retired in place.
    static func responseTimeoutStrategy(
        provider: TranscriptionProvider,
        commitPending: Bool,
        hasKnownItemID: Bool
    ) -> ResponseTimeoutStrategy {
        if commitPending { return .discardPendingCommit }
        if provider == .openAI, hasKnownItemID { return .retireCurrentTurn }
        return .replaceSession
    }

    // MARK: - Protocol

    /// A session configuration belongs to the socket that carries it. Settings are
    /// allowed to change while an utterance is buffered or in flight, but that change
    /// moves to a new provider connection only at the next idle boundary. In particular,
    /// an unsupported-field retry must not send Gemini's model to an OpenAI socket (or
    /// vice versa) just because another host changed the shared preference meanwhile.
    static func sessionTranscriptionModel(
        activeRoute: ServiceRoute?,
        liveSettingsModel: TranscriptionModel
    ) -> TranscriptionModel {
        activeRoute?.transcriptionModel ?? liveSettingsModel
    }

    private func sendSessionUpdate() {
        let model = Self.sessionTranscriptionModel(
            activeRoute: activeRoute,
            liveSettingsModel: settings.transcriptionModel
        )
        var transcription: [String: Any] = ["model": model.rawValue]

        // `delay` controls how much audio the model hears before committing to words.
        // Time-to-first-word measured on gpt-realtime-whisper, the model this
        // replaced: minimal 737ms, low 811ms, medium 1250ms, high 1937ms — the shape
        // of the tradeoff carries over, the numbers themselves want re-measuring on
        // gpt-live-transcribe before the settings pane quotes them. It only exists on
        // the streaming model; the other rejects it, and eating that round trip on
        // every connect just delays the first sentence.
        if model.supportsTranscriptionDelay {
            transcription["delay"] = settings.transcriptionDelay.rawValue
        }
        // The vocabulary, biasing recognition itself rather than repairing it after.
        // Both current models accept this; gpt-realtime-whisper had no such slot, which
        // is why the list used to reach only the cleanup pass. Repairing after the fact
        // works, but it costs a visible flash — measured on "我叫李铭一", the raw
        // transcript says 李明一, so live typing puts the wrong name on screen and
        // `reconcile` corrects it ~0.9s later — and it fails outright whenever cleanup
        // is switched off or times out, since every TranscriptPolisher failure path
        // returns the raw text unchanged.
        //
        // Empty lists are not sent at all: an empty array is a different request from
        // an absent field, and there is nothing to bias towards.
        let keywords = settings.vocabularyTerms
        if !keywords.isEmpty {
            transcription["keywords"] = keywords
        }
        // Language is deliberately not sent: the speech here is mixed zh/en and
        // auto-detection handles that better than pinning one language. `languages`
        // now takes a list, so ["zh", "en"] is no longer the same bet as pinning one —
        // an open question, and `script/ab_transcribe.mjs` has an arm for it.
        //
        // `prompt` is not sent. Both current models accept it, but using it as an
        // instruction channel measurably degraded transcription accuracy on the gpt-4o
        // models (backend→button, Kevin→Kelvin on identical audio). Cleanup belongs in
        // a separate text pass, see TranscriptPolisher.
        for field in unsupportedFields { transcription.removeValue(forKey: field) }

        send([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": transcription,
                        // Turns are driven by the hotkey, so server-side VAD stays off.
                        "turn_detection": NSNull(),
                    ]
                ],
            ],
        ])
    }

    private func handle(_ payload: [String: Any]) {
        guard let type = payload["type"] as? String else { return }

        switch type {
        case "session.created":
            if let session = payload["session"] as? [String: Any],
               let expires = session["expires_at"] as? TimeInterval {
                sessionExpiry = Date(timeIntervalSince1970: expires)
                scheduleRefreshBeforeExpiry()
            }

        case "input_audio_buffer.committed":
            // Authoritative: this names the item our committed audio became, so it
            // replaces whatever we adopted provisionally from an earlier event. A
            // retired id is a straggler from a turn we already gave up on — adopting
            // it would deliver the old sentence as the new turn's result.
            if let itemID = payload["item_id"] as? String, utteranceActive,
               !retiredItemIDs.contains(itemID) {
                currentItemID = itemID
                // The server has the whole utterance; the remaining wait is pure
                // transcription. Re-arm the transcription budget so a slow
                // upload's oversized backstop cannot mask a hung transcription.
                scheduleResponseTimeout(after: transcriptionBudget)
            }

        case "session.updated":
            reconnectAttempt = 0
            connectionTimeoutTimer?.invalidate()
            connectionTimeoutTimer = nil
            // A working session ends the failure episode the recovery latch guards, so
            // a rotation months from now starts with a fresh attempt.
            didTryBundledTokenRecovery = false
            status = .ready
            log.info("session ready")
            flushPendingAudio()

        case "conversation.item.input_audio_transcription.delta":
            guard utteranceActive, belongsToCurrentTurn(payload) else { return }
            if let delta = payload["delta"] as? String, !delta.isEmpty {
                currentPartialSnapshot += delta
                onDelta?(delta)
                onPartialSnapshot?(currentPartialSnapshot)
            }

        case "whisper.input_audio_transcription.partial":
            guard utteranceActive, belongsToCurrentTurn(payload) else { return }
            if let transcript = payload["transcript"] as? String, !transcript.isEmpty {
                currentPartialSnapshot = transcript
                onPartialSnapshot?(transcript)
            }

        case "conversation.item.input_audio_transcription.completed":
            // A transcript can still turn up after we gave up waiting, or after the
            // user abandoned the utterance. Delivering it then would type text into
            // whatever they have moved on to.
            guard utteranceActive, belongsToCurrentTurn(payload) else {
                log.info("dropping transcript for an utterance that is no longer active")
                return
            }
            clearResponseTimeout()
            utteranceActive = false
            let transcript = payload["transcript"] as? String ?? ""
            resetPartialState()
            if Self.sessionReplacementRequired(in: payload) {
                // Relay is retiring an uncertain Gemini boundary. A completion callback
                // can synchronously start a queued utterance, so replace the transport
                // before invoking it rather than waiting to observe Relay's close frame.
                disconnect()
                reconnectAttempt = 0
                connectIfNeeded()
            } else {
                applyPendingRefreshIfSettled()
            }
            onCompleted?(transcript)

        case "conversation.item.input_audio_transcription.failed":
            guard utteranceActive, belongsToCurrentTurn(payload) else { return }
            clearResponseTimeout()
            utteranceActive = false
            retireCurrentTurn()
            resetPartialState()
            let message = ((payload["error"] as? [String: Any])?["message"] as? String) ?? "转写失败"
            applyPendingRefreshIfSettled()
            onFailure?(message)

        case "error":
            let detail = payload["error"] as? [String: Any]
            let message = (detail?["message"] as? String) ?? "未知错误"
            // Public on purpose: these messages name the offending field and are the
            // only practical way to debug a rejected session config.
            log.error("server error: \(message, privacy: .public) | raw: \(String(describing: detail), privacy: .public)")

            // A rejected session field is recoverable: drop it and reconfigure, rather
            // than leaving the connection permanently unusable.
            if let param = detail?["param"] as? String,
               let field = param.split(separator: ".").last.map(String.init),
               param.hasPrefix("session.audio.input.transcription."),
               !unsupportedFields.contains(field),
               sessionConfigRetries < 3 {
                unsupportedFields.insert(field)
                sessionConfigRetries += 1
                log.info("retrying session config without '\(field, privacy: .public)'")
                sendSessionUpdate()
                return
            }
            // Auth and quota problems will not fix themselves by retrying the same way.
            let fatal = message.localizedCaseInsensitiveContains("api key")
                || message.localizedCaseInsensitiveContains("authentication")
                || message.localizedCaseInsensitiveContains("quota")
                || message.localizedCaseInsensitiveContains("billing")

            // Auth/quota failures are connection-wide. Teardown first and notify
            // last: the callback may synchronously start the next queued utterance.
            if fatal {
                let wasMidUtterance = utteranceActive
                disconnect(reason: message)
                if wasMidUtterance { onFailure?(message) }
                return
            }

            // During setup there is no usable session to preserve. A dead-but-open
            // socket would wedge `connectIfNeeded`, so always replace it.
            if !status.isReady {
                let wasMidUtterance = utteranceActive
                disconnect(retry: reconnectAttempt < 6, reason: message)
                if wasMidUtterance { onFailure?(message) }
                return
            }

            // A ready Realtime session generally survives ordinary request errors.
            // Only fail the current dictation when the server explicitly ties the
            // error to one of this turn's client events. An unscoped/session error or
            // a delayed error from an earlier turn is logged above and left alone.
            let errorTurn = turnSequence(
                fromClientEventID: detail?["event_id"] as? String
            )
            guard utteranceActive,
                  let currentTurnSequence,
                  errorTurn == currentTurnSequence else {
                log.info("recoverable server error does not belong to the active turn")
                return
            }

            clearResponseTimeout()
            utteranceActive = false
            if Self.sessionReplacementRequired(in: detail ?? [:]) {
                // Same callback-ordering fence as a flagged completion: the next queued
                // utterance must see a new socket even if Relay's close is still in flight.
                disconnect()
                reconnectAttempt = 0
                connectIfNeeded()
            } else {
                let hadKnownItemID = currentItemID != nil
                if hadKnownItemID {
                    retireCurrentTurn()
                } else {
                    // The failed turn has no server item id, so item-based retirement
                    // cannot isolate its late events from the next turn.
                    disconnect(retry: reconnectAttempt < 6, reason: message)
                }
                applyPendingRefreshIfSettled()
            }
            onFailure?(message)

        default:
            break
        }
    }

    private func belongsToCurrentTurn(_ payload: [String: Any]) -> Bool {
        guard let itemID = payload["item_id"] as? String else { return true }

        if retiredItemIDs.contains(itemID) {
            log.info("ignoring event from a turn we already gave up on")
            return false
        }
        guard let currentItemID else {
            // Pre-commit: no authoritative id yet, so take this one provisionally.
            self.currentItemID = itemID
            return true
        }
        if currentItemID != itemID {
            log.info("ignoring event from a different turn")
            return false
        }
        return true
    }

    /// Stops accepting anything further from the turn in flight.
    private func retireCurrentTurn() {
        guard let currentItemID else { return }
        retiredItemIDs.insert(currentItemID)
        self.currentItemID = nil
    }

    private func resetPartialState() {
        currentPartialSnapshot = ""
    }

    /// Relay marks results whose provider-side turn boundary is uncertain. The wire
    /// value is intentionally opt-in: older relays omit it and keep existing behavior.
    static func sessionReplacementRequired(in payload: [String: Any]) -> Bool {
        payload["session_replacement_required"] as? Bool == true
    }

    /// What a deferred flush has to put on the wire, and in what order.
    ///
    /// Split out from the socket so the ordering is testable: `beginUtterance` can only
    /// send the turn boundary when the session is already up, and an utterance started
    /// against a cold socket buffers its audio instead. Replaying that buffer without
    /// the boundary first is what let a sentence land in the previous turn — audible to
    /// the user as a transcript of two utterances run together.
    enum BufferedFlushOperation: Equatable {
        case clear
        case append(Int)
        case commit
    }

    static func bufferedFlushOperations(
        audioChunkCount: Int,
        commitPending: Bool,
        turnStartPending: Bool
    ) -> [BufferedFlushOperation] {
        guard audioChunkCount > 0 || commitPending || turnStartPending else { return [] }
        // Audio or a commit also imply a turn boundary defensively, even if future
        // lifecycle changes accidentally lose the explicit pending flag.
        var operations: [BufferedFlushOperation] = [.clear]
        operations += (0..<audioChunkCount).map(BufferedFlushOperation.append)
        if commitPending { operations.append(.commit) }
        return operations
    }

    private func flushPendingAudio() {
        let chunks = pendingAudio
        let operations = Self.bufferedFlushOperations(
            audioChunkCount: chunks.count,
            commitPending: commitPending,
            turnStartPending: turnStartPending
        )
        guard !operations.isEmpty else { return }

        for operation in operations {
            switch operation {
            case .clear:
                // `beginUtterance` could not send this while the socket was connecting.
                // It is Gemini's explicit activity start and OpenAI's harmless reset.
                send(["type": "input_audio_buffer.clear"])
                turnStartPending = false
            case .append(let index):
                transmitAudioChunk(chunks[index])
            case .commit:
                commitPending = false
                sendCommit()
            }
        }
        log.info("flushed \(self.pendingBytes) buffered bytes")
        pendingAudio.removeAll()
        pendingBytes = 0
    }

    // MARK: - Socket plumbing

    private enum ClientEventContext {
        case session
        case turn(Int)
    }

    private func send(
        _ originalObject: [String: Any],
        context explicitContext: ClientEventContext? = nil
    ) {
        var object = originalObject
        let context: ClientEventContext
        if let explicitContext {
            context = explicitContext
        } else if let type = object["type"] as? String,
                  type.hasPrefix("input_audio_buffer."),
                  let currentTurnSequence {
            context = .turn(currentTurnSequence)
        } else {
            context = .session
        }
        nextClientEventSequence += 1
        switch context {
        case .session:
            object["event_id"] = "whisper-session-\(nextClientEventSequence)"
        case .turn(let sequence):
            object["event_id"] = "whisper-turn-\(sequence)-\(nextClientEventSequence)"
        }

        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { return }

        let generation = self.generation
        socket.send(.string(text)) { [weak self] error in
            // A nil completion only proves the frame was accepted by URLSession/the
            // local transport. Remote progress is established by server events such as
            // `input_audio_buffer.committed`, never by this callback.
            guard let error else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // A failed send means this socket is done for. Waiting for the
                    // receive loop or the 20s response timeout to notice just makes
                    // the user stare at the spinner — fail fast and reconnect.
                    guard let self, generation == self.generation else { return }
                    log.error("send failed: \(error.localizedDescription)")
                    let failure = self.transportFailure(error)
                    let message = failure.message
                    let wasMidUtterance = self.utteranceActive
                    self.utteranceActive = false
                    // Cap the retries like the receive path does. A send failure
                    // bumps the generation and thereby swallows the receive loop's
                    // own failure callback — and since `session.update` goes out on
                    // every connect, a dead network fails through *this* path every
                    // time. With an unconditional `retry: true` here, the backoff
                    // ladder's stop condition was unreachable and the app would
                    // reconnect every 30 s forever.
                    if failure.rejectedCredential, self.recoverWithBundledToken() {
                        self.reconnectAttempt = 0
                        self.disconnect()
                        self.connectIfNeeded()
                        if wasMidUtterance { self.onFailure?(message) }
                        return
                    }
                    self.disconnect(
                        retry: failure.retryable && self.reconnectAttempt < 6,
                        reason: message
                    )
                    if wasMidUtterance {
                        self.onFailure?(message)
                    }
                }
            }
        }
    }

    public func turnSequence(fromClientEventID eventID: String?) -> Int? {
        guard let eventID else { return nil }
        let components = eventID.split(separator: "-", maxSplits: 3)
        guard components.count == 4,
              components[0] == "whisper",
              components[1] == "turn" else {
            return nil
        }
        return Int(components[2])
    }

    private func receive(generation: Int) {
        socket?.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    switch result {
                    case .failure(let error):
                        let wasMidUtterance = self.utteranceActive
                        self.utteranceActive = false
                        // Stop once the backoff ladder tops out: a handshake the
                        // server keeps rejecting (bad key, TLS interception) would
                        // otherwise loop forever with the UI flapping between
                        // 连接中/未连接. Always pass the reason so the menu can show
                        // *why*. Saving settings, a manual reconnect, or the next
                        // dictation attempt all try again from scratch.
                        let failure = self.transportFailure(error)
                        // Before reporting a dead end: a personalised build can replace
                        // a token the relay has stopped accepting with its own.
                        if failure.rejectedCredential, self.recoverWithBundledToken() {
                            self.reconnectAttempt = 0
                            self.disconnect()
                            self.connectIfNeeded()
                            if wasMidUtterance { self.onFailure?(failure.message) }
                            return
                        }
                        self.disconnect(
                            retry: failure.retryable && self.reconnectAttempt < 6,
                            reason: failure.message
                        )
                        if wasMidUtterance {
                            self.onFailure?(failure.message)
                        }
                    case .success(let message):
                        // Any server frame proves the transport is responsive; do not
                        // sacrifice an active transcript just because Foundation lost
                        // the completion callback for an overlapping idle ping.
                        self.clearKeepAliveProbe()
                        if case .string(let text) = message,
                           let data = text.data(using: .utf8),
                           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            self.handle(object)
                        }
                        // `handle` can tear the connection down and open a new one
                        // (a settings refresh at the settle boundary). Re-arming
                        // here then would register a *second* receive — carrying
                        // this dead generation — on the new socket, and every
                        // message it won would be silently dropped.
                        guard generation == self.generation else { return }
                        self.receive(generation: generation)
                    }
                }
            }
        }
    }

    private func startKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = CommonRunLoopTimer.schedule(after: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let socket = self.socket,
                      self.status.isReady,
                      !self.utteranceActive,
                      self.keepAlivePingInFlight == nil else { return }
                // A failed ping is the only way to notice a socket that died
                // *silently* (sleep/wake, Wi-Fi switch) while idle — the receive
                // loop only errors if the peer sends something back. Ignoring it
                // left `status` at `.ready` until the next dictation's first send
                // failed, which cost the user that whole sentence. Reconnect now,
                // so the socket is warm again long before they speak.
                let generation = self.generation
                self.keepAlivePingSequence += 1
                let pingSequence = self.keepAlivePingSequence
                self.keepAlivePingInFlight = pingSequence
                self.startKeepAliveTimeout(generation: generation, pingSequence: pingSequence)
                socket.sendPing { [weak self] error in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self,
                                  generation == self.generation,
                                  self.keepAlivePingInFlight == pingSequence else { return }
                            self.clearKeepAliveProbe()
                            guard let error else { return }
                            log.error("keep-alive ping failed: \(error.localizedDescription)")
                            let failure = self.transportFailure(error)
                            let wasMidUtterance = self.utteranceActive
                            self.utteranceActive = false
                            // Same backoff cap as the receive path — an unreachable
                            // network must not reconnect every 30 s forever.
                            self.disconnect(
                                retry: failure.retryable && self.reconnectAttempt < 6,
                                reason: failure.message
                            )
                            if wasMidUtterance { self.onFailure?(failure.message) }
                        }
                    }
                }
            }
        }
    }

    /// Bounds the whole handshake + session configuration phase. Foundation's request
    /// timeout does not consistently fire for a WebSocket parked in connectivity wait,
    /// which otherwise leaves `socket != nil` and `.connecting` blocking every future
    /// `connectIfNeeded` until the process is relaunched.
    private func startConnectionTimeout(generation: Int) {
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = CommonRunLoopTimer.schedule(
            after: Self.connectionSetupTimeout,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      generation == self.generation,
                      self.status == .connecting else { return }
                log.error("connection setup timed out")
                self.recoverFromUnresponsiveTransport(reason: "连接超时")
            }
        }
    }

    /// Detects the half-open case where `sendPing` itself never calls back. Only one
    /// ping may be in flight, so a wedged task cannot accumulate callbacks every 20 s.
    private func startKeepAliveTimeout(generation: Int, pingSequence: Int) {
        keepAliveTimeoutTimer?.invalidate()
        keepAliveTimeoutTimer = CommonRunLoopTimer.schedule(
            after: Self.keepAliveResponseTimeout,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      generation == self.generation,
                      self.keepAlivePingInFlight == pingSequence else { return }
                // `beginUtterance` normally clears this probe synchronously. Keep the
                // ownership check here too so a future entry point cannot turn an idle
                // liveness deadline into an active-utterance data-loss deadline.
                guard !self.utteranceActive else {
                    self.clearKeepAliveProbe()
                    return
                }
                log.error("keep-alive ping timed out")
                self.recoverFromUnresponsiveTransport(reason: "连接失去响应")
            }
        }
    }

    private func clearKeepAliveProbe() {
        keepAlivePingInFlight = nil
        keepAliveTimeoutTimer?.invalidate()
        keepAliveTimeoutTimer = nil
    }

    private func recoverFromUnresponsiveTransport(reason: String) {
        let wasMidUtterance = utteranceActive
        utteranceActive = false
        let shouldRetry = reconnectAttempt < 6
        let message = shouldRetry ? "\(reason)，正在重试" : reason
        disconnect(retry: shouldRetry, reason: message)
        if wasMidUtterance { onFailure?(message) }
    }

    /// Sessions expire server-side; renew ahead of time, but never mid-sentence.
    private func scheduleRefreshBeforeExpiry() {
        refreshTimer?.invalidate()
        guard let sessionExpiry else { return }
        let lead: TimeInterval = 60
        // Floor at seconds, not half a minute — flooring at 30 could schedule the
        // refresh *after* a short-lived session's expiry.
        let delay = max(5, sessionExpiry.timeIntervalSinceNow - lead)
        refreshTimer = CommonRunLoopTimer.schedule(after: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWhenIdle() }
        }
    }

    /// What a transport error means for the user, and whether retrying can fix it.
    public struct TransportFailure {
        public let message: String
        public let retryable: Bool
        /// The peer rejected the credential itself, rather than failing to talk to us.
        /// The one failure a personalised build can repair on its own.
        public var rejectedCredential = false
    }

    /// Set once a rejected credential has been answered by installing the bundled token,
    /// so a bundled token that is *also* rejected cannot loop. Scoped to the failure
    /// episode, not the process: a session coming up clears it, because a menu-bar app
    /// runs for months and one exhausted latch must not disable recovery forever.
    @ObservationIgnored private var didTryBundledTokenRecovery = false

    /// Repairs a rejected device token from the one this build shipped with, if it can.
    ///
    /// A 401 is unambiguous evidence that the stored token is not accepted — revoked,
    /// rotated, or left behind by an older personalised build. Deleting the app does not
    /// clear a keychain item, so without this the recipient of a re-issued build is stuck
    /// on 401 forever with no way out from their side.
    ///
    /// This is also the migration path for a copy seeded before provenance was tracked:
    /// there is no marker to consult, but there does not need to be. A working token is
    /// never touched, because a working token never produces a 401.
    private func recoverWithBundledToken() -> Bool {
        guard !didTryBundledTokenRecovery,
              let bundled = KeychainStore.bundledRelayToken,
              let rejectedCredential = activeRoute?.credential,
              bundled != rejectedCredential else { return false }
        // The rejection belongs to the credential *this* socket used. If the keychain
        // has moved on since, the 401 says nothing about what is stored now and
        // overwriting it would destroy a token the user had just saved — reachable
        // whenever a save lands while an utterance is still in flight, because the
        // reconnect is deferred to the settle boundary and the old socket's handshake
        // can fail after it.
        guard KeychainStore.loadRelayToken() == rejectedCredential else { return false }
        // Never sideways or backwards: an older copy of the app must not answer a 401 by
        // installing the token it happens to carry over a newer one already in use.
        guard KeychainStore.mayRecoverWithBundledToken else { return false }
        // The latch lands only after the keychain write succeeds. Latching first meant
        // one transiently locked keychain burned the process's only recovery attempt —
        // unlocked a minute later, the app still refused to try until it was relaunched.
        // No loop opens up in exchange: after a successful adopt the stored token *is*
        // the bundled one, and the `bundled != credential` guard refuses a second pass.
        guard KeychainStore.adoptBundledRelayToken(
            bundled,
            replacing: rejectedCredential
        ) else { return false }
        didTryBundledTokenRecovery = true
        log.info("device token was rejected; falling back to the one this build carries")
        return true
    }

    /// How a rejected WebSocket handshake should read, and whether the backoff ladder
    /// should keep climbing. Split out from `transportFailure` so it is testable
    /// without a live socket.
    public nonisolated static func handshakeRejection(
        statusCode: Int
    ) -> TransportFailure {
        switch statusCode {
        case 403:
            // The relay itself never sends 403 — auth.js answers a bad token with 401,
            // and nothing else in it produces a 403 — so this is Cloudflare or nginx
            // having a moment in front of it. Treating it as a rejected credential once
            // let a transient edge 403 overwrite a hand-typed token with the bundled
            // one, permanently: the keychain write cannot be undone from the app.
            return TransportFailure(
                message: "转发服务器前面的网关拒绝了连接（403），稍后会自动重试",
                retryable: true
            )
        case 401:
            // Retrying a rejected credential only burns the ladder. Not permanent: the
            // next dictation and any settings change both start a fresh attempt.
            return TransportFailure(
                message: "转发服务器拒绝了设备凭证（\(statusCode)），请在设置里更新",
                retryable: false,
                rejectedCredential: true
            )
        case 429:
            // Usually this device's own zombie connections from sleep/wake still
            // holding their slots; the relay's heartbeat reaps them within a sweep
            // or two, so this one clears itself.
            return TransportFailure(
                message: "转发服务器：这台设备的连接数暂时用满了（429），正在重试",
                retryable: true
            )
        case 404:
            return TransportFailure(
                message: "转发服务器上没有这个地址（404），App 和服务器的版本可能对不上",
                retryable: false
            )
        default:
            return TransportFailure(
                message: "转发服务器拒绝了连接（HTTP \(statusCode)）",
                retryable: true
            )
        }
    }

    /// Turns a transport error into something the user can act on.
    ///
    /// `URLSessionWebSocketTask` reports *every* rejected handshake as the same opaque
    /// `NSURLErrorBadServerResponse` — "There was a bad response from the server" — so a
    /// revoked device token was indistinguishable from a dead network, and the app spent
    /// all six backoff attempts on a credential that was never going to start working.
    /// The status does survive on the task's `response` though (measured against a relay
    /// that 401s the upgrade: `task.response.statusCode == 401`), and that is the only
    /// place it can be read from.
    private func transportFailure(_ error: Error) -> TransportFailure {
        let nsError = error as NSError
        // All three conditions matter: a socket that *did* upgrade keeps its 101 on
        // `response`, so status alone would relabel every later network drop.
        if nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorBadServerResponse,
           let http = socket?.response as? HTTPURLResponse,
           http.statusCode >= 400 {
            return Self.handshakeRejection(statusCode: http.statusCode)
        }
        return TransportFailure(
            message: "转发服务器连接中断：\(error.localizedDescription)",
            retryable: true
        )
    }

    /// Re-checks on every retry rather than once. Checking only the first time meant a
    /// dictation longer than the retry interval got cut off mid-sentence.
    private func refreshWhenIdle() {
        refreshTimer?.invalidate()
        guard !utteranceActive else {
            // The settle boundary (`applyPendingRefreshIfSettled`) is the real
            // trigger; this timer is only a backstop for paths that never reach
            // one, e.g. an utterance dissolved without any callback.
            pendingSettingsRefresh = true
            refreshTimer = CommonRunLoopTimer.schedule(after: 3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWhenIdle() }
            }
            return
        }
        log.info("refreshing session before expiry")
        reconnectNow()
    }

    /// Applies a refresh that arrived mid-utterance, now that the utterance has
    /// settled. Must run *before* the completion/failure callback goes out: the
    /// callback synchronously starts the next queued utterance, which would
    /// otherwise land on the old session — old model, old delay, old pricing —
    /// while its output mode was already frozen against the new settings.
    private func applyPendingRefreshIfSettled() {
        guard pendingSettingsRefresh, !utteranceActive else { return }
        reconnectAttempt = 0
        disconnect()
        connectIfNeeded()
    }

    /// Server-side transcription time scales with utterance length — a fixed
    /// 20 s would give up on a multi-minute utterance the server is still
    /// legitimately chewing on, and drop the completion that arrives right after.
    /// 0.5× realtime is generous; observed transcription is well under that.
    private var transcriptionBudget: TimeInterval {
        Self.responseTimeoutInterval(
            rawAudioBytes: utteranceUploadedBytes + pendingBytes,
            remoteUploadAcknowledged: true
        )
    }

    /// Shared by the live timeout and regression tests. Before the server's committed
    /// event, the budget includes remote upload time; local WebSocket send completions
    /// never select the acknowledged branch.
    static func responseTimeoutInterval(
        rawAudioBytes: Int,
        remoteUploadAcknowledged: Bool
    ) -> TimeInterval {
        let bytes = max(0, rawAudioBytes)
        let audioSeconds = Double(bytes) / Double(AudioCapture.bytesPerSecond)
        let transcription = responseTimeout + audioSeconds * 0.5
        guard !remoteUploadAcknowledged else { return transcription }
        return transcription + Double(bytes) / Double(assumedUploadBytesPerSecond)
    }

    /// Arms the response timeout with an allowance for audio whose remote receipt is not
    /// yet proven. A URLSession send completion only means "written to the local kernel",
    /// so the whole allowance remains until `input_audio_buffer.committed` arrives.
    /// Dead transports still fail faster through the send/receive paths.
    private func startResponseTimeout() {
        let remotelyUnacknowledged = utteranceUploadedBytes + pendingBytes
        scheduleResponseTimeout(after: Self.responseTimeoutInterval(
            rawAudioBytes: remotelyUnacknowledged,
            remoteUploadAcknowledged: false
        ))
    }

    private func scheduleResponseTimeout(after interval: TimeInterval) {
        clearResponseTimeout()
        responseTimeoutDeadline = Date().addingTimeInterval(interval)
        responseTimeoutTimer = CommonRunLoopTimer.schedule(
            after: interval,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.utteranceActive else { return }
                self.utteranceActive = false
                self.responseTimeoutTimer = nil
                self.responseTimeoutDeadline = nil
                let provider = self.activeRoute?.provider
                    ?? self.settings.transcriptionModel.provider
                switch Self.responseTimeoutStrategy(
                    provider: provider,
                    commitPending: self.commitPending,
                    hasKnownItemID: self.currentItemID != nil
                ) {
                case .discardPendingCommit:
                    // The commit never went out; drop the local buffers too, or the
                    // audio of an utterance we just told the user failed would be
                    // uploaded and billed the moment the session comes up.
                    self.commitPending = false
                    self.turnStartPending = false
                    self.pendingAudio.removeAll()
                    self.pendingBytes = 0
                case .retireCurrentTurn:
                    self.retireCurrentTurn()
                case .replaceSession:
                    // This also covers an OpenAI commit whose item id never arrived:
                    // a late event could not be distinguished from the next turn.
                    self.disconnect()
                    self.reconnectAttempt = 0
                    self.connectIfNeeded()
                }
                self.applyPendingRefreshIfSettled()
                self.onFailure?("等待转写结果超时")
            }
        }
    }

    private func clearResponseTimeout() {
        responseTimeoutTimer?.invalidate()
        responseTimeoutTimer = nil
        responseTimeoutDeadline = nil
    }
}
