import WebSocket from "ws";

const ALLOWED_EVENT_TYPES = new Set([
  "session.update",
  "input_audio_buffer.append",
  "input_audio_buffer.commit",
  "input_audio_buffer.clear",
]);
const ALLOWED_DELAYS = new Set(["minimal", "low", "medium", "high", "xhigh"]);

// AppSettings accepts 100 user-entered terms and prepends one built-in name. Re-checked
// here rather than trusted from the app, because this is the boundary that decides what
// an authenticated device may spend the upstream session on: without a cap, `keywords`
// is a free-text channel to OpenAI that happens to be shaped like a word list.
const MAX_KEYWORDS = 101;
const MAX_KEYWORD_LENGTH = 40;

/// Chinese lead, English detail in parentheses. These reach the user through the app's
/// connection error status, which is otherwise all Chinese. The English half stays
/// because it names the offending field and is the only practical way to debug a
/// client/server version mismatch.
const REJECT = Object.freeze({
  binary: "转发服务器不接受二进制消息（binary messages are not allowed）",
  tooLarge: "转发服务器：消息超过大小上限（message is too large）",
  notJSON: "转发服务器：消息不是有效 JSON（message is not valid JSON）",
  eventType: "转发服务器不接受这种事件类型（event type is not allowed）",
  eventID: "转发服务器：event_id 无效（event_id is invalid）",
  sessionField:
    "转发服务器：session.update 含有不支持的字段"
    + "（session.update contains an unsupported field）",
  sessionConfigField:
    "转发服务器：会话配置含有不支持的字段"
    + "（session configuration contains an unsupported field）",
  sessionConfig:
    "转发服务器不接受当前会话配置，可能是服务器与 App 的模型列表不一致"
    + "（session configuration is not allowed）",
  audioField:
    "转发服务器：音频事件含有不支持的字段"
    + "（audio event contains an unsupported field）",
  audioBase64: "转发服务器：音频不是有效 base64（audio is not valid base64）",
  audioTooLong: "转发服务器：这一句的音频超过上限（turn audio exceeds the relay limit）",
  audioDailyDevice: "今天的转写额度已用完，请明天再试（daily transcription limit reached）",
  audioDailyTotal: "转发服务器今天的总额度已用完，请稍后再试（relay daily limit reached）",
  audioUnexpected:
    "转发服务器：该事件不应携带 audio 字段（audio is not allowed on this event）",
  keywords:
    "转发服务器：常用词汇表不合法，可能太长或含有非法字符"
    + "（keywords list is not allowed）",
});

/// A vocabulary list the upstream will accept: bounded, non-empty strings. `<`, `>` and
/// line breaks are documented as invalid inside a keyword, and rejecting them here turns
/// one malformed term into a clear local error instead of a failed session upstream.
function validKeywords(value) {
  return Array.isArray(value)
    && value.length <= MAX_KEYWORDS
    && value.every((term) => typeof term === "string"
      && term.length > 0
      && term.length <= MAX_KEYWORD_LENGTH
      && !/[<>\r\n]/.test(term));
}

function onlyKeys(object, allowed) {
  return object
    && typeof object === "object"
    && !Array.isArray(object)
    && Object.keys(object).every((key) => allowed.has(key));
}

