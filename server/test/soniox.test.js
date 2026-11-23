import { spawn } from "node:child_process";
import http from "node:http";
import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";
import WebSocket, { WebSocketServer } from "ws";

import { tokenDigest } from "../src/auth.js";
import { loadConfig, SONIOX_DEFAULTS } from "../src/config.js";
import { validateRealtimeEvent } from "../src/realtime.js";
import {
  bridgeSonioxRealtime,
  sonioxErrorMessage,
  sonioxStartFromSessionUpdate,
} from "../src/soniox-realtime.js";

const baseEnv = {
  OPENAI_API_KEY: "server-only-openai-key",
  GEMINI_API_KEY: "server-only-gemini-key",
  SONIOX_API_KEY: "server-only-soniox-key",
  RELAY_DEVICE_TOKEN_HASHES: tokenDigest("relay_soniox-device-token"),
};
const baseConfig = loadConfig(baseEnv);

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.off("error", reject);
      resolve(server.address().port);
    });
  });
}

function close(server) {
  return new Promise((resolve) => server.close(resolve));
}

async function waitUntil(predicate, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  return false;
}

function sessionUpdate(eventID, keywords) {
  const transcription = { model: "stt-rt-v6" };
  if (keywords) transcription.keywords = keywords;
  return {
    type: "session.update",
    event_id: eventID,
    session: {
      type: "transcription",
      audio: {
        input: {
          format: { type: "audio/pcm", rate: 24_000 },
          transcription,
          turn_detection: null,
        },
      },
    },
  };
}

/// A stand-in for Soniox that records exactly what the relay put on the wire — text
/// frames parsed, binary frames kept as buffers, the end-of-stream frame as "" — and
/// lets each test script the replies. It answers `ping` like the documented service.
async function startRig(configOverrides = {}, { onUpstreamFrame } = {}) {
  const upstreamFrames = [];
  const upstream = { socket: null, authorization: null, frames: upstreamFrames };
  const upstreamServer = http.createServer();
  const upstreamWSS = new WebSocketServer({ server: upstreamServer });
  upstreamWSS.on("connection", (socket, request) => {
    upstream.socket = socket;
    upstream.authorization = request.headers.authorization;
    socket.on("message", (data, isBinary) => {
      const frame = isBinary
        ? { audio: Buffer.from(data) }
        : data.length === 0 ? { endOfStream: true } : JSON.parse(data.toString("utf8"));
      upstreamFrames.push(frame);
      if (frame.type === "ping") {
        socket.send(JSON.stringify({ type: "pong", id: frame.id }));
      }
      onUpstreamFrame?.(frame, socket);
    });
  });
  const upstreamPort = await listen(upstreamServer);

  const ends = [];
  const turns = [];
  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({ server: relayServer });
  relayWSS.on("connection", (downstream) => {
    bridgeSonioxRealtime(downstream, {
      ...baseConfig,
      sonioxRealtimeURL: `ws://127.0.0.1:${upstreamPort}/transcribe-websocket`,
      ...configOverrides,
    }, {
      onEnd: (reason) => ends.push(reason),
      onTurn: (record) => turns.push(record),
    });
  });
  const relayPort = await listen(relayServer);

  const client = new WebSocket(`ws://127.0.0.1:${relayPort}`);
  const events = [];
  const closes = [];
  client.on("message", (data) => events.push(JSON.parse(data.toString("utf8"))));
  client.on("close", (code) => closes.push(code));
  await new Promise((resolve, reject) => {
    client.once("open", resolve);
    client.once("error", reject);
  });

  return {
    client,
    events,
    closes,
    ends,
    turns,
    upstream,
    send: (object) => client.send(JSON.stringify(object)),
    reply: (object) => upstream.socket.send(JSON.stringify(object)),
    async ready(keywords) {
      client.send(JSON.stringify(sessionUpdate("whisper-session-1", keywords)));
      assert.ok(
        await waitUntil(() => events.some((event) => event.type === "session.updated")),
        "the relay never reported the session ready",
      );
    },
    async stop() {
      client.terminate();
      for (const socket of upstreamWSS.clients) socket.terminate();
      for (const socket of relayWSS.clients) socket.terminate();
      await close(relayServer);
      await close(upstreamServer);
    },
  };
}

