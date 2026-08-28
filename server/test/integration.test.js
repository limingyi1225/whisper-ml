import http from "node:http";
import net from "node:net";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import WebSocket, { WebSocketServer } from "ws";

import { tokenDigest } from "../src/auth.js";
import { loadConfig } from "../src/config.js";
import {
  EnrollmentRegistry,
  handleEnrollment,
  handleEnrollmentAdmin,
} from "../src/enrollment.js";
import { handlePolish } from "../src/polish.js";
import { FixedWindowRateLimiter } from "../src/rate-limit.js";
import {
  bridgeGeminiRealtime,
  geminiSilentTurnDeadlineMs,
} from "../src/gemini-realtime.js";
import { bridgeRealtime, revokeDownstream } from "../src/realtime.js";

const token = "relay_integration-device-token";
const baseConfig = loadConfig({
  OPENAI_API_KEY: "server-only-openai-key",
  GEMINI_API_KEY: "server-only-gemini-key",
  RELAY_DEVICE_TOKEN_HASHES: tokenDigest(token),
});

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.off("error", reject);
      resolve(server.address().port);
    });
  });
}

/// The app's own Gemini session frame, which the bridge's validator accepts.
function geminiSessionUpdate(eventID) {
  return {
    type: "session.update",
    event_id: eventID,
    session: {
      type: "transcription",
      audio: {
        input: {
          format: { type: "audio/pcm", rate: 24_000 },
          transcription: { model: "gemini-3.5-transcribe-live" },
          turn_detection: null,
        },
      },
    },
  };
}

function close(server) {
  return new Promise((resolve) => server.close(resolve));
}

function onceMessage(socket) {
  return new Promise((resolve, reject) => {
    socket.once("message", (data) => resolve(JSON.parse(data.toString("utf8"))));
    socket.once("error", reject);
  });
}

function pcm16Tone(durationMs, amplitude = 2_000, frequency = 220) {
  const sampleCount = Math.round(24_000 * durationMs / 1_000);
  const pcm = Buffer.alloc(sampleCount * 2);
  for (let index = 0; index < sampleCount; index += 1) {
    const sample = Math.round(
      amplitude * Math.sin(2 * Math.PI * frequency * index / 24_000),
    );
    pcm.writeInt16LE(sample, index * 2);
  }
  return pcm;
}

test("Gemini silence deadlines distinguish quiet, uncertain, and long turns", () => {
  const deadlines = {
    quietShortMs: 1_800,
    uncertainShortMs: 3_000,
    fullMs: 5_000,
  };
  assert.equal(geminiSilentTurnDeadlineMs({
    ...deadlines, audioMs: 500, provenQuiet: true,
  }), 1_800);
  assert.equal(geminiSilentTurnDeadlineMs({
    ...deadlines, audioMs: 500, provenQuiet: false,
  }), 3_000);
  assert.equal(geminiSilentTurnDeadlineMs({
    ...deadlines, audioMs: 2_500, provenQuiet: true,
  }), 5_000);
  assert.equal(geminiSilentTurnDeadlineMs({
    audioMs: 500,
    provenQuiet: false,
    quietShortMs: 1_800,
    uncertainShortMs: 3_000,
    fullMs: 2_000,
  }), 2_000, "a shortened general deadline still caps both short paths");
});

test("the enrollment endpoint is one-time but retries the same device safely", async () => {
  const directory = mkdtempSync(join(tmpdir(), "whisper-enrollment-http-"));
  const registry = new EnrollmentRegistry(join(directory, "registry.json"));
  const issued = registry.issueInvite("alice");
  const limiter = new FixedWindowRateLimiter(10);
  let authorizationChanges = 0;
  const relay = http.createServer((request, response) => {
    void handleEnrollment(request, response, {
      registry,
      rateLimiter: limiter,
      onAuthorizationChanged: () => { authorizationChanges += 1; },
    });
  });
  const relayPort = await listen(relay);
  const enroll = (deviceToken) => fetch(`http://127.0.0.1:${relayPort}/v1/enroll`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ inviteCode: issued.code, deviceToken }),
  });

  try {
    const aliceToken = `relay_${"a".repeat(43)}`;
    const firstEnrollment = await enroll(aliceToken);
    assert.equal(firstEnrollment.status, 200);
    assert.deepEqual(await firstEnrollment.json(), { ok: true });
    const idempotentEnrollment = await enroll(aliceToken);
    assert.equal(idempotentEnrollment.status, 200);
    assert.deepEqual(await idempotentEnrollment.json(), { ok: true });
    assert.equal(authorizationChanges, 1);
    const stolen = await enroll(`relay_${"b".repeat(43)}`);
    assert.equal(stolen.status, 409);
    assert.equal((await stolen.json()).error.code, "enrollment_already_used");

    const bob = registry.issueInvite("bob");
    const reusedToken = await fetch(`http://127.0.0.1:${relayPort}/v1/enroll`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ inviteCode: bob.code, deviceToken: aliceToken }),
    });
    assert.equal(reusedToken.status, 409);
    assert.equal((await reusedToken.json()).error.code, "enrollment_device_token_in_use");

    const racing = registry.issueInvite("carol");
    const raceEnroll = (suffix) => fetch(`http://127.0.0.1:${relayPort}/v1/enroll`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        inviteCode: racing.code,
        deviceToken: `relay_${suffix.repeat(43)}`,
      }),
    });
    const raced = await Promise.all([raceEnroll("c"), raceEnroll("d")]);
    assert.deepEqual(raced.map((response) => response.status).sort(), [200, 409]);
    assert.equal(authorizationChanges, 2, "only one concurrent claimant may be authorised");

    const wrongContentType = await fetch(`http://127.0.0.1:${relayPort}/v1/enroll`, {
      method: "POST",
      headers: { "content-type": "text/plain" },
      body: JSON.stringify({ inviteCode: racing.code, deviceToken: aliceToken }),
    });
    assert.equal(wrongContentType.status, 415);
  } finally {
    await close(relay);
  }
});

test("the local admin surface issues, lists, and revokes without exposing secrets", async () => {
  const directory = mkdtempSync(join(tmpdir(), "whisper-enrollment-admin-"));
  const registry = new EnrollmentRegistry(join(directory, "registry.json"));
  let authorizationChanges = 0;
  const admin = http.createServer((request, response) => {
    void handleEnrollmentAdmin(request, response, {
      registry,
      onAuthorizationChanged: () => { authorizationChanges += 1; },
    });
  });
  const port = await listen(admin);
  const post = (path, body) => fetch(`http://127.0.0.1:${port}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });

  try {
    const issuedResponse = await post("/admin/invites", { label: "alice" });
    assert.equal(issuedResponse.status, 201);
    const issued = await issuedResponse.json();
    assert.match(issued.code, /^WHISPER-/);

    const pending = await (await fetch(`http://127.0.0.1:${port}/admin/status`)).json();
    assert.deepEqual(pending.pendingInvites.map((item) => item.label), ["alice"]);
    assert.equal(JSON.stringify(pending).includes(issued.code), false);

    const duplicate = await post("/admin/invites", { label: "alice" });
    assert.equal(duplicate.status, 409);
    assert.equal((await duplicate.json()).error.code, "admin_label_in_use");

    const revoked = await post("/admin/revoke", { label: "alice" });
    assert.equal(revoked.status, 200);
    assert.deepEqual(await revoked.json(), { ok: true, devices: 0, invites: 1 });
    assert.equal(authorizationChanges, 1);
  } finally {
    await close(admin);
  }
});

async function waitUntil(predicate, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  return false;
}

test("polish proxy injects the server key and returns the upstream response", async () => {
  let upstreamAuthorization;
  let upstreamBody;
  let upstreamCalls = 0;
  let dailyQuota = null;
  const upstream = http.createServer(async (request, response) => {
    upstreamCalls += 1;
    upstreamAuthorization = request.headers.authorization;
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    upstreamBody = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    const body = Buffer.from(JSON.stringify({
      choices: [{ message: { content: "cleaned" } }],
    }));
    response.writeHead(200, {
      "content-type": "application/json",
      "content-length": body.length,
    });
    response.end(body);
  });
  const upstreamPort = await listen(upstream);

  const config = {
    ...baseConfig,
    openAIPolishURL: `http://127.0.0.1:${upstreamPort}/v1/chat/completions`,
  };
  const relay = http.createServer((request, response) => {
    void handlePolish(request, response, {
      config,
      deviceID: tokenDigest(token),
      rateLimiter: new FixedWindowRateLimiter(5),
      takeDailyQuota: () => dailyQuota,
    });
  });
  const relayPort = await listen(relay);

  try {
    const body = {
      model: "gpt-5.6-luna",
      messages: [
        { role: "system", content: "tidy only" },
        { role: "user", content: "<transcript>raw</transcript>" },
      ],
      reasoning_effort: "none",
    };
    const response = await fetch(`http://127.0.0.1:${relayPort}/v1/polish`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {
      choices: [{ message: { content: "cleaned" } }],
    });
    assert.equal(upstreamAuthorization, "Bearer server-only-openai-key");
    // The relay re-serializes rather than forwarding verbatim, so that it can force an
    // output ceiling the token holder cannot raise.
    assert.deepEqual(upstreamBody, {
      ...body,
      max_completion_tokens: baseConfig.maxPolishCompletionTokens,
    });
    assert.ok(baseConfig.maxPolishCompletionTokens > 0);

    dailyQuota = "device";
    const refused = await fetch(`http://127.0.0.1:${relayPort}/v1/polish`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    });
    assert.equal(refused.status, 429);
    assert.equal((await refused.json()).error.code, "relay_daily_quota");
    assert.equal(upstreamCalls, 1, "a daily-quota rejection must not spend the server key");
  } finally {
    await close(relay);
    await close(upstream);
  }
});

test("a cleanup the app abandons stops costing money upstream", async () => {
  let upstreamAbandoned = false;
  let upstreamReceived = false;
  const upstream = http.createServer((request, response) => {
    upstreamReceived = true;
    // Never answers. The question is only what happens when the Mac hangs up first —
    // which it does for most sentences in back-to-back dictation, because starting the
    // next utterance cancels the previous one's cleanup request.
    response.on("close", () => {
      if (!response.writableEnded) upstreamAbandoned = true;
    });
  });
  const upstreamPort = await listen(upstream);

  const config = {
    ...baseConfig,
    openAIPolishURL: `http://127.0.0.1:${upstreamPort}/v1/chat/completions`,
  };
  const relay = http.createServer((request, response) => {
    void handlePolish(request, response, {
      config,
      deviceID: tokenDigest(token),
      rateLimiter: new FixedWindowRateLimiter(5),
    });
  });
  const relayPort = await listen(relay);

  const abort = new AbortController();
  try {
    const inflight = fetch(`http://127.0.0.1:${relayPort}/v1/polish`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: "gpt-5.6-luna",
        messages: [
          { role: "system", content: "tidy only" },
          { role: "user", content: "<transcript>raw</transcript>" },
        ],
        reasoning_effort: "none",
      }),
      signal: abort.signal,
    }).then(() => "answered", () => "abandoned");

    assert.ok(await waitUntil(() => upstreamReceived), "upstream never saw the request");
    abort.abort();
    assert.equal(await inflight, "abandoned");
    assert.ok(
      await waitUntil(() => upstreamAbandoned),
      "the relay kept waiting on OpenAI after its own client had gone",
    );
  } finally {
    await close(relay);
    await close(upstream);
  }
});

