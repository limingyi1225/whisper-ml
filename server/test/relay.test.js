import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { authenticateRequest, tokenDigest } from "../src/auth.js";
import {
  allowlistDigest,
  CLIENT_MAX_TURN_AUDIO_BYTES,
  EMPTY_LEGACY_ALLOWLIST_SENTINEL,
  loadConfig,
  loadDeviceTokenHashes,
} from "../src/config.js";
import {
  createInviteCode,
  enrollmentClientAddress,
  EnrollmentRegistry,
  normalizeInviteCode,
} from "../src/enrollment.js";
import { routePath } from "../src/http.js";
import { validatePolishBody } from "../src/polish.js";
import { classifyRelaySmoke } from "../../script/relay_smoke_verdict.mjs";
import {
  admitConnection,
  DailyUsageLimiter,
  FixedWindowRateLimiter,
} from "../src/rate-limit.js";
import { clientEventID, safeCloseCode, validateRealtimeEvent } from "../src/realtime.js";

const token = "relay_test-device-token";
const baseEnv = {
  OPENAI_API_KEY: "test-openai-key",
  RELAY_DEVICE_TOKEN_HASHES: tokenDigest(token),
};

test("deploy mutations share the flock owner's SSH connection and fail closed", () => {
  const script = readFileSync(
    new URL("../../script/deploy_relay.sh", import.meta.url),
    "utf8",
  );

  // The primary session is both the ControlMaster and the remote fd-8 flock owner.
  // Every later remote command must be a multiplexed channel on that same transport,
  // with fallback disabled if the owner/connection disappears.
  assert.match(script, /ssh -M -S "\$REMOTE_LOCK_TEMP\/control"/);
  assert.match(script, /exec 8>\$DEPLOY_LOCK_FILE[\s\S]*flock -n 8/);
  assert.match(
    script,
    /remote_ssh\(\)[\s\S]*ssh -S "\$REMOTE_LOCK_TEMP\/control"[\s\S]*-o ProxyCommand=false/,
  );

  const mutableTransaction = script.slice(script.indexOf("acquire_remote_lock\n"));
  const unlockedCommands = mutableTransaction
    .split("\n")
    .filter((line) => !line.trimStart().startsWith("#"))
    .filter((line) => !line.trimStart().startsWith("echo "))
    .filter((line) => /\bssh\s+"\$HOST"/.test(line));
  assert.deepEqual(unlockedCommands, []);

  // Only a real remote `test` false (1) means this deploy created the token file.
  // Transport 255 and lost-lease 74 must enter rollback without setting the flag,
  // otherwise rollback can delete the pre-existing production allowlist.
  const tokenProbe = script.slice(
    script.indexOf('if remote_ssh "[ -s $TOKEN_FILE ]"'),
    script.indexOf("# The allowlist has to live somewhere"),
  );
  assert.match(tokenProbe, /TOKEN_FILE_STATUS=\$\?/);
  assert.match(tokenProbe, /if \[ "\$TOKEN_FILE_STATUS" -eq 1 \]/);
  assert.ok(tokenProbe.indexOf("-eq 1") < tokenProbe.indexOf("CREATED_TOKEN_FILE=1"));
  assert.match(tokenProbe, /else[\s\S]*false/);
});

