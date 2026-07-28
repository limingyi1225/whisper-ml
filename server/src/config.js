/// The Mac app buffers at most 610 s of 24 kHz PCM16 mono (48 000 B/s) while
/// disconnected mid-utterance and flushes it in one burst on reconnect. Every relay
/// ceiling that a single utterance can hit is derived from that number rather than
/// picked as a round power of two, so raising the client buffer cannot silently start
/// tripping a server limit.
const CLIENT_MAX_TURN_AUDIO_BYTES = 48_000 * 610;
/// Base64 inflates the wire size by 4/3.
const CLIENT_MAX_TURN_WIRE_BYTES = Math.ceil(CLIENT_MAX_TURN_AUDIO_BYTES / 3) * 4;

const DEFAULTS = Object.freeze({
  // Loopback by default: an unproxied relay binding every interface exposes an
  // endpoint backed by a real OpenAI key. Containers set HOST=0.0.0.0 explicitly.
  host: "127.0.0.1",
  port: 8787,
  basePath: "",
  maxWebSocketPayloadBytes: 2 * 1024 * 1024,
  maxPreopenQueueBytes: 64 * 1024,
  // Backpressure high-water mark, not a hard ceiling: crossing it pauses the reader
  // instead of closing the socket, so this only has to be a few messages deep.
  maxForwardBufferBytes: 8 * 1024 * 1024,
  maxTurnAudioBytes: CLIENT_MAX_TURN_AUDIO_BYTES + 4 * 1024 * 1024,
  maxPolishBodyBytes: 128 * 1024,
  maxPolishResponseBytes: 1024 * 1024,
  maxPolishRequestsPerMinute: 30,
  // Generous ceiling on a *tidy-up* reply. The app's entire 610 s audio buffer
  // transcribes to well under this, so hitting it means something is wrong rather
  // than that a real sentence was too long.
  maxPolishCompletionTokens: 8192,
  maxConnectionsPerDevice: 2,
  // Per-device caps bound one leaked token; they do nothing about ten honest people
  // all dictating at once. Each bridge can hold `maxForwardBufferBytes` queued in each
  // direction, so the arithmetic that matters is buffers × bridges against a 1 vCPU /
  // 2 GB box: 24 × 8 MiB × 2 is ~380 MiB worst case, which fits with room to spare.
  // Steady state is far below that — an idle warm socket costs almost nothing — so this
  // is a backstop against everyone flushing a long queued utterance simultaneously,
  // not a limit anyone should meet in normal use.
  maxTotalConnections: 24,
  openAIRequestTimeoutMs: 11_000,
  // Two missed sweeps' worth of silence. The app pings every 20 s, so a client that
  // is merely idle always answers well inside this.
  clientHeartbeatIntervalMs: 25_000,
});

export { CLIENT_MAX_TURN_AUDIO_BYTES, CLIENT_MAX_TURN_WIRE_BYTES };

function required(env, name) {
  const value = env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function positiveInteger(env, name, fallback) {
  const raw = env[name]?.trim();
  if (!raw) return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return value;
}

/// The Mac app addresses the relay at `<base>/v1/...`, so a relay published under a
/// path prefix only works if something strips it. Rather than depend on the reverse
/// proxy being configured with the right trailing slash — a mistake that shows up as a
/// bare 404 with nothing in the logs — the relay strips a configured prefix itself and
/// accepts the path either way.
function normalizeBasePath(raw) {
  const trimmed = (raw || "").trim();
  if (!trimmed || trimmed === "/") return "";
  const withLeadingSlash = trimmed.startsWith("/") ? trimmed : `/${trimmed}`;
  return withLeadingSlash.replace(/\/+$/, "");
}

/// Validated at load, not at first use. `new WebSocket(badURL)` throws synchronously
/// from inside the upgrade handler, which is an uncaught exception that takes the whole
/// process down — and it happens on the first user connection, long after `/healthz`
/// has told the deploy script everything is fine. Failing at startup instead means a
/// bad URL can never pass a health check.
function endpointURL(env, name, fallback, allowedProtocols) {
  const raw = env[name]?.trim() || fallback;
  let url;
  try {
    url = new URL(raw);
  } catch {
    throw new Error(`${name} must be a valid URL`);
  }
  if (!allowedProtocols.includes(url.protocol)) {
    throw new Error(`${name} must use one of: ${allowedProtocols.join(", ")}`);
  }
  return raw;
}

function commaSeparatedSet(raw) {
  return new Set(
    raw
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean),
  );
}

