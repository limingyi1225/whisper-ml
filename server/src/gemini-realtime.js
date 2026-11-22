import WebSocket from "ws";

import {
  clientEventID,
  pauseUntilDrained,
  safeCloseCode,
  validateRealtimeEvent,
} from "./realtime.js";

const GEMINI_MODEL = "gemini-3.5-transcribe-live";
// Gemini Transcribe documents a 10-minute Live session ceiling. RealtimeClient
// refreshes 60 seconds before this synthetic OpenAI-compatible expiry, leaving a
// full minute before Google's provider-side limit.
const GEMINI_SESSION_SECONDS = 10 * 60;
// inputTranscription is authoritative, but the dedicated transcription examples do
// not promise that it shares a frame with turnComplete. Keep a bounded fallback for
// that observed shape; 180 ms was too short to safely collect segmented final text.
const DEFAULT_FINAL_FALLBACK_DELAY_MS = 1_500;
// Gemini documents inputTranscription as independent of the model turn, so a
// generationComplete/turnComplete frame is not an ordering barrier for the final
// transcript. Keep a short, resettable quiet period after that boundary — but only for
// the shape it exists for, a boundary that arrives with no final in hand yet.
//
// Measured against the live service on 2026-11-21, 137 turns from half a second to
// 85 s: exactly one inputTranscription frame, then generationComplete in the very next
// frame 0–14 ms later (median 0), never the other way round and never a text frame
// after the boundary. Waiting out this grace on every one of those put a quarter of a
// second between releasing the key and the final text, for nothing. With the final
// already in hand the turn now completes at once; see `scheduleProviderBoundaryFinish`.
const DEFAULT_BOUNDARY_REORDER_GRACE_MS = 250;
// Measured 2026-11-21: Gemini aborts a Live session that has carried nothing for 60 s
// (close 1008 "The operation was aborted.", no warning frame). A warm session is idle
// by definition, so every one of them died there — over 90 % of all connections the
// relay ever closed — and each device spent its day in error → backoff → reconnect.
// A WebSocket ping does not count as traffic. `audioStreamEnd` does: sent every 20 s
// it kept an idle session alive for the 150 s tested, produced no frame, cost no audio,
// and the sentence spoken afterwards transcribed exactly as on a fresh session. A silent
// turn also keeps the session alive, but Gemini answers it and the next transcript
// carries the debris. Zero disables it.
const DEFAULT_IDLE_KEEPALIVE_MS = 25_000;
// Measured against the live service: a turn whose audio contains no speech gets no
// inputTranscription and no generationComplete — Gemini simply never answers it. The
// fallback above cannot help, because it is only ever armed by a serverContent frame.
// Without a bound here the turn hangs until the app's own ~20 s response timeout, which
// the user sees as the HUD stuck transcribing and the trigger key going dead.
const DEFAULT_SILENT_TURN_TIMEOUT_MS = 5_000;
// A short turn that is also locally quiet gets a tighter deadline and a gentler
// ending. Duration alone can never establish silence: "好的" and other real commands
// routinely fit below two seconds. The audio is 24 kHz mono 16-bit PCM, so one
// millisecond is 48 bytes.
//
// Measured over 187 answered turns: the reply lands 288 ms after the commit at the
// median and 487 ms at p90. Every reply slower than 2.7 s came from a turn carrying
// more than 8 s of audio; among turns under 2 s of audio the slowest was 1289 ms. The
// gap between those two populations is where this boundary sits, and the deadline is
// re-armed by every frame Gemini does send, so it bounds silence rather than work.
//
// The reason it also changes the ending: a short silent turn is overwhelmingly an
// accidental tap of the trigger key, which is not a failure and should not be reported
// as one. A long turn that goes unanswered is a real fault and still says so.
const AUDIO_BYTES_PER_MS = 48;
const SHORT_TURN_AUDIO_MS = 2_000;
const DEFAULT_SHORT_TURN_TIMEOUT_MS = 1_800;
const DEFAULT_SHORT_UNCERTAIN_TURN_TIMEOUT_MS = 3_000;
// About -30 dBFS. Set from the deployed relay's own `audio_rms` readings rather than
// from a dB figure that sounded conservative: an accidental tap in a real room measured
// 524, 658 and 866, while the shortest turns that carried a word measured 1247 and 2947.
// The first guess at this constant was 64 — eight times below the quietest silence
// anyone actually records — so nothing ever qualified as quiet and the accidental tap
// still ended in an error, three seconds in instead of five.
//
// The gap between those two populations is narrow, which is why this is not the only
// condition. A turn only completes empty if Gemini also returned no interim and no final
// text, and for real speech it always does. Losing a word therefore takes quiet audio
// *and* a provider that failed to answer real speech, not either one alone.
const QUIET_TURN_MAX_RMS = 1_000;