test("a polish request that outlives its authorisation is refused before OpenAI is paid", async () => {
  // Bearer auth runs when the headers arrive, but the body arrives at the client's
  // pace — so a deliberately slow POST can be opened while authorised and finished
  // after a revocation. The re-check has to land between the body and the upstream
  // fetch, or "revoked" would only mean "revoked for future requests".
  let upstreamContacted = false;
  const upstream = http.createServer((request, response) => {
    upstreamContacted = true;
    response.writeHead(200, { "content-type": "application/json" });
    response.end("{}");
  });
  const upstreamPort = await listen(upstream);

  let authorized = true;
  const config = {
    ...baseConfig,
    openAIPolishURL: `http://127.0.0.1:${upstreamPort}/v1/chat/completions`,
  };
  const relay = http.createServer((request, response) => {
    void handlePolish(request, response, {
      config,
      deviceID: tokenDigest(token),
      rateLimiter: new FixedWindowRateLimiter(5),
      stillAuthorized: () => authorized,
    });
  });
  const relayPort = await listen(relay);

  try {
    const body = JSON.stringify({
      model: "gpt-5.6-luna",
      messages: [
        { role: "system", content: "tidy only" },
        { role: "user", content: "<transcript>raw</transcript>" },
      ],
      reasoning_effort: "none",
    });
    const request = http.request({
      host: "127.0.0.1",
      port: relayPort,
      method: "POST",
      path: "/v1/polish",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
        "content-length": Buffer.byteLength(body),
      },
    });
    const answered = new Promise((resolve, reject) => {
      request.on("response", resolve);
      request.on("error", reject);
    });

    // Headers and half the body while still authorised…
    request.write(body.slice(0, 20));
    await new Promise((resolve) => setTimeout(resolve, 50));
    // …revoked mid-flight…
    authorized = false;
    // …and the rest of the body arrives anyway.
    request.end(body.slice(20));

    const response = await answered;
    assert.equal(response.statusCode, 401);
    assert.equal(upstreamContacted, false, "the server key must not be spent post-revocation");
  } finally {
    await close(relay);
    await close(upstream);
  }
});

test("revoking a device aborts the cleanup request it already has in flight", async () => {
  // The pre-fetch re-check only covers requests that have not started paying yet. Once
  // the upstream request is open, the only things that could end it were the client
  // hanging up and the 11 s timeout — so a device revoked mid-request still received a
  // completed answer, generated and billed on the server's key.
  let upstreamAborted = false;
  const upstream = http.createServer((request, response) => {
    // Never answers, like a generation still in progress.
    response.on("close", () => {
      if (!response.writableEnded) upstreamAborted = true;
    });
  });
  const upstreamPort = await listen(upstream);

  const deviceID = tokenDigest(token);
  let allowed = new Set([deviceID]);
  // The registry index.js keeps, and the loop its SIGHUP handler runs.
  const inflight = new Set();
  const revoke = () => {
    allowed = new Set();
    for (const entry of inflight) {
      if (allowed.has(entry.deviceID)) continue;
      entry.abort();
    }
  };

  const config = {
    ...baseConfig,
    openAIPolishURL: `http://127.0.0.1:${upstreamPort}/v1/chat/completions`,
  };
  const relay = http.createServer((request, response) => {
    void handlePolish(request, response, {
      config,
      deviceID,
      rateLimiter: new FixedWindowRateLimiter(5),
      stillAuthorized: () => allowed.has(deviceID),
      registerAbort: (abort) => {
        const entry = { deviceID, abort };
        inflight.add(entry);
        return () => inflight.delete(entry);
      },
    });
  });
  const relayPort = await listen(relay);

  try {
    const answered = fetch(`http://127.0.0.1:${relayPort}/v1/polish`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: "gpt-5.6-luna",
        messages: [
          { role: "system", content: "tidy only" },
          { role: "user", content: "<transcript>raw</transcript>" },
        ],
        reasoning_effort: "none",
      }),
    });

    assert.ok(await waitUntil(() => inflight.size === 1), "the request never registered");
    revoke();

    const response = await answered;
    // 401, not 502: telling a revoked device the relay could not reach OpenAI would send
    // it into its retry ladder over a request that will never be served again.
    assert.equal(response.status, 401);
    assert.ok(
      await waitUntil(() => upstreamAborted),
      "the upstream generation must stop, not run to completion and bill",
    );
    assert.equal(inflight.size, 0, "the registry must not leak entries");
  } finally {
    await close(relay);
    await close(upstream);
  }
});

test("Realtime bridge queues the first session update and injects the server key", async () => {
  let upstreamAuthorization;
  const receivedByUpstream = [];
  const upstreamServer = http.createServer();
  const upstreamWSS = new WebSocketServer({ server: upstreamServer });
  upstreamWSS.on("connection", (socket, request) => {
    upstreamAuthorization = request.headers.authorization;
    socket.on("message", (data) => {
      const event = JSON.parse(data.toString("utf8"));
      receivedByUpstream.push(event);
      if (event.type === "session.update") {
        socket.send(JSON.stringify({ type: "session.updated" }));
      }
    });
  });
  const upstreamPort = await listen(upstreamServer);

  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({ server: relayServer });
  relayWSS.on("connection", (downstream) => {
    bridgeRealtime(downstream, {
      ...baseConfig,
      openAIRealtimeURL: `ws://127.0.0.1:${upstreamPort}/v1/realtime`,
    });
  });
  const relayPort = await listen(relayServer);

  const client = new WebSocket(`ws://127.0.0.1:${relayPort}`);
  try {
    await new Promise((resolve, reject) => {
      client.once("open", resolve);
      client.once("error", reject);
    });

    // This is deliberately sent immediately: the relay's upstream socket is still
    // connecting on the common path, exactly like URLSession's first session.update.
    client.send(JSON.stringify({
      type: "session.update",
      event_id: "whisper-session-1",
      session: {
        type: "transcription",
        audio: {
          input: {
            format: { type: "audio/pcm", rate: 24_000 },
            transcription: { model: "gpt-live-transcribe", delay: "low" },
            turn_detection: null,
          },
        },
      },
    }));

    assert.deepEqual(await onceMessage(client), { type: "session.updated" });
    assert.equal(upstreamAuthorization, "Bearer server-only-openai-key");
    assert.equal(receivedByUpstream[0].type, "session.update");

    client.send(JSON.stringify({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-1-2",
      audio: Buffer.from([1, 2, 3, 4]).toString("base64"),
    }));
    client.send(JSON.stringify({
      type: "input_audio_buffer.commit",
      event_id: "whisper-turn-1-3",
    }));

    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.deepEqual(
      receivedByUpstream.map((event) => event.type),
      [
        "session.update",
        "input_audio_buffer.append",
        "input_audio_buffer.commit",
      ],
    );
  } finally {
    client.close();
    for (const socket of relayWSS.clients) socket.terminate();
    for (const socket of upstreamWSS.clients) socket.terminate();
    relayWSS.close();
    upstreamWSS.close();
    await close(relayServer);
    await close(upstreamServer);
  }
});

test("Gemini bridge translates the app protocol and returns snapshot plus final", async () => {
  const upstreamEvents = [];
  let upstreamRequestURL = "";
  let googleSocket;
  const upstreamServer = http.createServer();
  const upstreamWSS = new WebSocketServer({ server: upstreamServer });
  upstreamWSS.on("connection", (socket, request) => {
    googleSocket = socket;
    upstreamRequestURL = request.url;
    socket.on("message", (data) => {
      const event = JSON.parse(data.toString("utf8"));
      upstreamEvents.push(event);
      if (event.setup) socket.send(JSON.stringify({ setupComplete: {} }));
    });
  });
  const upstreamPort = await listen(upstreamServer);

  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({ server: relayServer });
  relayWSS.on("connection", (downstream) => {
    bridgeGeminiRealtime(downstream, {
      ...baseConfig,
      geminiLiveURL: `ws://127.0.0.1:${upstreamPort}/live`,
      // Production deliberately waits 1.5 s for segmented final text. Keep this test
      // quick while retaining enough room to prove a second segment resets the timer.
      geminiFinalFallbackDelayMs: 300,
    });
  });
  const relayPort = await listen(relayServer);
  const client = new WebSocket(`ws://127.0.0.1:${relayPort}`);
  const downstreamEvents = [];
  client.on("message", (data) => {
    downstreamEvents.push(JSON.parse(data.toString("utf8")));
  });

  try {
    await new Promise((resolve, reject) => {
      client.once("open", resolve);
      client.once("error", reject);
    });
    client.send(JSON.stringify({
      type: "session.update",
      event_id: "whisper-session-1",
      session: {
        type: "transcription",
        audio: {
          input: {
            format: { type: "audio/pcm", rate: 24_000 },
            transcription: {
              model: "gemini-3.5-transcribe-live",
              keywords: ["李铭一", "Whisper"],
            },
            turn_detection: null,
          },
        },
      },
    }));

    assert.ok(await waitUntil(
      () => downstreamEvents.some((event) => event.type === "session.updated"),
    ));
    const created = downstreamEvents.find((event) => event.type === "session.created");
    assert.ok(created.session.expires_at - Date.now() / 1000 > 590);
    assert.ok(created.session.expires_at - Date.now() / 1000 <= 600);
    assert.match(upstreamRequestURL, /[?&]key=server-only-gemini-key(?:&|$)/);
    assert.deepEqual(upstreamEvents[0], {
      setup: {
        model: "models/gemini-3.5-transcribe-live",
        generationConfig: { responseModalities: ["TEXT"] },
        realtimeInputConfig: { automaticActivityDetection: { disabled: true } },
        inputAudioTranscription: {
          languageCodes: [],
          mode: "SMART",
          customVocabulary: ["李铭一", "Whisper"],
        },
      },
    });

    client.send(JSON.stringify({
      type: "input_audio_buffer.clear",
      event_id: "whisper-turn-1-2",
    }));
    client.send(JSON.stringify({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-1-3",
      audio: Buffer.from([1, 2, 3, 4]).toString("base64"),
    }));
    client.send(JSON.stringify({
      type: "input_audio_buffer.commit",
      event_id: "whisper-turn-1-4",
    }));
    assert.ok(await waitUntil(() => upstreamEvents.length >= 4));
    assert.deepEqual(upstreamEvents.slice(1), [
      { realtimeInput: { activityStart: {} } },
      { realtimeInput: {
        audio: {
          data: Buffer.from([1, 2, 3, 4]).toString("base64"),
          mimeType: "audio/pcm;rate=24000",
        },
      } },
      { realtimeInput: { activityEnd: {} } },
    ]);
    assert.ok(downstreamEvents.some(
      (event) => event.type === "input_audio_buffer.committed"
        && event.item_id === "gemini-turn-1",
    ));

    googleSocket.send(JSON.stringify({
      serverContent: {
        interimInputTranscription: { text: "我们明天下午三点" },
      },
    }));
    googleSocket.send(JSON.stringify({
      serverContent: {
        inputTranscription: { text: "我们星期三上午" },
      },
    }));
    // Let most of the no-boundary quiet period elapse before the next segment starts.
    // Its interim is provider activity and must reset that existing timer; otherwise
    // the first segment completes while Gemini is visibly still answering the second.
    await new Promise((resolve) => setTimeout(resolve, 180));
    googleSocket.send(JSON.stringify({
      serverContent: {
        interimInputTranscription: { text: "十点" },
      },
    }));
    assert.ok(await waitUntil(() => downstreamEvents.some(
      (event) => event.type === "whisper.input_audio_transcription.partial"
        && event.transcript === "我们星期三上午十点",
    )), "a later interim snapshot must retain finalized segments");
    // Total time since the first final now exceeds the configured 300 ms fallback.
    // Only resetting it from the interim can keep this turn alive.
    await new Promise((resolve) => setTimeout(resolve, 180));
    assert.ok(!downstreamEvents.some(
      (event) => event.type === "conversation.item.input_audio_transcription.completed",
    ));
    googleSocket.send(JSON.stringify({
      serverContent: {
        inputTranscription: { text: "十点开会。" },
        turnComplete: true,
      },
    }));
    assert.ok(await waitUntil(() => downstreamEvents.some(
      (event) => event.type === "conversation.item.input_audio_transcription.completed",
    )));
    assert.ok(downstreamEvents.some(
      (event) => event.type === "whisper.input_audio_transcription.partial"
        && event.transcript === "我们明天下午三点",
    ));
    assert.ok(downstreamEvents.some(
      (event) => event.type === "conversation.item.input_audio_transcription.completed"
        && event.transcript === "我们星期三上午十点开会。"
        && event.item_id === "gemini-turn-1",
    ));

    // turnComplete is itself the provider's authoritative turn boundary. Even when
    // Google emits no transcription field for silence, settle the empty turn so the
    // next push-to-talk does not inherit stale state or force a reconnect.
    client.send(JSON.stringify({
      type: "input_audio_buffer.clear",
      event_id: "whisper-turn-2-1",
    }));
    client.send(JSON.stringify({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-2-2",
      audio: Buffer.from([5, 6]).toString("base64"),
    }));
    client.send(JSON.stringify({
      type: "input_audio_buffer.commit",
      event_id: "whisper-turn-2-3",
    }));
    assert.ok(await waitUntil(() => upstreamEvents.length >= 7));
    googleSocket.send(JSON.stringify({ serverContent: { turnComplete: true } }));
    assert.ok(await waitUntil(() => downstreamEvents.some(
      (event) => event.type === "conversation.item.input_audio_transcription.completed"
        && event.item_id === "gemini-turn-2",
    )));
    assert.ok(downstreamEvents.some(
      (event) => event.type === "conversation.item.input_audio_transcription.completed"
        && event.item_id === "gemini-turn-2"
        && event.transcript === "",
    ));
    // Reconnect queues can contain audio without the earlier clear boundary. The
    // bridge must supply activityStart before that first chunk rather than dropping
    // the utterance with a protocol close.
    const implicitAudio = Buffer.from([7, 8]).toString("base64");
    client.send(JSON.stringify({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-3-1",
      audio: implicitAudio,
    }));
    client.send(JSON.stringify({
      type: "input_audio_buffer.commit",
      event_id: "whisper-turn-3-2",
    }));
    assert.ok(await waitUntil(() => upstreamEvents.length >= 10));
    assert.deepEqual(upstreamEvents.slice(7), [
      { realtimeInput: { activityStart: {} } },
      { realtimeInput: {
        audio: { data: implicitAudio, mimeType: "audio/pcm;rate=24000" },
      } },
      { realtimeInput: { activityEnd: {} } },
    ]);
    googleSocket.send(JSON.stringify({
      serverContent: {
        inputTranscription: { text: "隐式开始也能完成。" },
        turnComplete: true,
      },
    }));
    assert.ok(await waitUntil(() => downstreamEvents.some(
      (event) => event.type === "conversation.item.input_audio_transcription.completed"
        && event.item_id === "gemini-turn-3"
        && event.transcript === "隐式开始也能完成。",
    )));
    assert.equal(client.readyState, WebSocket.OPEN);
  } finally {
    client.close();
    for (const socket of relayWSS.clients) socket.terminate();
    for (const socket of upstreamWSS.clients) socket.terminate();
    relayWSS.close();
    upstreamWSS.close();
    await close(relayServer);
    await close(upstreamServer);
  }
});