const audio = (bytes) => Buffer.from(bytes).toString("base64");

test("Soniox is optional, restricted to its own models, and defaults to Mandarin plus English", () => {
  const config = loadConfig(baseEnv);
  assert.equal(config.sonioxAPIKey, "server-only-soniox-key");
  assert.deepEqual([...config.allowedSonioxTranscriptionModels], ["stt-rt-v6"]);
  assert.deepEqual(config.sonioxLanguageHints, ["zh", "en"]);
  assert.equal(config.sonioxLanguageHintsStrict, true);

  // A relay deployed before this route existed has no key, and must still start.
  const { SONIOX_API_KEY: _omitted, ...withoutKey } = baseEnv;
  assert.equal(loadConfig(withoutKey).sonioxAPIKey, "");

  const overridden = loadConfig({
    ...baseEnv,
    SONIOX_LANGUAGE_HINTS: " ZH , en , ja ",
    SONIOX_LANGUAGE_HINTS_STRICT: "0",
  });
  assert.deepEqual(overridden.sonioxLanguageHints, ["zh", "en", "ja"]);
  assert.equal(overridden.sonioxLanguageHintsStrict, false);
  assert.throws(
    () => loadConfig({ ...baseEnv, SONIOX_LANGUAGE_HINTS: "zh,english please" }),
    /SONIOX_LANGUAGE_HINTS/,
  );
  assert.throws(
    () => loadConfig({ ...baseEnv, SONIOX_REALTIME_URL: "https://example.com" }),
    /SONIOX_REALTIME_URL/,
  );

  // Soniox closes an unstarted connection after 40 s of silence. Zero used to mean
  // "off" and anything at all was accepted above it; both ends had every idle device
  // reconnecting in a loop, so the interval is now held inside a range that cannot.
  const keepalive = (value) => loadConfig({
    ...baseEnv,
    ...(value === undefined ? {} : { SONIOX_PRESTART_KEEPALIVE_MS: value }),
  }).sonioxPrestartKeepaliveMs;
  assert.equal(keepalive(undefined), SONIOX_DEFAULTS.prestartKeepaliveMs);
  assert.equal(SONIOX_DEFAULTS.prestartKeepaliveMs, 15_000);
  assert.equal(keepalive("5000"), 5_000);
  assert.equal(keepalive("0"), 1_000);
  assert.equal(keepalive("-1"), 1_000);
  assert.equal(keepalive("40000"), 30_000);
  assert.throws(() => keepalive("soon"), /SONIOX_PRESTART_KEEPALIVE_MS/);
  assert.throws(() => keepalive("1.5"), /SONIOX_PRESTART_KEEPALIVE_MS/);

  const validateFor = (model, allowedModels) => validateRealtimeEvent(
    Buffer.from(JSON.stringify({ ...sessionUpdate(undefined), event_id: undefined })
      .replace("stt-rt-v6", model)),
    false,
    config,
    { turnAudioBytes: 0 },
    allowedModels,
  );
  assert.equal(validateFor("stt-rt-v6", config.allowedSonioxTranscriptionModels), null);
  assert.match(
    validateFor("gpt-live-transcribe", config.allowedSonioxTranscriptionModels),
    /session configuration is not allowed/,
  );
  assert.match(
    validateFor("stt-rt-v6", config.allowedOpenAITranscriptionModels),
    /session configuration is not allowed/,
  );
  assert.match(
    validateFor("stt-rt-v6", config.allowedGeminiTranscriptionModels),
    /session configuration is not allowed/,
  );
});

test("the Soniox start message pins the audio format, both languages and the vocabulary", () => {
  const start = sonioxStartFromSessionUpdate(
    sessionUpdate("whisper-session-1", ["李铭一", "Xcode"]),
    baseConfig,
  );
  assert.equal(start.model, "stt-rt-v6");
  assert.equal(start.audio_format, "pcm_s16le");
  assert.equal(start.sample_rate, 24_000);
  assert.equal(start.num_channels, 1);
  assert.deepEqual(start.language_hints, ["zh", "en"]);
  assert.equal(start.language_hints_strict, true);
  assert.equal(start.enable_endpoint_detection, false);
  assert.deepEqual(start.context.terms, ["李铭一", "Xcode"]);
  assert.ok(start.context.general.length >= 1);
  // The key belongs to the handshake; Soniox is retiring keys in the start message.
  assert.equal(start.api_key, undefined);

  const bare = sonioxStartFromSessionUpdate(sessionUpdate("whisper-session-1"), baseConfig);
  assert.equal(bare.context.terms, undefined);

  const wrongModel = sessionUpdate("whisper-session-1");
  wrongModel.session.audio.input.transcription.model = "gpt-live-transcribe";
  assert.equal(sonioxStartFromSessionUpdate(wrongModel, baseConfig), null);
});

