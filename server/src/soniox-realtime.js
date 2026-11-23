import WebSocket from "ws";

import { SONIOX_DEFAULTS } from "./config.js";
import {
  clientEventID,
  pauseUntilDrained,
  safeCloseCode,
  validateRealtimeEvent,
} from "./realtime.js";

export const SONIOX_MODEL = "stt-rt-v6";

// Written from Soniox's published WebSocket reference and checked once against the live
// service with `scripts/soniox-smoke.mjs`, both on 2026-11-22 (one 6.7 s synthetic zh/en
// sentence): 3/3 idle pings answered over 45 s, the strict two-language start message
// accepted, `<fin>` 49 ms and `finished` 199 ms after the last audio, and no non-final
// tokens after `<fin>`. One sentence is evidence for the protocol and the latency, not
// for accuracy on real speech.
//
// The shape of the service decides the shape of this bridge:
//
//   - One Soniox connection carries one *stream*, opened by a start message. A stream is
//     billed for its whole duration, not for the audio in it, and a keepalive keeps it
//     billable. The app keeps a socket warm all day, so starting the stream at connect
//     would bill every idle hour of every device.
//   - A connection that has not sent its start message yet is just a socket. Soniox
//     keeps it open as long as something arrives every 40 s.
//
// So the upstream socket is opened (and authenticated) as soon as the app connects, and
// the start message is held back until the first audio of a sentence. The sentence then
// has the stream to itself: it is finalized, answered, and the connection is retired
// with it — the same one-session-per-sentence contract the Gemini bridge already has
// with the app, which reconnects at once and finds the next socket warm.

// The app refreshes its socket a minute before this synthetic expiry. Soniox documents
// no lifetime for a connection that has not started a stream; ten minutes is the Gemini
// figure, which the app is already proven against, and a periodic replacement also
// bounds how long a silently dead idle socket can sit there looking ready.
const SONIOX_SESSION_SECONDS = 10 * 60;
// Documented: a connection with no start message is closed (1001) after 40 s of
// silence, which is what `SONIOX_DEFAULTS.prestartKeepaliveMs` is sized against. The
// message is Soniox's own `ping` rather than its one-way `keepalive`, because a ping is
// answered: an idle socket otherwise receives nothing at all, and the relay's liveness
// sweep would have only WebSocket-level pongs to go on — which nothing in Soniox's
// reference promises.

// Bounds a committed sentence Soniox never finalizes. Re-armed by every frame it does
// send, so it measures silence rather than elapsed time; the app's own timeout is 20 s.
const DEFAULT_FINAL_TIMEOUT_MS = 5_000;
// The speaker mixes Mandarin and English inside one sentence and speaks nothing else.
// Hints bias recognition towards these two; `language_hints_strict` additionally asks
// Soniox not to emit any other language. Soniox calls strict mode best-effort and most
// robust with a single language — if mixed sentences come back worse with it on, set
// SONIOX_LANGUAGE_HINTS_STRICT=0 before touching anything else. The defaults themselves
// are `SONIOX_DEFAULTS` in config.js.

// Background, not instructions: Soniox's `context` describes the audio, it cannot be
// told what to do with it. Nothing removes filler words or self-corrections on this
// route — the app deliberately skips its polish pass here, because this is the route
// chosen for speed — so what Soniox returns is what gets typed.
const CONTEXT_GENERAL = Object.freeze([
  { key: "setting", value: "Personal voice dictation typed into Mac apps" },
  {
    key: "language",
    value: "Mandarin Chinese in Simplified characters, with English words, names and "
      + "technical terms mixed into the same sentence",
  },
]);
// Markers Soniox interleaves with the text: `<fin>` answers a manual finalize, `<end>`
// an endpoint. Neither is speech.
const CONTROL_TOKENS = new Set(["<fin>", "<end>"]);

function relayError(message, code, eventID, sessionReplacementRequired = true) {
  const error = { message, type: "relay_error", code };
  if (eventID) error.event_id = eventID;
  if (sessionReplacementRequired) error.session_replacement_required = true;
  return JSON.stringify({ type: "error", error });
}