export function validateRealtimeEvent(data, isBinary, config, state) {
  state.acceptedAudioBytes = 0;
  state.acceptedAudioEventID = undefined;
  if (isBinary) return REJECT.binary;
  if (data.length > config.maxWebSocketPayloadBytes) return REJECT.tooLarge;

  let event;
  try {
    event = JSON.parse(data.toString("utf8"));
  } catch {
    return REJECT.notJSON;
  }
  if (!ALLOWED_EVENT_TYPES.has(event?.type)) return REJECT.eventType;
  if (event.event_id !== undefined
      && (typeof event.event_id !== "string" || event.event_id.length > 160)) {
    return REJECT.eventID;
  }

  if (event.type === "session.update") {
    if (!onlyKeys(event, new Set(["type", "event_id", "session"]))) {
      return REJECT.sessionField;
    }
    const session = event.session;
    const audio = session?.audio;
    const input = audio?.input;
    const format = input?.format;
    const transcription = input?.transcription;
    if (!onlyKeys(session, new Set(["type", "audio"]))
        || !onlyKeys(audio, new Set(["input"]))
        || !onlyKeys(input, new Set(["format", "transcription", "turn_detection"]))
        || !onlyKeys(format, new Set(["type", "rate"]))
        || !onlyKeys(transcription, new Set(["model", "delay", "keywords"]))) {
      return REJECT.sessionConfigField;
    }
    if (transcription.keywords !== undefined && !validKeywords(transcription.keywords)) {
      // Its own message rather than the generic one: a word list has many more ways to
      // be wrong than a model name, and "配置不对" would not narrow any of them down.
      return REJECT.keywords;
    }
    if (session.type !== "transcription"
        || format.type !== "audio/pcm"
        || format.rate !== 24_000
        || input.turn_detection !== null
        || !config.allowedTranscriptionModels.has(transcription.model)
        || (transcription.delay !== undefined && !ALLOWED_DELAYS.has(transcription.delay))) {
      return REJECT.sessionConfig;
    }
    return null;
  }

  if (!onlyKeys(event, new Set(["type", "event_id", "audio"]))) {
    return REJECT.audioField;
  }

  if (event.type === "input_audio_buffer.append") {
    if (typeof event.audio !== "string"
        || event.audio.length % 4 !== 0
        || !/^[A-Za-z0-9+/]*={0,2}$/.test(event.audio)) {
      return REJECT.audioBase64;
    }
    const audioBytes = Buffer.byteLength(event.audio, "base64");
    if (state.turnAudioBytes + audioBytes > config.maxTurnAudioBytes) {
      return REJECT.audioTooLong;
    }
    state.turnAudioBytes += audioBytes;
    state.acceptedAudioBytes = audioBytes;
    state.acceptedAudioEventID = event.event_id;
  } else {
    if (event.audio !== undefined) return REJECT.audioUnexpected;
    state.turnAudioBytes = 0;
  }
  return null;
}

/// Best-effort `event_id` of the client event that was rejected.
///
/// Re-parses on the rejection path only, which happens at most once per connection
/// because the bridge closes right after. Returns undefined for the rejections where
/// there is nothing to recover — a binary frame, an oversized frame, malformed JSON.
export function clientEventID(data, isBinary) {
  if (isBinary) return undefined;
  try {
    const id = JSON.parse(data.toString("utf8"))?.event_id;
    return typeof id === "string" && id.length <= 160 ? id : undefined;
  } catch {
    return undefined;
  }
}

/// The Realtime schema ties an error to the client event that caused it through a
/// *nested* `error.event_id`, and the app relies on exactly that field to decide whether
/// an error belongs to the sentence it is currently waiting on. Omitting it meant every
/// post-`session.updated` rejection — "这一句的音频超过上限" above all — was filed as
/// "not this turn" and dropped, so the user was told the connection broke instead of
/// what was actually wrong with their utterance.
function relayError(message, code, eventID) {
  const error = { message, type: "relay_error", code };
  if (eventID) error.event_id = eventID;
  return JSON.stringify({ type: "error", error });
}

/// Cuts a revoked connection off *now*, not when the close handshake completes.
///
/// `close()` alone leaves the socket in CLOSING, and `ws` keeps parsing and emitting
/// frames the whole time it waits for the peer's ack — measured: five frames sent after
/// `close()` were all still delivered to the message handler, i.e. still forwarded to
/// OpenAI on the server's key. `pause()` stops that stream synchronously, but is not
/// enough by itself: `ws`'s socket-close handler deliberately drains any data that was
/// buffered before destruction *into the receiver* (websocket.js, `socketOnClose`), so
/// everything held back by the pause would be parsed and forwarded in one burst the
/// moment the reaper fired — measured, all five frames arrived upstream exactly then.
/// Dropping the message listeners is what actually revokes: whatever gets parsed,
/// now or at the drain, is emitted to nobody. Sending is unaffected throughout, so the
/// 4001 close frame still reaches the peer to tell it why; a paused socket can never
/// read the close ack, so the timer reaps it unconditionally, and the bridge's own
/// `close` handler — untouched by this — then shuts the upstream side down.
export function revokeDownstream(socket, {
  upstream = null,
  graceMs = 5_000,
  closeCode = 4001,
  closeReason = "device token revoked",
} = {}) {
  socket.pause();
  socket.removeAllListeners("message");
  socket.close(closeCode, closeReason);
  // The OpenAI side dies with the revoke, not with the reap. Left to the bridge it
  // only closes when the downstream `close` event finally fires — up to graceMs away —
  // and until then audio already buffered toward OpenAI keeps transmitting, while an
  // upstream still in CONNECTING would flush the whole preopen queue the moment it
  // opened. `terminate()`, not `close()`: a close frame queues *behind* the buffered
  // audio, which is to say it politely sends every byte first.
  if (upstream) upstream.terminate();
  setTimeout(() => socket.terminate(), graceMs).unref();
}

