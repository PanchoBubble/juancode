#!/usr/bin/env node
// Bring the Swift core's session history across to the Rust core's stores.
//
// Each core owns its own sqlite file — deliberately: the daemon is a separate
// process that outlives the app, and two writers on one file is a corruption risk,
// not a cleanup. The cost of that is a sidebar that gets shorter when you switch
// `JUANCODE_CORE`, because the history only ever existed in the other file. This
// unions it across: every session the Swift store has and the Rust one does not.
//
// It is a UNION, never a copy. The Rust stores hold sessions the Swift one never
// saw (they were created under the Rust core), and those must survive untouched.
// For an id both stores know, the newer `updated_at` wins.
//
// Scrollback is the one thing that does NOT cross into the daemon store. The Swift
// `sessions.scrollback` is one TEXT column with no width recorded; the daemon needs
// the (cols, rows) the bytes were parsed at, and feeding a grid parsed at one width
// to a reader at another is exactly what garbles the paint. So the daemon pass is
// metadata-only and an imported session reads as empty — never as scrambled. The
// desktop mirror has the same widthless TEXT column as the Swift store, so there the
// scrollback comes across verbatim and replays as it always did.
//
// Usage:
//   node scripts/backfill-rust-sessions.mjs                 dry run, says what it would do
//   node scripts/backfill-rust-sessions.mjs --write         apply (quit the app first)
//   node scripts/backfill-rust-sessions.mjs --daemon-store  also do the metadata-only pass
//   node scripts/backfill-rust-sessions.mjs --json          machine output
//   ... --swift <db> --mirror <db> --daemon <db>            override paths (for testing on copies)
//
// Safety, none of it optional:
//   * it refuses to WRITE while any process holds one of the files open, or while
//     the app (:4280) or juancoded is answering — a dry run against a live store is
//     still allowed, and says that it is reading a moving target;
//   * it copies the target to <name>.bak-<stamp> before its first write;
//   * dry run is the default, and only `--write` changes a byte.

import { DatabaseSync } from "node:sqlite";
import { execFileSync } from "node:child_process";
import { connect } from "node:net";
import { once } from "node:events";
import { copyFileSync, existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { resolve, sep } from "node:path";

const args = process.argv.slice(2);
const flag = (name) => args.includes(`--${name}`);
const value = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};

const HOME = homedir();
const WRITE = flag("write");
const AS_JSON = flag("json");
const DO_DAEMON = flag("daemon-store");

const SWIFT_DB = resolve(value("swift", `${HOME}/.juancode/data/juancode.db`));
const MIRROR_DB = resolve(value("mirror", `${HOME}/.juancode/data/juancode-rust.db`));
const DAEMON_DB = resolve(value("daemon", `${HOME}/.juancode/rust-core/juancoded-rust.db`));
// The one directory whose files a running app or daemon can be holding. Paths
// outside it are copies somebody made to test with, and the liveness check that
// exists to protect the real history has nothing to say about them.
const LIVE_ROOT = resolve(value("live-root", `${HOME}/.juancode`));

// `--json` is for a caller that wants the counts, so the prose goes into the
// payload as `log` rather than being interleaved with it — or dropped, which
// would hide the liveness warnings from the one caller least able to notice.
const log = [];
const say = (line) => (AS_JSON ? log.push(line) : console.log(line));
const die = (msg) => {
  console.error(`backfill: ${msg}`);
  process.exit(2);
};

// ---------------------------------------------------------------- liveness

/** Every file sqlite may have open for one database. */
function dbFiles(path) {
  return [path, `${path}-wal`, `${path}-shm`].filter((p) => existsSync(p));
}

/** Processes holding any of these files open, as `pid command` lines. */
function holdersOf(paths) {
  if (paths.length === 0) return [];
  let raw = "";
  try {
    raw = execFileSync("lsof", ["-nP", "-Fpc", "--", ...paths], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
  } catch (err) {
    // lsof exits 1 when ANY named file has no open instances — including when it
    // found holders for the others and printed them. Reading only the exit code
    // here would report a live store as quiet, which is the one mistake this
    // function must not make.
    raw = err.stdout ?? "";
  }
  const found = [];
  let pid = null;
  for (const line of raw.split("\n")) {
    if (line.startsWith("p")) pid = line.slice(1);
    else if (line.startsWith("c") && pid) found.push(`${pid} ${line.slice(1)}`);
  }
  return [...new Set(found)];
}

async function somethingIsListening(port) {
  const socket = connect({ port, host: "127.0.0.1" });
  socket.setTimeout(700);
  try {
    await once(socket, "connect");
    return true;
  } catch {
    return false;
  } finally {
    socket.destroy();
  }
}

/** The port the daemon's run file claims, when a live pid wrote it. */
function daemonRunFile() {
  const path = `${LIVE_ROOT}/rust-core/juancoded.run`;
  if (!existsSync(path)) return null;
  const kv = Object.fromEntries(
    readFileSync(path, "utf8")
      .split("\n")
      .filter((l) => l.includes("="))
      .map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]),
  );
  return { port: Number(kv.port) || 4290, pid: Number(kv.pid) || 0 };
}