test("deploy polish smoke separates bad artifacts from transient upstream failures", () => {
  const deployScript = readFileSync(
    new URL("../../script/deploy_relay.sh", import.meta.url),
    "utf8",
  );
  assert.match(deployScript, /SMOKE_ALL_SAME_ROLLBACK=1/);
  assert.match(
    deployScript,
    /\[ "\$SMOKE_ROLLBACK_REASON" != "\$SMOKE_REASON" \][\s\S]*SMOKE_ALL_SAME_ROLLBACK=0/,
  );
  assert.match(
    deployScript,
    /\[ "\$SMOKE_FINAL_VERDICT" = rollback \][\s\S]*\[ "\$SMOKE_ALL_SAME_ROLLBACK" -eq 1 \][\s\S]*false/,
  );

  const valid = JSON.stringify({
    choices: [{ message: { content: "部署冒烟测试" } }],
  });
  assert.deepEqual(
    classifyRelaySmoke("200", valid),
    { verdict: "pass", reason: "client-contract" },
  );
  assert.equal(classifyRelaySmoke("200", "<html>edge error</html>").verdict, "rollback");
  assert.equal(classifyRelaySmoke("200", JSON.stringify({ choices: [] })).verdict, "rollback");
  assert.deepEqual(
    classifyRelaySmoke("404", '{"error":{"code":"relay_not_found"}}'),
    { verdict: "rollback", reason: "http-404" },
  );
  assert.deepEqual(
    classifyRelaySmoke("404", "<html>nginx route missing</html>"),
    { verdict: "rollback", reason: "http-404" },
  );
  assert.equal(classifyRelaySmoke("401", '{"error":{"code":"relay_unauthorized"}}').verdict, "rollback");
  assert.equal(classifyRelaySmoke("424", '{"error":{"code":"relay_upstream_authentication"}}').verdict, "rollback");
  assert.equal(classifyRelaySmoke("500", '{"error":{"code":"relay_internal_error"}}').verdict, "rollback");
  assert.equal(classifyRelaySmoke("400", '{"error":{"code":"model_not_found"}}').verdict, "rollback");
  assert.equal(
    classifyRelaySmoke("400", '{"error":{"type":"invalid_request_error","code":null}}').verdict,
    "rollback",
  );
  assert.equal(classifyRelaySmoke("400", "<html>edge error</html>").verdict, "inconclusive");
  assert.equal(classifyRelaySmoke("400", "").verdict, "inconclusive");

  for (const status of ["000", "301", "403", "408", "425", "429", "502", "503", "504"]) {
    assert.equal(classifyRelaySmoke(status, "").verdict, "inconclusive");
  }
  // OpenAI's own 500 is forwarded as-is; only the relay's explicit internal-error body
  // proves the deployed handler failed.
  assert.equal(
    classifyRelaySmoke("500", '{"error":{"code":"server_error"}}').verdict,
    "inconclusive",
  );
});

test("configuration requires hashed device tokens", () => {
  assert.throws(
    () => loadConfig({ ...baseEnv, RELAY_DEVICE_TOKEN_HASHES: token }),
    /SHA-256/,
  );
});

test("enrollment configuration is either complete or disabled", () => {
  assert.equal(loadConfig(baseEnv).enrollmentRegistryFile, "");
  assert.throws(
    () => loadConfig({ ...baseEnv, RELAY_ENROLLMENT_REGISTRY_FILE: "/tmp/registry.json" }),
    /configured together/,
  );
  assert.throws(
    () => loadConfig({
      ...baseEnv,
      RELAY_ENROLLMENT_REGISTRY_FILE: "relative.json",
      RELAY_ADMIN_SOCKET: "/tmp/admin.sock",
    }),
    /must be absolute/,
  );
  const configured = loadConfig({
    ...baseEnv,
    RELAY_ENROLLMENT_REGISTRY_FILE: "/tmp/registry.json",
    RELAY_ADMIN_SOCKET: "/tmp/admin.sock",
  });
  assert.equal(configured.enrollmentRegistryFile, "/tmp/registry.json");
  assert.equal(configured.adminSocketPath, "/tmp/admin.sock");

  const directory = mkdtempSync(join(tmpdir(), "whisper-empty-legacy-"));
  const allowlist = join(directory, "device-tokens");
  writeFileSync(allowlist, `${EMPTY_LEGACY_ALLOWLIST_SENTINEL}\n`);
  const enrollmentEnv = {
    ...baseEnv,
    RELAY_DEVICE_TOKEN_FILE: allowlist,
    RELAY_ENROLLMENT_REGISTRY_FILE: join(directory, "registry.json"),
    RELAY_ADMIN_SOCKET: join(directory, "admin.sock"),
  };
  assert.equal(loadConfig(enrollmentEnv).deviceTokenHashes.size, 0);
  assert.throws(
    () => loadConfig({ ...baseEnv, RELAY_DEVICE_TOKEN_FILE: allowlist }),
    /only when enrollment is configured/,
  );
});