export function safeCloseCode(code, fallback = 1011) {
  const protocolCodes = new Set([
    1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014,
  ]);
  return protocolCodes.has(code) || (code >= 3000 && code <= 4999)
    ? code
    : fallback;
}

/// Forwards one frame and reports whether the peer is now over its high-water mark.
///
/// Returning "over" is not an error: a queued multi-minute utterance is flushed by the
/// app as ~28 back-to-back 1.4 MB frames, and closing the socket the moment the far
/// side lags would destroy exactly the dictation the client-side buffering exists to
/// protect. The caller pauses the reader instead; TCP then does the rest.
function forward(target, data, isBinary, config) {
  if (target.readyState !== WebSocket.OPEN) return "closed";
  target.send(data, { binary: isBinary });
  return target.bufferedAmount > config.maxForwardBufferBytes ? "over" : "ok";
}

/// Stops reading from `source` until `target` has drained. `ws` has no drain event, so
/// this polls; the interval only runs while a peer is actually backed up.
///
/// `onResume` re-arms the caller's liveness flag. `pause()` stops the underlying
/// socket, which stops pong frames from being parsed too — so a peer that answered
/// normally looks dead for the whole pause, and the first tick after resuming would
/// act on a verdict that was really about backpressure. Measured, not assumed:
/// zero pongs are delivered while paused.
function pauseUntilDrained(source, target, config, isSettled, {
  onBackpressure,
  onResume,
  onStall,
} = {}) {
  if (source.isPaused) return;
  onBackpressure?.();
  source.pause();
  // A one-byte change is not proof that a multi-megabyte queue is draining. Measure
  // bounded windows and require enough movement to clear at least one eighth of the
  // configured high-water mark per window. At the production defaults this is only
  // about 17 KiB/s, deliberately below realtime PCM throughput, while still bounding
  // a half-open socket that merely dribbles kernel-buffer bookkeeping forever.
  const minimumWindowProgress = Math.max(
    1,
    Math.ceil(config.maxForwardBufferBytes / 8),
  );
  let windowStartedAt = Date.now();
  let windowStartBufferedAmount = target.bufferedAmount;
  const timer = setInterval(() => {
    const now = Date.now();
    const bufferedAmount = target.bufferedAmount;
    const done = isSettled()
      || target.readyState !== WebSocket.OPEN
      || bufferedAmount <= config.maxForwardBufferBytes / 2;
    if (done) {
      clearInterval(timer);
      if (source.readyState === WebSocket.OPEN && source.isPaused) {
        source.resume();
        onResume?.();
      }
      return;
    }
    if (now - windowStartedAt < config.backpressureStallTimeoutMs) return;
    if (windowStartBufferedAmount - bufferedAmount >= minimumWindowProgress) {
      windowStartedAt = now;
      windowStartBufferedAmount = bufferedAmount;
      return;
    }
    clearInterval(timer);
    onStall?.();
  }, 50);
  timer.unref();
}