function isLivePath(path) {
  return path === LIVE_ROOT || path.startsWith(LIVE_ROOT + sep);
}

/**
 * Everything that says these stores are in use right now.
 *
 * Three checks, because none alone is enough: `lsof` is exact but says nothing
 * about a daemon that has the file closed between writes; the ports say nothing
 * about a second app pointed at a different data dir; and neither applies to a
 * copy somebody made in a temp directory to test with.
 */
async function livenessReasons(paths) {
  const reasons = [];
  for (const holder of holdersOf(paths.flatMap(dbFiles))) {
    reasons.push(`pid ${holder} has one of these database files open`);
  }
  if (!paths.some(isLivePath)) return reasons;

  if (await somethingIsListening(4280)) {
    reasons.push("the native app is answering :4280 — quit juancode");
  }
  const run = daemonRunFile();
  if (run && (await somethingIsListening(run.port))) {
    reasons.push(
      `juancoded is answering :${run.port} (pid ${run.pid}) — ` +
        `apps/native/scripts/juancoded.sh stop`,
    );
  }
  return reasons;
}

/**
 * A write to a store something else is writing is how a sqlite file gets
 * corrupted, so that is refused outright and has no override. A dry run is only
 * reads, through `immutable=1`, and stays allowed — being able to see what the
 * migration would do before quitting the app is the whole point of having one —
 * but it says plainly that it is reading a moving target.
 */
async function assertSafe(paths) {
  const reasons = await livenessReasons(paths);
  if (reasons.length === 0) return;
  if (WRITE) {
    die(`these stores are in use. Nothing was written.\n  ` + reasons.join("\n  "));
  }
  say("live stores — this is a read-only preview:");
  for (const reason of reasons) say(`  ${reason}`);
  // immutable=1 skips the -wal, so a store being written to right now can have
  // committed rows this pass cannot see. Harmless for a preview, and the real
  // run happens against a quiet store where the WAL has been checkpointed.
  say("  counts may lag whatever is still in the write-ahead log.");
  say("");
}

// ---------------------------------------------------------------- stores

/** The real stores are only ever read through this: no locks, no WAL recovery. */
function openReadOnly(path) {
  if (!existsSync(path)) die(`no such database: ${path}`);
  return new DatabaseSync(`file:${path}?immutable=1`, { readOnly: true });
}

function openForWrite(path) {
  if (!existsSync(path)) die(`no such database: ${path}`);
  return new DatabaseSync(path);
}

function backup(path) {
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..+/, "");
  for (const file of dbFiles(path)) {
    copyFileSync(file, `${file}.bak-${stamp}`);
  }
  return `${path}.bak-${stamp}`;
}

const MIRROR_COLUMNS = [
  "id",
  "provider",
  "cwd",
  "title",
  "status",
  "exit_code",
  "cli_session_id",
  "scrollback",
  "skip_permissions",
  "worktree_path",
  "usage",
  "created_at",
  "updated_at",
  "archived",
  "dormant",
  "dispatch_id",
  "mid_turn",
];

// No `scrollback` (it has no width, and a guessed width garbles the paint), no
// `mid_turn` (the daemon does not carry it). `kind`, `parent_session_id` and
// `title_is_manual` keep their defaults: an imported row is a plain agent session
// nobody renamed.
const DAEMON_COLUMNS = [
  "id",
  "provider",
  "cwd",
  "title",
  "status",
  "exit_code",
  "created_at",
  "updated_at",
  "cli_session_id",
  "skip_permissions",
  "worktree_path",
  "usage",
  "archived",
  "dormant",
  "dispatch_id",
];

/** Column names a table actually has, so a schema drift is a clear error. */
function columnsOf(db, table) {
  return new Set(
    db
      .prepare(`PRAGMA table_info(${table})`)
      .all()
      .map((c) => c.name),
  );
}

function assertColumns(db, table, wanted, label) {
  const have = columnsOf(db, table);
  const missing = wanted.filter((c) => !have.has(c));
  if (missing.length > 0) {
    die(`${label} is missing columns this import needs: ${missing.join(", ")}`);
  }
}

/**
 * Decide, per id, what the union wants: an insert, an update, or nothing.
 *
 * An id only the target knows is never in the answer — those 35 sessions were
 * created under the Rust core and clobbering them is the failure this avoids.
 */
function plan(source, target) {
  const theirs = new Map(
    target
      .prepare("SELECT id, updated_at FROM sessions")
      .all()
      .map((r) => [r.id, r.updated_at]),
  );
  const insert = [];
  const update = [];
  const skip = [];
  for (const row of source.prepare("SELECT id, updated_at FROM sessions").all()) {
    if (!theirs.has(row.id)) insert.push(row.id);
    else if (row.updated_at > theirs.get(row.id)) update.push(row.id);
    else skip.push(row.id);
  }
  return { insert, update, skip, targetOnly: theirs.size - (update.length + skip.length) };
}