test("Soniox errors keep the words the app uses to stop retrying, and drop free text", () => {
  assert.match(sonioxErrorMessage({ error_code: 401 }), /authentication/);
  assert.match(sonioxErrorMessage({ error_code: 403 }), /authentication/);
  assert.match(sonioxErrorMessage({ error_code: 402 }), /Billing/);
  assert.equal(
    sonioxErrorMessage({
      error_code: 503,
      error_type: "service_unavailable",
      error_message: "anything the provider likes, including an api key lookalike",
    }),
    "Soniox 转写失败（service_unavailable）",
  );
  assert.equal(
    sonioxErrorMessage({ error_code: 500, error_type: "Not A Type\n" }),
    "Soniox 转写失败（HTTP 500）",
  );
});

test("an idle Soniox connection starts no billed stream and is kept open with pings", async () => {
  const rig = await startRig({ sonioxPrestartKeepaliveMs: 40 });
  try {
    await rig.ready();
    assert.equal(rig.upstream.authorization, "Bearer server-only-soniox-key");
    const created = rig.events.find((event) => event.type === "session.created");
    assert.ok(created.session.expires_at - Date.now() / 1000 > 590);
    assert.ok(created.session.expires_at - Date.now() / 1000 <= 600);

    assert.ok(
      await waitUntil(() => rig.upstream.frames.filter((f) => f.type === "ping").length >= 3),
      "an idle connection must send Soniox something every 40 s or be closed",
    );
    // Everything sent so far is a ping: a stream is billed for its whole duration, so
    // a start message on a socket that is merely warm would bill the idle hours.
    assert.deepEqual(
      [...new Set(rig.upstream.frames.map((frame) => frame.type))],
      ["ping"],
    );
    assert.deepEqual(rig.closes, []);
    // A pong is not a transcript and must not surface as one.
    assert.deepEqual(
      rig.events.map((event) => event.type),
      ["session.created", "session.updated"],
    );
  } finally {
    await rig.stop();
  }
});

