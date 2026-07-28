import http from "node:http";
import assert from "node:assert/strict";
import test from "node:test";
import WebSocket, { WebSocketServer } from "ws";

import { tokenDigest } from "../src/auth.js";
import { loadConfig } from "../src/config.js";
import { handlePolish } from "../src/polish.js";
import { FixedWindowRateLimiter } from "../src/rate-limit.js";
import { bridgeRealtime } from "../src/realtime.js";

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
  const upstream = http.createServer(async (request, response) => {
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
    });
  });
  const relayPort = await listen(relay);

  try {
    const body = {
      model: "gpt-5.6-terra",
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
        model: "gpt-5.6-terra",
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
            transcription: { model: "gpt-realtime-whisper", delay: "low" },
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
            transcription: { model: "gpt-realtime-whisper", delay: "low" },
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
  relayWSS.on("connection", (downstream) => {
    bridgeRealtime(downstream, {
      ...baseConfig,
      openAIRealtimeURL: `ws://127.0.0.1:${upstreamPort}/v1/realtime`,
      clientHeartbeatIntervalMs: 60,
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
            transcription: { model: "gpt-realtime-whisper", delay: "low" },
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
            transcription: { model: "gpt-realtime-whisper", delay: "low" },
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