test("invite codes carry 128 bits and accept pasted formatting", () => {
  const code = createInviteCode(Buffer.from("00112233445566778899aabbccddeeff", "hex"));
  assert.equal(code, "WHISPER-00112233-44556677-8899AABB-CCDDEEFF");
  assert.equal(normalizeInviteCode(code.toLowerCase()), "WHISPER00112233445566778899AABBCCDDEEFF");
  assert.equal(normalizeInviteCode("not an invite"), null);
});

test("one-time invites persist only hashes and retry idempotently", () => {
  const directory = mkdtempSync(join(tmpdir(), "whisper-enrollment-"));
  const registryPath = join(directory, "registry.json");
  const registry = new EnrollmentRegistry(registryPath);
  const issued = registry.issueInvite("alice", new Date("2026-08-13T00:00:00Z"));
  assert.equal(issued.status, "ok");

  const aliceToken = `relay_${"a".repeat(43)}`;
  const first = registry.claim(
    issued.code,
    aliceToken,
    new Date("2026-08-13T00:01:00Z"),
  );
  assert.deepEqual(first, { status: "ok", changed: true, label: "alice" });
  assert.deepEqual([...registry.activeTokenHashes()], [tokenDigest(aliceToken)]);

  const persisted = readFileSync(registryPath, "utf8");
  assert.ok(!persisted.includes(issued.code));
  assert.ok(!persisted.includes(aliceToken));
  const reloaded = new EnrollmentRegistry(registryPath);
  assert.deepEqual(
    reloaded.claim(issued.code.toLowerCase(), aliceToken),
    { status: "ok", changed: false, label: "alice" },
  );
  assert.equal(reloaded.issueInvite("alice").status, "label_in_use");
  assert.equal(reloaded.issueInvite("ALICE").status, "label_in_use");
  assert.equal(reloaded.claim(issued.code, `relay_${"b".repeat(43)}`).status, "already_used");

  assert.deepEqual(
    reloaded.revokeLabel("ALICE", new Date("2026-08-13T00:02:00Z")),
    { status: "ok", devices: 1, invites: 0 },
  );
  assert.equal(reloaded.activeTokenHashes().size, 0);
  assert.equal(reloaded.claim(issued.code, aliceToken).status, "revoked");
  const replacement = reloaded.issueInvite("alice");
  assert.equal(replacement.status, "ok");
  assert.equal(reloaded.claim(replacement.code, aliceToken).status, "device_in_use");
  const legacyToken = `relay_${"d".repeat(43)}`;
  assert.equal(
    reloaded.claim(replacement.code, legacyToken, new Date(), {
      isTokenHashReserved: (hash) => hash === tokenDigest(legacyToken),
    }).status,
    "device_in_use",
  );
  assert.equal(
    reloaded.claim(replacement.code, `relay_${"c".repeat(43)}`).status,
    "ok",
  );
});

test("registry rejects inconsistent invite-device relationships", () => {
  const directory = mkdtempSync(join(tmpdir(), "whisper-enrollment-invalid-"));
  const originalPath = join(directory, "original.json");
  const registry = new EnrollmentRegistry(originalPath);
  const issued = registry.issueInvite("alice", new Date("2026-08-13T00:00:00.000Z"));
  registry.claim(
    issued.code,
    `relay_${"a".repeat(43)}`,
    new Date("2026-08-13T00:01:00.000Z"),
  );
  const original = JSON.parse(readFileSync(originalPath, "utf8"));

  const rejects = (name, mutate) => {
    const state = structuredClone(original);
    mutate(state);
    const path = join(directory, `${name}.json`);
    writeFileSync(path, JSON.stringify(state));
    assert.throws(() => new EnrollmentRegistry(path), /enrollment registry/);
  };
  rejects("mismatched-label", (state) => { state.devices[0].label = "bob"; });
  rejects("mismatched-time", (state) => {
    state.devices[0].enrolledAt = "2026-08-13T00:02:00.000Z";
  });
  rejects("claimed-and-cancelled", (state) => {
    state.invites[0].cancelledAt = "2026-08-13T00:02:00.000Z";
  });
  rejects("orphan-device", (state) => {
    state.invites[0].deviceTokenHash = null;
    state.invites[0].claimedAt = null;
  });
  rejects("unknown-field", (state) => { state.devices[0].secret = "surprise"; });
});