function accumulatePCM16Energy(turn, base64Audio) {
  const pcm = Buffer.from(base64Audio, "base64");
  for (let offset = 0; offset + 1 < pcm.length; offset += 2) {
    const sample = pcm.readInt16LE(offset);
    turn.audioSquareSum += sample * sample;
    turn.audioSampleCount += 1;
  }
}

function turnAudioRMS(turn) {
  if (!turn?.audioSampleCount) return 0;
  return Math.sqrt(turn.audioSquareSum / turn.audioSampleCount);
}

export function geminiSilentTurnDeadlineMs({
  audioMs,
  provenQuiet,
  quietShortMs = DEFAULT_SHORT_TURN_TIMEOUT_MS,
  uncertainShortMs = DEFAULT_SHORT_UNCERTAIN_TURN_TIMEOUT_MS,
  fullMs = DEFAULT_SILENT_TURN_TIMEOUT_MS,
}) {
  if (audioMs >= SHORT_TURN_AUDIO_MS) return fullMs;
  return Math.min(provenQuiet ? quietShortMs : uncertainShortMs, fullMs);
}

function relayError(message, code, eventID, sessionReplacementRequired = false) {
  const error = { message, type: "relay_error", code };
  if (eventID) error.event_id = eventID;
  if (sessionReplacementRequired) error.session_replacement_required = true;
  return JSON.stringify({ type: "error", error });
}

/// An out-of-money project is not refused at the handshake. Google accepts the socket
/// and then closes it about 100 ms after `setup` with a plain 1011, the explanation only
/// in the close reason: "Your prepayment credits are depleted. Please go to AI Studio…"
/// (seen 2026-11-21). Dropping that reason left every device on a bare 连接失败 with a
/// healthy /healthz and a valid token, which points at everything except the cause.
export function geminiCreditsDepleted(reason) {
  const text = Buffer.isBuffer(reason) ? reason.toString("utf8") : String(reason ?? "");
  return /credits?\b[^.]*\bdepleted|prepayment|billing/i.test(text);
}

export function geminiSetupFromSessionUpdate(event) {
  const transcription = event?.session?.audio?.input?.transcription;
  if (transcription?.model !== GEMINI_MODEL) return null;
  const inputAudioTranscription = {
    languageCodes: [],
    mode: "SMART",
  };
  if (transcription.keywords?.length) {
    inputAudioTranscription.customVocabulary = transcription.keywords;
  }
  return {
    setup: {
      model: `models/${GEMINI_MODEL}`,
      generationConfig: { responseModalities: ["TEXT"] },
      realtimeInputConfig: {
        automaticActivityDetection: { disabled: true },
      },
      inputAudioTranscription,
    },
  };
}

function geminiRealtimeInput(body) {
  return JSON.stringify({ realtimeInput: body });
}