/// The start message for one sentence, built from the app's own session frame.
export function sonioxStartFromSessionUpdate(event, config = {}) {
  const transcription = event?.session?.audio?.input?.transcription;
  if (transcription?.model !== SONIOX_MODEL) return null;
  const context = { general: CONTEXT_GENERAL };
  // The same list the other routes receive as `keywords` / `customVocabulary`.
  if (transcription.keywords?.length) context.terms = transcription.keywords;
  return {
    model: SONIOX_MODEL,
    // What the app's AudioCapture produces, and what the relay validates above.
    audio_format: "pcm_s16le",
    sample_rate: 24_000,
    num_channels: 1,
    language_hints: config.sonioxLanguageHints ?? SONIOX_DEFAULTS.languageHints,
    language_hints_strict: config.sonioxLanguageHintsStrict
      ?? SONIOX_DEFAULTS.languageHintsStrict,
    // The hotkey decides where a sentence ends; nothing here should guess.
    enable_endpoint_detection: false,
    context,
  };
}

/// What a Soniox error frame should say to the person looking at the menu bar.
///
/// The app decides whether to keep retrying from words in the message — "authentication"
/// and "billing" stop the ladder, because neither fixes itself — so those words are
/// load-bearing here in the same way they are in the Gemini bridge.
export function sonioxErrorMessage(frame) {
  const code = Number(frame?.error_code);
  const type = typeof frame?.error_type === "string" ? frame.error_type : "";
  if (code === 401 || code === 403) {
    return "转发服务器 authentication 失败：Soniox API Key 无效或没有权限";
  }
  if (code === 402) {
    return "Soniox 余额用完了，去 Soniox 控制台的 Billing 充值后再按一次就恢复";
  }
  if (code === 429) {
    return "Soniox 暂时超出并发或频率上限，稍后会自动重试（rate limit）";
  }
  // Only the controlled vocabulary travels on: `error_message` is free text from a
  // third party and would be shown verbatim in the app.
  const detail = /^[a-z_]{1,64}$/.test(type) ? type : `HTTP ${code || "?"}`;
  return `Soniox 转写失败（${detail}）`;
}

