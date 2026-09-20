#!/usr/bin/env node
// Remove agent worktrees that are old and have nothing in them worth keeping.
//
// WHY THIS EXISTS. Nothing prunes worktrees. On 2026-09-19 this machine hit
// "No space left on device" at 301Mi free on a 926G volume, with 56 juancode
// worktrees holding 214G — so every agent session was one stale worktree away
// from a build that failed for a reason that had nothing to do with its ticket.
//
// WHAT IT WILL NOT DO. Several agent sessions are usually live in worktrees at
// once, and their unpushed commits exist nowhere else on earth. So the verdict
// is keep-biased at every step (see lib/worktree-sweep-core.mjs) and this
// script adds three more refusals on top of it:
//
//   * DRY RUN IS THE DEFAULT. With no arguments it prints and removes nothing.
//     Removing needs --apply, typed on purpose.
//   * NO DAEMON, NO SWEEP. Liveness has two independent sources and one of them
//     is the daemon's session list. If the daemon does not answer, we cannot
//     know what is running, so nothing is removed at all.
//   * LIVENESS IS RE-CHECKED IMMEDIATELY BEFORE EACH REMOVAL. The set of live
//     sessions changes while this script is walking the list; a check done once
//     at the start is a check that was true a minute ago.
//   * ONE APPLYING SWEEP AT A TIME. Two of these racing would each re-check
//     liveness against a tree the other is halfway through removing. --apply
//     takes ~/.juancode/worktree-reclaim.lock first (lib/run-lock.mjs), and a
//     lock whose owner pid is gone is taken over rather than believed — a dead
//     holder must never be able to stop this running again.
//
// Every run appends to ~/.juancode/logs/worktree-sweep.log: what it removed,
// what it skipped, and why. When this eventually deletes something it should
// not have, that log is the only account of what happened — so it records the
// branch and head sha too. The BRANCH IS NEVER DELETED, only the working
// directory, which is what makes a mistaken removal recoverable.
//
// Usage:
//   node scripts/worktree-sweep.mjs                  dry run (the default)
//   node scripts/worktree-sweep.mjs --dry-run        the same, said out loud
//   node scripts/worktree-sweep.mjs --apply          actually remove
//   node scripts/worktree-sweep.mjs --json           machine-readable verdicts
//   node scripts/worktree-sweep.mjs --days=5         override the 2-day age floor
//   node scripts/worktree-sweep.mjs --root=/path     sweep another checkout
//   node scripts/worktree-sweep.mjs --no-fetch       skip refreshing origin/main
//
// Env:
//   JUANCODE_APP_URL   where to ask for the running sessions (default :4280)
//   JUANCODE_LOG_DIR   where the run log goes (default ~/.juancode/logs)
//   JUANCODE_SWEEP_LOCK  the --apply lock directory (default
//                        ~/.juancode/worktree-reclaim.lock)

import { execFileSync } from "node:child_process";
import { appendFileSync, mkdirSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  fetchRemotes,
  inspectWorktree,
  loadPrsByBranch,
  mainCheckoutOf,
  parseWorktrees,
} from "./lib/worktree-scan.mjs";
import {
  DAY_MS,
  DEFAULT_MAX_AGE_DAYS,
  decide,
  formatAge,
  isUnder,
} from "./lib/worktree-sweep-core.mjs";
import { acquire, DEFAULT_LOCK_DIR } from "./lib/run-lock.mjs";

// ---- arguments ------------------------------------------------------------
const argv = process.argv.slice(2);
const flag = (name) => argv.includes(name);
const value = (name, fallback) => {
  const hit = argv.find((a) => a.startsWith(`${name}=`));
  return hit ? hit.slice(name.length + 1) : fallback;
};

if (flag("--help") || flag("-h")) {
  console.log(
    [
      "worktree-sweep — remove worktrees older than N days with nothing worth keeping",
      "",
      "  --dry-run        say what it would remove and change nothing (the default)",
      "  --apply          actually remove them; --dry-run overrides it",
      "  --json           verdicts as JSON",
      `  --days=N         age floor in days (default ${DEFAULT_MAX_AGE_DAYS})`,
      "  --root=PATH      sweep the checkout at PATH instead of the cwd's",
      "  --no-fetch       do not refresh origin/main first",
      "  --no-daemon      skip the daemon session check (dry run only; it refuses --apply)",
    ].join("\n"),
  );
  process.exit(0);
}