export function bridgeGeminiRealtime(
  downstream,
  config,
  { consumeAudio = null, onEnd = null, onTurn = null } = {},
) {
  const url = new URL(config.geminiLiveURL);
  url.searchParams.set("key", config.geminiAPIKey);
  const upstream = new WebSocket(url, {
    handshakeTimeout: 10_000,
    maxPayload: config.maxWebSocketPayloadBytes,
    perMessageDeflate: false,
  });
  const validationState = { turnAudioBytes: 0 };
  const allowedModels = config.allowedGeminiTranscriptionModels
    || new Set([GEMINI_MODEL]);
  const preopenQueue = [];
  let preopenBytes = 0;
  let settled = false;
  let setupSent = false;
  let setupComplete = false;
  let turnSequence = 0;
  let turn = null;
  let finalTimer = null;
  let silentTurnTimer = null;
  let idleKeepalive = null;
  let downstreamAlive = true;
  let upstreamAlive = true;
  let downstreamTargetBackpressured = false;
  let upstreamTargetBackpressured = false;
  const markDownstreamAlive = () => { downstreamAlive = true; };
  const markUpstreamAlive = () => { upstreamAlive = true; };

  const publishEnd = (reason) => {
    try { onEnd?.(reason); } catch { /* diagnostics never own transport teardown */ }
  };
  /// One line per turn, so a sentence that comes back garbled can be traced to the
  /// audio that actually produced it — the failure this bridge is most likely to have
  /// is audio landing in the wrong turn, and byte counts are the only way to see it.
  /// Counts only: neither transcripts nor audio may reach the log.
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
      audioRMS: Math.round(turnAudioRMS(turn)),
      ageMs: Math.max(0, Date.now() - turn.openedAt),
      chars,
      // Commit → the moment this turn was answered: the wait the user feels after
      // releasing the key, as far as the relay can see it. Only for a turn that *was*
      // answered — one that timed out or was abandoned has no such moment, and its
      // five seconds of waiting would pass for a slow final in any average of these.
      finalMs: answered && turn.committedAt !== null
        ? Math.max(0, Date.now() - turn.committedAt)
        : null,
      // Set only if a final transcript arrived *after* the provider's boundary — the
      // one ordering the boundary grace exists for, and never yet observed. If this
      // ever shows up in the log, that is the evidence to act on.
      lateFinalMs: turn.lateFinalMs,
    });
  };
  const closeBoth = (code = 1011, reason = "relay closed") => {
    if (settled) return;
    settled = true;
    // A turn still open at teardown is the signature of the failure that matters most:
    // audio was accepted and billed, and no final ever came back for it.
    reportTurnEnd("abandoned");
    publishEnd(reason);
    clearTimeout(finalTimer);
    clearTimeout(silentTurnTimer);
    clearInterval(idleKeepalive);
    if (downstream.readyState === WebSocket.OPEN) downstream.close(code, reason);
    if (upstream.readyState === WebSocket.OPEN
        || upstream.readyState === WebSocket.CONNECTING) upstream.close(code, reason);
  };
  const terminateBoth = (reason) => {
    if (settled) return;
    settled = true;
    reportTurnEnd("abandoned");
    publishEnd(reason);
    clearTimeout(finalTimer);
    clearTimeout(silentTurnTimer);
    clearInterval(idleKeepalive);
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
  const sendUpstream = (text) => {
    if (upstream.readyState !== WebSocket.OPEN) return false;
    upstream.send(text);
    if (upstream.bufferedAmount > config.maxForwardBufferBytes) {
      pauseForUpstream();
    }
    return true;
  };
  const rejectAudioQuota = (audioBytes, eventID) => {
    if (audioBytes <= 0 || !consumeAudio) return false;
    const quota = consumeAudio(audioBytes);
    if (!quota) return false;
    downstream.send(relayError(
      quota === "total"
        ? "转发服务器今天的总额度已用完，请稍后再试（relay daily limit reached）"
        : "今天的转写额度已用完，请明天再试（daily transcription limit reached）",
      "relay_daily_quota",
      eventID,
      true,
    ));
    closeBoth(1008, "daily relay quota reached");
    return true;
  };
  const finishTurn = ({
    isolateProvider = false,
    outcome = "completed",
    closeReason = "gemini turn boundary uncertain",
    fallbackToInterim = false,
  } = {}) => {
    clearTimeout(finalTimer);
    finalTimer = null;
    clearTimeout(silentTurnTimer);
    silentTurnTimer = null;
    if (!turn?.committed || turn.cancelled) return;
    const authoritativeTranscript = turn.finalParts.join("");
    const usedInterimFallback = fallbackToInterim
      && turn.latestInterimSnapshot !== null;
    const transcript = usedInterimFallback
      ? turn.latestInterimSnapshot
      : authoritativeTranscript;
    reportTurnEnd(
      usedInterimFallback ? "partial_fallback" : outcome,
      [...transcript].length,
      { answered: true },
    );
    const completed = turn;
    turn = null;
    sendDownstream({
      type: "conversation.item.input_audio_transcription.completed",
      item_id: completed.itemID,
      transcript,
      // The client may synchronously begin its queued next utterance from the
      // completion callback, before it observes our close frame. Tell it to replace
      // the socket first so that next utterance cannot race onto this retired session.
      session_replacement_required: isolateProvider,
    });
    if (isolateProvider) {
      // Every answered turn retires its provider session, for two reasons that both
      // come down to one session being one document. Gemini gives transcription frames
      // no provider turn id, so a frame that arrives late could only be adopted by the
      // next turn. And in SMART mode the final is not this turn's text at all but the
      // whole session's so far — see `scheduleProviderBoundaryFinish`. Close both sides
      // after delivering the text so the app reconnects to a fresh provider session
      // before it can start another turn.
      closeBoth(1012, closeReason);
    }
  };

  const turnHasSpeechEvidence = () => turn?.latestInterimSnapshot !== null
    || turn?.finalParts.some((part) => part.length > 0)
    || turnAudioRMS(turn) >= QUIET_TURN_MAX_RMS;
  const turnIsProvenQuietAndShort = () =>
    (turn?.audioBytes ?? 0) / AUDIO_BYTES_PER_MS < SHORT_TURN_AUDIO_MS
    && !turnHasSpeechEvidence();

  /// How long this turn may stay silent before it is given up on. Duration changes only
  /// the wait, never the outcome: a short uncertain turn fails after three seconds,
  /// while only a short locally quiet turn may complete empty after 1.8 seconds.
  const silentTurnTimeoutMs = () => {
    const full = config.geminiSilentTurnTimeoutMs ?? DEFAULT_SILENT_TURN_TIMEOUT_MS;
    return geminiSilentTurnDeadlineMs({
      audioMs: (turn?.audioBytes ?? 0) / AUDIO_BYTES_PER_MS,
      provenQuiet: turnIsProvenQuietAndShort(),
      quietShortMs: config.geminiShortTurnTimeoutMs
        ?? DEFAULT_SHORT_TURN_TIMEOUT_MS,
      uncertainShortMs: config.geminiShortUncertainTurnTimeoutMs
        ?? DEFAULT_SHORT_UNCERTAIN_TURN_TIMEOUT_MS,
      fullMs: full,
    });
  };
  /// Bounds a committed turn the provider never answers — re-armed by every frame it
  /// does send, so it measures silence rather than elapsed time. As an absolute
  /// deadline it cut off turns that were still being answered: a long sentence whose
  /// first `inputTranscription` frame lands after the timeout was finished as an empty
  /// transcript, `turn` was cleared, and the real final arrived to find nothing to
  /// attach to — the app then deleted the text it had already typed and the sentence
  /// was lost outright.
  const armSilentTurnTimeout = () => {
    clearTimeout(silentTurnTimer);
    silentTurnTimer = setTimeout(() => {
      if (!turn?.committed || turn.cancelled) return;
      if (turn?.latestInterimSnapshot !== null) {
        // Gemini heard speech and exposed it to the user, but never finalized it. Keep
        // that last complete snapshot rather than authoritatively replacing visible
        // words with an empty completion. The provider session is still retired because
        // a late final cannot be assigned safely to another turn.
        finishTurn({
          isolateProvider: true,
          fallbackToInterim: true,
          closeReason: "gemini turn finalized from interim fallback",
        });
        return;
      }
      if (turnIsProvenQuietAndShort()) {
        // Short, locally quiet audio with no transcription evidence is an accidental
        // trigger. `finishTurn` delivers the empty transcript and sets
        // `session_replacement_required` on it, which retires this provider session
        // exactly as the error did — the app is told to reconnect, not that it failed.
        // Reporting this as an error made every accidental tap of the trigger key cost
        // five seconds of spinner and a message about a service that did nothing wrong.
        finishTurn({
          isolateProvider: true,
          outcome: "silent",
          closeReason: "gemini turn had no speech",
        });
        return;
      }
      // Anything not proven to be a short quiet tap may contain speech, and an empty
      // completion would make the app erase or orphan what it already displayed. Fail
      // it explicitly and close the transport; the next utterance must use a fresh
      // Gemini session.
      sendDownstream({
        type: "error",
        error: {
          message: "Gemini 没有及时返回转写结果（Gemini transcription timed out）",
          type: "relay_error",
          code: "relay_gemini_turn_timeout",
          event_id: turn.lastEventID,
          session_replacement_required: true,
        },
      });
      closeBoth(1012, "gemini turn timed out");
    }, silentTurnTimeoutMs());
    silentTurnTimer.unref?.();
  };
  const scheduleTurnFinish = ({
    isolateProvider,
    delayMs,
    fallbackToInterim = false,
    closeReason,
  }) => {
    clearTimeout(finalTimer);
    finalTimer = setTimeout(
      () => finishTurn({ isolateProvider, fallbackToInterim, closeReason }),
      delayMs,
    );
  };
  const scheduleFallbackFinish = () => scheduleTurnFinish({
    isolateProvider: true,
    delayMs: config.geminiFinalFallbackDelayMs ?? DEFAULT_FINAL_FALLBACK_DELAY_MS,
    fallbackToInterim: true,
  });
  const scheduleProviderBoundaryFinish = () => {
    if (!turn) return;
    turn.responseBoundarySeen = true;
    // A final that was already in hand when the boundary arrived, with no newer
    // interim behind it, is the whole answer: the grace has nothing left to wait for.
    // Once a final has turned up *after* the boundary the order is the unusual one,
    // more may be in flight behind it, and every frame restarts the full grace.
    const finalInHand = turn.lateFinalMs === null
      && turn.finalParts.length > 0
      && turn.latestInterimSnapshot === null;
    scheduleTurnFinish({
      // Measured 2026-11-21, and documented by Google for SMART mode: the final is the
      // cumulative transcript of the *session*, not of the turn. A second sentence on
      // the same session came back as the first sentence plus the second (3, 13, 33,
      // 63 … characters for turns of 3, 10, 20, 30), and the app typed it as given —
      // the previous sentence, again, in front of the new one. Interims are per-turn,
      // so nothing looked wrong until the key was released. There is no setting that
      // turns this off and no message that resets it; a new session is the only fresh
      // document. So an answered turn always takes its session with it.
      isolateProvider: true,
      delayMs: finalInHand
        ? 0
        : config.geminiBoundaryReorderGraceMs ?? DEFAULT_BOUNDARY_REORDER_GRACE_MS,
      fallbackToInterim: true,
      closeReason: "gemini turn completed",
    });
  };
  const scheduleLocalEmptyFinish = () => scheduleTurnFinish({
    isolateProvider: false,
    delayMs: 0,
  });
  const startTurn = (eventID) => {
    turnSequence += 1;
    turn = {
      itemID: `gemini-turn-${turnSequence}`,
      active: true,
      committed: false,
      cancelled: false,
      finalParts: [],
      latestInterimSnapshot: null,
      lastEventID: eventID,
      audioBytes: 0,
      audioSquareSum: 0,
      audioSampleCount: 0,
      openedAt: Date.now(),
      reported: false,
      responseBoundarySeen: false,
      committedAt: null,
      boundaryAt: null,
      lateFinalMs: null,
      // Deferred until the first audio frame. Measured: activityStart followed by
      // activityEnd with nothing between them makes Gemini close the entire session
      // with 1007 "Precondition check failed" — so a press that captured no audio
      // used to cost the next sentence its warm socket.
      activityStarted: false,
    };
    publishTurn({ event: "open", item: turn.itemID });
  };

  const handleClientEvent = (event, audioBytes = 0) => {
    const type = event.type;
    if (type === "session.update") {
      const setup = geminiSetupFromSessionUpdate(event);
      if (!setup || setupSent) {
        downstream.send(relayError(
          "转发服务器不接受当前 Gemini 会话配置（Gemini session configuration is not allowed）",
          "relay_invalid_event",
          event.event_id,
          true,
        ));
        closeBoth(1008, "invalid gemini session");
        return;
      }
      setupSent = true;
      sendUpstream(JSON.stringify(setup));
      return;
    }
    if (!setupComplete) {
      downstream.send(relayError(
        "Gemini 会话还没有准备好（Gemini session is not ready）",
        "relay_upstream_not_ready",
        event.event_id,
        true,
      ));
      closeBoth(1013, "gemini session not ready");
      return;
    }
    if (type === "input_audio_buffer.clear") {
      if (turn) {
        // A clear while a turn exists is cancellation. Google finals carry no turn id,
        // so only a fresh provider session can prevent its late result being adopted
        // by the next utterance.
        turn.cancelled = true;
        if (!turn.activityStarted) {
          // The provider was never told this turn began, so it has nothing in flight
          // that could surface as the next utterance's result. Dropping it locally
          // keeps the warm socket that a reconnect would otherwise cost.
          reportTurnEnd("cancelled");
          turn = null;
          return;
        }
        if (turn.active) sendUpstream(geminiRealtimeInput({ activityEnd: {} }));
        reportTurnEnd("cancelled");
        closeBoth(1012, "gemini turn cancelled");
        return;
      }
      startTurn(event.event_id);
      return;
    }
    if (type === "input_audio_buffer.append") {
      // `clear` is the app protocol's explicit turn boundary, but audio can already be
      // queued while the socket is reconnecting and older clients did not replay that
      // boundary when flushing the queue. Treat the first append as an implicit start
      // so a harmless client lifecycle detail cannot discard the whole utterance.
      if (!turn) startTurn(event.event_id);
      if (!turn?.active) {
        downstream.send(relayError(
          "Gemini 没有正在录音的句子（Gemini turn is not active）",
          "relay_invalid_event",
          event.event_id,
          true,
        ));
        closeBoth(1008, "gemini audio outside turn");
        return;
      }
      if (rejectAudioQuota(audioBytes, event.event_id)) return;
      if (!turn.activityStarted) {
        turn.activityStarted = true;
        sendUpstream(geminiRealtimeInput({ activityStart: {} }));
      }
      turn.audioBytes += audioBytes;
      accumulatePCM16Energy(turn, event.audio);
      turn.lastEventID = event.event_id;
      sendUpstream(geminiRealtimeInput({
        audio: { data: event.audio, mimeType: "audio/pcm;rate=24000" },
      }));
      return;
    }
    if (type === "input_audio_buffer.commit") {
      if (!turn?.active) {
        downstream.send(relayError(
          "Gemini 没有可以提交的句子（Gemini turn is not active）",
          "relay_invalid_event",
          event.event_id,
          true,
        ));
        closeBoth(1008, "gemini commit outside turn");
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
      if (!turn.activityStarted) {
        // Nothing was ever spoken into this turn, and the provider never heard of it.
        // Answer it here rather than sending the empty activity pair that would kill
        // the session; an empty transcript puts the app straight back to idle.
        scheduleLocalEmptyFinish();
        return;
      }
      sendUpstream(geminiRealtimeInput({ activityEnd: {} }));
      armSilentTurnTimeout();
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
      downstream.send(relayError(
        validationError,
        "relay_invalid_event",
        clientEventID(data, isBinary),
        true,
      ));
      closeBoth(1008, "invalid relay event");
      return;
    }
    const event = JSON.parse(data.toString("utf8"));
    const audioBytes = validationState.acceptedAudioBytes || 0;
    // `session.update` is what *causes* setup, so it goes out as soon as the socket is
    // up. Everything else has to wait for `setupComplete`: handling it earlier reaches
    // the not-ready gate below, which answers by closing the connection — the queue
    // would then kill the very sentence it exists to protect.
    if (upstream.readyState === WebSocket.OPEN
        && (setupComplete || event.type === "session.update")) {
      handleClientEvent(event, audioBytes);
      return;
    }
    if ((upstream.readyState !== WebSocket.CONNECTING
         && upstream.readyState !== WebSocket.OPEN)
        || preopenBytes + data.length > config.maxPreopenQueueBytes) {
      closeBoth(1013, "gemini upstream not ready");
      return;
    }
    // The validated byte count travels with the event. By the time the queue is
    // replayed, validationState describes whichever message was validated last, so
    // reading it there charged the wrong turn for the wrong audio.
    preopenQueue.push({ event, audioBytes, bytes: data.length });
    preopenBytes += data.length;
  });

  /// Replays what the queue is allowed to send now, and keeps the rest queued.
  const replayQueuedEvents = (onlySessionSetup) => {
    const deferred = [];
    for (const queued of preopenQueue) {
      if (settled) return;
      if (onlySessionSetup && queued.event.type !== "session.update") {
        deferred.push(queued);
        continue;
      }
      handleClientEvent(queued.event, queued.audioBytes);
    }
    preopenQueue.length = 0;
    preopenBytes = 0;
    for (const queued of deferred) {
      preopenQueue.push(queued);
      preopenBytes += queued.bytes;
    }
  };

  upstream.on("open", () => replayQueuedEvents(true));

  upstream.on("message", (data) => {
    if (settled) return;
    let message;
    try { message = JSON.parse(data.toString("utf8")); } catch { return; }
    if (message.error) {
      const detail = message.error;
      downstream.send(relayError(
        detail.message || "Gemini 转写失败",
        "relay_gemini_error",
        turn?.lastEventID,
        true,
      ));
      closeBoth(1011, "gemini error");
      return;
    }
    if (message.setupComplete !== undefined) {
      setupComplete = true;
      const now = Date.now() / 1000;
      sendDownstream({
        type: "session.created",
        session: { expires_at: now + GEMINI_SESSION_SECONDS },
      });
      sendDownstream({ type: "session.updated" });
      replayQueuedEvents(false);
      const keepaliveMs = config.geminiIdleKeepaliveMs ?? DEFAULT_IDLE_KEEPALIVE_MS;
      if (keepaliveMs > 0 && idleKeepalive === null && !settled) {
        idleKeepalive = setInterval(() => {
          // Only between sentences. A turn in progress is its own traffic, and nothing
          // may be slipped into the stream of one that is waiting for its final.
          if (settled || turn) return;
          sendUpstream(geminiRealtimeInput({ audioStreamEnd: true }));
        }, keepaliveMs);
        idleKeepalive.unref?.();
      }
      return;
    }
    const content = message.serverContent;
    if (!content || !turn || turn.cancelled) return;
    const responseComplete = content.turnComplete === true
      || content.generationComplete === true;
    // Taken before this frame is applied: a final that shares its frame with the
    // boundary is not late.
    const boundaryPrecededThisFrame = turn.responseBoundarySeen;
    if (responseComplete && turn.boundaryAt === null) turn.boundaryAt = Date.now();
    // A response boundary stops the no-response watchdog immediately. Other frames
    // re-arm it only after their transcription evidence has been recorded below, so a
    // short spoken turn gets the ordinary deadline rather than the quiet-tap deadline.
    if (turn.committed) {
      if (responseComplete) {
        // The provider answered and declared its response boundary. From here the
        // ordering grace, not the no-response watchdog, owns the bounded wait for a
        // separately delivered inputTranscription frame.
        clearTimeout(silentTurnTimer);
        silentTurnTimer = null;
        turn.responseBoundarySeen = true;
      }
    }
    const interim = content.interimInputTranscription?.text;
    if (typeof interim === "string" && interim.length) {
      // Gemini finalizes long turns in segments. Its next interim is only the mutable
      // suffix after those finalized segments, while the app callback is explicitly a
      // complete utterance snapshot. Preserve the immutable prefix on the wire.
      const snapshot = turn.finalParts.join("") + interim;
      turn.latestInterimSnapshot = snapshot;
      sendDownstream({
        type: "whisper.input_audio_transcription.partial",
        item_id: turn.itemID,
        transcript: snapshot,
      });
      if (turn.responseBoundarySeen) scheduleProviderBoundaryFinish();
      else if (finalTimer !== null) {
        // A finalized segment already armed the no-boundary quiet timer. An interim for
        // the next segment is proof that Gemini is still answering this same turn, so
        // restart that quiet period rather than completing the prefix underneath it.
        scheduleFallbackFinish();
      }
    }
    // Measured against the live service on 36 s of speech: gemini-3.5-transcribe-live
    // never sends turnComplete for a transcription turn — it closes the response with
    // generationComplete alone. Waiting for turnComplete meant every single sentence
    // fell through to the fallback timer, so the app sat on a final it already had for
    // the full DEFAULT_FINAL_FALLBACK_DELAY_MS. That is the whole latency budget this
    // one-step provider was adopted to reclaim.
    const finalText = content.inputTranscription?.text;
    if (typeof finalText === "string") {
      if (boundaryPrecededThisFrame && turn.boundaryAt !== null) {
        turn.lateFinalMs = Math.max(0, Date.now() - turn.boundaryAt);
      }
      // Google documents a SMART final as the complete text so far, to *replace* what
      // came before; the segments this bridge was first measured against were deltas,
      // to append. A frame that begins with everything already collected is the
      // former. Appending it would say the start of a long sentence twice.
      const collected = turn.finalParts.join("");
      if (collected.length > 0 && finalText.startsWith(collected)) {
        turn.finalParts = [finalText];
      } else {
        turn.finalParts.push(finalText);
      }
      // A final segment supersedes the mutable interim suffix. A later interim will
      // rebuild the whole snapshot from this now-authoritative prefix.
      turn.latestInterimSnapshot = null;
      if (turn.responseBoundarySeen) scheduleProviderBoundaryFinish();
      else scheduleFallbackFinish();
    } else if (responseComplete) {
      scheduleProviderBoundaryFinish();
    }
    if (turn?.committed && !responseComplete) armSilentTurnTimeout();
  });

  upstream.on("unexpected-response", (_request, response) => {
    const auth = response.statusCode === 401 || response.statusCode === 403;
    if (downstream.readyState === WebSocket.OPEN) {
      downstream.send(relayError(
        auth
          ? "转发服务器 authentication 失败：Gemini API Key 无效或没有权限"
          : `转发服务器连接 Gemini 失败（HTTP ${response.statusCode}）`,
        "relay_upstream_handshake",
        undefined,
        true,
      ));
    }
    setImmediate(() => closeBoth(1011, "gemini handshake failed"));
  });
  upstream.on("error", () => {
    if (downstream.readyState === WebSocket.OPEN) {
      downstream.send(relayError(
        "转发服务器连接 Gemini 失败",
        "relay_upstream_unreachable",
        turn?.lastEventID,
        true,
      ));
    }
    setImmediate(() => closeBoth(1011, "gemini connection failed"));
  });
  upstream.on("close", (code, reason) => {
    if (geminiCreditsDepleted(reason)) {
      if (downstream.readyState === WebSocket.OPEN) {
        downstream.send(relayError(
          // "Billing" is load-bearing: it is the word RealtimeClient keys on to treat
          // an error as connection-wide and stop retrying, the same way the handshake
          // message above carries "authentication".
          "Gemini 额度用完了，去 AI Studio 的 Billing 充值后再按一次就恢复",
          "relay_gemini_credits_depleted",
          undefined,
          true,
        ));
      }
      setImmediate(() => closeBoth(1011, "gemini credits depleted"));
      return;
    }
    closeBoth(safeCloseCode(code), "gemini upstream closed");
  });
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
        terminateBoth("gemini upstream went away");
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
