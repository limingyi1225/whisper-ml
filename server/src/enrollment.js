import { randomBytes, randomUUID } from "node:crypto";
import {
  closeSync,
  existsSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname } from "node:path";

import { tokenDigest } from "./auth.js";
import { errorBody, readBody, writeJSON } from "./http.js";

const REGISTRY_VERSION = 1;
const MAX_BODY_BYTES = 8 * 1024;
const DEVICE_TOKEN = /^relay_[A-Za-z0-9_-]{40,80}$/;
const NORMALIZED_INVITE = /^WHISPER[0-9A-F]{32}$/;

export function normalizeInviteCode(value) {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toUpperCase().replace(/[\s-]/g, "");
  return NORMALIZED_INVITE.test(normalized) ? normalized : null;
}

export function createInviteCode(bytes = randomBytes(16)) {
  if (!Buffer.isBuffer(bytes) || bytes.length !== 16) {
    throw new Error("invite entropy must be exactly 16 bytes");
  }
  const hex = bytes.toString("hex").toUpperCase();
  return `WHISPER-${hex.match(/.{1,8}/g).join("-")}`;
}

function emptyState() {
  return { version: REGISTRY_VERSION, invites: [], devices: [] };
}

function isTimestamp(value) {
  if (typeof value !== "string") return false;
  try {
    return new Date(value).toISOString() === value;
  } catch {
    return false;
  }
}

function hasOnlyKeys(value, keys) {
  return value && typeof value === "object" && !Array.isArray(value)
    && Object.keys(value).length === keys.size
    && Object.keys(value).every((key) => keys.has(key));
}

function labelKey(value) {
  return value.toLowerCase();
}

function validateState(value) {
  if (!hasOnlyKeys(value, new Set(["version", "invites", "devices"]))
      || value.version !== REGISTRY_VERSION
      || !Array.isArray(value.invites) || !Array.isArray(value.devices)) {
    throw new Error("enrollment registry has an unsupported shape");
  }

  const inviteIDs = new Set();
  const inviteHashes = new Set();
  const pendingLabels = new Set();
  for (const invite of value.invites) {
    if (!hasOnlyKeys(invite, new Set([
      "id", "label", "inviteHash", "issuedAt", "claimedAt", "cancelledAt",
      "deviceTokenHash",
    ]))
        || typeof invite.id !== "string" || !invite.id
        || cleanLabel(invite.label) !== invite.label
        || !/^[a-f0-9]{64}$/.test(invite.inviteHash)
        || !isTimestamp(invite.issuedAt)
        || (invite.claimedAt !== null && !isTimestamp(invite.claimedAt))
        || (invite.cancelledAt !== null && !isTimestamp(invite.cancelledAt))
        || (invite.deviceTokenHash !== null
          && !/^[a-f0-9]{64}$/.test(invite.deviceTokenHash))) {
      throw new Error("enrollment registry contains an invalid invite");
    }
    if (inviteIDs.has(invite.id) || inviteHashes.has(invite.inviteHash)) {
      throw new Error("enrollment registry contains a duplicate invite");
    }
    if ((invite.claimedAt === null) !== (invite.deviceTokenHash === null)) {
      throw new Error("enrollment registry contains a partial invite claim");
    }
    if (invite.claimedAt !== null && invite.cancelledAt !== null) {
      throw new Error("enrollment registry contains a cancelled claimed invite");
    }
    if (invite.claimedAt === null && invite.cancelledAt === null) {
      const key = labelKey(invite.label);
      if (pendingLabels.has(key)) {
        throw new Error("enrollment registry contains duplicate pending identities");
      }
      pendingLabels.add(key);
    }
    inviteIDs.add(invite.id);
    inviteHashes.add(invite.inviteHash);
  }

  const deviceIDs = new Set();
  const deviceHashes = new Set();
  const activeLabels = new Set();
  const devicesByHash = new Map();
  for (const device of value.devices) {
    if (!hasOnlyKeys(device, new Set([
      "id", "label", "tokenHash", "enrolledAt", "revokedAt",
    ]))
        || typeof device.id !== "string" || !device.id
        || cleanLabel(device.label) !== device.label
        || !/^[a-f0-9]{64}$/.test(device.tokenHash)
        || !isTimestamp(device.enrolledAt)
        || (device.revokedAt !== null && !isTimestamp(device.revokedAt))) {
      throw new Error("enrollment registry contains an invalid device");
    }
    if (deviceIDs.has(device.id) || deviceHashes.has(device.tokenHash)) {
      throw new Error("enrollment registry contains a duplicate device");
    }
    if (device.revokedAt === null) {
      const key = labelKey(device.label);
      if (activeLabels.has(key)) {
        throw new Error("enrollment registry contains duplicate active identities");
      }
      activeLabels.add(key);
    }
    deviceIDs.add(device.id);
    deviceHashes.add(device.tokenHash);
    devicesByHash.set(device.tokenHash, device);
  }

  const referencedDevices = new Set();
  for (const invite of value.invites) {
    if (invite.deviceTokenHash === null) continue;
    const device = devicesByHash.get(invite.deviceTokenHash);
    if (!device || device.label !== invite.label || device.enrolledAt !== invite.claimedAt) {
      throw new Error("enrollment registry invite points at a mismatched device");
    }
    if (referencedDevices.has(device.tokenHash)) {
      throw new Error("enrollment registry contains duplicate device references");
    }
    referencedDevices.add(device.tokenHash);
  }
  if (referencedDevices.size !== deviceHashes.size) {
    throw new Error("enrollment registry contains an orphan device");
  }
  return value;
}

