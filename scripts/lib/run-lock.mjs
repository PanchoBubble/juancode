// A mutual-exclusion lock that survives its owner dying, because that is the
// ordinary case here and not the exotic one.
//
// WHAT WENT WRONG. The one-off reclaim pass of 2026-09-19 guarded itself with
// `mkdir ~/.juancode/worktree-reclaim.lock` plus an `owner` file. The first
// agent holding it was killed mid-run by the duplicate-dispatch bug; the second
// one took the lock over by hand, finished, and exited without removing the
// directory. What is left on disk is a held lock owned by a session that has
// been gone since 2026-09-19 — and `mkdir` alone can never tell the difference
// between that and a sweep running right now. So the NEXT run would refuse
// forever, and the failure is silent: a housekeeping job that quietly stops
// happening.
//
// A lock is therefore not a directory. It is a directory plus a CLAIM naming a
// pid, and a claim whose pid is gone is not a claim. That is the same shape as
// `apps/juancoded/crates/juancoded-server/src/owner.rs`, which exists for the
// same reason: macOS has no `PR_SET_PDEATHSIG`, so nothing in the kernel will
// clean up after a process that was SIGKILLed, and every such record has to be
// re-validated by whoever reads it next.
//
// WHICH WAY THIS FAILS. Reading a live owner as dead would run two sweeps at
// once, which is the thing the lock is for; reading a dead owner as live only
// skips a housekeeping run. So liveness is deliberately generous — `kill(pid,0)`
// with EPERM counting as ALIVE — and the only thing that overrides it is the
// staleness ceiling below.

import { mkdirSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir, hostname } from "node:os";
import { join } from "node:path";
import { randomBytes } from "node:crypto";

/** The claim, inside the lock directory. */
export const OWNER_FILE = "owner";

/**
 * The directory the one-off reclaim pass created, reused on purpose: adopting
 * it is what retires the leftover, where a fresh name would leave it on disk
 * forever with nothing that knows about it.
 */
export const DEFAULT_LOCK_DIR = join(homedir(), ".juancode", "worktree-reclaim.lock");

/**
 * How old a claim may be before it is taken over whatever its pid says.
 *
 * Pids are recycled, and a recycled pid reads as alive — which on its own would
 * be a lock that no liveness check can ever clear, i.e. exactly the bug this
 * module is about, just slower. Six hours is ~60x the longest run either of
 * these jobs has taken (that pass ran about an hour; a sweep is minutes), so
 * the ceiling cannot plausibly fire on a real holder. The trade is explicit: a
 * run that somehow lasts longer than this can be joined by a second one.
 */
export const STALE_AFTER_MS = 6 * 60 * 60 * 1000;

/**
 * Whether a pid is a live process. `kill(pid, 0)` delivers nothing, it only
 * asks. EPERM means the process exists and simply is not ours to signal, which
 * is alive — treating "not mine" as "gone" is how a lock gets stolen from a
 * running holder.
 *
 * pid 1 is never an owner: `launchd` is what an orphan is reparented TO, so a
 * record naming it is a record of an owner that already died.
 */
export function processAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 1) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err.code === "EPERM";
  }
}

/**
 * Parse the `key=value` claim. First occurrence of a key wins. Everything is
 * optional because everything might be missing: this has to read the freeform
 * line the one-off pass wrote, which has no keys at all.
 */
export function parseOwner(body) {
  const out = { pid: null, token: null, startedAt: null, tool: null, host: null };
  for (const line of String(body ?? "").split("\n")) {
    const at = line.indexOf("=");
    if (at < 0) continue;
    const key = line.slice(0, at).trim();
    const value = line.slice(at + 1).trim();
    if (!value) continue;
    if (key === "pid" && out.pid === null) {
      const n = Number(value);
      out.pid = Number.isInteger(n) ? n : null;
    } else if (key in out && out[key] === null && key !== "pid") {
      out[key] = value;
    }
  }
  return out;
}

function serializeOwner(claim) {
  return (
    Object.entries(claim)
      .filter(([, v]) => v !== null && v !== undefined && v !== "")
      .map(([k, v]) => `${k}=${String(v).replace(/\n/g, " ")}`)
      .join("\n") + "\n"
  );
}

/**
 * What the claim on disk means right now: `held` (leave it alone), `stale`
 * (take it over), or `none` (no readable claim).
 *
 * An unreadable or pid-less claim is STALE, not held. That is the whole
 * decision, so it is worth saying why: nothing that writes this file after this
 * module lands omits a pid, so a claim without one came from before it — which
 * on this machine means the dead one-off pass. The alternative reading, "a
 * claim we cannot check is a claim we must respect", is a lock nobody can ever
 * release, which is the bug.
 */
