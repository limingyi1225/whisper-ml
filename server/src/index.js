import http from "node:http";
import { chmodSync, mkdirSync, rmSync } from "node:fs";
import { dirname } from "node:path";
import { WebSocketServer } from "ws";

import { authenticateRequest } from "./auth.js";
import {
  auditConnectionEnd,
  auditDeviceID,
  connectionMetadata,
} from "./connection-audit.js";
import { allowlistDigest, loadConfig, loadDeviceTokenHashes } from "./config.js";
import {
  EnrollmentRegistry,
  handleEnrollment,
  handleEnrollmentAdmin,
} from "./enrollment.js";
import { errorBody, routePath, writeJSON } from "./http.js";
import { handlePolish } from "./polish.js";
import {
  admitConnection,
  DailyUsageLimiter,
  FixedWindowRateLimiter,
} from "./rate-limit.js";
import { bridgeRealtime, revokeDownstream } from "./realtime.js";

const config = loadConfig();
const enrollmentRegistry = config.enrollmentRegistryFile
  ? new EnrollmentRegistry(config.enrollmentRegistryFile)
  : null;

/// Mutable copy of the allowlist, so a token can be issued or revoked without a restart.
///
/// Restarting drops every open WebSocket, and the app treats that as a failed utterance:
/// handing a build to one new person would have cost everyone else mid-sentence the
/// sentence they were speaking. `systemctl reload` sends SIGHUP instead.
let legacyTokenHashes = new Set(config.deviceTokenHashes);
if (enrollmentRegistry) {
  const enrollmentHashes = enrollmentRegistry.allTokenHashes();
  for (const hash of legacyTokenHashes) {
    if (enrollmentHashes.has(hash)) {
      throw new Error("a device token cannot belong to both legacy and enrollment auth");
    }
  }
}
let deviceTokenHashes = combinedTokenHashes();

function combinedTokenHashes() {
  return new Set([
    ...legacyTokenHashes,
    ...(enrollmentRegistry?.activeTokenHashes() || []),
  ]);
}

function applyAuthorization(nextLegacy = legacyTokenHashes) {
  legacyTokenHashes = nextLegacy;
  const next = combinedTokenHashes();
  deviceTokenHashes = next;

  let revoked = 0;
  for (const [socket, session] of downstreamSockets) {
    if (next.has(session.deviceID)) continue;
    revoked += 1;
    // Not a bare close(): stop forwarding immediately, and take the paid upstream
    // session with it rather than waiting for the WebSocket close handshake.
    revokeDownstream(socket, { upstream: session.upstream });
  }

  let abortedRequests = 0;
  for (const { deviceID, abort } of inflightPolish) {
    if (next.has(deviceID)) continue;
    abortedRequests += 1;
    abort();
  }
  return { next, revoked, abortedRequests };
}

