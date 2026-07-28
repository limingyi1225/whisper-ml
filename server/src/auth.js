import { createHash, timingSafeEqual } from "node:crypto";

export function tokenDigest(token) {
  return createHash("sha256").update(token, "utf8").digest("hex");
}

export function authenticateRequest(request, allowedHashes) {
  const header = request.headers.authorization;
  if (typeof header !== "string" || !header.startsWith("Bearer ")) return null;

  const token = header.slice("Bearer ".length).trim();
  if (!token) return null;

  const candidate = Buffer.from(tokenDigest(token), "hex");
  for (const allowedHash of allowedHashes) {
    const allowed = Buffer.from(allowedHash, "hex");
    if (allowed.length === candidate.length && timingSafeEqual(allowed, candidate)) {
      return allowedHash;
    }
  }
  return null;
}