test("Soniox bridge streams snapshots, finalizes on commit and retires the connection", async () => {
  const rig = await startRig({ sonioxPrestartKeepaliveMs: 0 });
  try {
    await rig.ready(["Xcode"]);
    rig.send({ type: "input_audio_buffer.clear", event_id: "whisper-turn-1-2" });
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.deepEqual(rig.upstream.frames, [], "a turn boundary alone starts no stream");

    rig.send({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-1-3",
      audio: audio([1, 2, 3, 4]),
    });
    rig.send({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-1-4",
      audio: audio([5, 6]),
    });
    assert.ok(await waitUntil(() => rig.upstream.frames.length >= 3));
    assert.equal(rig.upstream.frames[0].model, "stt-rt-v6");
    assert.deepEqual(rig.upstream.frames[0].language_hints, ["zh", "en"]);
    assert.deepEqual(rig.upstream.frames[0].context.terms, ["Xcode"]);
    assert.deepEqual(rig.upstream.frames[1].audio, Buffer.from([1, 2, 3, 4]));
    assert.deepEqual(rig.upstream.frames[2].audio, Buffer.from([5, 6]));

    // Non-final tokens are a hypothesis: the second frame replaces the first one's tail.
    rig.reply({ tokens: [
      { text: "我用", is_final: false },
      { text: " ex", is_final: false },
    ] });
    rig.reply({ tokens: [
      { text: "我用", is_final: true },
      { text: " X", is_final: false },
      { text: "code", is_final: false },
    ] });
    assert.ok(await waitUntil(
      () => rig.events.filter((e) => e.type.endsWith(".partial")).length === 2,
    ));
    assert.deepEqual(
      rig.events.filter((e) => e.type.endsWith(".partial")).map((e) => e.transcript),
      ["我用 ex", "我用 Xcode"],
    );
    assert.ok(rig.events
      .filter((e) => e.type.endsWith(".partial"))
      .every((e) => e.item_id === "soniox-turn-1"));

    rig.send({ type: "input_audio_buffer.commit", event_id: "whisper-turn-1-5" });
    assert.ok(await waitUntil(() => rig.upstream.frames.length >= 5));
    assert.deepEqual(rig.upstream.frames.slice(3), [
      { type: "finalize" },
      { endOfStream: true },
    ]);
    assert.ok(rig.events.some(
      (e) => e.type === "input_audio_buffer.committed" && e.item_id === "soniox-turn-1",
    ));

    rig.reply({ tokens: [
      { text: " Xcode", is_final: true },
      { text: " 打开", is_final: true },
      { text: "<fin>", is_final: true },
    ] });
    assert.ok(await waitUntil(() => rig.closes.length === 1));
    const completed = rig.events.find(
      (e) => e.type === "conversation.item.input_audio_transcription.completed",
    );
    assert.deepEqual(completed, {
      type: "conversation.item.input_audio_transcription.completed",
      item_id: "soniox-turn-1",
      transcript: "我用 Xcode 打开",
      session_replacement_required: true,
    });
    // The closing frame brought new text, and `completed` is the only thing that
    // carried it: the two interims from before the commit are still the only ones.
    assert.deepEqual(
      rig.events.filter((e) => e.type.endsWith(".partial")).map((e) => e.transcript),
      ["我用 ex", "我用 Xcode"],
    );
    // One sentence, one stream: the app is told to reconnect, and is not told it failed.
    assert.deepEqual(rig.closes, [1012]);
    assert.deepEqual(rig.ends, ["soniox turn completed"]);
    assert.ok(!rig.events.some((e) => e.type === "error"));
    assert.equal(
      rig.upstream.frames.filter((frame) => frame.endOfStream).length,
      1,
      "the stream is ended exactly once",
    );
    const end = rig.turns.find((record) => record.event === "end");
    assert.equal(end.outcome, "completed");
    assert.equal(end.audioBytes, 6);
    assert.equal(end.chars, [..."我用 Xcode 打开"].length);
    assert.ok(Number.isInteger(end.finalMs));
  } finally {
    await rig.stop();
  }
});

test("a stream that ends without answering the finalize still delivers the sentence", async () => {
  const rig = await startRig({ sonioxPrestartKeepaliveMs: 0 });
  try {
    await rig.ready();
    rig.send({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-1-2",
      audio: audio([1, 2]),
    });
    rig.send({ type: "input_audio_buffer.commit", event_id: "whisper-turn-1-3" });
    assert.ok(await waitUntil(() => rig.upstream.frames.some((frame) => frame.endOfStream)));
    rig.reply({ tokens: [{ text: "好的", is_final: true }] });
    rig.reply({ tokens: [], finished: true });
    assert.ok(await waitUntil(() => rig.closes.length === 1));
    const completed = rig.events.find(
      (e) => e.type === "conversation.item.input_audio_transcription.completed",
    );
    assert.equal(completed.transcript, "好的");
    assert.equal(completed.session_replacement_required, true);
    assert.deepEqual(rig.closes, [1012]);
  } finally {
    await rig.stop();
  }
});