test("an unanswered audio turn fails and retires its provider session", async () => {
  // Both halves are measured behaviour of the live service:
  //  - activityStart followed by activityEnd with no audio between them is answered
  //    with a 1007 "Precondition check failed" close of the whole session;
  //  - a turn carrying only silence is never answered at all — no inputTranscription,
  //    no generationComplete, nothing, for as long as you care to wait.
  // Either one used to strand the app until its own ~20 s response timeout.
  const upstreamEvents = [];
  let upstreamConnections = 0;
  let lateAWasBlocked = false;
  const upstreamServer = http.createServer();
  const upstreamWSS = new WebSocketServer({ server: upstreamServer });
  upstreamWSS.on("connection", (socket) => {
    upstreamConnections += 1;
    const connection = upstreamConnections;
    socket.on("message", (data) => {
      const event = JSON.parse(data.toString("utf8"));
      if (event.setup) {
        socket.send(JSON.stringify({ setupComplete: {} }));
        return;
      }
      upstreamEvents.push(event);
      if (!event.realtimeInput?.activityEnd) return;
      if (connection === 1) {
        // This is A: answer only after the Relay's timeout. The old provider socket
        // must already be gone, making this result unable to reach a later B turn.
        setTimeout(() => {
          if (socket.readyState !== WebSocket.OPEN) {
            lateAWasBlocked = true;
            return;
          }
          socket.send(JSON.stringify({
            serverContent: {
              inputTranscription: { text: "迟到的 A" },
              generationComplete: true,
            },
          }));
        }, 450);
        return;
      }
      socket.send(JSON.stringify({
        serverContent: {
          inputTranscription: { text: "新的 B" },
          generationComplete: true,
        },
      }));
    });
  });
  const upstreamPort = await listen(upstreamServer);

  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({ server: relayServer });
  relayWSS.on("connection", (downstream) => {
    bridgeGeminiRealtime(downstream, {
      ...baseConfig,
      geminiLiveURL: `ws://127.0.0.1:${upstreamPort}/live`,
      geminiSilentTurnTimeoutMs: 250,
      geminiFinalFallbackDelayMs: 30_000,
    });
  });
  const relayPort = await listen(relayServer);
  const client = new WebSocket(`ws://127.0.0.1:${relayPort}`);
  const downstreamEvents = [];
  let clientClose = null;
  client.on("close", (code) => { clientClose = code; });
  client.on("message", (data) => {
    downstreamEvents.push(JSON.parse(data.toString("utf8")));
  });

  const completed = () => downstreamEvents.filter(
    (event) => event.type === "conversation.item.input_audio_transcription.completed",
  );

  try {
    await new Promise((resolve, reject) => {
      client.once("open", resolve);
      client.once("error", reject);
    });
    client.send(JSON.stringify({
      type: "session.update",
      event_id: "whisper-session-1",
      session: {
        type: "transcription",
        audio: {
          input: {
            format: { type: "audio/pcm", rate: 24_000 },
            transcription: { model: "gemini-3.5-transcribe-live" },
            turn_detection: null,
          },
        },
      },
    }));
    assert.ok(await waitUntil(
      () => downstreamEvents.some((event) => event.type === "session.updated"),
    ));

    // A press that captured nothing at all must never reach the provider.
    client.send(JSON.stringify({
      type: "input_audio_buffer.clear",
      event_id: "whisper-turn-1-1",
    }));
    client.send(JSON.stringify({
      type: "input_audio_buffer.commit",
      event_id: "whisper-turn-1-2",
    }));
    assert.ok(await waitUntil(() => completed().length === 1));
    assert.equal(completed()[0].transcript, "");
    assert.deepEqual(
      upstreamEvents, [],
      "an empty turn must send no activity pair upstream",
    );
    assert.equal(clientClose, null, "and must not cost the socket");

    // A turn that carried enough audio to hold a sentence and draws no response at all
    // has an uncertain provider boundary. It must fail and retire this transport, not
    // fabricate an empty completion and leave a late provider result free to attach to
    // the next turn. (A short, locally quiet turn is the accidental-tap case and is
    // covered separately; see the short-quiet-turn test.)
    client.send(JSON.stringify({
      type: "input_audio_buffer.clear",
      event_id: "whisper-turn-2-1",
    }));
    client.send(JSON.stringify({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-2-2",
      // 24 kHz mono 16-bit is 48 bytes per millisecond, so this is 2.5 s of audio —
      // past the boundary where silence is read as "nothing was said".
      audio: Buffer.alloc(120_000, 0).toString("base64"),
    }));
    const started = Date.now();
    client.send(JSON.stringify({
      type: "input_audio_buffer.commit",
      event_id: "whisper-turn-2-3",
    }));
    assert.ok(await waitUntil(() => downstreamEvents.some(
      (event) => event.type === "error"
        && event.error?.code === "relay_gemini_turn_timeout",
    )));
    assert.equal(
      downstreamEvents.find(
        (event) => event.type === "error"
          && event.error?.code === "relay_gemini_turn_timeout",
      ).error.session_replacement_required,
      true,
    );
    assert.ok(await waitUntil(() => clientClose === 1012));
    assert.equal(completed().length, 1);
    assert.ok(
      Date.now() - started < 5_000,
      "the silent turn must fail on its own timeout, not the app's",
    );
    assert.deepEqual(
      upstreamEvents.map((event) => Object.keys(event.realtimeInput)[0]),
      ["activityStart", "audio", "activityEnd"],
      "a turn with audio still opens and closes its activity in order",
    );
    assert.equal(clientClose, 1012);

    // B reconnects through an entirely new Relay and Gemini transport. The delayed A
    // result must be fenced out rather than being adopted as B's transcript.
    const secondClient = new WebSocket(`ws://127.0.0.1:${relayPort}`);
    const secondEvents = [];
    secondClient.on("message", (data) => {
      secondEvents.push(JSON.parse(data.toString("utf8")));
    });
    await new Promise((resolve, reject) => {
      secondClient.once("open", resolve);
      secondClient.once("error", reject);
    });
    secondClient.send(JSON.stringify(geminiSessionUpdate("whisper-session-2")));
    assert.ok(await waitUntil(
      () => secondEvents.some((event) => event.type === "session.updated"),
    ));
    secondClient.send(JSON.stringify({
      type: "input_audio_buffer.clear",
      event_id: "whisper-turn-b-1",
    }));
    secondClient.send(JSON.stringify({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-b-2",
      audio: Buffer.alloc(960, 1).toString("base64"),
    }));
    secondClient.send(JSON.stringify({
      type: "input_audio_buffer.commit",
      event_id: "whisper-turn-b-3",
    }));
    assert.ok(await waitUntil(() => secondEvents.some(
      (event) => event.type === "conversation.item.input_audio_transcription.completed",
    )));
    assert.equal(
      secondEvents.find(
        (event) => event.type === "conversation.item.input_audio_transcription.completed",
      ).transcript,
      "新的 B",
    );
    assert.equal(upstreamConnections, 2);
    assert.ok(await waitUntil(() => lateAWasBlocked));
    assert.ok(!secondEvents.some((event) => event.transcript === "迟到的 A"));
    secondClient.close();
  } finally {
    client.close();
    for (const socket of relayWSS.clients) socket.terminate();
    for (const socket of upstreamWSS.clients) socket.terminate();
    relayWSS.close();
    upstreamWSS.close();
    await close(relayServer);
    await close(upstreamServer);
  }
});


