// Progressive-disclosure recall over Claude Code session transcripts (juancode-48wz).
//
// Claude Code already writes every session to ~/.claude/projects/<slug>/<sessionId>.jsonl,
// so we index what is on disk rather than capturing anything new: no extra runtime, no
// vector DB, no always-on worker. SQLite FTS5 (via the bundled node:sqlite) gives keyword
// search; the two-step search -> excerpt shape keeps recall cheap in tokens, since a hit
// list is a few dozen tokens and full text is only fetched for the ids that matter.
//
// The index is local-only and lives next to the native app's DB under ~/.juancode/data.
// Transcripts contain confidential tool output, so nothing here fans out on its own —
// callers decide what to surface.

import { DatabaseSync } from "node:sqlite";
import { closeSync, mkdirSync, openSync, readSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import { parseTranscriptLine } from "./transcript-lines.ts";

export { parseTranscriptLine } from "./transcript-lines.ts";

/** One search hit: enough to decide whether to fetch the full excerpt, no more. */
export type SearchHit = {
  id: number;
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
};

export type RefreshStats = { filesScanned: number; filesUpdated: number; entriesAdded: number };

/** Guard against a runaway line (a single huge base64 blob) before it reaches JSON.parse. */
const MAX_LINE_BYTES = 2_000_000;
const DEFAULT_LIMIT = 20;
const MAX_LIMIT = 100;

export function transcriptsDir(): string {
  return process.env.JUANCODE_CLAUDE_PROJECTS_DIR ?? join(homedir(), ".claude", "projects");
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
    CREATE TABLE IF NOT EXISTS entries (
      id INTEGER PRIMARY KEY,
      path TEXT NOT NULL,
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

/** Bring the index up to date. Only bytes appended since the last run are read, so a
 *  warm index refreshes in milliseconds even with hundreds of megabytes on disk. */
export function refreshIndex(db = openIndex(), root = transcriptsDir()): RefreshStats {
  const stats: RefreshStats = { filesScanned: 0, filesUpdated: 0, entriesAdded: 0 };
  const known = new Map<string, { offset: number; mtimeMs: number }>();
  for (const row of db.prepare("SELECT path, offset, mtimeMs FROM files").all()) {
    const r = row as { path: string; offset: number; mtimeMs: number };
    known.set(r.path, { offset: r.offset, mtimeMs: r.mtimeMs });
  }

  const insertEntry = db.prepare(
    "INSERT INTO entries (path, sessionId, project, branch, ts, role, text) VALUES (?, ?, ?, ?, ?, ?, ?)",
  );
  const insertFts = db.prepare("INSERT INTO entries_fts (rowid, text) VALUES (?, ?)");
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
      dropFile(db, path);
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
        const res = insertEntry.run(
          path,
          entry.sessionId || fallbackSession,
          entry.project,
          entry.branch,
          entry.ts,
          entry.role,
          entry.text,
        );
        insertFts.run(res.lastInsertRowid, entry.text);
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
  return stats;
}

function dropFile(db: DatabaseSync, path: string): void {
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
  params.push(limit);
  const rows = db
    .prepare(
      `SELECT e.id, e.sessionId, e.project, e.branch, e.ts, e.role,
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
    .prepare("SELECT id, path, sessionId, project, branch, ts, role, text FROM entries WHERE id = ?")
    .get(id);
  if (!row) return undefined;
  const r = row as Record<string, unknown>;
  const hit: Excerpt = {
    id: Number(r.id),
    sessionId: String(r.sessionId),
    project: String(r.project),
    branch: String(r.branch),
    ts: String(r.ts),
    role: String(r.role),
    text: String(r.text),
  };
  const span = Math.min(Math.max(contextEntries, 0), 20);
  if (!span) return hit;
  // Neighbours by rank within the file, not by id arithmetic: a session indexed over
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