export function bridgeSonioxRealtime(
  downstream,
  config,
  { consumeAudio = null, onEnd = null, onTurn = null } = {},
) {
  const upstream = new WebSocket(config.sonioxRealtimeURL, {
    // In the handshake rather than in the start message: Soniox refuses a key sent only
    // in the start message from 2027-01-15, and a key in the handshake is also what
    // lets the connection be held open before any stream starts.
    headers: { authorization: `Bearer ${config.sonioxAPIKey}` },
    handshakeTimeout: 10_000,
    maxPayload: config.maxWebSocketPayloadBytes,
    perMessageDeflate: false,
  });
  const validationState = { turnAudioBytes: 0 };
  const allowedModels = config.allowedSonioxTranscriptionModels
    || new Set([SONIOX_MODEL]);
  const preopenQueue = [];
  let preopenBytes = 0;
  let settled = false;
  let startMessage = null;
  let ready = false;
  let streamStarted = false;
  let streamEnded = false;
  let pingSequence = 0;
  let turnSequence = 0;
  let turn = null;
  let finalTimer = null;
  let prestartKeepalive = null;
  let downstreamAlive = true;
  let upstreamAlive = true;
  let downstreamTargetBackpressured = false;
  let upstreamTargetBackpressured = false;
  const markDownstreamAlive = () => { downstreamAlive = true; };
  const markUpstreamAlive = () => { upstreamAlive = true; };

  const publishEnd = (reason) => {
    try { onEnd?.(reason); } catch { /* diagnostics never own transport teardown */ }
  };
  /// Counts only, as on the Gemini path: neither transcripts nor audio reach the log.
  const publishTurn = (record) => {
    try { onTurn?.(record); } catch { /* diagnostics never own transport teardown */ }
  };
  const reportTurnEnd = (outcome, chars = 0, { answered = false } = {}) => {
    if (!turn || turn.reported) return;
    turn.reported = true;
    publishTurn({
      event: "end",
      item: turn.itemID,
      outcome,
      audioBytes: turn.audioBytes,
      ageMs: Math.max(0, Date.now() - turn.openedAt),
      chars,
      finalMs: answered && turn.committedAt !== null
        ? Math.max(0, Date.now() - turn.committedAt)
        : null,
    });
  };
  const clearTimers = () => {
    clearTimeout(finalTimer);
    finalTimer = null;
    clearInterval(prestartKeepalive);
    prestartKeepalive = null;
  };
  const closeBoth = (code = 1011, reason = "relay closed") => {
    if (settled) return;
    settled = true;
    reportTurnEnd("abandoned");
    publishEnd(reason);
    clearTimers();
    if (downstream.readyState === WebSocket.OPEN) downstream.close(code, reason);
    if (upstream.readyState === WebSocket.OPEN) {
      // An empty text frame is Soniox's end-of-stream. Sending it before the close
      // frame ends the billed stream explicitly instead of leaving that to however
      // the far side accounts for a dropped connection.
      if (streamStarted && !streamEnded) upstream.send("");
      upstream.close(1000, "relay closed");
    } else if (upstream.readyState === WebSocket.CONNECTING) {
      upstream.close();
    }
  };
  const terminateBoth = (reason) => {
    if (settled) return;
    settled = true;
    reportTurnEnd("abandoned");
    publishEnd(reason);
    clearTimers();
    if (downstream.readyState === WebSocket.OPEN
        || downstream.readyState === WebSocket.CONNECTING) downstream.terminate();
    if (upstream.readyState === WebSocket.OPEN
        || upstream.readyState === WebSocket.CONNECTING) upstream.terminate();
  };
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
      onStall: () => terminateBoth("upstream backpressure stalled"),
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
      onStall: () => terminateBoth("downstream backpressure stalled"),
    },
  );
  const sendDownstream = (object) => {
    if (downstream.readyState !== WebSocket.OPEN) return false;
    downstream.send(JSON.stringify(object));
    if (downstream.bufferedAmount > config.maxForwardBufferBytes) {
      pauseForDownstream();
    }
    return true;
  };
  const sendUpstream = (payload, isBinary = false) => {
    if (upstream.readyState !== WebSocket.OPEN) return false;
    upstream.send(payload, { binary: isBinary });
    if (upstream.bufferedAmount > config.maxForwardBufferBytes) {
      pauseForUpstream();
    }
    return true;
  };
  const failSession = (message, code, closeCode, reason, eventID) => {
    if (downstream.readyState === WebSocket.OPEN) {
      downstream.send(relayError(message, code, eventID));
    }
    closeBoth(closeCode, reason);
  };
  const rejectAudioQuota = (audioBytes, eventID) => {
    if (audioBytes <= 0 || !consumeAudio) return false;
    const quota = consumeAudio(audioBytes);
    if (!quota) return false;
    failSession(
      quota === "total"
        ? "转发服务器今天的总额度已用完，请稍后再试（relay daily limit reached）"
        : "今天的转写额度已用完，请明天再试（daily transcription limit reached）",
      "relay_daily_quota",
      1008,
      "daily relay quota reached",
      eventID,
    );
    return true;
  };

  /// Final text is append-only — Soniox never revises a token it has marked final — and
  /// the non-final tail is replaced wholesale by every frame. Together they are the
  /// complete-utterance snapshot the app's partial callback expects.
  const snapshot = () => turn.finalText + turn.nonFinalText;

  const finishTurn = ({ isolateProvider, outcome = "completed", fallback = false }) => {
    clearTimeout(finalTimer);
    finalTimer = null;
    if (!turn?.committed || turn.cancelled) return;
    const transcript = fallback ? snapshot() : turn.finalText;
    reportTurnEnd(outcome, [...transcript].length, { answered: true });
    const completed = turn;
    turn = null;
    sendDownstream({
      type: "conversation.item.input_audio_transcription.completed",
      item_id: completed.itemID,
      transcript,
      // The stream this sentence opened is over, so the app must have a new socket
      // before it starts the next one — and its completion callback can start the
      // next one synchronously, before it would ever see our close frame.
      session_replacement_required: isolateProvider,
    });
    if (isolateProvider) closeBoth(1012, "soniox turn completed");
  };

  const armFinalTimeout = () => {
    clearTimeout(finalTimer);
    finalTimer = setTimeout(() => {
      if (!turn?.committed || turn.cancelled) return;
      if (snapshot().length > 0) {
        // Soniox heard the sentence and the app has been typing it; only the closing
        // confirmation is missing. Keep the words rather than replace them with an
        // error and an empty document.
        finishTurn({ isolateProvider: true, outcome: "partial_fallback", fallback: true });
        return;
      }
      failSession(
        "Soniox 没有及时返回转写结果（Soniox transcription timed out）",
        "relay_soniox_turn_timeout",
        1012,
        "soniox turn timed out",
        turn.lastEventID,
      );
    }, config.sonioxFinalTimeoutMs ?? DEFAULT_FINAL_TIMEOUT_MS);
    finalTimer.unref?.();
  };

  const startTurn = (eventID) => {
    turnSequence += 1;
    turn = {
      itemID: `soniox-turn-${turnSequence}`,
      active: true,
      committed: false,
      cancelled: false,
      finalText: "",
      nonFinalText: "",
      sentSnapshot: "",
      lastEventID: eventID,
      audioBytes: 0,
      openedAt: Date.now(),
      committedAt: null,
      reported: false,
    };
    publishTurn({ event: "open", item: turn.itemID });
  };

  const announceReady = () => {
    if (ready || settled || !startMessage || upstream.readyState !== WebSocket.OPEN) {
      return;
    }
    ready = true;
    // There is no provider acknowledgement to wait for: nothing is sent to Soniox until
    // a sentence begins. A rejected key or an empty balance surfaces as an error frame
    // on this same socket and is reported then.
    sendDownstream({
      type: "session.created",
      session: { expires_at: Date.now() / 1000 + SONIOX_SESSION_SECONDS },
    });
    sendDownstream({ type: "session.updated" });
    const keepaliveMs = config.sonioxPrestartKeepaliveMs
      ?? SONIOX_DEFAULTS.prestartKeepaliveMs;
    if (keepaliveMs > 0) {
      prestartKeepalive = setInterval(() => {
        // Only while idle and unbilled. Once the stream has started its own audio is
        // the traffic, and the stream ends with the sentence.
        if (settled || streamStarted) return;
        pingSequence += 1;
        sendUpstream(JSON.stringify({ type: "ping", id: pingSequence }));
      }, keepaliveMs);
      prestartKeepalive.unref?.();
    }
  };

  const handleClientEvent = (event, audioBytes = 0) => {
    const type = event.type;
    if (type === "session.update") {
      const start = sonioxStartFromSessionUpdate(event, config);
      if (!start || startMessage) {
        failSession(
          "转发服务器不接受当前 Soniox 会话配置（Soniox session configuration is not allowed）",
          "relay_invalid_event",
          1008,
          "invalid soniox session",
          event.event_id,
        );
        return;
      }
      startMessage = start;
      announceReady();
      return;
    }
    if (!ready) {
      failSession(
        "Soniox 会话还没有准备好（Soniox session is not ready）",
        "relay_upstream_not_ready",
        1013,
        "soniox session not ready",
        event.event_id,
      );
      return;
    }
    if (type === "input_audio_buffer.clear") {
      if (turn) {
        turn.cancelled = true;
        reportTurnEnd("cancelled");
        if (!streamStarted) {
          // Soniox never heard of this sentence, so there is nothing in flight that
          // could come back as the next one's text. Keep the warm socket.
          turn = null;
          return;
        }
        // Tokens carry no turn id. Once audio has gone out, only a new connection can
        // prove that a late result is not from the sentence that was abandoned.
        closeBoth(1012, "soniox turn cancelled");
        return;
      }
      startTurn(event.event_id);
      return;
    }
    if (type === "input_audio_buffer.append") {
      // Same leniency as the Gemini bridge: audio queued across a reconnect may arrive
      // without its explicit turn boundary, and that must not cost the sentence.
      if (!turn) startTurn(event.event_id);
      if (!turn.active) {
        failSession(
          "Soniox 没有正在录音的句子（Soniox turn is not active）",
          "relay_invalid_event",
          1008,
          "soniox audio outside turn",
          event.event_id,
        );
        return;
      }
      if (rejectAudioQuota(audioBytes, event.event_id)) return;
      if (audioBytes <= 0) return;
      if (!streamStarted) {
        streamStarted = true;
        sendUpstream(JSON.stringify(startMessage));
      }
      turn.audioBytes += audioBytes;
      turn.lastEventID = event.event_id;
      sendUpstream(Buffer.from(event.audio, "base64"), true);
      return;
    }
    if (type === "input_audio_buffer.commit") {
      if (!turn?.active) {
        failSession(
          "Soniox 没有可以提交的句子（Soniox turn is not active）",
          "relay_invalid_event",
          1008,
          "soniox commit outside turn",
          event.event_id,
        );
        return;
      }
      turn.active = false;
      turn.committed = true;
      turn.committedAt = Date.now();
      turn.lastEventID = event.event_id;
      sendDownstream({
        type: "input_audio_buffer.committed",
        item_id: turn.itemID,
      });
      if (!streamStarted) {
        // A press that captured no audio. Answer it here; the socket stays warm.
        finishTurn({ isolateProvider: false, outcome: "silent" });
        return;
      }
      // `finalize` makes every token up to here final and is answered with `<fin>`.
      // The empty text frame behind it ends the stream, which is answered with
      // `finished`. Either one completes the sentence; sending both means a lost or
      // unanswered finalize still ends in a complete transcript rather than a timeout.
      sendUpstream(JSON.stringify({ type: "finalize" }));
      sendUpstream("");
      streamEnded = true;
      armFinalTimeout();
    }
  };

  downstream.on("message", (data, isBinary) => {
    const validationError = validateRealtimeEvent(
      data,
      isBinary,
      config,
      validationState,
      allowedModels,
    );
    if (validationError) {
      failSession(
        validationError,
        "relay_invalid_event",
        1008,
        "invalid relay event",
        clientEventID(data, isBinary),
      );
      return;
    }
    const event = JSON.parse(data.toString("utf8"));
    const audioBytes = validationState.acceptedAudioBytes || 0;
    if (upstream.readyState === WebSocket.OPEN) {
      handleClientEvent(event, audioBytes);
      return;
    }
    if (upstream.readyState !== WebSocket.CONNECTING
        || preopenBytes + data.length > config.maxPreopenQueueBytes) {
      closeBoth(1013, "soniox upstream not ready");
      return;
    }
    // The validated byte count travels with the event; by replay time the validator's
    // state describes whichever message it saw last.
    preopenQueue.push({ event, audioBytes });
    preopenBytes += data.length;
  });

  upstream.on("open", () => {
    const queued = preopenQueue.splice(0);
    preopenBytes = 0;
    for (const { event, audioBytes } of queued) {
      if (settled) return;
      handleClientEvent(event, audioBytes);
    }
    announceReady();
  });

  upstream.on("message", (data, isBinary) => {
    if (settled || isBinary) return;
    let message;
    try { message = JSON.parse(data.toString("utf8")); } catch { return; }
    if (message.error_code !== undefined || message.error_type !== undefined) {
      const code = Number(message.error_code);
      failSession(
        sonioxErrorMessage(message),
        code === 401 || code === 403
          ? "relay_upstream_handshake"
          : code === 402 ? "relay_soniox_balance_exhausted" : "relay_soniox_error",
        1011,
        code === 402 ? "soniox balance exhausted" : "soniox error",
        turn?.lastEventID,
      );
      return;
    }
    // The answer to a pre-start ping. Its arrival is the point — the `message` listener
    // below has already counted it as proof the idle socket is alive.
    if (message.type === "pong") return;
    if (!turn || turn.cancelled) return;

    let finalized = false;
    let nonFinalText = "";
    for (const token of Array.isArray(message.tokens) ? message.tokens : []) {
      if (typeof token?.text !== "string") continue;
      if (CONTROL_TOKENS.has(token.text)) {
        if (token.text === "<fin>") finalized = true;
        continue;
      }
      if (token.is_final === true) turn.finalText += token.text;
      else nonFinalText += token.text;
    }
    turn.nonFinalText = nonFinalText;

    const endsTurn = finalized || message.finished === true;
    const text = snapshot();
    // Once the sentence is committed — the key is up — nothing more is sent as a partial.
    // `completed` follows within a fraction of a second and carries the whole text, and
    // the tokens keep accumulating above, so the timeout fallback still has them.
    //
    // A partial this late does harm: the app types it and is handed the final before the
    // keystroke has landed, and a document asked that soon still shows its caret one
    // keystroke back. Measured in the app: last partial to final, 5 to 10 ms on every
    // Soniox sentence. Not observed directly: whether those two came from one Soniox
    // frame or from two a few ms apart. This rule does not depend on which.
    if (!turn.committed && text.length > 0 && text !== turn.sentSnapshot) {
      turn.sentSnapshot = text;
      sendDownstream({
        type: "whisper.input_audio_transcription.partial",
        item_id: turn.itemID,
        transcript: text,
      });
    }

    if (endsTurn) {
      if (!turn.committed) {
        // Soniox closed the stream while the key was still down. Whatever the cause,
        // the rest of this sentence has nowhere to go.
        failSession(
          "Soniox 提前结束了这一句（Soniox ended the stream early）",
          "relay_soniox_stream_ended",
          1011,
          "soniox stream ended early",
          turn.lastEventID,
        );
        return;
      }
      // `finished` without `<fin>` means the finalize was not answered separately; the
      // stream's own ending has made everything final all the same, so any tail still
      // marked non-final at this point is kept rather than dropped.
      finishTurn({ isolateProvider: true, fallback: !finalized });
      return;
    }
    if (turn.committed) armFinalTimeout();
  });

  upstream.on("unexpected-response", (_request, response) => {
    const auth = response.statusCode === 401 || response.statusCode === 403;
    if (downstream.readyState === WebSocket.OPEN) {
      downstream.send(relayError(
        auth
          ? "转发服务器 authentication 失败：Soniox API Key 无效或没有权限"
          : `转发服务器连接 Soniox 失败（HTTP ${response.statusCode}）`,
        "relay_upstream_handshake",
      ));
    }
    setImmediate(() => closeBoth(1011, "soniox handshake failed"));
  });
  upstream.on("error", () => {
    if (downstream.readyState === WebSocket.OPEN) {
      downstream.send(relayError(
        "转发服务器连接 Soniox 失败",
        "relay_upstream_unreachable",
        turn?.lastEventID,
      ));
    }
    setImmediate(() => closeBoth(1011, "soniox connection failed"));
  });
  upstream.on("close", (code) => closeBoth(safeCloseCode(code), "soniox upstream closed"));
  downstream.on("close", (code) => closeBoth(safeCloseCode(code, 1000), "client closed"));
  downstream.on("error", () => closeBoth(1011, "client connection failed"));

  downstream.on("pong", markDownstreamAlive);
  downstream.on("message", markDownstreamAlive);
  upstream.on("pong", markUpstreamAlive);
  upstream.on("message", markUpstreamAlive);
  upstream.on("open", markUpstreamAlive);
  const pingTimer = setInterval(() => {
    if (!downstream.isPaused && !downstreamTargetBackpressured) {
      if (!downstreamAlive) {
        terminateBoth("client went away");
        return;
      }
      downstreamAlive = false;
      if (downstream.readyState === WebSocket.OPEN) downstream.ping();
    }
    if (!upstream.isPaused
        && !upstreamTargetBackpressured
        && upstream.readyState === WebSocket.OPEN) {
      if (!upstreamAlive) {
        terminateBoth("soniox upstream went away");
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
