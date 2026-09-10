// Progressive-disclosure recall over past agent sessions (juancode-48wz, juancode-eo4r).
//
// Every agent already writes its sessions somewhere on disk — Claude Code to
// ~/.claude/projects/<slug>/<sessionId>.jsonl, opencode to a SQLite DB under
// ~/.local/share/opencode — so we index what is already there rather than capturing
// anything new: no extra runtime, no vector DB, no always-on worker. SQLite FTS5 (via the
// bundled node:sqlite) gives keyword search; the two-step search -> excerpt shape keeps
// recall cheap in tokens, since a hit list is a few dozen tokens and full text is only
// fetched for the ids that matter.
//
// One store, several readers: each `IndexSource` writes rows tagged with its own `agent`,
// which comes back on every hit, so an answer can say which agent said a thing. Rows are
// never merged across agents — two agents saying the same thing is a signal, not a dupe.
//
// The index is local-only and lives next to the native app's DB under ~/.juancode/data.
// Transcripts contain confidential tool output, so nothing here fans out on its own —
// callers decide what to surface.

import { DatabaseSync } from "node:sqlite";
import {
  closeSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readSync,
  readdirSync,
  rmSync,
  statSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { parseTranscriptLine } from "./transcript-lines.ts";
import { parseOpencodeMessage, textOfParts } from "./opencode-parts.ts";

export { parseTranscriptLine } from "./transcript-lines.ts";

/** Which agent produced an entry. Open-ended on purpose: a third reader adds a label. */
export type AgentLabel = "claude" | "opencode" | (string & {});

/** One search hit: enough to decide whether to fetch the full excerpt, no more. */
export type SearchHit = {
  id: number;
  /** Which agent's session this came from. */
  agent: AgentLabel;
  sessionId: string;
  /** Last two path segments of the session's cwd — enough to tell projects apart
   *  without spending tokens on `/Users/<me>/workdir/...` on every row. */
  project: string;
  branch: string;
  ts: string;
  role: string;
  snippet: string;
};

/** A single indexed transcript entry, plus its neighbours when asked for. */
export type Excerpt = {
  id: number;
  agent: AgentLabel;
  sessionId: string;
  project: string;
  branch: string;
  ts: string;
  role: string;
  text: string;
  context?: { id: number; role: string; ts: string; text: string }[];
};

export type SearchOptions = {
  limit?: number;
  /** Substring match against the session's cwd (e.g. "juancode"). */
  project?: string;
  /** ISO timestamp lower bound, inclusive. */
  since?: string;
  /** Restrict to these agents; omitted or empty means every agent. */
  agents?: AgentLabel[];
};

/** `filesScanned` / `filesUpdated` count source units: a jsonl transcript for Claude
 *  Code, a session for opencode. */
export type RefreshStats = { filesScanned: number; filesUpdated: number; entriesAdded: number };

/** A row on its way into the index, before it gets an id. */
export type IndexedEntry = {
  agent: AgentLabel;
  /** Grouping key for neighbour lookups: a transcript path, or `opencode:<sessionId>`. */
  path: string;
  /** Stable id of this row in its source, so a re-read replaces instead of duplicating.
   *  Empty for append-only sources (Claude's jsonl) where a row can never change. */
  srcId: string;
  sessionId: string;
  project: string;
  branch: string;
  ts: string;
  role: string;
  text: string;
};

/** What a reader gets handed: the open index, the stats to bump, and a row writer.
 *  `addEntry` returns false when the row was already indexed unchanged. */
export type SourceContext = {
  db: DatabaseSync;
  stats: RefreshStats;
  addEntry: (entry: IndexedEntry) => boolean;
};

/** One place sessions come from. Add a third by writing one of these. */
export type IndexSource = {
  agent: AgentLabel;
  refresh: (ctx: SourceContext) => void;
};

/** Guard against a runaway line (a single huge base64 blob) before it reaches JSON.parse. */
const MAX_LINE_BYTES = 2_000_000;
const DEFAULT_LIMIT = 20;
const MAX_LIMIT = 100;

export function transcriptsDir(): string {
  return process.env.JUANCODE_CLAUDE_PROJECTS_DIR ?? join(homedir(), ".claude", "projects");
}

export function opencodeDbPath(): string {
  return (
    process.env.JUANCODE_OPENCODE_DB ??
    join(homedir(), ".local", "share", "opencode", "opencode.db")
  );
}

export function indexDbPath(): string {
  return (
    process.env.JUANCODE_TRANSCRIPT_INDEX_DB ??
    join(homedir(), ".juancode", "data", "transcript-index.db")
  );
}

let cached: { path: string; db: DatabaseSync } | undefined;

/** Open (and migrate) the index DB, memoised per path so repeated tool calls are cheap. */
export function openIndex(path = indexDbPath()): DatabaseSync {
  if (cached?.path === path) return cached.db;
  cached?.db.close();
  if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true });
  const db = new DatabaseSync(path);
  db.exec("PRAGMA journal_mode = WAL");
  db.exec(`
    CREATE TABLE IF NOT EXISTS files (
      path TEXT PRIMARY KEY,
      offset INTEGER NOT NULL,
      mtimeMs REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS cursors (
      key TEXT PRIMARY KEY,
      value REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS entries (
      id INTEGER PRIMARY KEY,
      path TEXT NOT NULL,
      agent TEXT NOT NULL DEFAULT 'claude',
      srcId TEXT NOT NULL DEFAULT '',
      sessionId TEXT NOT NULL,
      project TEXT NOT NULL,
      branch TEXT NOT NULL,
      ts TEXT NOT NULL,
      role TEXT NOT NULL,
      text TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS entries_path_id ON entries(path, id);
    CREATE INDEX IF NOT EXISTS entries_session ON entries(sessionId);
    CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
      text, content='entries', content_rowid='id'
    );
  `);
  // An index built before provenance existed predates the two columns above.
  const columns = new Set(
    db
      .prepare("PRAGMA table_info(entries)")
      .all()
      .map((r) => String((r as Record<string, unknown>).name)),
  );
  if (!columns.has("agent")) db.exec("ALTER TABLE entries ADD COLUMN agent TEXT NOT NULL DEFAULT 'claude'");
  if (!columns.has("srcId")) db.exec("ALTER TABLE entries ADD COLUMN srcId TEXT NOT NULL DEFAULT ''");
  db.exec("CREATE INDEX IF NOT EXISTS entries_agent ON entries(agent)");
  db.exec(
    "CREATE UNIQUE INDEX IF NOT EXISTS entries_src ON entries(agent, srcId) WHERE srcId <> ''",
  );
  cached = { path, db };
  return db;
}