test("once a sentence is committed its text arrives in completed alone", async () => {
  // Measured in the app: the last partial and the final arrive 5 to 10 ms apart, the app
  // types the partial, and the final then asks the document about a keystroke that has
  // not landed yet. `completed` already carries the whole text, so after the commit the
  // relay sends nothing else — whichever way Soniox splits its frames.
  const order = (rig) => rig.events
    .filter((e) => e.type.endsWith(".partial") || e.type.endsWith(".completed"))
    .map((e) => `${e.type.endsWith(".partial") ? "partial" : "completed"}:${e.transcript}`);
  const speakThenCommit = async (rig) => {
    await rig.ready();
    rig.send({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-1-2",
      audio: audio([1, 2]),
    });
    assert.ok(await waitUntil(() => rig.upstream.frames.length === 2));
    // Before the commit an interim is still an interim, and still sent as one.
    rig.reply({ tokens: [{ text: "明天", is_final: false }] });
    assert.ok(await waitUntil(() => rig.events.some((e) => e.type.endsWith(".partial"))));
    rig.send({ type: "input_audio_buffer.commit", event_id: "whisper-turn-1-3" });
    assert.ok(await waitUntil(() => rig.upstream.frames.some((frame) => frame.endOfStream)));
    assert.ok(await waitUntil(
      () => rig.events.some((e) => e.type === "input_audio_buffer.committed"),
    ));
  };

  // The last words and `<fin>` in one frame, with a revisable frame before it.
  const oneFrame = await startRig({ sonioxPrestartKeepaliveMs: 0 });
  try {
    await speakThenCommit(oneFrame);
    oneFrame.reply({ tokens: [
      { text: "明天", is_final: true },
      { text: "开", is_final: false },
    ] });
    oneFrame.reply({ tokens: [
      { text: "开会", is_final: true },
      { text: "。", is_final: true },
      { text: "<fin>", is_final: true },
    ] });
    assert.ok(await waitUntil(() => oneFrame.closes.length === 1));
    assert.deepEqual(order(oneFrame), ["partial:明天", "completed:明天开会。"]);
  } finally {
    await oneFrame.stop();
  }

  // The split case: the last words in a frame of their own, every token final, and
  // `<fin>` alone in a later one. Nothing is sent for the first of the two.
  const split = await startRig({ sonioxPrestartKeepaliveMs: 0 });
  try {
    await speakThenCommit(split);
    split.reply({ tokens: [
      { text: "明天", is_final: true },
      { text: "开会", is_final: true },
      { text: "。", is_final: true },
    ] });
    await new Promise((resolve) => setTimeout(resolve, 40));
    assert.deepEqual(order(split), ["partial:明天"], "the last words were sent early");
    split.reply({ tokens: [{ text: "<fin>", is_final: true }] });
    assert.ok(await waitUntil(() => split.closes.length === 1));
    assert.deepEqual(order(split), ["partial:明天", "completed:明天开会。"]);
    assert.deepEqual(split.closes, [1012]);
  } finally {
    await split.stop();
  }

  // The other way a sentence ends: the stream's own `finished`, here with a tail that
  // was never marked final. It is delivered once, by `completed`.
  const finished = await startRig({ sonioxPrestartKeepaliveMs: 0 });
  try {
    await finished.ready();
    finished.send({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-1-2",
      audio: audio([1, 2]),
    });
    finished.send({ type: "input_audio_buffer.commit", event_id: "whisper-turn-1-3" });
    assert.ok(await waitUntil(
      () => finished.upstream.frames.some((frame) => frame.endOfStream),
    ));
    finished.reply({
      tokens: [
        { text: "好的", is_final: true },
        { text: "谢谢", is_final: false },
      ],
      finished: true,
    });
    assert.ok(await waitUntil(() => finished.closes.length === 1));
    assert.deepEqual(order(finished), ["completed:好的谢谢"]);
  } finally {
    await finished.stop();
  }

  // Words that only arrive after the commit are withheld, not lost: if the finalize is
  // never answered, the timeout delivers them.
  const unanswered = await startRig({ sonioxPrestartKeepaliveMs: 0, sonioxFinalTimeoutMs: 150 });
  try {
    await speakThenCommit(unanswered);
    unanswered.reply({ tokens: [
      { text: "明天", is_final: true },
      { text: "开会", is_final: false },
    ] });
    assert.ok(await waitUntil(() => unanswered.closes.length === 1));
    assert.deepEqual(order(unanswered), ["partial:明天", "completed:明天开会"]);
    assert.deepEqual(
      unanswered.turns.filter((record) => record.event === "end").map((r) => r.outcome),
      ["partial_fallback"],
    );
  } finally {
    await unanswered.stop();
  }
});

