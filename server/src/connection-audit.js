const KNOWN_CLIENTS = new Set(["whisper", "wink"]);
const SAFE_VERSION = /^[A-Za-z0-9._+-]{1,32}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function firstHeader(value) {
  if (Array.isArray(value)) return value[0];
  return typeof value === "string" ? value : undefined;
}

/// Client-provided values are audit hints, not authority. Keep only a tiny controlled
/// vocabulary before anything reaches journald: a malicious bearer token must not be
/// able to smuggle newlines, user text, or another unbounded value into server logs.
export function connectionMetadata(headers = {}) {
  const rawClient = firstHeader(headers["x-whisper-client"])?.toLowerCase();
  const rawVersion = firstHeader(headers["x-whisper-version"]);
  const rawConnectionID = firstHeader(headers["x-whisper-connection-id"]);
  return {
    client: KNOWN_CLIENTS.has(rawClient) ? rawClient : "unknown",
    version: SAFE_VERSION.test(rawVersion || "") ? rawVersion : "unknown",
    connectionID: UUID.test(rawConnectionID || "")
      ? rawConnectionID.toLowerCase()
      : "unknown",
  };
}

/// The authenticated identity is already a SHA-256 digest. A short prefix correlates
/// one device's lifecycle without printing the full allowlist value into routine logs.
export function auditDeviceID(deviceID) {
  return typeof deviceID === "string" && /^[0-9a-f]{64}$/i.test(deviceID)
    ? deviceID.slice(0, 12).toLowerCase()
    : "unknown";
}

/// Bridge reasons come from controlled server branches today. Validate them anyway so
/// a future refactor cannot accidentally pipe a peer-supplied close reason into logs.
export function auditConnectionEnd(value) {
  return typeof value === "string" && /^[a-z][a-z0-9 ]{0,63}$/.test(value)
    ? value.replaceAll(" ", "-")
    : "unknown";
}
