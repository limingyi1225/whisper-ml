import { pathToFileURL } from "node:url";

import WebSocket from "ws";

const AUTHENTICATION_DETAIL = /api[ _-]*key|authenticat|credential|forbidden|permission|unauthori[sz]ed/i;
const MODEL_DETAIL = /model.{0,40}(?:invalid|not found|unsupported)|(?:invalid|unsupported).{0,40}model/i;

export function classifyGeminiRelayEvent(event, { credentialUpdated = false } = {}) {
  if (event?.type === "session.updated") {
    return { verdict: "pass", reason: "gemini-setup-complete" };
  }
  if (event?.type !== "error") return null;

  const code = event.error?.code || "unknown-error";
  const detail = event.error?.message || "";
  if (AUTHENTICATION_DETAIL.test(detail)) {
    // A retained key can be revoked or lose permission independently of this deploy.
    // Rolling the source back cannot repair it and only causes a second relay-wide
    // restart. A key written by this transaction is different: restore_backup also
    // restores the old EnvironmentFile, so rejection is attributable and reversible.
    return credentialUpdated
      ? { verdict: "rollback", reason: "gemini-credential-rejected" }
      : { verdict: "inconclusive", reason: "gemini-retained-credential-rejected" };
  }
  if (MODEL_DETAIL.test(detail) || code === "relay_invalid_event") {
    return { verdict: "rollback", reason: "gemini-setup-rejected" };
  }
  // A provider outage, transient handshake failure, or quota response does not say the
  // uploaded artifact is bad. Report it, but do not add another relay-wide restart.
  return { verdict: "inconclusive", reason: code };
}

export function classifyGeminiSmokeHTTPStatus(status) {
  // The Relay itself uses 401 for a rejected device token, but that token comes from
  // this Mac's Keychain and can have been revoked before the deploy. Rolling source
  // back cannot restore mutable allowlist state. A public 403 can likewise be generated
  // by Cloudflare/nginx before the request reaches this build.
  if (status === 401) {
    return { verdict: "inconclusive", reason: "relay-device-token-rejected" };
  }
  if (status === 404) return { verdict: "rollback", reason: "http-404" };
  // The Relay's upgrade gate answers missing paths/providers with 404 and reports an
  // invalid session as a structured WebSocket error after upgrading. A handshake-level
  // 400 therefore came from the edge or this local probe; rolling remote source back
  // cannot repair either one.
  if (status === 400) {
    return { verdict: "inconclusive", reason: "edge-or-smoke-http-400" };
  }
  return { verdict: "inconclusive", reason: `edge-or-upstream-http-${status || "none"}` };
}

function webSocketURL(endpoint) {
  const url = new URL(endpoint);
  if (url.protocol === "https:") url.protocol = "wss:";
  else if (url.protocol === "http:") url.protocol = "ws:";
  if (url.protocol !== "wss:" && url.protocol !== "ws:") {
    throw new Error("Gemini smoke URL must use HTTP(S) or WS(S)");
  }
  return url.toString();
}

export function probeGeminiSetup(
  endpoint,
  token,
  { timeoutMs = 20_000, credentialUpdated = false } = {},
) {
  return new Promise((resolve) => {
    let socket;
    let settled = false;
    let timer;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(result);
      if (socket?.readyState === WebSocket.OPEN
          || socket?.readyState === WebSocket.CONNECTING) {
        socket.terminate();
      }
    };

    try {
      socket = new WebSocket(webSocketURL(endpoint), {
        handshakeTimeout: Math.min(timeoutMs, 10_000),
        headers: {
          authorization: `Bearer ${token}`,
          "x-whisper-client": "deploy-smoke",
          "x-whisper-version": "1",
        },
        perMessageDeflate: false,
      });
    } catch {
      // The endpoint is derived from the operator's local RELAY_PUBLIC_HEALTH value,
      // which rollback does not touch.
      finish({ verdict: "inconclusive", reason: "invalid-gemini-smoke-url" });
      return;
    }

    timer = setTimeout(() => {
      finish({ verdict: "inconclusive", reason: "gemini-setup-timeout" });
    }, timeoutMs);

    socket.on("open", () => {
      socket.send(JSON.stringify({
        type: "session.update",
        event_id: "deploy-gemini-setup-smoke",
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
    });
    socket.on("message", (data) => {
      let event;
      try { event = JSON.parse(data.toString("utf8")); } catch { return; }
      const result = classifyGeminiRelayEvent(event, { credentialUpdated });
      if (result) finish(result);
    });
    socket.on("unexpected-response", (_request, response) => {
      response.resume();
      finish(classifyGeminiSmokeHTTPStatus(response.statusCode));
    });
    socket.on("error", () => {
      finish({ verdict: "inconclusive", reason: "gemini-smoke-transport" });
    });
    socket.on("close", () => {
      finish({ verdict: "inconclusive", reason: "gemini-session-closed-before-setup" });
    });
  });
}

async function readStandardInput() {
  let value = "";
  process.stdin.setEncoding("utf8");
  for await (const chunk of process.stdin) value += chunk;
  return value.replace(/[\r\n]+$/, "");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const token = await readStandardInput();
  const endpoint = process.argv[2];
  const credentialUpdated = process.argv[3] === "updated";
  const result = !endpoint || !token
    ? { verdict: "rollback", reason: "gemini-smoke-input-missing" }
    : await probeGeminiSetup(endpoint, token, { credentialUpdated });
  process.stdout.write(`${result.verdict}\t${result.reason}\n`);
}