process.on("SIGHUP", () => {
  if (!config.deviceTokenFile) {
    process.stderr.write("SIGHUP ignored: no RELAY_DEVICE_TOKEN_FILE configured\n");
    return;
  }
  try {
    const nextLegacy = loadDeviceTokenHashes(process.env, null, {
      allowIntentionalEmpty: enrollmentRegistry !== null,
    });
    const enrollmentHashes = enrollmentRegistry?.allTokenHashes() || new Set();
    if ([...nextLegacy].some((hash) => enrollmentHashes.has(hash))) {
      throw new Error("a device token cannot belong to both legacy and enrollment auth");
    }
    // Swapped only after a clean parse. A half-written or truncated file must leave the
    // running allowlist alone rather than locking every device out until someone
    // notices — the failure mode of "reload" should never be worse than not reloading.
    // Swapping the list is not revocation. A device is authenticated once, during the
    // upgrade, and the app then holds that socket for the life of the session — so
    // without this a revoked person keeps transcribing until their session happens to
    // refresh, which is up to half an hour away. Close theirs and only theirs; leaving
    // everyone else connected is the entire reason this is a reload and not a restart.
    const { next, revoked, abortedRequests } = applyAuthorization(nextLegacy);
    process.stdout.write(
      `reloaded allowlist: ${next.size} device tokens, ${revoked} connection(s) `
      + `and ${abortedRequests} in-flight request(s) revoked\n`,
    );
  } catch (error) {
    process.stderr.write(
      `SIGHUP reload rejected, keeping ${deviceTokenHashes.size} tokens: ${error.message}\n`,
    );
  }
});
const polishRateLimiter = new FixedWindowRateLimiter(
  config.maxPolishRequestsPerMinute,
);
const enrollmentRateLimiter = new FixedWindowRateLimiter(
  config.maxEnrollmentAttemptsPerMinute,
  60_000,
  2_000,
);
const transcriptionDailyUsage = new DailyUsageLimiter(
  config.maxTranscriptionBytesPerDevicePerDay,
  config.maxTotalTranscriptionBytesPerDay,
);
const polishDailyUsage = new DailyUsageLimiter(
  config.maxPolishRequestsPerDevicePerDay,
  config.maxTotalPolishRequestsPerDay,
);
const activeConnections = new Map();
/// socket → { deviceID, upstream }: the device hash it authenticated as, so a reload
/// can tell whose connection to drop, and its OpenAI-side socket, so revoking kills
/// the paid session too instead of letting buffered audio drain for another 5 s.
const downstreamSockets = new Map();
/// In-flight `/v1/polish` requests that have already reached OpenAI, as
/// `{ deviceID, abort }`. The pre-fetch authorisation re-check cannot help these: once
/// the upstream request is open, the only things that could end it were the client
/// hanging up and the 11 s timeout, so a device revoked mid-request still received a
/// completed, billed answer. A reload aborts the ones it just cut off.
const inflightPolish = new Set();

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url || "/", "http://relay.invalid");
  const pathname = routePath(url, config.basePath);
  if (request.method === "GET" && pathname === "/healthz") {
    // `tokens` and `allowlist` are how the issue/revoke scripts confirm a SIGHUP
    // actually landed — without them "reload" is a command with no observable result.
    // The count alone was not enough: counts collide, and a reload the server *rejected*
    // (keeping its old set) can report the same number the new file would have, which
    // let a script bless a token that was never loaded. The digest identifies the list
    // itself. Neither discloses anything usable — the hashes are not replayable.
    writeJSON(response, 200, {
      ok: true,
      tokens: deviceTokenHashes.size,
      allowlist: allowlistDigest(deviceTokenHashes),
      legacyTokens: legacyTokenHashes.size,
      legacyAllowlist: allowlistDigest(legacyTokenHashes),
      enrolledTokens: enrollmentRegistry?.activeTokenHashes().size || 0,
      enrollment: enrollmentRegistry !== null,
    });
    return;
  }

  if (request.method === "POST" && pathname === "/v1/enroll" && enrollmentRegistry) {
    try {
      await handleEnrollment(request, response, {
        registry: enrollmentRegistry,
        rateLimiter: enrollmentRateLimiter,
        onAuthorizationChanged: () => applyAuthorization(),
        // An enrollment identity must not alias a legacy credential. Otherwise
        // revoking either source would appear successful while the same hash remained
        // authorised by the other source.
        isTokenHashReserved: (hash) => legacyTokenHashes.has(hash),
      });
    } catch (error) {
      process.stderr.write(`enrollment handler failed: ${error.stack || error.message}\n`);
      if (!response.headersSent) {
        writeJSON(response, 500, errorBody("激活服务内部错误", "enrollment_internal_error"));
      } else if (!response.writableEnded) {
        response.end();
      }
    }
    return;
  }

  if (request.method !== "POST" || pathname !== "/v1/polish") {
    writeJSON(response, 404, errorBody("not found", "relay_not_found"));
    return;
  }

  const deviceID = authenticateRequest(request, deviceTokenHashes);
  if (!deviceID) {
    writeJSON(
      response,
      401,
      errorBody("转发服务器设备 Token 无效或没有权限", "relay_unauthorized"),
      { "www-authenticate": "Bearer" },
    );
    return;
  }

  // Same reasoning as the upgrade handler below, and the same cost if it is missing:
  // an async listener that rejects is an unhandled rejection, which Node turns into a
  // process exit — one malformed cleanup request would drop every open dictation
  // session on the box. No live throw path today; this is the missing half of a
  // symmetry, not a repair.
  try {
    await handlePolish(request, response, {
      config,
      deviceID,
      rateLimiter: polishRateLimiter,
      // Authentication above ran when the *headers* arrived. A slow POST can span a
      // revocation — opened while authorised, body finished after — and would then
      // spend the server's OpenAI key for a device that has just been cut off. The
      // closure reads the live set, so polish re-checks right before paying.
      stillAuthorized: () => deviceTokenHashes.has(deviceID),
      // And for the part that is already paying: a reload aborts these.
      registerAbort: (abort) => {
        const entry = { deviceID, abort };
        inflightPolish.add(entry);
        return () => inflightPolish.delete(entry);
      },
      takeDailyQuota: () => polishDailyUsage.take(deviceID),
    });
  } catch (error) {
    process.stderr.write(`polish handler failed: ${error.stack || error.message}\n`);
    if (!response.headersSent) {
      writeJSON(response, 500, errorBody("转发服务器内部错误", "relay_internal_error"));
    } else if (!response.writableEnded) {
      response.end();
    }
  }
});