/** Drop the memoised handle (tests open several DBs in one process). */
export function closeIndex(): void {
  cached?.db.close();
  cached = undefined;
}

/** Read `path` from `offset` to EOF, returning whole lines only. The trailing partial
 *  line of a session still being written is left for the next refresh. */
function readNewLines(path: string, offset: number, size: number): { lines: string[]; consumed: number } {
  if (size <= offset) return { lines: [], consumed: offset };
  const fd = openSync(path, "r");
  try {
    const buf = Buffer.allocUnsafe(size - offset);
    let read = 0;
    while (read < buf.length) {
      const n = readSync(fd, buf, read, buf.length - read, offset + read);
      if (n <= 0) break;
      read += n;
    }
    const chunk = buf.subarray(0, read);
    const lastBreak = chunk.lastIndexOf(0x0a);
    if (lastBreak < 0) return { lines: [], consumed: offset };
    const complete = chunk.subarray(0, lastBreak).toString("utf8");
    const lines = complete.split("\n").filter((l) => l.length > 0 && l.length <= MAX_LINE_BYTES);
    return { lines, consumed: offset + lastBreak + 1 };
  } finally {
    closeSync(fd);
  }
}

function listTranscripts(root: string): string[] {
  let dirs: string[];
  try {
    dirs = readdirSync(root, { withFileTypes: true })
      .filter((d) => d.isDirectory())
      .map((d) => join(root, d.name));
  } catch {
    return [];
  }
  const files: string[] = [];
  for (const dir of dirs) {
    try {
      for (const f of readdirSync(dir)) {
        if (f.endsWith(".jsonl")) files.push(join(dir, f));
      }
    } catch {
      // A project dir that vanished mid-scan is not an error worth failing the search for.
    }
  }
  return files;
}

/** Claude Code: append-only JSONL under ~/.claude/projects. Only bytes appended since the
 *  last run are read, so a warm index refreshes in milliseconds even with hundreds of
 *  megabytes on disk. */
