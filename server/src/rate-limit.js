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
  constructor(limit, windowMs = 60_000, maxKeys = 10_000) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.maxKeys = maxKeys;
    this.windows = new Map();
  }

  take(key, now = Date.now()) {
    const current = this.windows.get(key);
    if (!current || now - current.startedAt >= this.windowMs) {
      if (!current && this.windows.size >= this.maxKeys) {
        for (const [candidate, window] of this.windows) {
          if (now - window.startedAt >= this.windowMs) this.windows.delete(candidate);
        }
        if (this.windows.size >= this.maxKeys) return false;
      }
      this.windows.set(key, { startedAt: now, count: 1 });
      return true;
    }
    if (current.count >= this.limit) return false;
    current.count += 1;
    return true;
  }
}

/// One atomic daily budget with both a per-device and a whole-relay ceiling.
///
/// The relay is single-process Node, so checking and committing both counters in one
/// synchronous method is enough to prevent a request from consuming the device budget
/// and then discovering that the global budget was already gone (or vice versa).
/// Counters deliberately live in memory: they are cost backstops, not billing records;
/// a deploy may grant the remainder of one extra day's allowance, while persistent
/// per-audio-frame writes would put the hot Realtime path on disk.
export class DailyUsageLimiter {
  constructor(perDeviceLimit, totalLimit, maxKeys = 10_000) {
    this.perDeviceLimit = perDeviceLimit;
    this.totalLimit = totalLimit;
    this.maxKeys = maxKeys;
    this.day = null;
    this.total = 0;
    this.devices = new Map();
  }

  take(key, units = 1, now = Date.now()) {
    if (!Number.isSafeInteger(units) || units <= 0) {
      throw new TypeError("daily usage units must be a positive safe integer");
    }

    const day = Math.floor(now / 86_400_000);
    if (day !== this.day) {
      this.day = day;
      this.total = 0;
      this.devices.clear();
    }

    const device = this.devices.get(key) || 0;
    if (device + units > this.perDeviceLimit) return "device";
    if (this.total + units > this.totalLimit) return "total";
    if (!this.devices.has(key) && this.devices.size >= this.maxKeys) return "device";

    this.devices.set(key, device + units);
    this.total += units;
    return null;
  }
}