test("a client that vanishes mid-sentence ends the billed stream", async () => {
  // Soniox bills a stream for as long as it is open. A laptop lid, a dropped network or
  // a crashed app must not leave one running with nobody listening to it.
  const rig = await startRig({ sonioxPrestartKeepaliveMs: 0 });
  try {
    await rig.ready();
    rig.send({ type: "input_audio_buffer.clear", event_id: "whisper-turn-1-2" });
    rig.send({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-1-3",
      audio: audio([1, 2, 3, 4]),
    });
    assert.ok(await waitUntil(() => rig.upstream.frames.length === 2));
    assert.equal(rig.upstream.frames[0].model, "stt-rt-v6", "the stream is open");
    let upstreamClosed = null;
    rig.upstream.socket.once("close", (code) => { upstreamClosed = code; });

    // No close handshake, no commit: the way a connection actually dies.
    rig.client.terminate();

    assert.ok(await waitUntil(() => upstreamClosed !== null), "the upstream was left open");
    assert.deepEqual(
      rig.upstream.frames.slice(2),
      [{ endOfStream: true }],
      "the stream is ended explicitly, and nothing else is sent after the audio",
    );
    assert.equal(upstreamClosed, 1000);
    assert.deepEqual(rig.ends, ["client closed"]);
    const end = rig.turns.find((record) => record.event === "end");
    assert.equal(end.outcome, "abandoned");
    assert.equal(end.audioBytes, 4);
  } finally {
    await rig.stop();
  }
});

