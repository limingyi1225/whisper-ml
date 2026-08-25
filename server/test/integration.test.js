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
import { bridgeRealtime, revokeDownstream } from "../src/realtime.js";

const token = "relay_integration-device-token";
const baseConfig = loadConfig({
  OPENAI_API_KEY: "server-only-openai-key",
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

function close(server) {
  return new Promise((resolve) => server.close(resolve));
}

function onceMessage(socket) {
  return new Promise((resolve, reject) => {
    socket.once("message", (data) => resolve(JSON.parse(data.toString("utf8"))));
    socket.once("error", reject);
  });
}

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