test("enrollment rate limiting ignores spoofed X-Forwarded-For prefixes", () => {
  const request = (peer, forwarded) => ({
    socket: { remoteAddress: peer },
    headers: forwarded === undefined ? {} : { "x-forwarded-for": forwarded },
  });
  assert.equal(
    enrollmentClientAddress(request("127.0.0.1", "spoofed, 203.0.113.9")),
    "203.0.113.9",
  );
  assert.equal(
    enrollmentClientAddress(request("::ffff:127.0.0.1", "198.51.100.3")),
    "198.51.100.3",
  );
  // A direct public peer cannot make the relay trust the forwarding header at all.
  assert.equal(
    enrollmentClientAddress(request("198.51.100.8", "203.0.113.99")),
    "198.51.100.8",
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
  assert.equal(config.maxTranscriptionBytesPerDevicePerDay, 48_000 * 7_200);
  assert.equal(config.maxTotalTranscriptionBytesPerDay, 48_000 * 43_200);
  assert.equal(config.maxPolishRequestsPerDevicePerDay, 1_000);
  assert.equal(config.maxTotalPolishRequestsPerDay, 6_000);

  const overridden = loadConfig({
    ...baseEnv,
    MAX_TRANSCRIPTION_SECONDS_PER_DEVICE_PER_DAY: "60",
    MAX_TOTAL_TRANSCRIPTION_SECONDS_PER_DAY: "120",
  });
  assert.equal(overridden.maxTranscriptionBytesPerDevicePerDay, 48_000 * 60);
  assert.equal(overridden.maxTotalTranscriptionBytesPerDay, 48_000 * 120);
  assert.throws(
    () => loadConfig({
      ...baseEnv,
      MAX_TRANSCRIPTION_SECONDS_PER_DEVICE_PER_DAY: String(Number.MAX_SAFE_INTEGER),
    }),
    /too large/,
  );
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
    model: "gpt-5.6-luna",
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
          transcription: { model: "gpt-live-transcribe", delay: "low" },
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

test("Realtime validation bounds the keywords list", () => {
  const config = loadConfig(baseEnv);
  const state = { turnAudioBytes: 0 };
  const withKeywords = (keywords) => Buffer.from(JSON.stringify({
    type: "session.update",
    event_id: "whisper-session-1",
    session: {
      type: "transcription",
      audio: {
        input: {
          format: { type: "audio/pcm", rate: 24_000 },
          transcription: { model: "gpt-live-transcribe", delay: "low", keywords },
          turn_detection: null,
        },
      },
    },
  }));

  assert.equal(validateRealtimeEvent(withKeywords(["李铭一", "Xcode"]), false, config, state), null);
  assert.equal(validateRealtimeEvent(withKeywords([]), false, config, state), null);
  assert.equal(
    validateRealtimeEvent(
      withKeywords(["李铭一", ...Array.from({ length: 100 }, (_, i) => `user-${i}`)]),
      false,
      config,
      state,
    ),
    null,
    "the app's built-in term must fit beside all 100 user terms",
  );

  // The caps are the point: without them an authenticated device could push arbitrary
  // text upstream through a field that merely looks like a word list.
  for (const bad of [
    Array.from({ length: 102 }, (_, i) => `t${i}`), // too many
    ["x".repeat(41)], // one term too long
    [""], // empty term
    ["has\nnewline"],
    ["angle <brackets>"],
    ["fine", 42], // not all strings
    "not-an-array",
  ]) {
    assert.match(
      validateRealtimeEvent(withKeywords(bad), false, config, state),
      /keywords list is not allowed/,
      `expected rejection for ${JSON.stringify(bad)}`,
    );
  }
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

test("the allowlist can be re-read from a file, and a bad file changes nothing", () => {
  // Issuing or revoking a token must not restart the relay — a restart closes every
  // socket and the app scores that as a failed utterance for everyone mid-sentence.
  const file = "/etc/whisper-relay/device-tokens";
  const a = tokenDigest("relay_a");
  const b = tokenDigest("relay_b");
  const env = { ...baseEnv, RELAY_DEVICE_TOKEN_FILE: file };

  const read = (contents) => (path) => {
    assert.equal(path, file);
    return contents;
  };
  assert.deepEqual(
    [...loadDeviceTokenHashes(env, read(`# issued to alice\n${a}\n${b}\n`))],
    [a, b],
  );
  // The env var is ignored entirely once a file is configured, so there is exactly one
  // source of truth to reason about.
  assert.deepEqual([...loadDeviceTokenHashes(env, read(`${a}\n`))], [a]);

  // Every rejection has to throw, because index.js keeps the previous set on throw. A
  // truncated or half-written file must never be able to lock everyone out.
  assert.throws(() => loadDeviceTokenHashes(env, read("")), /is empty/);
  assert.throws(() => loadDeviceTokenHashes(env, read("# only a comment\n")), /is empty/);
  assert.throws(() => loadDeviceTokenHashes(env, read(`${a}\nnot-a-hash\n`)), /SHA-256/);
  assert.throws(() => loadDeviceTokenHashes(env, read(`${a.slice(0, 40)}\n`)), /SHA-256/);
  assert.throws(
    () => loadDeviceTokenHashes(env, () => { throw new Error("ENOENT"); }),
    /ENOENT/,
  );

  // Revoking the last legacy identity needs a representable state, but a bare empty or
  // comment-only file must remain a rejected partial-write signal. Only enrollment
  // deployments accept this exact, standalone operator marker.
  assert.throws(
    () => loadDeviceTokenHashes(env, read(`${EMPTY_LEGACY_ALLOWLIST_SENTINEL}\n`)),
    /only when enrollment is configured/,
  );
  assert.deepEqual(
    [...loadDeviceTokenHashes(
      env,
      read(`${EMPTY_LEGACY_ALLOWLIST_SENTINEL}\n`),
      { allowIntentionalEmpty: true },
    )],
    [],
  );
  assert.throws(
    () => loadDeviceTokenHashes(
      env,
      read(`${EMPTY_LEGACY_ALLOWLIST_SENTINEL}\n${a}\n`),
      { allowIntentionalEmpty: true },
    ),
    /must be the only nonblank line/,
  );

  // No file configured: the static env list, exactly as before.
  assert.deepEqual(
    [...loadDeviceTokenHashes(baseEnv)],
    [tokenDigest(token)],
  );

  // The canonicalisation the issue/revoke scripts must mirror: lowercased before
  // parsing, and a Set, so a hash counts once no matter how it is written. A script
  // that counted or compared any other way would disagree with /healthz's number and
  // either bless a revoke that never happened or roll back one that did.
  assert.deepEqual(
    [...loadDeviceTokenHashes(env, read(`${a.toUpperCase()}\n${a}\n${b} # bob\n`))],
    [a, b],
  );
});

test("the issue/revoke scripts and the relay agree on the allowlist digest", () => {
  // /healthz reports this digest and both scripts verify a reload against it, so a
  // divergence between the two implementations would not fail loudly — it would make
  // every issue and revoke report failure and roll back, for a change that had in fact
  // landed. The shell half is duplicated here verbatim from the scripts rather than
  // described, so drift in either direction fails this test.
  const a = tokenDigest("relay_a");
  const b = tokenDigest("relay_b");
  const c = tokenDigest("relay_c");

  const dir = mkdtempSync(join(tmpdir(), "whisper-digest-"));
  const file = join(dir, "device-tokens");
  // Deliberately awkward: unsorted, a duplicate, mixed case, a comment, a comment-only
  // line, blank lines, trailing whitespace. All of it has to canonicalize identically.
  writeFileSync(
    file,
    `# issued to the team\n${c}\n\n${a.toUpperCase()}   \n${b} # bob\n${a}\n`,
  );

  const sha = process.platform === "darwin" ? "shasum -a 256" : "sha256sum";
  const shellDigest = execFileSync("bash", ["-c", `
    set -euo pipefail
    effective() { awk '{ sub(/#.*/, ""); gsub(/^[ \\t]+|[ \\t]+$/, ""); if (length) print tolower($0) }' "$1" | LC_ALL=C sort -u; }
    digest_of() { printf '%s' "$(effective "$1")" | ${sha} | cut -c1-16; }
    digest_of "$1"
  `, "bash", file]).toString().trim();

  const parsed = loadDeviceTokenHashes(
    { RELAY_DEVICE_TOKEN_FILE: file },
    () => `# issued to the team\n${c}\n\n${a.toUpperCase()}   \n${b} # bob\n${a}\n`,
  );
  assert.deepEqual([...parsed].sort(), [a, b, c].sort());
  assert.equal(allowlistDigest(parsed), shellDigest);

  // Order-independent and duplicate-insensitive, which is what makes it safe for the
  // scripts to compare a file they appended to against a Set the server built.
  assert.equal(allowlistDigest(new Set([c, a, b])), allowlistDigest(new Set([a, b, c])));
  // And it actually distinguishes lists — a digest that ignored a revocation would be
  // worse than the count it replaced.
  assert.notEqual(allowlistDigest(new Set([a, b])), allowlistDigest(new Set([a, b, c])));
  assert.match(allowlistDigest(new Set([a])), /^[a-f0-9]{16}$/);
});

test("a reload revokes the right sockets and leaves the rest connected", () => {
  // The bookkeeping index.js's SIGHUP handler performs. Authentication happens once, at
  // upgrade, and the app then holds that socket for the life of the session — so
  // swapping the allowlist without touching live sockets leaves a revoked person
  // transcribing until their session happens to refresh, up to half an hour later.
  const alice = tokenDigest("relay_alice");
  const bob = tokenDigest("relay_bob");
  const sockets = new Map([
    ["alice-1", { deviceID: alice, upstream: null }],
    ["alice-2", { deviceID: alice, upstream: null }],
    ["bob-1", { deviceID: bob, upstream: null }],
  ]);

  const next = new Set([bob]);           // alice revoked
  const dropped = [];
  for (const [socket, session] of sockets) {
    if (!next.has(session.deviceID)) dropped.push(socket);
  }
  assert.deepEqual(dropped, ["alice-1", "alice-2"]);

  // And the converse, which is the whole reason this is a reload rather than a restart:
  // issuing a token to someone new must disconnect nobody at all.
  const afterIssue = new Set([alice, bob, tokenDigest("relay_carol")]);
  const droppedByIssue = [...sockets]
    .filter(([, session]) => !afterIssue.has(session.deviceID))
    .map(([socket]) => socket);
  assert.deepEqual(droppedByIssue, []);
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

test("rate limiter refuses unbounded attacker keys", () => {
  const limiter = new FixedWindowRateLimiter(2, 100, 2);
  assert.equal(limiter.take("a", 0), true);
  assert.equal(limiter.take("b", 0), true);
  assert.equal(limiter.take("c", 1), false);
  assert.equal(limiter.take("c", 100), true);
});

test("daily usage checks device and total budgets atomically and resets by UTC day", () => {
  const limiter = new DailyUsageLimiter(5, 8, 2);
  assert.equal(limiter.take("alice", 5, 0), null);
  assert.equal(limiter.take("alice", 1, 1), "device");
  // The rejected unit above did not consume the global budget.
  assert.equal(limiter.take("bob", 3, 2), null);
  assert.equal(limiter.take("bob", 1, 3), "total");
  assert.equal(limiter.take("carol", 1, 4), "total");

  assert.equal(limiter.take("carol", 5, 86_400_000), null);
  assert.throws(() => limiter.take("carol", 0), /positive safe integer/);
});

test("reserved WebSocket close codes are not mirrored to the other peer", () => {
  assert.equal(safeCloseCode(1000), 1000);
  assert.equal(safeCloseCode(1013), 1013);
  assert.equal(safeCloseCode(4001), 4001);
  assert.equal(safeCloseCode(1005), 1011);
  assert.equal(safeCloseCode(1006), 1011);
});
