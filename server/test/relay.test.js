import assert from "node:assert/strict";
import test from "node:test";

import { authenticateRequest, tokenDigest } from "../src/auth.js";
import { CLIENT_MAX_TURN_AUDIO_BYTES, loadConfig } from "../src/config.js";
import { routePath } from "../src/http.js";
import { validatePolishBody } from "../src/polish.js";
import { admitConnection, FixedWindowRateLimiter } from "../src/rate-limit.js";
import { clientEventID, safeCloseCode, validateRealtimeEvent } from "../src/realtime.js";

const token = "relay_test-device-token";
const baseEnv = {
  OPENAI_API_KEY: "test-openai-key",
  RELAY_DEVICE_TOKEN_HASHES: tokenDigest(token),
};

test("configuration requires hashed device tokens", () => {
  assert.throws(
    () => loadConfig({ ...baseEnv, RELAY_DEVICE_TOKEN_HASHES: token }),
    /SHA-256/,
  );
});

test("a configured base path is accepted with or without the prefix", () => {
  const config = loadConfig({ ...baseEnv, RELAY_BASE_PATH: "/whisper-relay/" });
  assert.equal(config.basePath, "/whisper-relay");

  const at = (pathname) => routePath(new URL(pathname, "http://x"), config.basePath);
  // The app addresses <base>/v1/...; a prefix-stripping proxy delivers /v1/...
  assert.equal(at("/whisper-relay/v1/polish"), "/v1/polish");
  assert.equal(at("/v1/polish"), "/v1/polish");
  assert.equal(at("/whisper-relay/v1/realtime"), "/v1/realtime");
  assert.equal(at("/whisper-relay/healthz"), "/healthz");
  assert.equal(at("/whisper-relay"), "/");
  // A prefix that only looks like the base must not be stripped.
  assert.equal(at("/whisper-relay-evil/v1/polish"), "/whisper-relay-evil/v1/polish");

  const rootConfig = loadConfig(baseEnv);
  assert.equal(rootConfig.basePath, "");
  assert.equal(
    routePath(new URL("/v1/polish", "http://x"), rootConfig.basePath),
    "/v1/polish",
  );
});

test("defaults are loopback-bound and derived from the client's audio buffer", () => {
  const config = loadConfig(baseEnv);
  // An unproxied relay must not expose an OpenAI-key-backed endpoint on every
  // interface; the Dockerfile opts into 0.0.0.0 explicitly.
  assert.equal(config.host, "127.0.0.1");
  // The app can flush its whole 610 s buffer as one turn, so the ceiling has to sit
  // above that with room to spare rather than at a round power of two below it.
  assert.ok(config.maxTurnAudioBytes > CLIENT_MAX_TURN_AUDIO_BYTES);
});

test("a malformed upstream URL fails at startup, not on the first user connection", () => {
  // `new WebSocket(bad)` throws synchronously from inside the upgrade handler, which
  // would kill the whole process — after /healthz had already reported success.
  assert.throws(
    () => loadConfig({ ...baseEnv, OPENAI_REALTIME_URL: "not-a-url" }),
    /must be a valid URL/,
  );
  assert.throws(
    () => loadConfig({ ...baseEnv, OPENAI_REALTIME_URL: "https://api.openai.com/v1/realtime" }),
    /must use one of/,
  );
  assert.throws(
    () => loadConfig({ ...baseEnv, OPENAI_POLISH_URL: "wss://api.openai.com/v1/x" }),
    /must use one of/,
  );
  assert.equal(
    loadConfig({ ...baseEnv, OPENAI_REALTIME_URL: "ws://127.0.0.1:9/x" }).openAIRealtimeURL,
    "ws://127.0.0.1:9/x",
  );
});

test("Bearer authentication returns only the token hash", () => {
  const request = { headers: { authorization: `Bearer ${token}` } };
  const hash = tokenDigest(token);
  assert.equal(authenticateRequest(request, new Set([hash])), hash);
  assert.equal(
    authenticateRequest(
      { headers: { authorization: "Bearer wrong" } },
      new Set([hash]),
    ),
    null,
  );
});

