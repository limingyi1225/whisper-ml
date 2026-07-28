import http from "node:http";
import { WebSocketServer } from "ws";

import { authenticateRequest } from "./auth.js";
import { loadConfig } from "./config.js";
import { errorBody, routePath, writeJSON } from "./http.js";
import { handlePolish } from "./polish.js";
import { admitConnection, FixedWindowRateLimiter } from "./rate-limit.js";
import { bridgeRealtime } from "./realtime.js";

const config = loadConfig();
const polishRateLimiter = new FixedWindowRateLimiter(
  config.maxPolishRequestsPerMinute,
);
const activeConnections = new Map();
const downstreamSockets = new Set();

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url || "/", "http://relay.invalid");
  const pathname = routePath(url, config.basePath);
  if (request.method === "GET" && pathname === "/healthz") {
    writeJSON(response, 200, { ok: true });
    return;
  }

  if (request.method !== "POST" || pathname !== "/v1/polish") {
    writeJSON(response, 404, errorBody("not found", "relay_not_found"));
    return;
  }

  const deviceID = authenticateRequest(request, config.deviceTokenHashes);
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

  const deviceID = authenticateRequest(request, config.deviceTokenHashes);
  if (!deviceID) {
    socket.end(
      "HTTP/1.1 401 Unauthorized\r\n"
      + "WWW-Authenticate: Bearer\r\n"
      + "Connection: close\r\n\r\n",
    );
    return;
  }

  const active = activeConnections.get(deviceID) || 0;
  // `downstreamSockets.size`, not a sum over the per-device map: it is the set the
  // close handlers maintain, so it cannot drift out of step with what is really open.
  const refusal = admitConnection({
    openForDevice: active,
    openTotal: downstreamSockets.size,
    config,
  });
  if (refusal) {
    if (refusal === "total") {
      process.stderr.write(
        `refusing connection: ${downstreamSockets.size} already open\n`,
      );
    }
    socket.end("HTTP/1.1 429 Too Many Requests\r\nConnection: close\r\n\r\n");
    return;
  }

  webSocketServer.handleUpgrade(request, socket, head, (downstream) => {
    // Count only completed WebSocket handshakes. A malformed or partially forwarded
    // upgrade never reaches this callback; counting it earlier would permanently use
    // one of the device's slots because there is no downstream close event to release.
    activeConnections.set(deviceID, active + 1);
    downstreamSockets.add(downstream);
    let counted = true;
    const release = () => {
      downstreamSockets.delete(downstream);
      if (!counted) return;
      counted = false;
      const count = activeConnections.get(deviceID) || 1;
      if (count <= 1) activeConnections.delete(deviceID);
      else activeConnections.set(deviceID, count - 1);
    };
    downstream.once("close", release);
    downstream.once("error", release);
    // Belt and braces behind the URL validation in config: anything thrown here would
    // otherwise be an uncaught exception inside an event handler, i.e. the whole relay
    // dies and every other user's session goes with it. One bad connection should cost
    // one connection.
    try {
      bridgeRealtime(downstream, config);
    } catch (error) {
      process.stderr.write(`bridge failed to start: ${error.message}\n`);
      downstream.close(1011, "relay could not reach OpenAI");
      release();
    }
  });
});

server.listen(config.port, config.host, () => {
  process.stdout.write(
    `Whisper Relay listening on http://${config.host}:${config.port}\n`,
  );
});

function shutdown() {
  for (const socket of downstreamSockets) {
    socket.close(1012, "server restarting");
  }
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 10_000).unref();
}

process.once("SIGTERM", shutdown);
process.once("SIGINT", shutdown);