// --dry-run is the default AND spellable, and it wins over --apply if both are
// passed: the safe reading of a contradictory command line is the safe one.
const apply = flag("--apply") && !flag("--dry-run");
const asJson = flag("--json");
const skipDaemon = flag("--no-daemon");
const maxAgeDays = Number(value("--days", DEFAULT_MAX_AGE_DAYS));
const maxAgeMs = maxAgeDays * DAY_MS;
const appUrl = (process.env.JUANCODE_APP_URL || "http://127.0.0.1:4280").replace(/\/+$/, "");
const logDir = process.env.JUANCODE_LOG_DIR || join(homedir(), ".juancode", "logs");
const logFile = join(logDir, "worktree-sweep.log");
const lockDir = process.env.JUANCODE_SWEEP_LOCK || DEFAULT_LOCK_DIR;

if (!Number.isFinite(maxAgeDays) || maxAgeDays <= 0) {
  console.error(`--days must be a positive number, got ${value("--days", "")}`);
  process.exit(2);
}

// The MAIN checkout, even when --root names a worktree: `rev-parse
// --show-toplevel` would answer with the worktree it was run from, and that
// tree would then be exempt as "the main checkout" while the real one was not.
const repoRoot = mainCheckoutOf(value("--root", process.cwd()));
if (!repoRoot) {
  console.error("not inside a git repository (pass --root=/path/to/checkout)");
  process.exit(2);
}

// ---- 1. what must never be touched ---------------------------------------
// The directory the launchd daemon plist names: removing it would take the core
// (and every session it owns) out from under the user at 04:00.
function daemonPaths() {
  const out = new Set();
  const plist = join(homedir(), "Library", "LaunchAgents", "com.juanone.juancoded.plist");
  for (const key of ["WorkingDirectory", "ProgramArguments:0"]) {
    try {
      const raw = execFileSync("/usr/libexec/PlistBuddy", ["-c", `Print :${key}`, plist], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      }).trim();
      if (raw) out.add(raw.replace(/\/apps\/native\/scripts\/[^/]+$/, ""));
    } catch {
      /* no plist installed: nothing to protect */
    }
  }
  return [...out];
}