test("a fallback-finalized Gemini turn retires the uncertain provider boundary", async () => {
  let upstreamConnections = 0;
  let lateSegmentWasBlocked = false;
  const upstreamServer = http.createServer();
  const upstreamWSS = new WebSocketServer({ server: upstreamServer });
  upstreamWSS.on("connection", (socket) => {
    upstreamConnections += 1;
    const connection = upstreamConnections;
    socket.on("message", (data) => {
      const event = JSON.parse(data.toString("utf8"));
      if (event.setup) {
        socket.send(JSON.stringify({ setupComplete: {} }));
        return;
      }
      if (!event.realtimeInput?.activityEnd) return;
      if (connection === 1) {
        // A has a final transcription frame but no provider response boundary. The
        // fallback may deliver it, but must then close this provider session.
        socket.send(JSON.stringify({
          serverContent: { inputTranscription: { text: "A 的第一段" } },
        }));
        setTimeout(() => {
          if (socket.readyState !== WebSocket.OPEN) {
            lateSegmentWasBlocked = true;
            return;
          }
          socket.send(JSON.stringify({
            serverContent: {
              inputTranscription: { text: "A 的迟到第二段" },
              generationComplete: true,
            },
          }));
        }, 250);
        return;
      }
      socket.send(JSON.stringify({
        serverContent: {
          inputTranscription: { text: "B 的结果" },
          generationComplete: true,
        },
      }));
    });
  });
  const upstreamPort = await listen(upstreamServer);

  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({ server: relayServer });
  relayWSS.on("connection", (downstream) => {
    bridgeGeminiRealtime(downstream, {
      ...baseConfig,
      geminiLiveURL: `ws://127.0.0.1:${upstreamPort}/live`,
      geminiSilentTurnTimeoutMs: 5_000,
      geminiFinalFallbackDelayMs: 100,
    });
  });
  const relayPort = await listen(relayServer);

  const runTurn = async (sessionID, prefix) => {
    const socket = new WebSocket(`ws://127.0.0.1:${relayPort}`);
    const events = [];
    let closeCode = null;
    socket.on("message", (data) => events.push(JSON.parse(data.toString("utf8"))));
    socket.on("close", (code) => { closeCode = code; });
    await new Promise((resolve, reject) => {
      socket.once("open", resolve);
      socket.once("error", reject);
    });
    socket.send(JSON.stringify(geminiSessionUpdate(sessionID)));
    assert.ok(await waitUntil(() => events.some((event) => event.type === "session.updated")));
    socket.send(JSON.stringify({
      type: "input_audio_buffer.clear",
      event_id: `${prefix}-1`,
    }));
    socket.send(JSON.stringify({
      type: "input_audio_buffer.append",
      event_id: `${prefix}-2`,
      audio: Buffer.alloc(960, 2).toString("base64"),
    }));
    socket.send(JSON.stringify({
      type: "input_audio_buffer.commit",
      event_id: `${prefix}-3`,
    }));
    assert.ok(await waitUntil(() => events.some(
      (event) => event.type === "conversation.item.input_audio_transcription.completed",
    )));
    return { socket, events, closeCode: () => closeCode };
  };

  let first;
  let second;
  try {
    first = await runTurn("whisper-session-a", "whisper-turn-a");
    assert.equal(
      first.events.find(
        (event) => event.type === "conversation.item.input_audio_transcription.completed",
      ).transcript,
      "A 的第一段",
    );
    assert.equal(
      first.events.find(
        (event) => event.type === "conversation.item.input_audio_transcription.completed",
      ).session_replacement_required,
      true,
      "the client must replace the socket before a completion callback starts B",
    );
    assert.ok(await waitUntil(() => first.closeCode() === 1012));

    second = await runTurn("whisper-session-b", "whisper-turn-b");
    assert.equal(
      second.events.find(
        (event) => event.type === "conversation.item.input_audio_transcription.completed",
      ).transcript,
      "B 的结果",
    );
    assert.equal(upstreamConnections, 2);
    assert.ok(await waitUntil(() => lateSegmentWasBlocked));
    assert.ok(!second.events.some((event) => event.transcript?.includes("迟到")));
  } finally {
    first?.socket.close();
    second?.socket.close();
    for (const socket of relayWSS.clients) socket.terminate();
    for (const socket of upstreamWSS.clients) socket.terminate();
    relayWSS.close();
    upstreamWSS.close();
    await close(relayServer);
    await close(upstreamServer);
  }
});


test("a Gemini response boundary waits for independently ordered final transcripts", async () => {
  // Measured against the live service: gemini-3.5-transcribe-live closes a
  // transcription response with generationComplete and never sends turnComplete.
  // Treating only turnComplete as the end meant every sentence waited out the
  // fallback timer with its final already in hand.
  let googleSocket;
  const upstreamServer = http.createServer();
  const upstreamWSS = new WebSocketServer({ server: upstreamServer });
  upstreamWSS.on("connection", (socket) => {
    googleSocket = socket;
    socket.on("message", (data) => {
      if (JSON.parse(data.toString("utf8")).setup) {
        socket.send(JSON.stringify({ setupComplete: {} }));
      }
    });
  });
  const upstreamPort = await listen(upstreamServer);

  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({ server: relayServer });
  relayWSS.on("connection", (downstream) => {
    bridgeGeminiRealtime(downstream, {
      ...baseConfig,
      geminiLiveURL: `ws://127.0.0.1:${upstreamPort}/live`,
      // Long enough that a finish which relied on it would fail this test outright
      // rather than merely being slow.
      geminiFinalFallbackDelayMs: 30_000,
      geminiBoundaryReorderGraceMs: 120,
    });
  });
  const relayPort = await listen(relayServer);
  const client = new WebSocket(`ws://127.0.0.1:${relayPort}`);
  const downstreamEvents = [];
  client.on("message", (data) => {
    downstreamEvents.push(JSON.parse(data.toString("utf8")));
  });

  try {
    await new Promise((resolve, reject) => {
      client.once("open", resolve);
      client.once("error", reject);
    });
    client.send(JSON.stringify({
      type: "session.update",
      event_id: "whisper-session-1",
      session: {
        type: "transcription",
        audio: {
          input: {
            format: { type: "audio/pcm", rate: 24_000 },
            transcription: { model: "gemini-3.5-transcribe-live" },
            turn_detection: null,
          },
        },
      },
    }));
    assert.ok(await waitUntil(
      () => downstreamEvents.some((event) => event.type === "session.updated"),
    ));
    client.send(JSON.stringify({
      type: "input_audio_buffer.clear",
      event_id: "whisper-turn-1-1",
    }));
    client.send(JSON.stringify({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-1-2",
      audio: Buffer.alloc(960, 3).toString("base64"),
    }));
    client.send(JSON.stringify({
      type: "input_audio_buffer.commit",
      event_id: "whisper-turn-1-3",
    }));
    assert.ok(await waitUntil(() => downstreamEvents.some(
      (event) => event.type === "input_audio_buffer.committed",
    )));

    // inputTranscription is explicitly independent of the model turn. Exercise the
    // legal ordering that lost the whole sentence before: the response boundary first,
    // then multiple finalized transcription frames already in flight.
    googleSocket.send(JSON.stringify({
      serverContent: { generationComplete: true },
    }));
    await new Promise((resolve) => setTimeout(resolve, 40));
    assert.ok(!downstreamEvents.some(
      (event) => event.type === "conversation.item.input_audio_transcription.completed",
    ));
    googleSocket.send(JSON.stringify({
      serverContent: { inputTranscription: { text: "好，现在测试" } },
    }));
    await new Promise((resolve) => setTimeout(resolve, 40));
    googleSocket.send(JSON.stringify({
      serverContent: { inputTranscription: { text: "一下效果。" } },
    }));

    const started = Date.now();
    assert.ok(await waitUntil(() => downstreamEvents.some(
      (event) => event.type === "conversation.item.input_audio_transcription.completed",
    )));
    assert.ok(
      Date.now() - started < 5_000,
      "the ordered final must wait only for the boundary grace, not the fallback timer",
    );
    assert.equal(
      downstreamEvents.find(
        (event) => event.type === "conversation.item.input_audio_transcription.completed",
      ).transcript,
      "好，现在测试一下效果。",
    );
  } finally {
    client.close();
    for (const socket of relayWSS.clients) socket.terminate();
    for (const socket of upstreamWSS.clients) socket.terminate();
    relayWSS.close();
    upstreamWSS.close();
    await close(relayServer);
    await close(upstreamServer);
  }
});


test("the Gemini turn audit counts the audio each turn actually carried", async () => {
  // The bridge's most likely failure is audio landing in a turn it does not belong to,
  // and a transcript alone cannot show that. These counts can: a turn whose audio_bytes
  // exceed what the user spoke was fed someone else's audio, and a turn that ends
  // `abandoned` took audio and never returned a final for it.
  let googleSocket;
  const upstreamServer = http.createServer();
  const upstreamWSS = new WebSocketServer({ server: upstreamServer });
  upstreamWSS.on("connection", (socket) => {
    googleSocket = socket;
    socket.on("message", (data) => {
      const event = JSON.parse(data.toString("utf8"));
      if (event.setup) socket.send(JSON.stringify({ setupComplete: {} }));
    });
  });
  const upstreamPort = await listen(upstreamServer);

  const turns = [];
  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({ server: relayServer });
  relayWSS.on("connection", (downstream) => {
    bridgeGeminiRealtime(downstream, {
      ...baseConfig,
      geminiLiveURL: `ws://127.0.0.1:${upstreamPort}/live`,
    }, { onTurn: (record) => turns.push(record) });
  });
  const relayPort = await listen(relayServer);
  const client = new WebSocket(`ws://127.0.0.1:${relayPort}`);
  const downstreamEvents = [];
  client.on("message", (data) => {
    downstreamEvents.push(JSON.parse(data.toString("utf8")));
  });

  const audio = Buffer.alloc(1_200, 7);
  try {
    await new Promise((resolve, reject) => {
      client.once("open", resolve);
      client.once("error", reject);
    });
    client.send(JSON.stringify({
      type: "session.update",
      event_id: "whisper-session-1",
      session: {
        type: "transcription",
        audio: {
          input: {
            format: { type: "audio/pcm", rate: 24_000 },
            transcription: { model: "gemini-3.5-transcribe-live" },
            turn_detection: null,
          },
        },
      },
    }));
    assert.ok(await waitUntil(
      () => downstreamEvents.some((event) => event.type === "session.updated"),
    ));

    client.send(JSON.stringify({
      type: "input_audio_buffer.clear",
      event_id: "whisper-turn-1-1",
    }));
    for (const index of [0, 1]) {
      client.send(JSON.stringify({
        type: "input_audio_buffer.append",
        event_id: `whisper-turn-1-${index + 2}`,
        audio: audio.toString("base64"),
      }));
    }
    client.send(JSON.stringify({
      type: "input_audio_buffer.commit",
      event_id: "whisper-turn-1-4",
    }));
    assert.ok(await waitUntil(() => downstreamEvents.some(
      (event) => event.type === "input_audio_buffer.committed",
    )));

    googleSocket.send(JSON.stringify({
      serverContent: {
        inputTranscription: { text: "我们星期三上午十点开会。" },
        turnComplete: true,
      },
    }));
    assert.ok(await waitUntil(() => turns.some((record) => record.event === "end")));

    assert.deepEqual(
      turns.map((record) => record.event),
      ["open", "end"],
    );
    const completed = turns.find((record) => record.event === "end");
    assert.equal(completed.item, "gemini-turn-1");
    assert.equal(completed.outcome, "completed");
    // Exactly the two appends, decoded — not the base64 length, and not a byte count
    // left over from whichever event happened to be validated last.
    assert.equal(completed.audioBytes, audio.length * 2);
    assert.equal(completed.audioRMS, 1_799);
    assert.equal(completed.chars, 12);

    // A second turn that takes audio and never gets a final must be visible as such
    // rather than vanishing when the connection goes away.
    client.send(JSON.stringify({
      type: "input_audio_buffer.clear",
      event_id: "whisper-turn-2-1",
    }));
    client.send(JSON.stringify({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-2-2",
      audio: audio.toString("base64"),
    }));
    assert.ok(await waitUntil(
      () => turns.filter((record) => record.event === "open").length === 2,
    ));
    googleSocket.close();

    assert.ok(await waitUntil(() => turns.length >= 4));
    const abandoned = turns.at(-1);
    assert.equal(abandoned.item, "gemini-turn-2");
    assert.equal(abandoned.outcome, "abandoned");
    assert.equal(abandoned.audioBytes, audio.length);
  } finally {
    client.close();
    for (const socket of relayWSS.clients) socket.terminate();
    for (const socket of upstreamWSS.clients) socket.terminate();
    relayWSS.close();
    upstreamWSS.close();
    await close(relayServer);
    await close(upstreamServer);
  }
});