export function claudeSource(root = transcriptsDir()): IndexSource {
  return {
    agent: "claude",
    refresh({ db, stats, addEntry }) {
      const known = new Map<string, { offset: number; mtimeMs: number }>();
      for (const row of db.prepare("SELECT path, offset, mtimeMs FROM files").all()) {
        const r = row as { path: string; offset: number; mtimeMs: number };
        known.set(r.path, { offset: r.offset, mtimeMs: r.mtimeMs });
      }
      const upsertFile = db.prepare(
        "INSERT INTO files (path, offset, mtimeMs) VALUES (?, ?, ?) ON CONFLICT(path) DO UPDATE SET offset = excluded.offset, mtimeMs = excluded.mtimeMs",
      );

      for (const path of listTranscripts(root)) {
        let size: number;
        let mtimeMs: number;
        try {
          const st = statSync(path);
          size = st.size;
          mtimeMs = st.mtimeMs;
        } catch {
          continue;
        }
        stats.filesScanned += 1;
        const prev = known.get(path);
        let offset = prev?.offset ?? 0;
        // A shrunken file was rewritten (resume/compaction), so its rows are stale.
        if (prev && size < prev.offset) {
          dropGroup(db, path);
          offset = 0;
        } else if (prev && size === prev.offset && mtimeMs === prev.mtimeMs) {
          continue;
        }

        const { lines, consumed } = readNewLines(path, offset, size);
        if (!lines.length && consumed === offset) {
          upsertFile.run(path, consumed, mtimeMs);
          continue;
        }
        const fallbackSession = basename(path, ".jsonl");
        db.exec("BEGIN");
        try {
          for (const line of lines) {
            const entry = parseTranscriptLine(line);
            if (!entry) continue;
            addEntry({
              agent: "claude",
              path,
              srcId: "",
              sessionId: entry.sessionId || fallbackSession,
              project: entry.project,
              branch: entry.branch,
              ts: entry.ts,
              role: entry.role,
              text: entry.text,
            });
            stats.entriesAdded += 1;
          }
          upsertFile.run(path, consumed, mtimeMs);
          db.exec("COMMIT");
        } catch (e) {
          db.exec("ROLLBACK");
          throw e;
        }
        stats.filesUpdated += 1;
      }
    },
  };
}

/** Open opencode's store without ever writing to it. A live opencode session holds the
 *  DB in WAL mode, so a plain read-only open is tried first (it sees committed WAL
 *  frames); if the -shm handshake refuses us, fall back to reading a throwaway copy. */
function openOpencodeReadOnly(path: string): { db: DatabaseSync; cleanup: () => void } {
  try {
    return { db: new DatabaseSync(path, { readOnly: true }), cleanup: () => {} };
  } catch {
    const dir = mkdtempSync(join(tmpdir(), "juancode-opencode-"));
    const copy = join(dir, "opencode.db");
    copyFileSync(path, copy);
    for (const suffix of ["-wal", "-shm"]) {
      if (existsSync(path + suffix)) copyFileSync(path + suffix, copy + suffix);
    }
    return {
      db: new DatabaseSync(copy, { readOnly: true }),
      cleanup: () => rmSync(dir, { recursive: true, force: true }),
    };
  }
}

type OpencodeRow = {
  id: string;
  sessionId: string;
  created: number;
  updated: number;
  data: string;
};

/** opencode: one SQLite DB, one row per message plus one row per part. Refresh is keyed
 *  on `time_updated` the way the file reader is keyed on mtime and size — and on the
 *  parts' `time_updated` too, since a streamed part can land after its message row. */