// ---- 2. liveness, from two independent sources ---------------------------
// Either one saying "live" is enough. They fail differently on purpose: the
// daemon knows about a session whose process list looks idle, and the process
// table knows about a shell someone opened by hand that the daemon never saw.
function daemonSessionPaths() {
  let raw;
  try {
    raw = execFileSync("curl", ["-fsS", "--max-time", "5", `${appUrl}/api/sessions`], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
  } catch {
    return null; // unreachable — the caller must refuse to remove anything
  }
  try {
    const parsed = JSON.parse(raw);
    const rows = Array.isArray(parsed) ? parsed : (parsed.sessions ?? []);
    const paths = new Set();
    for (const r of rows) {
      if (!r || r.status !== "running") continue;
      for (const p of [r.cwd, r.worktreePath]) if (p) paths.add(p);
    }
    return paths;
  } catch {
    return null;
  }
}

// Every process's cwd, plus every process's argv. A process sitting in the tree
// is the obvious case; a process that merely NAMES the path (an editor, a build,
// a `git -C`) is not proof of much, but it is cheap and it errs toward keeping.
function processPathHits() {
  const cwds = [];
  try {
    const out = execFileSync("sh", ["-c", "lsof -w -d cwd -Fpn 2>/dev/null"], {
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
    });
    let pid = "?";
    for (const line of out.split("\n")) {
      if (line.startsWith("p")) pid = line.slice(1);
      else if (line.startsWith("n")) cwds.push({ pid, path: line.slice(1) });
    }
  } catch {
    /* lsof denied: the argv pass below still runs */
  }
  const argvs = [];
  try {
    const out = execFileSync("sh", ["-c", "ps -Ao pid=,command= 2>/dev/null"], {
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
    });
    for (const line of out.split("\n")) {
      const m = line.match(/^\s*(\d+)\s+(.*)$/);
      if (m) argvs.push({ pid: m[1], cmd: m[2] });
    }
  } catch {
    /* ps denied */
  }
  return { cwds, argvs };
}

const selfPid = String(process.pid);

function liveReasonsFor(path, live) {
  const reasons = [];
  if (live.daemonPaths) {
    for (const p of live.daemonPaths) {
      if (isUnder(p, path)) {
        reasons.push(`daemon reports a running session at ${p}`);
        break;
      }
    }
  }
  for (const { pid, path: cwd } of live.cwds) {
    if (pid !== selfPid && isUnder(cwd, path)) {
      reasons.push(`pid ${pid} has its cwd in the tree`);
      break;
    }
  }
  for (const { pid, cmd } of live.argvs) {
    if (pid !== selfPid && cmd.includes(path)) {
      reasons.push(`pid ${pid} names the path: ${cmd.slice(0, 60)}`);
      break;
    }
  }
  return reasons;
}

function sampleLiveness() {
  const { cwds, argvs } = processPathHits();
  return {
    daemonPaths: skipDaemon ? new Set() : daemonSessionPaths(),
    cwds,
    argvs,
    // An empty sample is not "nothing is running", it is "lsof/ps told us
    // nothing" — on a live machine both list hundreds of processes. Treated
    // exactly like a daemon that will not answer: the second liveness source is
    // blind, so nothing may be removed.
    fsSampled: cwds.length > 0 && argvs.length > 0,
  };
}

// ---- 3. age = last MODIFIED --------------------------------------------
// A tree someone touched an hour ago is not two days old however long ago it
// was made, so this is a max over every cheap signal of recent use, never a
// creation time. Build dirs are not descended into (they are the 214G) but they
// ARE stat'd: a fresh .build directory means somebody built here.
const HEAVY_DIRS = new Set([
  ".git",
  "node_modules",
  ".build",
  "target",
  "dist",
  ".next",
  ".turbo",
  ".venv",
]);
const MAX_WALK_DEPTH = 3;

function newestMtimeMs(root) {
  let newest = 0;
  const bump = (p) => {
    try {
      const st = statSync(p);
      if (st.mtimeMs > newest) newest = st.mtimeMs;
    } catch {
      /* raced with a delete, or unreadable */
    }
  };
  const walk = (dir, depth) => {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const p = join(dir, e.name);
      bump(p);
      if (e.isDirectory() && !HEAVY_DIRS.has(e.name) && depth < MAX_WALK_DEPTH) walk(p, depth + 1);
    }
  };
  bump(root);
  walk(root, 0);

  // Git's own bookkeeping, for the session that committed but changed no file
  // since: the linked worktree's gitdir lives under the main checkout.
  //
  // NOT .git/index. `git status` rewrites the index whenever it finds stale stat
  // data — and this script runs `git status` in every tree it looks at. An index
  // mtime would therefore be a freshness signal the sweeper sets itself, so no
  // tree would ever age past the floor once a sweep had run. Every file below is
  // written only by an actual ref update.
  const gitDir = execFileSync("git", ["-C", root, "rev-parse", "--absolute-git-dir"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  })
    .trim()
    .replace(/\n.*$/, "");
  for (const f of ["HEAD", "logs/HEAD", "ORIG_HEAD", "COMMIT_EDITMSG"]) {
    bump(join(gitDir, f));
  }
  return newest || NaN;
}

// ---- 4. the run -----------------------------------------------------------
const nowMs = Date.now();
const startedAt = new Date(nowMs).toISOString();
const protectedPaths = daemonPaths();

// Taken before the scan, which costs minutes: a run that may not remove
// anything should find that out first. A dry run takes nothing — it changes no
// state, so two of them racing is not a race.
let lock = null;
let lockRefusal = null;
if (apply) {
  const got = acquire(lockDir, { tool: "worktree-sweep" });
  if (got.ok) {
    lock = got;
    // Released on every exit path, including a throw and a signal, because the
    // one thing a lock must not do is outlive the run it belongs to — which is
    // precisely how the leftover this replaces came about.
    process.on("exit", () => lock?.release());
    for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
      process.on(sig, () => {
        lock?.release();
        process.exit(1);
      });
    }
  } else {
    lockRefusal = got.why;
  }
}

if (!flag("--no-fetch")) fetchRemotes(repoRoot);
const { prs, ok: ghOk } = loadPrsByBranch();

let live = sampleLiveness();
const daemonDown = live.daemonPaths === null;

// A missing daemon is not "no sessions are running", it is "we cannot see what
// is running". The only safe reading of that is to remove nothing. Same for a
// process table that came back empty.
const armed = apply && !daemonDown && !skipDaemon && live.fsSampled && !lockRefusal;

