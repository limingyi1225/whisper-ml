/// Whether one more Realtime connection can be admitted, and if not, which ceiling
/// stopped it.
///
/// Two different jobs. The per-device cap bounds a single leaked token; the total cap
/// bounds the box, which the per-device cap cannot do once several people hold tokens —
/// ten honest users are ten separate devices and every per-device check passes.
export function admitConnection({ openForDevice, openTotal, config }) {
  if (openForDevice >= config.maxConnectionsPerDevice) return "device";
  if (openTotal >= config.maxTotalConnections) return "total";
  return null;
}

export class FixedWindowRateLimiter {
  constructor(limit, windowMs = 60_000) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.windows = new Map();
  }

  take(key, now = Date.now()) {
    const current = this.windows.get(key);
    if (!current || now - current.startedAt >= this.windowMs) {
      this.windows.set(key, { startedAt: now, count: 1 });
      return true;
    }
    if (current.count >= this.limit) return false;
    current.count += 1;
    return true;
  }
}