function cleanLabel(value) {
  if (typeof value !== "string") return null;
  const label = value.trim();
  if (!label || label.length > 80 || /[\u0000-\u001f\u007f]/.test(label)) return null;
  return label;
}

/// Persistent one-time invites and the device-token hashes they authorised.
///
/// Only this process writes the file: public claims and the root-only Unix admin socket
/// both arrive on the same event loop. Each mutation is written to a temporary file and
/// renamed before it becomes live, so a crash leaves either the old complete registry
/// or the new complete one — never a consumed invite without its device identity.
export class EnrollmentRegistry {
  constructor(path) {
    if (typeof path !== "string" || !path.startsWith("/")) {
      throw new Error("enrollment registry path must be absolute");
    }
    this.path = path;
    this.state = existsSync(path)
      ? validateState(JSON.parse(readFileSync(path, "utf8")))
      : emptyState();
  }

  activeTokenHashes() {
    return new Set(
      this.state.devices
        .filter((device) => device.revokedAt === null)
        .map((device) => device.tokenHash),
    );
  }

  allTokenHashes() {
    return new Set(this.state.devices.map((device) => device.tokenHash));
  }

  issueInvite(rawLabel, now = new Date()) {
    const label = cleanLabel(rawLabel);
    if (!label) return { status: "invalid_label" };
    const key = labelKey(label);
    const alreadyActive = this.state.devices.some(
      (device) => labelKey(device.label) === key && device.revokedAt === null,
    );
    const alreadyPending = this.state.invites.some(
      (invite) => labelKey(invite.label) === key
        && invite.claimedAt === null
        && invite.cancelledAt === null,
    );
    if (alreadyActive || alreadyPending) return { status: "label_in_use" };

    const code = createInviteCode();
    const inviteHash = tokenDigest(normalizeInviteCode(code));
    const next = structuredClone(this.state);
    next.invites.push({
      id: randomUUID(),
      label,
      inviteHash,
      issuedAt: now.toISOString(),
      claimedAt: null,
      cancelledAt: null,
      deviceTokenHash: null,
    });
    this.persist(next);
    return { status: "ok", code, label };
  }

  claim(
    rawCode,
    deviceToken,
    now = new Date(),
    { isTokenHashReserved = () => false } = {},
  ) {
    const code = normalizeInviteCode(rawCode);
    if (!code || typeof deviceToken !== "string" || !DEVICE_TOKEN.test(deviceToken)) {
      return { status: "invalid_request" };
    }

    const inviteHash = tokenDigest(code);
    const tokenHash = tokenDigest(deviceToken);
    const invite = this.state.invites.find((candidate) => candidate.inviteHash === inviteHash);
    if (!invite || invite.cancelledAt !== null) return { status: "invalid_invite" };

    if (invite.deviceTokenHash !== null) {
      if (invite.deviceTokenHash !== tokenHash) return { status: "already_used" };
      const device = this.state.devices.find((candidate) => candidate.tokenHash === tokenHash);
      if (!device || device.revokedAt !== null) return { status: "revoked" };
      return { status: "ok", changed: false, label: device.label };
    }

    // A pending keychain item can outlive the invite it originally claimed: for
    // example, the server committed, the 200 response was lost, and an operator then
    // revoked that identity before the Mac retried. Reusing that token for a different
    // invite would either create two labels for one credential or trip the registry's
    // duplicate-token invariant as a 500. Tell the client to discard only this local
    // proposal and generate a fresh credential, then retry the still-unused invite.
    if (isTokenHashReserved(tokenHash)
        || this.state.devices.some((candidate) => candidate.tokenHash === tokenHash)) {
      return { status: "device_in_use" };
    }

    const next = structuredClone(this.state);
    const nextInvite = next.invites.find((candidate) => candidate.inviteHash === inviteHash);
    const claimedAt = now.toISOString();
    nextInvite.claimedAt = claimedAt;
    nextInvite.deviceTokenHash = tokenHash;
    next.devices.push({
      id: randomUUID(),
      label: nextInvite.label,
      tokenHash,
      enrolledAt: claimedAt,
      revokedAt: null,
    });
    this.persist(next);
    return { status: "ok", changed: true, label: nextInvite.label };
  }