export function ownerState(body, { now = Date.now(), alive = processAlive } = {}) {
  if (body === null || body === undefined) return { state: "none", owner: null, why: "no claim" };
  const owner = parseOwner(body);
  const summary = String(body).trim().split("\n").join(" · ").slice(0, 160);
  if (owner.pid === null) {
    return {
      state: "stale",
      owner,
      why: `the claim names no pid, so it predates the liveness check: ${summary}`,
    };
  }
  const ageMs = owner.startedAt ? now - Date.parse(owner.startedAt) : NaN;
  if (Number.isFinite(ageMs) && ageMs > STALE_AFTER_MS) {
    return {
      state: "stale",
      owner,
      why: `pid ${owner.pid} still answers but the claim is ${(ageMs / 3600000).toFixed(1)}h old, past the ${STALE_AFTER_MS / 3600000}h ceiling`,
    };
  }
  if (alive(owner.pid)) {
    return { state: "held", owner, why: `pid ${owner.pid} is alive: ${summary}` };
  }
  return { state: "stale", owner, why: `pid ${owner.pid} is gone: ${summary}` };
}

function readOwner(dir) {
  try {
    return readFileSync(join(dir, OWNER_FILE), "utf8");
  } catch {
    return null;
  }
}

/** Write the claim through a rename, so a reader never sees half of one. */
function writeOwner(dir, claim) {
  const tmp = join(dir, `${OWNER_FILE}.${claim.token}.tmp`);
  writeFileSync(tmp, serializeOwner(claim));
  renameSync(tmp, join(dir, OWNER_FILE));
}

/**
 * Anything the old hand-rolled scheme left beside the claim. The previous
 * takeover preserved the record it displaced as `owner.stale-<token>`; one such
 * file per death is unbounded cruft, and the takeover line in the new claim
 * says the same thing in the place somebody will actually read.
 */
function sweepLeftovers(dir) {
  const gone = [];
  let entries = [];
  try {
    entries = readdirSync(dir);
  } catch {
    return gone;
  }
  for (const name of entries) {
    if (name === OWNER_FILE) continue;
    if (!name.startsWith(`${OWNER_FILE}.`)) continue;
    try {
      rmSync(join(dir, name), { force: true });
      gone.push(name);
    } catch {
      /* not ours to remove; the lock still works without it */
    }
  }
  return gone;
}

/**
 * Take the lock, or report who holds it.
 *
 * Returns `{ ok: true, release(), tookOver }` or `{ ok: false, why, owner }`.
 * `tookOver` is the reason string when this acquire displaced a dead claim, so
 * the caller can log the takeover rather than performing it silently.
 */
export function acquire(
  dir = DEFAULT_LOCK_DIR,
  { tool = "unknown", pid = process.pid, now = Date.now(), alive = processAlive } = {},
) {
  const token = randomBytes(4).toString("hex");
  const claim = {
    pid,
    token,
    startedAt: new Date(now).toISOString(),
    tool,
    host: hostname(),
  };

  let tookOver = null;
  try {
    mkdirSync(dir, { recursive: false });
  } catch (err) {
    if (err.code !== "EEXIST") throw err;
    const state = ownerState(readOwner(dir), { now, alive });
    if (state.state === "held") return { ok: false, why: state.why, owner: state.owner };
    tookOver = state.why;
  }

  writeOwner(dir, tookOver ? { ...claim, tookOver } : claim);

  // Two processes can both have found the same claim stale and both have
  // written. The rename is atomic, so exactly one of them is on disk now —
  // whoever does not see their own token lost and backs off rather than
  // sweeping alongside the winner.
  const landed = parseOwner(readOwner(dir));
  if (landed.token !== token) {
    return {
      ok: false,
      why: `lost a takeover race to pid ${landed.pid ?? "?"}`,
      owner: landed,
    };
  }
  const leftovers = sweepLeftovers(dir);

  return {
    ok: true,
    dir,
    token,
    tookOver,
    leftovers,
    /**
     * Give the lock up. It removes the directory only while the claim in it is
     * still ours: if somebody took it over — because this process hung past the
     * ceiling — removing it would pull the lock out from under a run that is
     * still going.
     */
    release() {
      const current = parseOwner(readOwner(dir));
      if (current.token !== token) return false;
      try {
        rmSync(dir, { recursive: true, force: true });
        return true;
      } catch {
        return false;
      }
    },
  };
}