test("an illegal frame from a half-open peer does not free its connection slot", async () => {
  // The bookkeeping index.js uses. `ws` answers a protocol error with close(), not
  // destroy(), so the socket sits in CLOSING until the peer's FIN or a ~30 s timer. An
  // ordinary client sends that FIN automatically; a raw socket with allowHalfOpen just
  // does not, and releasing the slot on `error` then handed the ceiling away while the
  // connection was still alive — repeatable, so both caps could be walked past.
  const counted = new Set();
  const server = http.createServer();
  const wss = new WebSocketServer({ server, maxPayload: 1024 * 1024 });
  wss.on("connection", (socket) => {
    counted.add(socket);
    socket.once("close", () => counted.delete(socket));
    socket.once("error", () => socket.terminate());
  });
  const port = await listen(server);

  const raws = [];
  try {
    for (let i = 0; i < 5; i += 1) {
      const raw = net.connect({ port, host: "127.0.0.1", allowHalfOpen: true });
      raws.push(raw);
      raw.on("error", () => {});
      raw.on("data", () => {});
      raw.on("end", () => {});   // deliberately never finish the close
      // Exactly 16 bytes before base64: ws validates the key against /^[+/0-9A-Za-z]
      // {22}==$/ and 400s anything else. A 17-byte key made every handshake fail,
      // `connection` never fire, and both waits pass vacuously on empty sets — five
      // rounds of pure timeout that guarded nothing. Hence the assert below, so a
      // handshake that stops completing fails the test instead of hollowing it out.
      raw.write(
        `GET / HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nUpgrade: websocket\r\n`
        + "Connection: Upgrade\r\n"
        + `Sec-WebSocket-Key: ${Buffer.from(`key-padding-123${i}`).toString("base64")}\r\n`
        + "Sec-WebSocket-Version: 13\r\n\r\n",
      );
      assert.ok(
        await waitUntil(() => counted.size === 1, 2_000),
        `round ${i}: the WebSocket handshake never completed`,
      );
      raw.write(Buffer.from([0xc1, 0x80, 0, 0, 0, 0]));   // RSV1, no extension
      // The slot must come back because the socket is really gone, not because the
      // error handler stopped counting a socket that is still open.
      assert.ok(
        await waitUntil(() => counted.size === 0 && wss.clients.size === 0, 5_000),
        `round ${i}: slot released while ${wss.clients.size} socket(s) were still held`,
      );
    }
  } finally {
    for (const raw of raws) raw.destroy();
    wss.close();
    await close(server);
  }
});

test("a revoked connection stops forwarding the instant the revoke lands", async () => {
  // close() alone does not do this: the socket sits in CLOSING waiting for the peer's
  // ack, and ws keeps parsing and forwarding frames the whole time — measured, five
  // frames sent after close() all still reached the upstream handler. pause() alone
  // does not either: ws's close handler drains data buffered before destruction into
  // the receiver, so everything the pause held back would be forwarded in one burst
  // when the reaper fires. And the paid OpenAI session must die *with* the revoke —
  // graceMs here is far beyond the wait below, so the upstream-closed assertion can
  // only pass if the revoke killed it directly, not the reap.
  const receivedByUpstream = [];
  let upstreamGone = false;
  const upstreamServer = http.createServer();
  const upstreamWSS = new WebSocketServer({ server: upstreamServer });
  upstreamWSS.on("connection", (socket) => {
    socket.on("close", () => { upstreamGone = true; });
    socket.on("message", (data) => {
      const event = JSON.parse(data.toString("utf8"));
      receivedByUpstream.push(event.type);
      if (event.type === "session.update") {
        socket.send(JSON.stringify({ type: "session.updated" }));
      }
    });
  });
  const upstreamPort = await listen(upstreamServer);

  let downstream;
  let bridgeUpstream;
  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({ server: relayServer });
  relayWSS.on("connection", (socket) => {
    downstream = socket;
    bridgeUpstream = bridgeRealtime(socket, {
      ...baseConfig,
      openAIRealtimeURL: `ws://127.0.0.1:${upstreamPort}/v1/realtime`,
    });
  });
  const relayPort = await listen(relayServer);

  const client = new WebSocket(`ws://127.0.0.1:${relayPort}`);
  try {
    await new Promise((resolve, reject) => {
      client.once("open", resolve);
      client.once("error", reject);
    });
    client.send(JSON.stringify({
      type: "session.update",
      session: {
        type: "transcription",
        audio: {
          input: {
            format: { type: "audio/pcm", rate: 24_000 },
            transcription: { model: "gpt-live-transcribe", delay: "low" },
            turn_detection: null,
          },
        },
      },
    }));
    assert.deepEqual(await onceMessage(client), { type: "session.updated" });

    const append = JSON.stringify({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-1-1",
      audio: Buffer.from([1, 2, 3, 4]).toString("base64"),
    });
    client.send(append);
    assert.ok(
      await waitUntil(() => receivedByUpstream.length === 2),
      "the pre-revocation append should have been forwarded",
    );

    // The client never processes the incoming close frame — the model of frames
    // already in flight, or of a peer that simply declines to stop sending.
    client.pause();
    revokeDownstream(downstream, { upstream: bridgeUpstream, graceMs: 2_000 });
    for (let i = 0; i < 5; i += 1) client.send(append);
    await new Promise((resolve) => setTimeout(resolve, 400));

    assert.deepEqual(
      receivedByUpstream,
      ["session.update", "input_audio_buffer.append"],
      "nothing sent after the revoke may reach upstream",
    );
    assert.ok(
      upstreamGone,
      "the paid OpenAI session must be killed by the revoke itself, not the later reap",
    );
  } finally {
    client.terminate();
    for (const socket of relayWSS.clients) socket.terminate();
    for (const socket of upstreamWSS.clients) socket.terminate();
    relayWSS.close();
    upstreamWSS.close();
    await close(relayServer);
    await close(upstreamServer);
  }
});

test("a rejected event names the client event that caused it", async () => {
  const upstreamServer = http.createServer();
  const upstreamWSS = new WebSocketServer({ server: upstreamServer });
  upstreamWSS.on("connection", (socket) => {
    socket.on("message", (data) => {
      if (JSON.parse(data.toString("utf8")).type === "session.update") {
        socket.send(JSON.stringify({ type: "session.updated" }));
      }
    });
  });
  const upstreamPort = await listen(upstreamServer);

  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({ server: relayServer });
  relayWSS.on("connection", (downstream) => {
    bridgeRealtime(downstream, {
      ...baseConfig,
      openAIRealtimeURL: `ws://127.0.0.1:${upstreamPort}/v1/realtime`,
      // Low enough that one ordinary append trips it, standing in for the real
      // ten-minute ceiling.
      maxTurnAudioBytes: 8,
    });
  });
  const relayPort = await listen(relayServer);

  const client = new WebSocket(`ws://127.0.0.1:${relayPort}`);
  try {
    await new Promise((resolve, reject) => {
      client.once("open", resolve);
      client.once("error", reject);
    });
    client.send(JSON.stringify({
      type: "session.update",
      event_id: "whisper-session-1",
      session: {
        type: "transcription",
        audio: {
          input: {
            format: { type: "audio/pcm", rate: 24_000 },
            transcription: { model: "gpt-live-transcribe", delay: "low" },
            turn_detection: null,
          },
        },
      },
    }));
    assert.deepEqual(await onceMessage(client), { type: "session.updated" });

    client.send(JSON.stringify({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-7-4",
      audio: Buffer.alloc(64).toString("base64"),
    }));

    const rejection = await onceMessage(client);
    assert.equal(rejection.type, "error");
    assert.match(rejection.error.message, /音频超过上限/);
    // Nested `error.event_id`, per the Realtime schema — and the only thing the app
    // can parse the turn number out of. Without it a rejection that arrives on a
    // ready session is filed as "not this turn" and dropped, so the user is told the
    // connection broke rather than what was actually wrong with their sentence.
    assert.equal(rejection.error.event_id, "whisper-turn-7-4");
  } finally {
    client.close();
    for (const socket of relayWSS.clients) socket.terminate();
    for (const socket of upstreamWSS.clients) socket.terminate();
    relayWSS.close();
    upstreamWSS.close();
    await close(relayServer);
    await close(upstreamServer);
  }
});

test("daily audio quota is enforced before the append reaches OpenAI", async () => {
  const receivedByUpstream = [];
  const upstreamServer = http.createServer();
  const upstreamWSS = new WebSocketServer({ server: upstreamServer });
  upstreamWSS.on("connection", (socket) => {
    socket.on("message", (data) => {
      const event = JSON.parse(data.toString("utf8"));
      receivedByUpstream.push(event.type);
      if (event.type === "session.update") {
        socket.send(JSON.stringify({ type: "session.updated" }));
      }
    });
  });
  const upstreamPort = await listen(upstreamServer);

  const consumed = [];
  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({ server: relayServer });
  relayWSS.on("connection", (downstream) => {
    bridgeRealtime(
      downstream,
      {
        ...baseConfig,
        openAIRealtimeURL: `ws://127.0.0.1:${upstreamPort}/v1/realtime`,
      },
      {
        consumeAudio: (bytes) => {
          consumed.push(bytes);
          return "device";
        },
      },
    );
  });
  const relayPort = await listen(relayServer);

  const client = new WebSocket(`ws://127.0.0.1:${relayPort}`);
  try {
    await new Promise((resolve, reject) => {
      client.once("open", resolve);
      client.once("error", reject);
    });
    client.send(JSON.stringify({
      type: "session.update",
      session: {
        type: "transcription",
        audio: {
          input: {
            format: { type: "audio/pcm", rate: 24_000 },
            transcription: { model: "gpt-live-transcribe", delay: "low" },
            turn_detection: null,
          },
        },
      },
    }));
    assert.deepEqual(await onceMessage(client), { type: "session.updated" });

    client.send(JSON.stringify({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-9-1",
      audio: Buffer.from([1, 2, 3, 4]).toString("base64"),
    }));
    const rejection = await onceMessage(client);
    assert.equal(rejection.error.code, "relay_daily_quota");
    assert.equal(rejection.error.event_id, "whisper-turn-9-1");
    assert.deepEqual(consumed, [4]);
    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.deepEqual(receivedByUpstream, ["session.update"]);
  } finally {
    client.terminate();
    for (const socket of relayWSS.clients) socket.terminate();
    for (const socket of upstreamWSS.clients) socket.terminate();
    relayWSS.close();
    upstreamWSS.close();
    await close(relayServer);
    await close(upstreamServer);
  }
});