export function opencodeSource(path = opencodeDbPath()): IndexSource {
  return {
    agent: "opencode",
    refresh({ db, stats, addEntry }) {
      if (!existsSync(path)) return;
      const cursorKey = `opencode:${path}`;
      const cursorRow = db.prepare("SELECT value FROM cursors WHERE key = ?").get(cursorKey);
      const since = cursorRow ? Number((cursorRow as Record<string, unknown>).value) : 0;

      const { db: src, cleanup } = openOpencodeReadOnly(path);
      let rows: OpencodeRow[];
      let directories: Map<string, string>;
      try {
        rows = src
          .prepare(
            `SELECT m.id AS id, m.session_id AS sessionId, m.time_created AS created,
                    MAX(m.time_updated, COALESCE(p.pmax, 0)) AS updated, m.data AS data
               FROM message m
               LEFT JOIN (SELECT message_id, MAX(time_updated) AS pmax FROM part GROUP BY message_id) p
                 ON p.message_id = m.id
              WHERE MAX(m.time_updated, COALESCE(p.pmax, 0)) >= ?
              ORDER BY created ASC, id ASC`,
          )
          .all(since) as unknown as OpencodeRow[];
        directories = new Map(
          src
            .prepare("SELECT id, directory FROM session")
            .all()
            .map((r) => {
              const s = r as Record<string, unknown>;
              return [String(s.id), String(s.directory ?? "")] as const;
            }),
        );
        // Pull the parts for exactly the messages we are about to (re)index.
        const partsOf = src.prepare(
          "SELECT data FROM part WHERE message_id = ? ORDER BY time_created ASC, id ASC",
        );
        const updated = new Set<string>();
        let watermark = since;
        db.exec("BEGIN");
        try {
          for (const row of rows) {
            watermark = Math.max(watermark, Number(row.updated));
            const message = parseOpencodeMessage(row.data);
            if (!message) continue;
            const parts = partsOf.all(row.id).map((p) => String((p as Record<string, unknown>).data));
            const text = textOfParts(parts);
            if (!text) continue;
            const wrote = addEntry({
              agent: "opencode",
              path: `opencode:${row.sessionId}`,
              srcId: row.id,
              sessionId: row.sessionId,
              project: message.cwd || directories.get(row.sessionId) || "",
              // opencode does not record a git branch on a message.
              branch: "",
              ts: new Date(Number(row.created)).toISOString(),
              role: message.role,
              text,
            });
            if (!wrote) continue;
            stats.entriesAdded += 1;
            updated.add(row.sessionId);
          }
          db.prepare(
            "INSERT INTO cursors (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
          ).run(cursorKey, watermark);
          db.exec("COMMIT");
        } catch (e) {
          db.exec("ROLLBACK");
          throw e;
        }
        stats.filesScanned += directories.size;
        stats.filesUpdated += updated.size;
      } finally {
        src.close();
        cleanup();
      }
    },
  };
}

/** Every reader this machine has. opencode is skipped silently when it is not installed. */
export function defaultSources(): IndexSource[] {
  return [claudeSource(), opencodeSource()];
}

/** Insert rows, replacing whatever a source wrote earlier for the same `srcId`. That is
 *  the only dedup there is: same session, same source, read twice. Nothing is ever
 *  deduped across agents. A row that comes back byte-identical is left alone, so a
 *  watermark that overlaps by one tick costs nothing. */
function entryWriter(db: DatabaseSync): (entry: IndexedEntry) => boolean {
  // `srcId <> ''` is redundant for a caller (we only run these with a real srcId) but it
  // is what lets SQLite use the partial `entries_src` index instead of scanning; without
  // it a cold opencode index is quadratic.
  const existing = db.prepare("SELECT text FROM entries WHERE agent = ? AND srcId = ? AND srcId <> ''");
  const unindex = db.prepare(
    "INSERT INTO entries_fts (entries_fts, rowid, text) SELECT 'delete', id, text FROM entries WHERE agent = ? AND srcId = ? AND srcId <> ''",
  );
  const remove = db.prepare("DELETE FROM entries WHERE agent = ? AND srcId = ? AND srcId <> ''");
  const insert = db.prepare(
    "INSERT INTO entries (path, agent, srcId, sessionId, project, branch, ts, role, text) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
  );
  const insertFts = db.prepare("INSERT INTO entries_fts (rowid, text) VALUES (?, ?)");
  return (e) => {
    if (e.srcId) {
      const prev = existing.get(e.agent, e.srcId);
      if (prev && String((prev as Record<string, unknown>).text) === e.text) return false;
      unindex.run(e.agent, e.srcId);
      remove.run(e.agent, e.srcId);
    }
    const res = insert.run(
      e.path,
      e.agent,
      e.srcId,
      e.sessionId,
      e.project,
      e.branch,
      e.ts,
      e.role,
      e.text,
    );
    insertFts.run(res.lastInsertRowid, e.text);
    return true;
  };
}

/** Bring the index up to date across every source. Passing a string keeps the old
 *  single-source shape: "index the Claude transcripts rooted here, nothing else". */
export function refreshIndex(
  db = openIndex(),
  sources: string | IndexSource[] = defaultSources(),
): RefreshStats {
  const stats: RefreshStats = { filesScanned: 0, filesUpdated: 0, entriesAdded: 0 };
  const list = typeof sources === "string" ? [claudeSource(sources)] : sources;
  const ctx: SourceContext = { db, stats, addEntry: entryWriter(db) };
  for (const source of list) source.refresh(ctx);
  return stats;
}

/** Forget everything indexed under one grouping key (a rewritten transcript file). */
function dropGroup(db: DatabaseSync, path: string): void {
  db.exec("BEGIN");
  try {
    db.prepare(
      "INSERT INTO entries_fts (entries_fts, rowid, text) SELECT 'delete', id, text FROM entries WHERE path = ?",
    ).run(path);
    db.prepare("DELETE FROM entries WHERE path = ?").run(path);
    db.prepare("DELETE FROM files WHERE path = ?").run(path);
    db.exec("COMMIT");
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }
}