/** Statement that writes one whole row, whether or not it was there before. */
function upsertSql(columns) {
  return (
    `INSERT OR REPLACE INTO sessions (${columns.join(", ")}) ` +
    `VALUES (${columns.map(() => "?").join(", ")})`
  );
}

function applyRows(source, target, ids, columns, { fts }) {
  const read = source.prepare(`SELECT ${columns.join(", ")} FROM sessions WHERE id = ?`);
  const write = target.prepare(upsertSql(columns));
  // fts5 with its own content: 'rebuild' is only legal on a contentless or
  // external-content table, so the index is maintained the way the app maintains
  // it — the old entry dropped, the new one written beside the row.
  const dropFts = fts ? target.prepare("DELETE FROM sessions_fts WHERE session_id = ?") : null;
  const addFts = fts
    ? target.prepare("INSERT INTO sessions_fts (session_id, title, scrollback) VALUES (?, ?, ?)")
    : null;

  let bytes = 0;
  target.exec("BEGIN IMMEDIATE");
  try {
    for (const id of ids) {
      const row = read.get(id);
      if (!row) continue;
      write.run(...columns.map((c) => row[c] ?? null));
      if (fts) {
        dropFts.run(id);
        addFts.run(id, row.title ?? "", row.scrollback ?? "");
      }
      bytes += (row.scrollback ?? "").length;
    }
    target.exec("COMMIT");
  } catch (err) {
    target.exec("ROLLBACK");
    throw err;
  }
  if (fts) {
    // Merges the segments the inserts above just fragmented. Never fatal.
    try {
      target.exec("INSERT INTO sessions_fts (sessions_fts) VALUES ('optimize')");
    } catch {
      /* an index too old to optimize still searches */
    }
  }
  return bytes;
}

// ---------------------------------------------------------------- passes

function describe(label, p) {
  say(
    `${label}: ${p.insert.length} to insert, ${p.update.length} to refresh, ` +
      `${p.skip.length} already current, ${p.targetOnly} only in the target (kept).`,
  );
}

const mb = (n) => `${(n / 1024 / 1024).toFixed(1)} MB`;

async function main() {
  const targets = [MIRROR_DB, ...(DO_DAEMON ? [DAEMON_DB] : [])];
  await assertSafe([SWIFT_DB, ...targets]);

  const swift = openReadOnly(SWIFT_DB);
  assertColumns(swift, "sessions", MIRROR_COLUMNS, "the Swift store");

  const summary = { write: WRITE, swift: SWIFT_DB, passes: {} };

  // Pass 1 — the desktop mirror. Same schema as the Swift store, so this is a
  // whole-row union, scrollback and search index included.
  {
    const mirror = WRITE ? openForWrite(MIRROR_DB) : openReadOnly(MIRROR_DB);
    assertColumns(mirror, "sessions", MIRROR_COLUMNS, "the desktop mirror");
    const p = plan(swift, mirror);
    describe(`mirror ${MIRROR_DB}`, p);
    summary.passes.mirror = {
      path: MIRROR_DB,
      insert: p.insert.length,
      update: p.update.length,
      skip: p.skip.length,
      targetOnly: p.targetOnly,
    };
    if (WRITE && p.insert.length + p.update.length > 0) {
      const saved = backup(MIRROR_DB);
      say(`  backed up to ${saved}`);
      const bytes = applyRows(swift, mirror, [...p.insert, ...p.update], MIRROR_COLUMNS, {
        fts: true,
      });
      say(`  wrote ${p.insert.length + p.update.length} sessions (${mb(bytes)} of scrollback)`);
      summary.passes.mirror.backup = saved;
      summary.passes.mirror.scrollbackBytes = bytes;
    }
    mirror.close();
  }

  // Pass 2 — the daemon's own store, metadata only, and only when asked for.
  if (DO_DAEMON) {
    const daemon = WRITE ? openForWrite(DAEMON_DB) : openReadOnly(DAEMON_DB);
    assertColumns(daemon, "sessions", DAEMON_COLUMNS, "the daemon store");
    const p = plan(swift, daemon);
    describe(`daemon ${DAEMON_DB}`, p);
    say("  metadata only: imported sessions read as empty, never as a guessed grid width.");
    summary.passes.daemon = {
      path: DAEMON_DB,
      insert: p.insert.length,
      update: p.update.length,
      skip: p.skip.length,
      targetOnly: p.targetOnly,
    };
    if (WRITE && p.insert.length + p.update.length > 0) {
      const saved = backup(DAEMON_DB);
      say(`  backed up to ${saved}`);
      applyRows(swift, daemon, [...p.insert, ...p.update], DAEMON_COLUMNS, { fts: false });
      say(`  wrote ${p.insert.length + p.update.length} sessions`);
      summary.passes.daemon.backup = saved;
    }
    daemon.close();
  }

  swift.close();

  if (!WRITE) {
    say("");
    say("dry run — nothing was written. Re-run with --write once the app is quit.");
  }
  if (AS_JSON) console.log(JSON.stringify({ ...summary, log }, null, 2));
}

main().catch((err) => die(err.stack || String(err)));