test("audio rejected before upstream admission does not consume daily quota", async () => {
  // Accept the TCP connection but never answer the WebSocket handshake, holding the
  // OpenAI-side socket in CONNECTING while the client sends an append too large for
  // the relay's pre-open queue.
  const upstreamSockets = new Set();
  const hangingUpstream = net.createServer((socket) => {
    upstreamSockets.add(socket);
    socket.once("close", () => upstreamSockets.delete(socket));
  });
  const upstreamPort = await listen(hangingUpstream);
  const consumed = [];
  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({ server: relayServer });
  relayWSS.on("connection", (downstream) => {
    bridgeRealtime(
      downstream,
      {
        ...baseConfig,
        openAIRealtimeURL: `ws://127.0.0.1:${upstreamPort}/v1/realtime`,
        maxPreopenQueueBytes: 8,
      },
      { consumeAudio: (bytes) => { consumed.push(bytes); return null; } },
    );
  });
  const relayPort = await listen(relayServer);
  const client = new WebSocket(`ws://127.0.0.1:${relayPort}`);

  try {
    await new Promise((resolve, reject) => {
      client.once("open", resolve);
      client.once("error", reject);
    });
    client.send(JSON.stringify({
      type: "input_audio_buffer.append",
      event_id: "whisper-not-admitted",
      audio: Buffer.from([1, 2, 3, 4]).toString("base64"),
    }));
    const closeCode = await new Promise((resolve) => client.once("close", resolve));
    assert.equal(closeCode, 1013);
    assert.deepEqual(consumed, []);
  } finally {
    client.terminate();
    for (const socket of relayWSS.clients) socket.terminate();
    relayWSS.close();
    await close(relayServer);
    for (const socket of upstreamSockets) socket.destroy();
    await close(hangingUpstream);
  }
});

test("a client that stops answering pings is terminated and releases its upstream", async () => {
  const upstreamServer = http.createServer();
  const upstreamWSS = new WebSocketServer({ server: upstreamServer });
  let upstreamClosed = false;
  upstreamWSS.on("connection", (socket) => {
    socket.on("close", () => { upstreamClosed = true; });
  });
  const upstreamPort = await listen(upstreamServer);

  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({ server: relayServer });
  let auditEnd;
  relayWSS.on("connection", (downstream) => {
    bridgeRealtime(downstream, {
      ...baseConfig,
      openAIRealtimeURL: `ws://127.0.0.1:${upstreamPort}/v1/realtime`,
      clientHeartbeatIntervalMs: 60,
    }, {
      onEnd: (reason) => { auditEnd = reason; },
    });
  });
  const relayPort = await listen(relayServer);

  // A sleeping laptop or a Wi-Fi change leaves a socket that is open as far as the
  // relay can see but will never answer again. `ws` auto-replies to pings, so the
  // only way to model that here is to suppress the pong.
  const client = new WebSocket(`ws://127.0.0.1:${relayPort}`);
  client.on("ping", () => { /* deliberately never pongs */ });
  client._receiver?.removeAllListeners("ping");

  try {
    await new Promise((resolve, reject) => {
      client.once("open", resolve);
      client.once("error", reject);
    });
    client.pong = () => {};

    const closedCleanly = await new Promise((resolve) => {
      client.once("close", () => resolve(true));
      setTimeout(() => resolve(false), 2_000);
    });
    assert.equal(closedCleanly, true, "relay should have reaped the silent client");

    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(upstreamClosed, true, "the paid upstream session must go with it");
    assert.equal(auditEnd, "client went away");
  } finally {
    client.terminate();
    for (const socket of relayWSS.clients) socket.terminate();
    for (const socket of upstreamWSS.clients) socket.terminate();
    relayWSS.close();
    upstreamWSS.close();
    await close(relayServer);
    await close(upstreamServer);
  }
});

test("backpressure does not let the heartbeat mistake a healthy client for a dead one", async () => {
  // ws stops parsing pong frames while a socket is paused (measured: zero pongs get
  // through). Combining backpressure with a liveness sweep therefore kills exactly the
  // long queued utterance that backpressure exists to protect, and the audio already
  // handed to the socket cannot be replayed.
  const upstreamServer = http.createServer();
  const upstreamWSS = new WebSocketServer({
    server: upstreamServer,
    maxPayload: baseConfig.maxWebSocketPayloadBytes,
  });
  const receivedByUpstream = [];
  upstreamWSS.on("connection", (socket) => {
    socket.on("message", (data) => {
      receivedByUpstream.push(data.length);
      if (data.length < 4096
          && JSON.parse(data.toString("utf8")).type === "session.update") {
        socket.send(JSON.stringify({ type: "session.updated" }));
      }
    });
  });
  const upstreamPort = await listen(upstreamServer);

  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({
    server: relayServer,
    maxPayload: baseConfig.maxWebSocketPayloadBytes,
  });
  relayWSS.on("connection", (downstream) => {
    bridgeRealtime(downstream, {
      ...baseConfig,
      openAIRealtimeURL: `ws://127.0.0.1:${upstreamPort}/v1/realtime`,
      maxForwardBufferBytes: 1024,   // every frame trips backpressure
      clientHeartbeatIntervalMs: 40, // many sweeps land inside the pause
    });
  });
  const relayPort = await listen(relayServer);

  const client = new WebSocket(`ws://127.0.0.1:${relayPort}`);
  const closes = [];
  client.on("close", (code) => closes.push(code));

  try {
    await new Promise((resolve, reject) => {
      client.once("open", resolve);
      client.once("error", reject);
    });
    client.send(JSON.stringify({
      type: "session.update",
      session: {
        type: "transcription",
        audio: {
          input: {
            format: { type: "audio/pcm", rate: 24_000 },
            transcription: { model: "gpt-live-transcribe", delay: "low" },
            turn_detection: null,
          },
        },
      },
    }));
    assert.deepEqual(await onceMessage(client), { type: "session.updated" });

    const chunk = Buffer.alloc(1 << 20).toString("base64");
    const sent = 16;
    for (let i = 0; i < sent; i += 1) {
      client.send(JSON.stringify({
        type: "input_audio_buffer.append",
        event_id: `whisper-turn-1-${i}`,
        audio: chunk,
      }));
    }

    const expected = sent + 1; // session.update + every append
    const deadline = Date.now() + 15_000;
    while (receivedByUpstream.length < expected && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 50));
    }

    assert.deepEqual(closes, [], "a backed-up client must not be reaped as dead");
    assert.equal(receivedByUpstream.length, expected, "no audio may be dropped");
  } finally {
    client.terminate();
    for (const socket of relayWSS.clients) socket.terminate();
    for (const socket of upstreamWSS.clients) socket.terminate();
    relayWSS.close();
    upstreamWSS.close();
    await close(relayServer);
    await close(upstreamServer);
  }
});