test("polish requests are restricted to the allowlisted shape", () => {
  const config = loadConfig(baseEnv);
  const valid = {
    model: "gpt-5.6-terra",
    messages: [
      { role: "system", content: "tidy only" },
      { role: "user", content: "<transcript>hello</transcript>" },
    ],
    reasoning_effort: "none",
  };
  assert.equal(validatePolishBody(valid, config), null);
  assert.match(
    validatePolishBody({ ...valid, tools: [] }, config),
    /unsupported field/,
  );
  assert.match(
    validatePolishBody({ ...valid, model: "gpt-5.6-sol" }, config),
    /not allowed/,
  );
});

test("Realtime validation permits transcription but rejects arbitrary sessions", () => {
  const config = loadConfig(baseEnv);
  const state = { turnAudioBytes: 0 };
  const sessionUpdate = Buffer.from(JSON.stringify({
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
  assert.equal(validateRealtimeEvent(sessionUpdate, false, config, state), null);

  const forbidden = JSON.parse(sessionUpdate.toString("utf8"));
  forbidden.session.tools = [];
  assert.match(
    validateRealtimeEvent(
      Buffer.from(JSON.stringify(forbidden)),
      false,
      config,
      state,
    ),
    /unsupported field/,
  );
});

test("Realtime validation enforces cumulative audio per turn", () => {
  const config = {
    ...loadConfig(baseEnv),
    maxTurnAudioBytes: 3,
  };
  const state = { turnAudioBytes: 0 };
  const append = Buffer.from(JSON.stringify({
    type: "input_audio_buffer.append",
    event_id: "whisper-turn-1-2",
    audio: Buffer.from([1, 2, 3]).toString("base64"),
  }));
  assert.equal(validateRealtimeEvent(append, false, config, state), null);
  assert.match(
    validateRealtimeEvent(append, false, config, state),
    /exceeds/,
  );
});

test("the offending event_id is recovered where there is one to recover", () => {
  const of = (object) => clientEventID(Buffer.from(JSON.stringify(object)), false);
  assert.equal(of({ type: "input_audio_buffer.append", event_id: "whisper-turn-3-9" }), "whisper-turn-3-9");
  assert.equal(of({ type: "input_audio_buffer.commit" }), undefined);
  // Not a string, and absurdly long ids, are the same rejection the validator makes.
  assert.equal(of({ event_id: 7 }), undefined);
  assert.equal(of({ event_id: "x".repeat(161) }), undefined);
  // Nothing to recover from a frame that was rejected for not being parseable at all.
  assert.equal(clientEventID(Buffer.from("not json"), false), undefined);
  assert.equal(clientEventID(Buffer.from([0, 1, 2]), true), undefined);
});

test("ten people each hold their own slots, but not the whole box", () => {
  const config = loadConfig(baseEnv);
  // One warm socket per person, plus one transient during a reconnect. This is what
  // makes a token each the right shape: ten people sharing one token would be ten
  // connections on one device, and the third of them would be refused.
  assert.equal(config.maxConnectionsPerDevice, 2);
  assert.equal(admitConnection({ openForDevice: 1, openTotal: 9, config }), null);
  assert.equal(admitConnection({ openForDevice: 2, openTotal: 9, config }), "device");

  // The per-device cap alone cannot protect a 1 vCPU box: ten distinct devices all
  // pass it. Headroom for ten people at two slots each, and a wall after that.
  assert.ok(config.maxTotalConnections >= 10 * config.maxConnectionsPerDevice);
  assert.equal(
    admitConnection({ openForDevice: 0, openTotal: config.maxTotalConnections, config }),
    "total",
  );
  assert.equal(
    admitConnection({ openForDevice: 0, openTotal: config.maxTotalConnections - 1, config }),
    null,
  );
});

test("rate limiter resets at the next window", () => {
  const limiter = new FixedWindowRateLimiter(2, 100);
  assert.equal(limiter.take("device", 0), true);
  assert.equal(limiter.take("device", 1), true);
  assert.equal(limiter.take("device", 2), false);
  assert.equal(limiter.take("device", 100), true);
});

test("reserved WebSocket close codes are not mirrored to the other peer", () => {
  assert.equal(safeCloseCode(1000), 1000);
  assert.equal(safeCloseCode(1013), 1013);
  assert.equal(safeCloseCode(4001), 4001);
  assert.equal(safeCloseCode(1005), 1011);
  assert.equal(safeCloseCode(1006), 1011);
});