export function loadConfig(env = process.env) {
  const deviceTokenHashes = commaSeparatedSet(
    required(env, "RELAY_DEVICE_TOKEN_HASHES").toLowerCase(),
  );
  for (const hash of deviceTokenHashes) {
    if (!/^[a-f0-9]{64}$/.test(hash)) {
      throw new Error("RELAY_DEVICE_TOKEN_HASHES must contain SHA-256 hex hashes");
    }
  }

  return Object.freeze({
    host: env.HOST?.trim() || DEFAULTS.host,
    port: positiveInteger(env, "PORT", DEFAULTS.port),
    basePath: normalizeBasePath(env.RELAY_BASE_PATH) || DEFAULTS.basePath,
    openAIAPIKey: required(env, "OPENAI_API_KEY"),
    openAIRealtimeURL: endpointURL(
      env,
      "OPENAI_REALTIME_URL",
      "wss://api.openai.com/v1/realtime?intent=transcription",
      ["wss:", "ws:"],
    ),
    openAIPolishURL: endpointURL(
      env,
      "OPENAI_POLISH_URL",
      "https://api.openai.com/v1/chat/completions",
      ["https:", "http:"],
    ),
    deviceTokenHashes,
    allowedTranscriptionModels: commaSeparatedSet(
      env.ALLOWED_TRANSCRIPTION_MODELS
      || "gpt-realtime-whisper,gpt-4o-transcribe,gpt-4o-mini-transcribe",
    ),
    allowedPolishModels: commaSeparatedSet(
      env.ALLOWED_POLISH_MODELS || "gpt-5.6-terra",
    ),
    maxWebSocketPayloadBytes: positiveInteger(
      env,
      "MAX_WEBSOCKET_PAYLOAD_BYTES",
      DEFAULTS.maxWebSocketPayloadBytes,
    ),
    maxPreopenQueueBytes: positiveInteger(
      env,
      "MAX_PREOPEN_QUEUE_BYTES",
      DEFAULTS.maxPreopenQueueBytes,
    ),
    maxForwardBufferBytes: positiveInteger(
      env,
      "MAX_FORWARD_BUFFER_BYTES",
      DEFAULTS.maxForwardBufferBytes,
    ),
    maxTurnAudioBytes: positiveInteger(
      env,
      "MAX_TURN_AUDIO_BYTES",
      DEFAULTS.maxTurnAudioBytes,
    ),
    maxPolishBodyBytes: positiveInteger(
      env,
      "MAX_POLISH_BODY_BYTES",
      DEFAULTS.maxPolishBodyBytes,
    ),
    maxPolishResponseBytes: positiveInteger(
      env,
      "MAX_POLISH_RESPONSE_BYTES",
      DEFAULTS.maxPolishResponseBytes,
    ),
    maxPolishRequestsPerMinute: positiveInteger(
      env,
      "MAX_POLISH_REQUESTS_PER_MINUTE",
      DEFAULTS.maxPolishRequestsPerMinute,
    ),
    maxPolishCompletionTokens: positiveInteger(
      env,
      "MAX_POLISH_COMPLETION_TOKENS",
      DEFAULTS.maxPolishCompletionTokens,
    ),
    maxConnectionsPerDevice: positiveInteger(
      env,
      "MAX_CONNECTIONS_PER_DEVICE",
      DEFAULTS.maxConnectionsPerDevice,
    ),
    maxTotalConnections: positiveInteger(
      env,
      "MAX_TOTAL_CONNECTIONS",
      DEFAULTS.maxTotalConnections,
    ),
    openAIRequestTimeoutMs: positiveInteger(
      env,
      "OPENAI_REQUEST_TIMEOUT_MS",
      DEFAULTS.openAIRequestTimeoutMs,
    ),
    clientHeartbeatIntervalMs: positiveInteger(
      env,
      "CLIENT_HEARTBEAT_INTERVAL_MS",
      DEFAULTS.clientHeartbeatIntervalMs,
    ),
  });
}