/** Turn a natural-language query into an FTS5 MATCH expression. Quoting each term keeps
 *  user punctuation (`~/.juancode/data`, `bd-42`) from being read as FTS operators. */
export function toMatchExpression(query: string): string {
  const terms = query
    .split(/\s+/)
    .map((t) => t.replace(/"/g, "").trim())
    .filter(Boolean);
  if (!terms.length) return "";
  return terms.map((t) => `"${t}"`).join(" AND ");
}

/** `/Users/me/workdir/personal/juancode` -> `personal/juancode`. */
export function shortProject(cwd: string): string {
  const parts = cwd.split("/").filter(Boolean);
  return parts.slice(-2).join("/") || cwd;
}

/** Compact hit list: ids plus a one-line snippet, nothing else. Fetch bodies with
 *  `getExcerpt` only for the ids worth reading. */
export function searchTranscripts(
  query: string,
  opts: SearchOptions = {},
  db = openIndex(),
): SearchHit[] {
  const match = toMatchExpression(query);
  if (!match) return [];
  const limit = Math.min(Math.max(opts.limit ?? DEFAULT_LIMIT, 1), MAX_LIMIT);
  const where = ["entries_fts MATCH ?"];
  const params: (string | number)[] = [match];
  if (opts.project) {
    where.push("e.project LIKE ?");
    params.push(`%${opts.project}%`);
  }
  if (opts.since) {
    where.push("e.ts >= ?");
    params.push(opts.since);
  }
  if (opts.agents?.length) {
    where.push(`e.agent IN (${opts.agents.map(() => "?").join(", ")})`);
    params.push(...opts.agents);
  }
  params.push(limit);
  const rows = db
    .prepare(
      `SELECT e.id, e.agent, e.sessionId, e.project, e.branch, e.ts, e.role,
              snippet(entries_fts, 0, '', '', '…', 12) AS snippet
         FROM entries_fts
         JOIN entries e ON e.id = entries_fts.rowid
        WHERE ${where.join(" AND ")}
        ORDER BY rank
        LIMIT ?`,
    )
    .all(...params);
  return rows.map((row) => {
    const r = row as Record<string, unknown>;
    return {
      id: Number(r.id),
      agent: String(r.agent),
      sessionId: String(r.sessionId),
      project: shortProject(String(r.project)),
      branch: String(r.branch),
      ts: String(r.ts),
      role: String(r.role),
      snippet: String(r.snippet ?? "")
        .replace(/\s+/g, " ")
        .trim(),
    };
  });
}

/** Full text for one hit, optionally with the surrounding turns from the same session. */
export function getExcerpt(id: number, contextEntries = 0, db = openIndex()): Excerpt | undefined {
  const row = db
    .prepare(
      "SELECT id, path, agent, sessionId, project, branch, ts, role, text FROM entries WHERE id = ?",
    )
    .get(id);
  if (!row) return undefined;
  const r = row as Record<string, unknown>;
  const hit: Excerpt = {
    id: Number(r.id),
    agent: String(r.agent),
    sessionId: String(r.sessionId),
    project: String(r.project),
    branch: String(r.branch),
    ts: String(r.ts),
    role: String(r.role),
    text: String(r.text),
  };
  const span = Math.min(Math.max(contextEntries, 0), 20);
  if (!span) return hit;
  // Neighbours by rank within the group, not by id arithmetic: a session indexed over
  // several refreshes has gaps in its id range.
  const path = String(r.path);
  const before = db
    .prepare("SELECT id, role, ts, text FROM entries WHERE path = ? AND id < ? ORDER BY id DESC LIMIT ?")
    .all(path, hit.id, span)
    .reverse();
  const after = db
    .prepare("SELECT id, role, ts, text FROM entries WHERE path = ? AND id > ? ORDER BY id ASC LIMIT ?")
    .all(path, hit.id, span);
  hit.context = [...before, ...after].map((n) => {
    const c = n as Record<string, unknown>;
    return {
      id: Number(c.id),
      role: String(c.role),
      ts: String(c.ts),
      text: String(c.text),
    };
  });
  return hit;
}

/** Refresh, then search — the shape the MCP tools use. */
export function searchWithRefresh(
  query: string,
  opts: SearchOptions = {},
): { hits: SearchHit[]; refresh: RefreshStats } {
  const db = openIndex();
  const refresh = refreshIndex(db);
  return { hits: searchTranscripts(query, opts, db), refresh };
}