  revokeLabel(rawLabel, now = new Date()) {
    const label = cleanLabel(rawLabel);
    if (!label) return { status: "invalid_label" };
    const key = labelKey(label);
    const next = structuredClone(this.state);
    const revokedAt = now.toISOString();
    let devices = 0;
    let invites = 0;

    for (const device of next.devices) {
      if (labelKey(device.label) === key && device.revokedAt === null) {
        device.revokedAt = revokedAt;
        devices += 1;
      }
    }
    for (const invite of next.invites) {
      if (labelKey(invite.label) === key
          && invite.claimedAt === null && invite.cancelledAt === null) {
        invite.cancelledAt = revokedAt;
        invites += 1;
      }
    }
    if (devices === 0 && invites === 0) return { status: "not_found" };
    this.persist(next);
    return { status: "ok", devices, invites };
  }

  summary() {
    return {
      pendingInvites: this.state.invites
        .filter((invite) => invite.claimedAt === null && invite.cancelledAt === null)
        .map(({ label, issuedAt }) => ({ label, issuedAt })),
      devices: this.state.devices.map(({ label, enrolledAt, revokedAt }) => ({
        label,
        enrolledAt,
        status: revokedAt === null ? "active" : "revoked",
        revokedAt,
      })),
    };
  }

  persist(next) {
    validateState(next);
    const directory = dirname(this.path);
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    const temporary = `${this.path}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`;
    let file = null;
    try {
      file = openSync(temporary, "wx", 0o600);
      writeFileSync(file, `${JSON.stringify(next, null, 2)}\n`, "utf8");
      // Atomic rename prevents a torn JSON file; fsync prevents the complete-looking
      // old file from coming back after power loss, which would resurrect a used invite
      // or a revoked device.
      fsyncSync(file);
      closeSync(file);
      file = null;
      renameSync(temporary, this.path);
    } catch (error) {
      if (file !== null) {
        try { closeSync(file); } catch {}
      }
      try { unlinkSync(temporary); } catch {}
      throw error;
    }
    this.state = next;
    // Persist the directory entry too. Once rename succeeds the in-process mutation is
    // committed, so a filesystem that refuses directory fsync must not make the HTTP
    // handler report failure while silently keeping the new authorization state.
    let directoryFile = null;
    try {
      directoryFile = openSync(directory, "r");
      fsyncSync(directoryFile);
    } catch (error) {
      process.emitWarning(`could not fsync enrollment registry directory: ${error.message}`);
    } finally {
      if (directoryFile !== null) {
        try { closeSync(directoryFile); } catch {}
      }
    }
  }
}

export function enrollmentClientAddress(request) {
  const peer = request.socket?.remoteAddress || "unknown";
  const trustedProxy = peer === "127.0.0.1" || peer === "::1" || peer === "::ffff:127.0.0.1";
  const forwarded = request.headers["x-forwarded-for"];
  if (trustedProxy && typeof forwarded === "string") {
    // nginx's `$proxy_add_x_forwarded_for` preserves any client-supplied prefix and
    // appends the actual address it saw. Trusting the first value let anyone choose a
    // fresh fake IP per attempt, bypass the enrollment limiter, and fill its key map.
    // There is exactly one trusted hop here (the loopback nginx), so its appended last
    // value is the only one whose provenance we know.
    const addresses = forwarded.split(",").map((value) => value.trim()).filter(Boolean);
    if (addresses.length > 0) return addresses.at(-1);
  }
  return peer;
}

async function jsonBody(request) {
  const body = await readBody(request, MAX_BODY_BYTES);
  try {
    return JSON.parse(body.toString("utf8"));
  } catch {
    const error = new Error("invalid JSON");
    error.statusCode = 400;
    throw error;
  }
}