const rows = [];
for (const t of parseWorktrees(repoRoot)) {
  let mtimeMs = NaN;
  try {
    mtimeMs = newestMtimeMs(t.path);
  } catch {
    /* decide() keeps a tree with no mtime */
  }
  const info = inspectWorktree(t, { repoRoot, prs });
  const candidate = { ...info, mtimeMs, liveReasons: liveReasonsFor(t.path, live) };
  // gh being down hides open PRs, which is a keep signal. Treat every tree with
  // commits as unmerged in that case rather than trusting a blank PR column.
  if (!ghOk && candidate.aheadMain > 0) candidate.pr = null;
  const verdict = decide(candidate, { nowMs, maxAgeMs, protectedPaths });
  rows.push({ ...candidate, ...verdict });
}

// ---- 5. act ---------------------------------------------------------------
const removed = [];
const failed = [];
for (const r of rows) {
  if (r.verdict !== "remove") continue;
  if (!armed) continue;

  // Re-check liveness against a FRESH sample: the list above may be minutes old
  // by now, and a session that started in the meantime is the whole risk.
  live = sampleLiveness();
  if (live.daemonPaths === null || !live.fsSampled) {
    r.verdict = "keep";
    r.code = live.daemonPaths === null ? "DAEMON_GONE" : "NO_PROCESS_SAMPLE";
    r.reason =
      live.daemonPaths === null
        ? "the daemon stopped answering mid-sweep — stopping here"
        : "lsof/ps stopped reporting mid-sweep — stopping here";
    failed.push(r);
    break;
  }
  const nowLive = liveReasonsFor(r.path, live);
  if (nowLive.length) {
    r.verdict = "keep";
    r.code = "LIVE";
    r.reason = `became live during the sweep: ${nowLive.join("; ")}`;
    continue;
  }

  // Re-run the whole verdict, not just liveness. Classifying fifty worktrees
  // takes minutes on this machine, so a tree that was clean when it was judged
  // can have an uncommitted file or an unpushed commit in it by the time its
  // turn comes round. Age is carried over from the first pass: it only grows.
  const current = parseWorktrees(repoRoot).find((w) => w.path === r.path);
  if (!current) {
    r.verdict = "keep";
    r.code = "VANISHED";
    r.reason = "git no longer lists this worktree — someone else removed it";
    continue;
  }
  const recheck = decide(
    { ...inspectWorktree(current, { repoRoot, prs }), mtimeMs: r.mtimeMs, liveReasons: [] },
    { nowMs, maxAgeMs, protectedPaths },
  );
  if (recheck.verdict !== "remove") {
    r.verdict = "keep";
    r.code = recheck.code;
    r.reason = `changed during the sweep: ${recheck.reason}`;
    continue;
  }

  // Plain `git worktree remove`, never --force: git refuses a tree with
  // uncommitted or untracked files, which is a last independent veto on top of
  // everything above. (Ignored build output does not stop it.)
  try {
    execFileSync("git", ["-C", repoRoot, "worktree", "remove", r.path], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    r.removed = true;
    removed.push(r);
  } catch (err) {
    r.verdict = "keep";
    r.code = "REMOVE_FAILED";
    r.reason = `git refused: ${
      String(err.stderr || err.message)
        .trim()
        .split("\n")[0]
    }`;
    failed.push(r);
  }
}

// ---- 6. log + report ------------------------------------------------------
const kept = rows.filter((r) => r.verdict !== "remove");
const wouldRemove = rows.filter((r) => r.verdict === "remove");
const mode = armed
  ? "APPLY"
  : apply && lockRefusal
    ? `REFUSED (another sweep holds ${lockDir}: ${lockRefusal})`
    : apply && skipDaemon
      ? "REFUSED (--no-daemon cannot arm a removal)"
      : apply && daemonDown
        ? "REFUSED (daemon unreachable)"
        : apply && !live.fsSampled
          ? "REFUSED (lsof/ps reported nothing)"
          : "DRY-RUN";

function logLines() {
  const out = [];
  out.push(
    `=== ${startedAt} ${mode} root=${repoRoot} days=${maxAgeDays} trees=${rows.length} ` +
      `removed=${removed.length} would-remove=${wouldRemove.length - removed.length} kept=${kept.length}` +
      `${daemonDown ? " daemon=UNREACHABLE" : ""}${live.fsSampled ? "" : " lsof/ps=BLIND"}` +
      `${ghOk ? "" : " gh=UNAVAILABLE"}`,
  );
  // The takeover is logged rather than performed quietly: it is the one moment
  // this script overrules a lock somebody else took, and the log is the only
  // account of it afterwards.
  if (lock?.tookOver) out.push(`lock  took over a stale claim on ${lockDir}: ${lock.tookOver}`);
  if (lock?.leftovers?.length)
    out.push(`lock  removed leftovers from the old scheme: ${lock.leftovers.join(", ")}`);
  if (lockRefusal) out.push(`lock  refused: ${lockDir} — ${lockRefusal}`);
  for (const r of rows) {
    const what = r.removed ? "REMOVED " : r.verdict === "remove" ? "WOULD-RM" : "kept    ";
    out.push(
      `${what} ${r.path} branch=${r.branch} head=${(r.head || "").slice(0, 12)} ` +
        `age=${formatAge(r.ageMs)} ${r.code}: ${r.reason}`,
    );
  }
  return out.join("\n") + "\n";
}

try {
  mkdirSync(logDir, { recursive: true });
  appendFileSync(logFile, logLines());
} catch (err) {
  console.error(`worktree-sweep: could not write ${logFile}: ${err.message}`);
}

if (asJson) {
  console.log(
    JSON.stringify(
      {
        startedAt,
        mode,
        repoRoot,
        maxAgeDays,
        daemonReachable: skipDaemon ? null : !daemonDown,
        daemonChecked: !skipDaemon,
        processesSampled: live.fsSampled,
        ghAvailable: ghOk,
        lock: apply
          ? {
              dir: lockDir,
              held: Boolean(lock),
              tookOver: lock?.tookOver ?? null,
              why: lockRefusal,
            }
          : null,
        logFile,
        removed: removed.map((r) => r.path),
        rows: rows.map((r) => ({
          path: r.path,
          branch: r.branch,
          head: r.head,
          verdict: r.verdict,
          code: r.code,
          reason: r.reason,
          ageHours: Number.isFinite(r.ageMs) ? +(r.ageMs / 3600000).toFixed(1) : null,
          dirty: r.dirty,
          aheadMain: r.aheadMain,
          pushed: r.pushed,
          removed: Boolean(r.removed),
        })),
      },
      null,
      2,
    ),
  );
} else {
  const c = process.stdout.isTTY
    ? { red: "\x1b[31m", dim: "\x1b[2m", grn: "\x1b[32m", bold: "\x1b[1m", rst: "\x1b[0m" }
    : { red: "", dim: "", grn: "", bold: "", rst: "" };
  console.log(
    `${c.bold}worktree sweep${c.rst} ${c.dim}${mode} · ${repoRoot} · older than ${maxAgeDays}d${c.rst}`,
  );
  if (lockRefusal) {
    console.log(
      `${c.red}another sweep holds ${lockDir} (${lockRefusal}) — nothing will be removed${c.rst}`,
    );
  }
  if (lock?.tookOver) {
    console.log(`${c.dim}took over a stale lock on ${lockDir}: ${lock.tookOver}${c.rst}`);
  }
  if (daemonDown) {
    console.log(
      `${c.red}the daemon at ${appUrl} did not answer — liveness is unknown, so nothing will be removed${c.rst}`,
    );
  }
  if (!live.fsSampled) {
    console.log(
      `${c.red}lsof/ps reported no processes — the second liveness check is blind, so nothing will be removed${c.rst}`,
    );
  }
  if (!ghOk)
    console.log(`${c.dim}gh unavailable: PR state unknown, trees with commits kept${c.rst}`);
  console.log("");
  for (const r of rows) {
    if (r.verdict === "remove") {
      console.log(`${c.red}${r.removed ? "REMOVED " : "would rm"}${c.rst} ${r.path}`);
      console.log(`  ${c.dim}${r.branch} · ${r.code}: ${r.reason}${c.rst}`);
    }
  }
  const byCode = new Map();
  for (const r of kept) byCode.set(r.code, (byCode.get(r.code) ?? 0) + 1);
  console.log(
    `\n${c.bold}kept ${kept.length}:${c.rst} ` +
      [...byCode.entries()].map(([k, n]) => `${k}×${n}`).join(" · "),
  );
  for (const r of kept)
    console.log(`  ${c.dim}${r.code.padEnd(14)} ${r.short} — ${r.reason}${c.rst}`);
  console.log(
    `\n${c.bold}summary:${c.rst} ${rows.length} worktrees · ${removed.length} removed · ` +
      `${wouldRemove.length - removed.length} would be removed · ${kept.length} kept`,
  );
  if (!apply && wouldRemove.length) {
    console.log(`${c.dim}re-run with --apply to actually remove them${c.rst}`);
  }
  console.log(`${c.dim}log: ${logFile}${c.rst}`);
}

if (failed.length) process.exit(1);