test("target-side upstream congestion does not queue a ping then reap the upstream", async () => {
  // This is deliberately different from the localhost fast-drain test above. The
  // OpenAI stand-in stops reading its TCP socket, so the relay's *target* send buffer
  // fills. `upstream.isPaused` remains false in this state: only the downstream source
  // is paused. A heartbeat keyed solely to isPaused queues ping behind the audio, sees
  // no pong on the next sweep, and terminates a healthy but congested upstream.
  const upstreamServer = http.createServer();
  const upstreamWSS = new WebSocketServer({
    server: upstreamServer,
    maxPayload: baseConfig.maxWebSocketPayloadBytes,
  });
  const receivedByUpstream = [];
  let congestedSocket;
  upstreamWSS.on("connection", (socket) => {
    congestedSocket = socket;
    socket._socket.pause();
    socket.on("message", (data) => receivedByUpstream.push(data.length));
  });
  const upstreamPort = await listen(upstreamServer);

  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({
    server: relayServer,
    maxPayload: baseConfig.maxWebSocketPayloadBytes,
  });
  let relayDownstream;
  let relayUpstream;
  relayWSS.on("connection", (downstream) => {
    relayDownstream = downstream;
    relayUpstream = bridgeRealtime(downstream, {
      ...baseConfig,
      openAIRealtimeURL: `ws://127.0.0.1:${upstreamPort}/v1/realtime`,
      maxForwardBufferBytes: 1024,
      clientHeartbeatIntervalMs: 80,
    });
  });
  const relayPort = await listen(relayServer);
  const client = new WebSocket(`ws://127.0.0.1:${relayPort}`);

  try {
    await new Promise((resolve, reject) => {
      client.once("open", resolve);
      client.once("error", reject);
    });
    const upstreamOpenDeadline = Date.now() + 5_000;
    while ((relayUpstream?.readyState !== WebSocket.OPEN || !congestedSocket)
        && Date.now() < upstreamOpenDeadline) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.equal(relayUpstream?.readyState, WebSocket.OPEN, "the upstream must open before flooding");
    client.send(JSON.stringify({
      type: "session.update",
      session: {
        type: "transcription",
        audio: {
          input: {
            format: { type: "audio/pcm", rate: 24_000 },
            transcription: { model: "gpt-live-transcribe", delay: "low" },
            turn_detection: null,
          },
        },
      },
    }));
    const chunk = Buffer.alloc(1 << 20).toString("base64");
    const sent = 30;
    for (let i = 0; i < sent; i += 1) {
      client.send(JSON.stringify({
        type: "input_audio_buffer.append",
        event_id: `target-backpressure-${i}`,
        audio: chunk,
      }));
    }

    const congestionDeadline = Date.now() + 5_000;
    while ((!relayDownstream?.isPaused || relayUpstream?.bufferedAmount <= 1024)
        && Date.now() < congestionDeadline) {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.equal(relayDownstream?.isPaused, true, "the source should be backpressured");
    assert.ok(relayUpstream.bufferedAmount > 1024, "the upstream target must be congested");

    // More than two complete heartbeat sweeps: the buggy bridge always closed here.
    await new Promise((resolve) => setTimeout(resolve, 400));
    assert.equal(client.readyState, WebSocket.OPEN, "the healthy client must remain open");
    assert.equal(relayUpstream.readyState, WebSocket.OPEN, "the congested upstream must remain open");

    congestedSocket._socket.resume();
    const expected = sent + 1;
    const drainDeadline = Date.now() + 15_000;
    while (receivedByUpstream.length < expected && Date.now() < drainDeadline) {
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    assert.equal(receivedByUpstream.length, expected, "every queued audio frame must drain");
  } finally {
    congestedSocket?._socket.resume();
    client.terminate();
    for (const socket of relayWSS.clients) socket.terminate();
    for (const socket of upstreamWSS.clients) socket.terminate();
    relayWSS.close();
    upstreamWSS.close();
    await close(relayServer);
    await close(upstreamServer);
  }
});

test("a target that stops draining is reaped after the backpressure progress deadline", async () => {
  const upstreamServer = http.createServer();
  const upstreamWSS = new WebSocketServer({
    server: upstreamServer,
    maxPayload: baseConfig.maxWebSocketPayloadBytes,
  });
  let frozenSocket;
  upstreamWSS.on("connection", (socket) => {
    frozenSocket = socket;
    // Complete the WebSocket handshake, then model a half-open peer whose TCP receive
    // side never advances again. No pong can get ahead of the already queued audio.
    socket._socket.pause();
  });
  const upstreamPort = await listen(upstreamServer);

  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({
    server: relayServer,
    maxPayload: baseConfig.maxWebSocketPayloadBytes,
  });
  let relayDownstream;
  let relayUpstream;
  relayWSS.on("connection", (downstream) => {
    relayDownstream = downstream;
    relayUpstream = bridgeRealtime(downstream, {
      ...baseConfig,
      openAIRealtimeURL: `ws://127.0.0.1:${upstreamPort}/v1/realtime`,
      maxForwardBufferBytes: 1024,
      clientHeartbeatIntervalMs: 80,
      backpressureStallTimeoutMs: 250,
    });
  });
  const relayPort = await listen(relayServer);
  const client = new WebSocket(`ws://127.0.0.1:${relayPort}`);

  try {
    await new Promise((resolve, reject) => {
      client.once("open", resolve);
      client.once("error", reject);
    });
    // Register before creating congestion. With the deliberately short watchdog the
    // relay can correctly close while the fixture is still proving that it paused;
    // attaching afterwards turns that success into a missed-event timeout.
    const clientClosed = new Promise((resolve) => {
      client.once("close", () => resolve(true));
    });
    const upstreamOpenDeadline = Date.now() + 5_000;
    while ((relayUpstream?.readyState !== WebSocket.OPEN || !frozenSocket)
        && Date.now() < upstreamOpenDeadline) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.equal(relayUpstream?.readyState, WebSocket.OPEN);

    client.send(JSON.stringify({
      type: "session.update",
      session: {
        type: "transcription",
        audio: {
          input: {
            format: { type: "audio/pcm", rate: 24_000 },
            transcription: { model: "gpt-live-transcribe", delay: "low" },
            turn_detection: null,
          },
        },
      },
    }));
    const chunk = Buffer.alloc(1 << 20).toString("base64");
    for (let i = 0; i < 30; i += 1) {
      client.send(JSON.stringify({
        type: "input_audio_buffer.append",
        event_id: `frozen-target-${i}`,
        audio: chunk,
      }));
    }

    const congestionDeadline = Date.now() + 5_000;
    while ((!relayDownstream?.isPaused || relayUpstream?.bufferedAmount <= 1024)
        && Date.now() < congestionDeadline) {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.equal(relayDownstream?.isPaused, true, "the fixture must reach target backpressure");

    let closeDeadline;
    const closeTimedOut = new Promise((resolve) => {
      closeDeadline = setTimeout(() => resolve(false), 2_000);
    });
    const closed = client.readyState === WebSocket.CLOSED
      ? true
      : await Promise.race([clientClosed, closeTimedOut]);
    clearTimeout(closeDeadline);
    assert.equal(closed, true, "a frozen target must not retain the bridge indefinitely");
  } finally {
    frozenSocket?._socket.resume();
    client.terminate();
    for (const socket of relayWSS.clients) socket.terminate();
    for (const socket of upstreamWSS.clients) socket.terminate();
    relayWSS.close();
    upstreamWSS.close();
    await close(relayServer);
    await close(upstreamServer);
  }
});

test("a silently dead OpenAI upstream tears the client down instead of looking ready", async () => {
  // The failure this prevents: relay->OpenAI dies without a close frame while
  // Mac->relay is fine, so the app keeps showing "ready" and the next sentence the
  // user speaks is written into a corpse.
  const upstreamServer = http.createServer();
  const upstreamWSS = new WebSocketServer({ server: upstreamServer });
  upstreamWSS.on("connection", (socket) => {
    // Answer the handshake, then go silent: never pong again.
    socket.on("ping", () => {});
    socket._receiver?.removeAllListeners("ping");
    socket.pong = () => {};
  });
  const upstreamPort = await listen(upstreamServer);

  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({ server: relayServer });
  relayWSS.on("connection", (downstream) => {
    bridgeRealtime(downstream, {
      ...baseConfig,
      openAIRealtimeURL: `ws://127.0.0.1:${upstreamPort}/v1/realtime`,
      clientHeartbeatIntervalMs: 60,
    });
  });
  const relayPort = await listen(relayServer);

  const client = new WebSocket(`ws://127.0.0.1:${relayPort}`);
  try {
    await new Promise((resolve, reject) => {
      client.once("open", resolve);
      client.once("error", reject);
    });

    const clientClosed = await new Promise((resolve) => {
      client.once("close", () => resolve(true));
      setTimeout(() => resolve(false), 2_000);
    });
    assert.equal(
      clientClosed,
      true,
      "the client must be disconnected so it reconnects before the user speaks",
    );
  } finally {
    client.terminate();
    for (const socket of relayWSS.clients) socket.terminate();
    for (const socket of upstreamWSS.clients) socket.terminate();
    relayWSS.close();
    upstreamWSS.close();
    await close(relayServer);
    await close(upstreamServer);
  }
});

test("a slow upstream throttles the client instead of dropping the utterance", async () => {
  const receivedBytes = [];
  const upstreamServer = http.createServer();
  const upstreamWSS = new WebSocketServer({
    server: upstreamServer,
    maxPayload: baseConfig.maxWebSocketPayloadBytes,
  });
  upstreamWSS.on("connection", (socket) => {
    socket.on("message", (data) => {
      receivedBytes.push(data.length);
      const event = data.length < 4096
        ? JSON.parse(data.toString("utf8"))
        : { type: "input_audio_buffer.append" };
      if (event.type === "session.update") {
        socket.send(JSON.stringify({ type: "session.updated" }));
      }
    });
  });
  const upstreamPort = await listen(upstreamServer);

  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({
    server: relayServer,
    maxPayload: baseConfig.maxWebSocketPayloadBytes,
  });
  relayWSS.on("connection", (downstream) => {
    bridgeRealtime(downstream, {
      ...baseConfig,
      openAIRealtimeURL: `ws://127.0.0.1:${upstreamPort}/v1/realtime`,
      // Far below one frame, so every single append trips the high-water mark. The
      // old code closed the socket here; the utterance must survive instead.
      maxForwardBufferBytes: 1024,
    });
  });
  const relayPort = await listen(relayServer);

  const client = new WebSocket(`ws://127.0.0.1:${relayPort}`);
  const closes = [];
  client.on("close", (code) => closes.push(code));

  try {
    await new Promise((resolve, reject) => {
      client.once("open", resolve);
      client.once("error", reject);
    });

    // Audio only ever follows `session.updated`, which cannot arrive before the
    // relay's upstream socket is open. Sending appends any earlier would pile them
    // into the pre-open queue and hit a different limit than the one under test.
    client.send(JSON.stringify({
      type: "session.update",
      session: {
        type: "transcription",
        audio: {
          input: {
            format: { type: "audio/pcm", rate: 24_000 },
            transcription: { model: "gpt-live-transcribe", delay: "low" },
            turn_detection: null,
          },
        },
      },
    }));
    assert.deepEqual(await onceMessage(client), { type: "session.updated" });

    // Same shape as the queued-utterance flush: back-to-back appends, each one the
    // app's 1 MiB raw-PCM chunk inflated by base64.
    const chunk = Buffer.alloc(1 << 20).toString("base64");
    const sent = 12;
    for (let i = 0; i < sent; i += 1) {
      client.send(JSON.stringify({
        type: "input_audio_buffer.append",
        event_id: `whisper-turn-1-${i}`,
        audio: chunk,
      }));
    }
    client.send(JSON.stringify({
      type: "input_audio_buffer.commit",
      event_id: "whisper-turn-1-commit",
    }));

    const expected = sent + 2; // the session.update, every append, and the commit
    const deadline = Date.now() + 15_000;
    while (receivedBytes.length < expected && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 50));
    }

    assert.deepEqual(closes, [], "the relay must not close a merely-backed-up client");
    assert.equal(
      receivedBytes.length,
      expected,
      "every append and the commit must reach upstream",
    );
  } finally {
    client.terminate();
    for (const socket of relayWSS.clients) socket.terminate();
    for (const socket of upstreamWSS.clients) socket.terminate();
    relayWSS.close();
    upstreamWSS.close();
    await close(relayServer);
    await close(upstreamServer);
  }
});

test("a turn still being answered is not cut off by the silence watchdog", async () => {
  // The watchdog exists for a turn the provider never answers. As an absolute deadline
  // it also killed turns that *were* being answered: a long sentence whose first final
  // segment lands after the timeout was completed as an empty transcript, the turn was
  // cleared, and the real final arrived to find nothing to attach to — the app then
  // deleted the text it had already typed live and the sentence was lost outright.
  const upstreamServer = http.createServer();
  const upstreamWSS = new WebSocketServer({ server: upstreamServer });
  upstreamWSS.on("connection", (socket) => {
    socket.on("message", (data) => {
      const event = JSON.parse(data.toString("utf8"));
      if (event.setup) {
        socket.send(JSON.stringify({ setupComplete: {} }));
        return;
      }
      if (!event.realtimeInput?.activityEnd) return;
      // Answer slowly, in the shape a long sentence produces: interim only for well
      // past the watchdog's window, then the final.
      const send = (object) => {
        if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(object));
      };
      setTimeout(() => send({
        serverContent: { interimInputTranscription: { text: "好" } },
      }), 80);
      setTimeout(() => send({
        serverContent: { interimInputTranscription: { text: "好，现在" } },
      }), 160);
      setTimeout(() => send({
        serverContent: { interimInputTranscription: { text: "好，现在测试" } },
      }), 240);
      setTimeout(() => send({
        serverContent: {
          inputTranscription: { text: "好，现在测试一下效果。" },
          generationComplete: true,
        },
      }), 320);
    });
  });
  const upstreamPort = await listen(upstreamServer);

  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({ server: relayServer });
  relayWSS.on("connection", (downstream) => {
    bridgeGeminiRealtime(downstream, {
      ...baseConfig,
      geminiLiveURL: `ws://127.0.0.1:${upstreamPort}/live`,
      geminiSilentTurnTimeoutMs: 150,
      geminiFinalFallbackDelayMs: 30_000,
    });
  });
  const relayPort = await listen(relayServer);
  const client = new WebSocket(`ws://127.0.0.1:${relayPort}`);
  const downstreamEvents = [];
  client.on("message", (data) => {
    downstreamEvents.push(JSON.parse(data.toString("utf8")));
  });
  const completed = () => downstreamEvents.filter(
    (event) => event.type === "conversation.item.input_audio_transcription.completed",
  );

  try {
    await new Promise((resolve, reject) => {
      client.once("open", resolve);
      client.once("error", reject);
    });
    client.send(JSON.stringify(geminiSessionUpdate("whisper-session-1")));
    assert.ok(await waitUntil(
      () => downstreamEvents.some((event) => event.type === "session.updated"),
    ));

    client.send(JSON.stringify({
      type: "input_audio_buffer.clear",
      event_id: "whisper-turn-1-1",
    }));
    client.send(JSON.stringify({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-1-2",
      audio: Buffer.alloc(960, 7).toString("base64"),
    }));
    client.send(JSON.stringify({
      type: "input_audio_buffer.commit",
      event_id: "whisper-turn-1-3",
    }));

    assert.ok(await waitUntil(() => completed().length === 1));
    assert.equal(
      completed()[0].transcript, "好，现在测试一下效果。",
      "the sentence must survive a response that outlasts the watchdog window",
    );
    assert.equal(completed().length, 1, "and must be delivered exactly once");
  } finally {
    client.close();
    await close(relayServer);
    await close(upstreamServer);
  }
});