export function bridgeRealtime(downstream, config, { consumeAudio = null } = {}) {
  const upstream = new WebSocket(config.openAIRealtimeURL, {
    headers: { authorization: `Bearer ${config.openAIAPIKey}` },
    handshakeTimeout: 10_000,
    maxPayload: config.maxWebSocketPayloadBytes,
    perMessageDeflate: false,
  });
  const state = { turnAudioBytes: 0 };
  const preopenQueue = [];
  let preopenBytes = 0;
  let settled = false;
  // Re-armed on resume: a verdict formed while the socket was paused says nothing
  // about the peer, only about backpressure.
  let downstreamAlive = true;
  let upstreamAlive = true;
  // A socket can be unobservable for either of two independent reasons. It may be the
  // paused source, in which case ws cannot parse its pong; or it may be the congested
  // target, in which case our ping sits behind megabytes already queued to it. Looking
  // only at `isPaused` covers the first case and falsely reaps the second one.
  let downstreamTargetBackpressured = false;
  let upstreamTargetBackpressured = false;
  const markDownstreamAlive = () => { downstreamAlive = true; };
  const markUpstreamAlive = () => { upstreamAlive = true; };
  const pauseForUpstream = () => pauseUntilDrained(
    downstream,
    upstream,
    config,
    () => settled,
    {
      onBackpressure: () => { upstreamTargetBackpressured = true; },
      onResume: () => {
        upstreamTargetBackpressured = false;
        markDownstreamAlive();
        markUpstreamAlive();
      },
      onStall: () => terminateBoth(),
    },
  );
  const pauseForDownstream = () => pauseUntilDrained(
    upstream,
    downstream,
    config,
    () => settled,
    {
      onBackpressure: () => { downstreamTargetBackpressured = true; },
      onResume: () => {
        downstreamTargetBackpressured = false;
        markUpstreamAlive();
        markDownstreamAlive();
      },
      onStall: () => terminateBoth(),
    },
  );

  const closeBoth = (code = 1011, reason = "relay closed") => {
    if (settled) return;
    settled = true;
    if (downstream.readyState === WebSocket.OPEN) downstream.close(code, reason);
    if (upstream.readyState === WebSocket.OPEN
        || upstream.readyState === WebSocket.CONNECTING) {
      upstream.close(code, reason);
    }
  };

  // A no-progress deadline is different from an ordinary protocol failure. The source
  // is paused and may itself have a large outbound queue, so a graceful close frame can
  // sit behind that queue until ws's 30-second close timer. Force both TCP connections
  // down to release the paid upstream and the relay slot at the watchdog deadline.
  const terminateBoth = () => {
    if (settled) return;
    settled = true;
    if (downstream.readyState === WebSocket.OPEN
        || downstream.readyState === WebSocket.CONNECTING) downstream.terminate();
    if (upstream.readyState === WebSocket.OPEN
        || upstream.readyState === WebSocket.CONNECTING) upstream.terminate();
  };

  const rejectConsumedAudio = () => {
    if (state.acceptedAudioBytes <= 0 || !consumeAudio) return false;
    const quota = consumeAudio(state.acceptedAudioBytes);
    if (!quota) return false;
    downstream.send(relayError(
      quota === "total" ? REJECT.audioDailyTotal : REJECT.audioDailyDevice,
      "relay_daily_quota",
      // The caller has already parsed and validated this event. It supplies the id
      // below because keeping the raw frame outside the message callback would retain
      // multi-megabyte audio buffers for the lifetime of the bridge.
      state.acceptedAudioEventID,
    ));
    closeBoth(1008, "daily relay quota reached");
    return true;
  };

  downstream.on("message", (data, isBinary) => {
    const validationError = validateRealtimeEvent(data, isBinary, config, state);
    if (validationError) {
      downstream.send(relayError(
        validationError,
        "relay_invalid_event",
        clientEventID(data, isBinary),
      ));
      closeBoth(1008, "invalid relay event");
      return;
    }

    if (upstream.readyState === WebSocket.OPEN) {
      // The quota is a cost backstop, so charge only after this frame has a viable
      // destination. Charging before the state/queue checks below made a frame the
      // relay discarded while OpenAI was still connecting consume the user's day.
      if (rejectConsumedAudio()) return;
      const result = forward(upstream, data, isBinary, config);
      if (result === "closed") closeBoth(1011, "upstream closed");
      else if (result === "over") {
        pauseForUpstream();
      }
      return;
    }
    if (upstream.readyState !== WebSocket.CONNECTING
        || preopenBytes + data.length > config.maxPreopenQueueBytes) {
      closeBoth(1013, "relay upstream not ready");
      return;
    }
    if (rejectConsumedAudio()) return;
    preopenQueue.push({ data: Buffer.from(data), isBinary });
    preopenBytes += data.length;
  });

  upstream.on("open", () => {
    for (const queued of preopenQueue) {
      if (forward(upstream, queued.data, queued.isBinary, config) === "closed") {
        closeBoth(1011, "upstream closed");
        return;
      }
    }
    preopenQueue.length = 0;
    preopenBytes = 0;
    if (upstream.bufferedAmount > config.maxForwardBufferBytes) {
      pauseForUpstream();
    }
  });

  upstream.on("message", (data, isBinary) => {
    const result = forward(downstream, data, isBinary, config);
    if (result === "closed") closeBoth(1011, "client closed");
    else if (result === "over") {
      pauseForDownstream();
    }
  });

  upstream.on("unexpected-response", (_request, response) => {
    const authenticationFailed = response.statusCode === 401 || response.statusCode === 403;
    const message = authenticationFailed
      ? "转发服务器 authentication 失败：OpenAI API Key 无效或没有权限"
      : `转发服务器连接 OpenAI 失败（HTTP ${response.statusCode}）`;
    if (downstream.readyState === WebSocket.OPEN) {
      downstream.send(relayError(message, "relay_upstream_handshake"));
    }
    setImmediate(() => closeBoth(1011, "upstream handshake failed"));
  });

  upstream.on("error", () => {
    if (downstream.readyState === WebSocket.OPEN) {
      downstream.send(relayError(
        "转发服务器连接 OpenAI 失败",
        "relay_upstream_unreachable",
      ));
    }
    setImmediate(() => closeBoth(1011, "upstream connection failed"));
  });
  upstream.on("close", (code) => {
    closeBoth(safeCloseCode(code), "upstream closed");
  });
  downstream.on("close", (code) => {
    closeBoth(safeCloseCode(code, 1000), "client closed");
  });
  downstream.on("error", () => closeBoth(1011, "client connection failed"));

  // Liveness has to be checked in *both* directions. Pinging only upstream keeps the
  // paid OpenAI session alive on behalf of a client that may already be gone: this is
  // a laptop menu-bar app, so sleep and Wi-Fi changes routinely leave a half-open
  // downstream socket that no close event ever reports and that TCP takes minutes to
  // reap. Each of those zombies also holds one of the device's connection slots, so
  // two sleep/wake cycles are enough to lock the user out with 429.
  //
  // The upstream side needs its own verdict, not just a ping. A silently dead
  // relay→OpenAI socket while the Mac→relay socket is healthy leaves the app showing
  // "ready", so the next thing the user says is written into a corpse and is not
  // noticed until the client's own timeout — by which point the sentence is gone.
  // Any inbound frame proves liveness, not just a pong — a peer mid-way through
  // uploading an utterance is obviously alive, and under load its pong can sit behind
  // megabytes of queued audio for longer than one sweep. The sweep exists to catch a
  // *silent* peer; treating it as a pong-only check invents failures under load.
  downstream.on("pong", markDownstreamAlive);
  downstream.on("message", markDownstreamAlive);
  upstream.on("pong", markUpstreamAlive);
  upstream.on("message", markUpstreamAlive);
  upstream.on("open", markUpstreamAlive);

  const pingTimer = setInterval(() => {
    // A paused peer cannot deliver pongs at all, so while backpressure holds, its
    // liveness is simply unobservable — checking anyway would terminate a perfectly
    // healthy client mid-utterance and lose audio that has already been handed to
    // the socket and therefore cannot be replayed.
    if (!downstream.isPaused && !downstreamTargetBackpressured) {
      if (!downstreamAlive) {
        // No pong across a whole interval. `terminate`, not `close`: a peer that is
        // not answering will not complete a closing handshake either.
        downstream.terminate();
        closeBoth(1001, "client went away");
        return;
      }
      downstreamAlive = false;
      if (downstream.readyState === WebSocket.OPEN) downstream.ping();
    }

    if (upstream.readyState === WebSocket.OPEN
        && !upstream.isPaused
        && !upstreamTargetBackpressured) {
      if (!upstreamAlive) {
        upstream.terminate();
        closeBoth(1011, "upstream went away");
        return;
      }
      upstreamAlive = false;
      upstream.ping();
    }
  }, config.clientHeartbeatIntervalMs);
  pingTimer.unref();

  const stopPinging = () => clearInterval(pingTimer);
  upstream.once("close", stopPinging);
  downstream.once("close", stopPinging);

  return upstream;
}