const webSocketServer = new WebSocketServer({
  noServer: true,
  maxPayload: config.maxWebSocketPayloadBytes,
  perMessageDeflate: false,
});

server.on("upgrade", (request, socket, head) => {
  const url = new URL(request.url || "/", "http://relay.invalid");
  if (routePath(url, config.basePath) !== "/v1/realtime"
      || url.searchParams.get("intent") !== "transcription") {
    socket.end("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
    return;
  }

  const deviceID = authenticateRequest(request, deviceTokenHashes);
  if (!deviceID) {
    socket.end(
      "HTTP/1.1 401 Unauthorized\r\n"
      + "WWW-Authenticate: Bearer\r\n"
      + "Connection: close\r\n\r\n",
    );
    return;
  }

  const active = activeConnections.get(deviceID) || 0;
  const metadata = connectionMetadata(request.headers);
  const auditID = auditDeviceID(deviceID);
  // `downstreamSockets.size`, not a sum over the per-device map: it is the set the
  // close handlers maintain, so it cannot drift out of step with what is really open.
  const refusal = admitConnection({
    openForDevice: active,
    openTotal: downstreamSockets.size,
    config,
  });
  if (refusal) {
    process.stderr.write(
      "realtime connection rejected"
      + ` reason=${refusal}`
      + ` device=${auditID}`
      + ` client=${metadata.client}`
      + ` version=${metadata.version}`
      + ` connection=${metadata.connectionID}`
      + ` device_open=${active}`
      + ` device_limit=${config.maxConnectionsPerDevice}`
      + ` total_open=${downstreamSockets.size}`
      + ` total_limit=${config.maxTotalConnections}\n`,
    );
    socket.end("HTTP/1.1 429 Too Many Requests\r\nConnection: close\r\n\r\n");
    return;
  }

  webSocketServer.handleUpgrade(request, socket, head, (downstream) => {
    // Count only completed WebSocket handshakes. A malformed or partially forwarded
    // upgrade never reaches this callback; counting it earlier would permanently use
    // one of the device's slots because there is no downstream close event to release.
    activeConnections.set(deviceID, active + 1);
    const connectedAt = Date.now();
    const session = {
      deviceID,
      upstream: null,
      ...metadata,
      connectedAt,
      end: "unsettled",
    };
    downstreamSockets.set(downstream, session);
    process.stdout.write(
      "realtime connection admitted"
      + ` device=${auditID}`
      + ` client=${metadata.client}`
      + ` version=${metadata.version}`
      + ` connection=${metadata.connectionID}`
      + ` device_open=${active + 1}`
      + ` total_open=${downstreamSockets.size}\n`,
    );
    let counted = true;
    const release = (closeCode = 1011, end = session.end) => {
      downstreamSockets.delete(downstream);
      if (!counted) return;
      counted = false;
      const count = activeConnections.get(deviceID) || 1;
      if (count <= 1) activeConnections.delete(deviceID);
      else activeConnections.set(deviceID, count - 1);
      process.stdout.write(
        "realtime connection released"
        + ` device=${auditID}`
        + ` client=${metadata.client}`
        + ` version=${metadata.version}`
        + ` connection=${metadata.connectionID}`
        + ` close_code=${Number.isInteger(closeCode) ? closeCode : 1011}`
        + ` end=${end}`
        + ` age_ms=${Math.max(0, Date.now() - connectedAt)}`
        + ` device_open=${Math.max(0, count - 1)}`
        + ` total_open=${downstreamSockets.size}\n`,
      );
    };
    // Only `close` releases the slot, because only `close` means the socket is gone.
    //
    // `ws` answers a protocol error with `close()`, not `destroy()`: the socket enters
    // CLOSING and sits there until the peer's FIN or a ~30 s close timer. A normal
    // client closes its write half automatically on receiving our FIN, which ends it in
    // about a millisecond and hides this completely — but a raw socket opened with
    // `allowHalfOpen: true` simply declines to, and measured, the gap is then 30 001 ms.
    // Releasing on `error` therefore freed the slot while the connection was still very
    // much alive, and "connect, send one illegal frame, never answer" in a loop walked
    // straight past both the per-device and the total ceiling. Measured with ten such
    // rounds: releasing on `error` left 10 live uncounted sockets, this leaves 0.
    downstream.once("error", () => downstream.terminate());
    // Belt and braces behind the URL validation in config: anything thrown here would
    // otherwise be an uncaught exception inside an event handler, i.e. the whole relay
    // dies and every other user's session goes with it. One bad connection should cost
    // one connection.
    try {
      session.upstream = bridgeRealtime(downstream, config, {
        consumeAudio: (bytes) => transcriptionDailyUsage.take(deviceID, bytes),
        onEnd: (reason) => { session.end = auditConnectionEnd(reason); },
      });
      // Register after the bridge's own close listener. It assigns the controlled
      // internal reason first; this listener then releases the counted slot and logs
      // that reason instead of the peer's arbitrary close-frame text.
      downstream.once("close", (code) => release(code));
    } catch (error) {
      process.stderr.write(`bridge failed to start: ${error.message}\n`);
      downstream.close(1011, "relay could not reach OpenAI");
      release(1011, "bridge-start-failed");
    }
  });
});

server.listen(config.port, config.host, () => {
  process.stdout.write(
    `Whisper Relay listening on http://${config.host}:${config.port}\n`,
  );
});

let adminServer = null;
if (enrollmentRegistry) {
  // The public reverse proxy only reaches the TCP listener above. This second server
  // exists solely on a mode-0600 Unix socket created inside systemd's RuntimeDirectory,
  // so issuing or revoking access never becomes a bearer-secret admin endpoint on the
  // internet.
  mkdirSync(dirname(config.adminSocketPath), { recursive: true, mode: 0o700 });
  rmSync(config.adminSocketPath, { force: true });
  adminServer = http.createServer((request, response) => {
    void handleEnrollmentAdmin(request, response, {
      registry: enrollmentRegistry,
      onAuthorizationChanged: () => applyAuthorization(),
    }).catch((error) => {
      process.stderr.write(`enrollment admin failed: ${error.stack || error.message}\n`);
      if (!response.headersSent) {
        writeJSON(response, 500, errorBody("internal error", "admin_internal_error"));
      } else if (!response.writableEnded) {
        response.end();
      }
    });
  });
  adminServer.listen(config.adminSocketPath, () => {
    chmodSync(config.adminSocketPath, 0o600);
    process.stdout.write(`Whisper enrollment admin listening on ${config.adminSocketPath}\n`);
  });
}

let shuttingDown = false;
function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  // A normal close handshake keeps `message` listeners alive while CLOSING. Stop the
  // paid paths synchronously during a deploy too; otherwise a peer that delays its FIN
  // can keep forwarding audio until systemd's kill timeout expires.
  for (const [socket, session] of downstreamSockets) {
    revokeDownstream(socket, {
      upstream: session.upstream,
      closeCode: 1012,
      closeReason: "server restarting",
    });
  }
  for (const { abort } of inflightPolish) abort();
  adminServer?.close();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 10_000).unref();
}

process.once("SIGTERM", shutdown);
process.once("SIGINT", shutdown);