test("a short locally quiet turn Gemini never answers ends quietly", async () => {
  // An accidental tap of the trigger key sends a fraction of a second of room tone.
  // Gemini answers such a turn with nothing at all — no interim, no generationComplete
  // — so the relay's own deadline is the only thing that ends it. Reporting that as an
  // error charged the user a full spinner and a message about a service that did
  // nothing wrong. It is now an empty transcript, which puts the app back to idle,
  // still carrying the session replacement the uncertain boundary requires.
  const upstreamServer = http.createServer();
  const upstreamWSS = new WebSocketServer({ server: upstreamServer });
  upstreamWSS.on("connection", (socket) => {
    socket.on("message", (data) => {
      const event = JSON.parse(data.toString("utf8"));
      if (event.setup) socket.send(JSON.stringify({ setupComplete: {} }));
      // Everything else is met with silence, which is the case under test.
    });
  });
  const upstreamPort = await listen(upstreamServer);

  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({ server: relayServer });
  relayWSS.on("connection", (downstream) => {
    bridgeGeminiRealtime(downstream, {
      ...baseConfig,
      geminiLiveURL: `ws://127.0.0.1:${upstreamPort}/live`,
      geminiSilentTurnTimeoutMs: 5_000,
      geminiShortTurnTimeoutMs: 150,
      geminiFinalFallbackDelayMs: 30_000,
    });
  });
  const relayPort = await listen(relayServer);
  const client = new WebSocket(`ws://127.0.0.1:${relayPort}`);
  const downstreamEvents = [];
  let clientClose = null;
  client.on("close", (code) => { clientClose = code; });
  client.on("message", (data) => {
    downstreamEvents.push(JSON.parse(data.toString("utf8")));
  });
  const completed = () => downstreamEvents.filter(
    (event) => event.type === "conversation.item.input_audio_transcription.completed",
  );

  try {
    await new Promise((resolve, reject) => {
      client.once("open", resolve);
      client.once("error", reject);
    });
    client.send(JSON.stringify(geminiSessionUpdate("whisper-session-1")));
    assert.ok(await waitUntil(
      () => downstreamEvents.some((event) => event.type === "session.updated"),
    ));

    client.send(JSON.stringify({
      type: "input_audio_buffer.clear",
      event_id: "whisper-turn-1-1",
    }));
    client.send(JSON.stringify({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-1-2",
      // 0.3 s at 48 bytes per millisecond: audio really was sent, so this is not the
      // captured-nothing path. Its zero-valued PCM also proves local quiet.
      audio: Buffer.alloc(14_400, 0).toString("base64"),
    }));
    client.send(JSON.stringify({
      type: "input_audio_buffer.commit",
      event_id: "whisper-turn-1-3",
    }));

    const started = Date.now();
    assert.ok(await waitUntil(() => completed().length === 1));
    assert.equal(completed()[0].transcript, "");
    assert.equal(
      completed()[0].session_replacement_required, true,
      "the boundary is still uncertain, so the provider session must be retired",
    );
    assert.ok(
      !downstreamEvents.some((event) => event.type === "error"),
      "an accidental tap is not a failure and must not be reported as one",
    );
    assert.ok(await waitUntil(() => clientClose === 1012));
    assert.ok(
      Date.now() - started < 5_000,
      "and it must not wait out the deadline meant for turns that carried speech",
    );
  } finally {
    client.close();
    await close(relayServer);
    await close(upstreamServer);
  }
});

test("a short spoken turn is not completed empty at the quiet-tap deadline", async () => {
  const upstreamServer = http.createServer();
  const upstreamWSS = new WebSocketServer({ server: upstreamServer });
  upstreamWSS.on("connection", (socket) => {
    socket.on("message", (data) => {
      const event = JSON.parse(data.toString("utf8"));
      if (event.setup) {
        socket.send(JSON.stringify({ setupComplete: {} }));
        return;
      }
      if (!event.realtimeInput?.activityEnd) return;
      setTimeout(() => {
        if (socket.readyState === WebSocket.OPEN) {
          socket.send(JSON.stringify({
            serverContent: {
              inputTranscription: { text: "好的" },
              generationComplete: true,
            },
          }));
        }
      }, 100);
    });
  });
  const upstreamPort = await listen(upstreamServer);

  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({ server: relayServer });
  relayWSS.on("connection", (downstream) => {
    bridgeGeminiRealtime(downstream, {
      ...baseConfig,
      geminiLiveURL: `ws://127.0.0.1:${upstreamPort}/live`,
      geminiSilentTurnTimeoutMs: 300,
      geminiShortTurnTimeoutMs: 40,
      geminiFinalFallbackDelayMs: 30_000,
    });
  });
  const relayPort = await listen(relayServer);
  const client = new WebSocket(`ws://127.0.0.1:${relayPort}`);
  const downstreamEvents = [];
  client.on("message", (data) => {
    downstreamEvents.push(JSON.parse(data.toString("utf8")));
  });

  try {
    await new Promise((resolve, reject) => {
      client.once("open", resolve);
      client.once("error", reject);
    });
    client.send(JSON.stringify(geminiSessionUpdate("whisper-session-1")));
    assert.ok(await waitUntil(
      () => downstreamEvents.some((event) => event.type === "session.updated"),
    ));
    client.send(JSON.stringify({
      type: "input_audio_buffer.clear",
      event_id: "whisper-turn-1-1",
    }));
    client.send(JSON.stringify({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-1-2",
      audio: pcm16Tone(300).toString("base64"),
    }));
    client.send(JSON.stringify({
      type: "input_audio_buffer.commit",
      event_id: "whisper-turn-1-3",
    }));

    const started = Date.now();
    assert.ok(await waitUntil(() => downstreamEvents.some(
      (event) => event.type === "conversation.item.input_audio_transcription.completed",
    )));
    const completed = downstreamEvents.find(
      (event) => event.type === "conversation.item.input_audio_transcription.completed",
    );
    assert.equal(completed.transcript, "好的");
    assert.ok(
      Date.now() - started >= 80,
      "speech energy must keep the quiet-tap deadline from completing the turn empty",
    );
    assert.ok(!downstreamEvents.some((event) => event.type === "error"));
  } finally {
    client.close();
    await close(relayServer);
    await close(upstreamServer);
  }
});

test("an interim from a short quiet turn is preserved if Gemini never finalizes it", async () => {
  const upstreamServer = http.createServer();
  const upstreamWSS = new WebSocketServer({ server: upstreamServer });
  upstreamWSS.on("connection", (socket) => {
    socket.on("message", (data) => {
      const event = JSON.parse(data.toString("utf8"));
      if (event.setup) {
        socket.send(JSON.stringify({ setupComplete: {} }));
        return;
      }
      if (!event.realtimeInput?.activityEnd) return;
      setTimeout(() => {
        if (socket.readyState === WebSocket.OPEN) {
          socket.send(JSON.stringify({
            serverContent: { interimInputTranscription: { text: "帮我提醒一下" } },
          }));
        }
      }, 20);
    });
  });
  const upstreamPort = await listen(upstreamServer);

  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({ server: relayServer });
  const turnEvents = [];
  relayWSS.on("connection", (downstream) => {
    bridgeGeminiRealtime(downstream, {
      ...baseConfig,
      geminiLiveURL: `ws://127.0.0.1:${upstreamPort}/live`,
      geminiSilentTurnTimeoutMs: 140,
      geminiShortTurnTimeoutMs: 40,
      geminiFinalFallbackDelayMs: 30_000,
    }, { onTurn: (event) => turnEvents.push(event) });
  });
  const relayPort = await listen(relayServer);
  const client = new WebSocket(`ws://127.0.0.1:${relayPort}`);
  const downstreamEvents = [];
  client.on("message", (data) => {
    downstreamEvents.push(JSON.parse(data.toString("utf8")));
  });

  try {
    await new Promise((resolve, reject) => {
      client.once("open", resolve);
      client.once("error", reject);
    });
    client.send(JSON.stringify(geminiSessionUpdate("whisper-session-1")));
    assert.ok(await waitUntil(
      () => downstreamEvents.some((event) => event.type === "session.updated"),
    ));
    client.send(JSON.stringify({
      type: "input_audio_buffer.clear",
      event_id: "whisper-turn-1-1",
    }));
    client.send(JSON.stringify({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-1-2",
      // Keep local audio quiet so the provider's interim is the only speech evidence.
      audio: Buffer.alloc(14_400, 0).toString("base64"),
    }));
    const started = Date.now();
    client.send(JSON.stringify({
      type: "input_audio_buffer.commit",
      event_id: "whisper-turn-1-3",
    }));

    assert.ok(await waitUntil(() => downstreamEvents.some(
      (event) => event.type === "conversation.item.input_audio_transcription.completed",
    )));
    const completed = downstreamEvents.find(
      (event) => event.type === "conversation.item.input_audio_transcription.completed",
    );
    assert.equal(completed.transcript, "帮我提醒一下");
    assert.equal(completed.session_replacement_required, true);
    assert.ok(!downstreamEvents.some((event) => event.type === "error"));
    assert.ok(
      Date.now() - started >= 100,
      "provider speech evidence must replace the quiet-tap deadline with the full one",
    );
    assert.equal(turnEvents.find((event) => event.event === "end")?.outcome, "partial_fallback");
  } finally {
    client.close();
    await close(relayServer);
    await close(upstreamServer);
  }
});

test("audio sent before the provider finishes setup is delivered, not refused", async () => {
  // The pre-open queue exists so a client that does not wait for `session.created`
  // keeps its sentence. Replaying it the moment the upstream socket opened defeated
  // that: `setupComplete` had not arrived yet, so every queued audio event hit the
  // not-ready gate and closed the connection the queue was protecting.
  const upstreamEvents = [];
  const upstreamServer = http.createServer();
  const upstreamWSS = new WebSocketServer({ server: upstreamServer });
  upstreamWSS.on("connection", (socket) => {
    socket.on("message", (data) => {
      const event = JSON.parse(data.toString("utf8"));
      if (event.setup) {
        // Deliberately slow, so the client's audio arrives while the provider socket
        // is open but not yet configured.
        setTimeout(() => {
          if (socket.readyState === WebSocket.OPEN) {
            socket.send(JSON.stringify({ setupComplete: {} }));
          }
        }, 120);
        return;
      }
      upstreamEvents.push(event);
      if (event.realtimeInput?.activityEnd) {
        socket.send(JSON.stringify({
          serverContent: {
            inputTranscription: { text: "队列里的句子" },
            generationComplete: true,
          },
        }));
      }
    });
  });
  const upstreamPort = await listen(upstreamServer);

  const relayServer = http.createServer();
  const relayWSS = new WebSocketServer({ server: relayServer });
  relayWSS.on("connection", (downstream) => {
    bridgeGeminiRealtime(downstream, {
      ...baseConfig,
      geminiLiveURL: `ws://127.0.0.1:${upstreamPort}/live`,
    });
  });
  const relayPort = await listen(relayServer);
  const client = new WebSocket(`ws://127.0.0.1:${relayPort}`);
  const downstreamEvents = [];
  let clientClose = null;
  client.on("close", (code) => { clientClose = code; });
  client.on("message", (data) => {
    downstreamEvents.push(JSON.parse(data.toString("utf8")));
  });
  const completed = () => downstreamEvents.filter(
    (event) => event.type === "conversation.item.input_audio_transcription.completed",
  );

  try {
    await new Promise((resolve, reject) => {
      client.once("open", resolve);
      client.once("error", reject);
    });
    // Everything at once, without waiting for `session.updated`.
    client.send(JSON.stringify(geminiSessionUpdate("whisper-session-1")));
    client.send(JSON.stringify({
      type: "input_audio_buffer.clear",
      event_id: "whisper-turn-1-1",
    }));
    client.send(JSON.stringify({
      type: "input_audio_buffer.append",
      event_id: "whisper-turn-1-2",
      audio: Buffer.alloc(960, 3).toString("base64"),
    }));
    client.send(JSON.stringify({
      type: "input_audio_buffer.commit",
      event_id: "whisper-turn-1-3",
    }));

    assert.ok(await waitUntil(() => completed().length === 1));
    assert.equal(completed()[0].transcript, "队列里的句子");
    assert.deepEqual(
      upstreamEvents.map((event) => Object.keys(event.realtimeInput)[0]),
      ["activityStart", "audio", "activityEnd"],
      "the queued turn reaches the provider in order once setup completes",
    );
    assert.equal(clientClose, null, "and the queue never costs the connection");
  } finally {
    client.close();
    await close(relayServer);
    await close(upstreamServer);
  }
});