function hasJSONContentType(request) {
  const value = request.headers["content-type"];
  return typeof value === "string"
    && value.split(";", 1)[0].trim().toLowerCase() === "application/json";
}

export async function handleEnrollment(request, response, {
  registry,
  rateLimiter,
  onAuthorizationChanged,
  isTokenHashReserved = () => false,
}) {
  if (!hasJSONContentType(request)) {
    writeJSON(response, 415, errorBody("邀请码请求必须使用 JSON", "enrollment_invalid_request"));
    return;
  }
  // `application/json` is not a CORS-safelisted content type. Checking it before the
  // limiter means an unrelated web page cannot make browsers send cheap `text/plain`
  // POSTs that burn all activation attempts for every Mac behind the same public IP.
  if (!rateLimiter.take(enrollmentClientAddress(request))) {
    writeJSON(response, 429, errorBody("尝试次数过多，请稍后再试", "enrollment_rate_limited"));
    return;
  }

  let body;
  try {
    body = await jsonBody(request);
  } catch (error) {
    writeJSON(
      response,
      error.statusCode || 400,
      errorBody("邀请码请求格式不正确", "enrollment_invalid_request"),
    );
    return;
  }
  if (!body || typeof body !== "object" || Array.isArray(body)
      || Object.keys(body).some((key) => !["inviteCode", "deviceToken"].includes(key))) {
    writeJSON(response, 400, errorBody("邀请码请求格式不正确", "enrollment_invalid_request"));
    return;
  }

  const result = registry.claim(body.inviteCode, body.deviceToken, new Date(), {
    isTokenHashReserved,
  });
  switch (result.status) {
  case "ok":
    if (result.changed) onAuthorizationChanged();
    writeJSON(response, 200, { ok: true });
    return;
  case "invalid_request":
    writeJSON(response, 400, errorBody("邀请码请求格式不正确", "enrollment_invalid_request"));
    return;
  case "invalid_invite":
    writeJSON(response, 401, errorBody("邀请码无效或已被停用", "enrollment_invalid_invite"));
    return;
  case "already_used":
    writeJSON(response, 409, errorBody("这个邀请码已经被另一台设备使用", "enrollment_already_used"));
    return;
  case "device_in_use":
    writeJSON(
      response,
      409,
      errorBody("正在更新本机设备身份，请重试", "enrollment_device_token_in_use"),
    );
    return;
  case "revoked":
    writeJSON(response, 403, errorBody("这台设备的访问权限已被停用", "enrollment_revoked"));
    return;
  default:
    throw new Error(`unexpected enrollment result: ${result.status}`);
  }
}

export async function handleEnrollmentAdmin(request, response, {
  registry,
  onAuthorizationChanged,
}) {
  const url = new URL(request.url || "/", "http://admin.invalid");
  if (request.method === "GET" && url.pathname === "/admin/status") {
    writeJSON(response, 200, registry.summary());
    return;
  }

  if (request.method === "POST" && url.pathname === "/admin/invites") {
    if (!hasJSONContentType(request)) {
      writeJSON(response, 415, errorBody("invalid request", "admin_invalid_request"));
      return;
    }
    let body;
    try { body = await jsonBody(request); } catch {
      writeJSON(response, 400, errorBody("invalid request", "admin_invalid_request"));
      return;
    }
    const result = registry.issueInvite(body?.label);
    if (result.status === "label_in_use") {
      writeJSON(response, 409, errorBody("identity already active", "admin_label_in_use"));
      return;
    }
    if (result.status !== "ok") {
      writeJSON(response, 400, errorBody("invalid label", "admin_invalid_label"));
      return;
    }
    writeJSON(response, 201, { code: result.code, label: result.label });
    return;
  }

  if (request.method === "POST" && url.pathname === "/admin/revoke") {
    if (!hasJSONContentType(request)) {
      writeJSON(response, 415, errorBody("invalid request", "admin_invalid_request"));
      return;
    }
    let body;
    try { body = await jsonBody(request); } catch {
      writeJSON(response, 400, errorBody("invalid request", "admin_invalid_request"));
      return;
    }
    const result = registry.revokeLabel(body?.label);
    if (result.status === "not_found") {
      writeJSON(response, 404, errorBody("identity not found", "admin_not_found"));
      return;
    }
    if (result.status !== "ok") {
      writeJSON(response, 400, errorBody("invalid label", "admin_invalid_label"));
      return;
    }
    onAuthorizationChanged();
    writeJSON(response, 200, { ok: true, devices: result.devices, invites: result.invites });
    return;
  }

  writeJSON(response, 404, errorBody("not found", "admin_not_found"));
}