test("a relay without a Soniox key says so on that route and keeps serving", async () => {
  // The real server process, because the branch under test lives in index.js: it must
  // answer before any bridge is built, name the missing key in words that stop the
  // app's retry ladder, and give the connection slot back.
  const deviceToken = "relay_soniox-not-configured-token";
  const probe = http.createServer();
  const port = await listen(probe);
  await close(probe);
  const { SONIOX_API_KEY: _omitted, ...withoutKey } = baseEnv;
  const child = spawn(process.execPath, [fileURLToPath(new URL("../src/index.js", import.meta.url))], {
    env: {
      PATH: process.env.PATH,
      ...withoutKey,
      RELAY_DEVICE_TOKEN_HASHES: tokenDigest(deviceToken),
      PORT: String(port),
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  child.stdout.on("data", (chunk) => { output += chunk; });
  child.stderr.on("data", (chunk) => { output += chunk; });
  const exited = new Promise((resolve) => child.once("exit", resolve));
  try {
    assert.ok(
      await waitUntil(() => output.includes("Whisper Relay listening"), 10_000),
      `the relay did not start without a Soniox key:\n${output}`,
    );
    const client = new WebSocket(
      `ws://127.0.0.1:${port}/v1/realtime?intent=transcription&provider=soniox`,
      { headers: { authorization: `Bearer ${deviceToken}` } },
    );
    const events = [];
    let closeCode = null;
    client.on("message", (data) => events.push(JSON.parse(data.toString("utf8"))));
    client.on("close", (code) => { closeCode = code; });
    client.on("error", () => {});
    assert.ok(await waitUntil(() => closeCode !== null), "the connection was left open");
    assert.equal(closeCode, 1011);
    assert.equal(events.length, 1);
    assert.equal(events[0].type, "error");
    assert.equal(events[0].error.code, "relay_soniox_not_configured");
    // "API Key" is one of the phrases RealtimeClient treats as not worth retrying.
    assert.match(events[0].error.message, /API Key/);
    assert.ok(await waitUntil(() => /realtime connection released.*end=soniox-not-configured/.test(output)));
    assert.match(output, /realtime connection released.*provider=soniox.*device_open=0 total_open=0/);
    assert.doesNotMatch(output, /bridge failed to start/);
    assert.doesNotMatch(output, new RegExp(deviceToken));

    // The process is still up and still routes: a provider it has never heard of is a
    // plain 404, before authentication is even looked at.
    const unknown = await new Promise((resolve) => {
      const socket = new WebSocket(
        `ws://127.0.0.1:${port}/v1/realtime?intent=transcription&provider=nonesuch`,
        { headers: { authorization: `Bearer ${deviceToken}` } },
      );
      socket.on("unexpected-response", (_request, response) => {
        resolve(response.statusCode);
        socket.terminate();
      });
      socket.on("error", () => {});
      socket.on("open", () => { resolve("opened"); socket.terminate(); });
    });
    assert.equal(unknown, 404);
    assert.equal(child.exitCode, null, "the relay must still be running");
  } finally {
    child.kill("SIGTERM");
    await exited;
  }
});

test("a press that captured no audio is answered locally and keeps the warm socket", async () => {
  const rig = await startRig({ sonioxPrestartKeepaliveMs: 0 });
  try {
    await rig.ready();
    rig.send({ type: "input_audio_buffer.clear", event_id: "whisper-turn-1-2" });
    rig.send({ type: "input_audio_buffer.commit", event_id: "whisper-turn-1-3" });
    assert.ok(await waitUntil(() => rig.events.some(
      (e) => e.type === "conversation.item.input_audio_transcription.completed",
    )));
    const completed = rig.events.find(
      (e) => e.type === "conversation.item.input_audio_transcription.completed",
    );
    assert.equal(completed.transcript, "");
    assert.equal(completed.session_replacement_required, false);
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.deepEqual(rig.closes, []);
    assert.deepEqual(rig.upstream.frames, [], "Soniox never hears of an empty press");

    // The same socket then carries a real sentence.
    rig.send({ type: "input_audio_buffer.clear", event_id: "whisper-turn-2-4" });
    rig.send({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-2-5",
      audio: audio([9, 9]),
    });
    assert.ok(await waitUntil(() => rig.upstream.frames.length === 2));
    assert.equal(rig.upstream.frames[0].model, "stt-rt-v6");
  } finally {
    await rig.stop();
  }
});

test("cancelling before any audio keeps the socket; cancelling after it retires the stream", async () => {
  const rig = await startRig({ sonioxPrestartKeepaliveMs: 0 });
  try {
    await rig.ready();
    rig.send({ type: "input_audio_buffer.clear", event_id: "whisper-turn-1-2" });
    rig.send({ type: "input_audio_buffer.clear", event_id: "whisper-turn-1-3" });
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.deepEqual(rig.closes, []);
    assert.deepEqual(rig.upstream.frames, []);

    rig.send({ type: "input_audio_buffer.clear", event_id: "whisper-turn-2-4" });
    rig.send({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-2-5",
      audio: audio([1, 2]),
    });
    rig.send({ type: "input_audio_buffer.clear", event_id: "whisper-turn-2-6" });
    assert.ok(await waitUntil(() => rig.closes.length === 1));
    // Tokens carry no turn id, so a late result could only be told apart from the next
    // sentence's by not sharing a connection with it.
    assert.deepEqual(rig.closes, [1012]);
    assert.deepEqual(rig.ends, ["soniox turn cancelled"]);
    assert.ok(!rig.events.some((e) => e.type.endsWith(".completed")));
    assert.deepEqual(
      rig.turns.filter((record) => record.event === "end").map((record) => record.outcome),
      ["cancelled", "cancelled"],
    );
  } finally {
    await rig.stop();
  }
});

test("a rejected Soniox key and an empty balance each say so in the app's own terms", async () => {
  for (const [frame, pattern, code] of [
    [{ tokens: [], error_code: 401, error_type: "unauthenticated", error_message: "x" },
      /authentication/, "relay_upstream_handshake"],
    [{ tokens: [], error_code: 402, error_type: "balance_exhausted", error_message: "x" },
      /Billing/, "relay_soniox_balance_exhausted"],
  ]) {
    const rig = await startRig({ sonioxPrestartKeepaliveMs: 0 });
    try {
      await rig.ready();
      rig.reply(frame);
      assert.ok(await waitUntil(() => rig.closes.length === 1));
      const error = rig.events.find((e) => e.type === "error")?.error;
      assert.equal(error?.code, code);
      assert.match(error.message, pattern);
      assert.equal(error.session_replacement_required, true);
      assert.deepEqual(rig.closes, [1011]);
    } finally {
      await rig.stop();
    }
  }
});

test("a Soniox error mid-sentence is tied to that sentence's last client event", async () => {
  const rig = await startRig({ sonioxPrestartKeepaliveMs: 0 });
  try {
    await rig.ready();
    rig.send({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-1-2",
      audio: audio([1, 2]),
    });
    assert.ok(await waitUntil(() => rig.upstream.frames.length === 2));
    rig.reply({
      tokens: [],
      error_code: 503,
      error_type: "service_unavailable",
      error_message: "overloaded",
    });
    assert.ok(await waitUntil(() => rig.closes.length === 1));
    const error = rig.events.find((e) => e.type === "error").error;
    assert.equal(error.code, "relay_soniox_error");
    assert.equal(error.message, "Soniox 转写失败（service_unavailable）");
    // Without this the app files the error under "not this turn" and reports a broken
    // connection instead of a failed sentence.
    assert.equal(error.event_id, "whisper-turn-1-2");
    assert.deepEqual(
      rig.turns.filter((record) => record.event === "end").map((record) => record.outcome),
      ["abandoned"],
    );
  } finally {
    await rig.stop();
  }
});

test("an unanswered finalize keeps the words already heard, and fails only with none", async () => {
  const heard = await startRig({ sonioxPrestartKeepaliveMs: 0, sonioxFinalTimeoutMs: 150 });
  try {
    await heard.ready();
    heard.send({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-1-2",
      audio: audio([1, 2]),
    });
    assert.ok(await waitUntil(() => heard.upstream.frames.length === 2));
    heard.reply({ tokens: [
      { text: "明天", is_final: true },
      { text: "开会", is_final: false },
    ] });
    heard.send({ type: "input_audio_buffer.commit", event_id: "whisper-turn-1-3" });
    assert.ok(await waitUntil(() => heard.closes.length === 1));
    const completed = heard.events.find(
      (e) => e.type === "conversation.item.input_audio_transcription.completed",
    );
    assert.equal(completed.transcript, "明天开会");
    assert.equal(completed.session_replacement_required, true);
    assert.deepEqual(
      heard.turns.filter((record) => record.event === "end").map((r) => r.outcome),
      ["partial_fallback"],
    );
  } finally {
    await heard.stop();
  }

  const silent = await startRig({ sonioxPrestartKeepaliveMs: 0, sonioxFinalTimeoutMs: 150 });
  try {
    await silent.ready();
    silent.send({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-1-2",
      audio: audio([1, 2]),
    });
    silent.send({ type: "input_audio_buffer.commit", event_id: "whisper-turn-1-3" });
    assert.ok(await waitUntil(() => silent.closes.length === 1));
    const error = silent.events.find((e) => e.type === "error").error;
    assert.equal(error.code, "relay_soniox_turn_timeout");
    assert.equal(error.event_id, "whisper-turn-1-3");
    assert.equal(error.session_replacement_required, true);
    assert.ok(!silent.events.some((e) => e.type.endsWith(".completed")));
    assert.deepEqual(silent.closes, [1012]);
  } finally {
    await silent.stop();
  }
});

test("a silent sentence that Soniox does finalize completes empty rather than failing", async () => {
  const rig = await startRig({ sonioxPrestartKeepaliveMs: 0 });
  try {
    await rig.ready();
    rig.send({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-1-2",
      audio: audio([0, 0, 0, 0]),
    });
    rig.send({ type: "input_audio_buffer.commit", event_id: "whisper-turn-1-3" });
    assert.ok(await waitUntil(() => rig.upstream.frames.some((frame) => frame.endOfStream)));
    rig.reply({ tokens: [{ text: "<fin>", is_final: true }] });
    assert.ok(await waitUntil(() => rig.closes.length === 1));
    const completed = rig.events.find(
      (e) => e.type === "conversation.item.input_audio_transcription.completed",
    );
    assert.equal(completed.transcript, "");
    assert.ok(!rig.events.some((e) => e.type === "error"));
    assert.ok(!rig.events.some((e) => e.type.endsWith(".partial")));
  } finally {
    await rig.stop();
  }
});

test("a second session.update on a Soniox connection is refused", async () => {
  // The start message is built once per connection. Reconfiguring mid-connection would
  // let a sentence start under one vocabulary and finish under another; the app never
  // does it, and a client that tries is told rather than quietly ignored.
  const rig = await startRig({ sonioxPrestartKeepaliveMs: 0 });
  try {
    await rig.ready();
    const second = sessionUpdate("whisper-session-2");
    rig.send(second);
    assert.ok(await waitUntil(() => rig.closes.length === 1));
    const error = rig.events.find((e) => e.type === "error").error;
    assert.equal(error.code, "relay_invalid_event");
    assert.match(error.message, /Soniox session configuration is not allowed/);
    assert.deepEqual(rig.closes, [1008]);
  } finally {
    await rig.stop();
  }
});
