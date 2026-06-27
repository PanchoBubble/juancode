// Desktop-presence gate for Web Push (juancode-2zp). The native app reports when
// it's frontmost via GET /presence; we suppress phone pushes while the user is at
// the desk (the desktop already shows its own notification). Fail-open: if
// presence can't be read, we DON'T suppress — a redundant phone push beats a
// silently dropped one.

/** Shape of the native server's `/presence` response. */
export interface Presence {
  active: boolean;
  lastActiveMs: number | null;
}

/** Fetch the native server's presence, or null if unreachable/erroring/timing out.
 *  Injectable so the suppression logic can be tested without a live server. */
export type PresenceFetcher = () => Promise<Presence | null>;

/** Resolve the native backend's base URL — same precedence oracle.ts uses. */
function nativeApiBase(): string {
  if (process.env.JUANCODE_API) return process.env.JUANCODE_API.replace(/\/$/, "");
  const port = process.env.JUANCODE_PORT || "4280";
  return `http://127.0.0.1:${port}`;
}

/** How recently the desktop must have been frontmost to count as "at the desk".
 *  Default 60s, overridable via JUANCODE_PRESENCE_WINDOW_MS. */
export function presenceWindowMs(): number {
  const raw = process.env.JUANCODE_PRESENCE_WINDOW_MS;
  const n = raw ? Number(raw) : NaN;
  return Number.isFinite(n) && n >= 0 ? n : 60_000;
}

/** GET <base>/presence with a short timeout. Returns null on any failure so the
 *  caller fails open (sends the push). */
export async function fetchPresence(timeoutMs = 1500): Promise<Presence | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(`${nativeApiBase()}/presence`, { signal: controller.signal });
    if (!res.ok) return null;
    const data = (await res.json()) as Partial<Presence>;
    if (typeof data.active !== "boolean") return null;
    const lastActiveMs = typeof data.lastActiveMs === "number" ? data.lastActiveMs : null;
    return { active: data.active, lastActiveMs };
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Decide whether to suppress a push given a presence reading.
 *
 * Suppress (true) when the desktop is at the desk: `active === true`, OR
 * `lastActiveMs` falls within `windowMs` of `now`. Fail-open (false) when
 * `presence` is null (unreachable/error/timeout).
 */
export function suppressForPresence(
  presence: Presence | null,
  windowMs: number,
  now: number = Date.now(),
): boolean {
  if (presence === null) return false; // fail-open
  if (presence.active) return true;
  if (presence.lastActiveMs !== null && now - presence.lastActiveMs <= windowMs) return true;
  return false;
}
