import { mkdirSync } from "node:fs";
import { join } from "node:path";
import Database from "better-sqlite3";
import { DATA_DIR } from "./config.ts";
import type { DiffComment, ProviderId, ReviewResult, SessionMeta } from "./protocol.ts";

mkdirSync(DATA_DIR, { recursive: true });

const db = new Database(join(DATA_DIR, "juancode.db"));
db.pragma("journal_mode = WAL");

db.exec(`
  CREATE TABLE IF NOT EXISTS sessions (
    id              TEXT PRIMARY KEY,
    provider        TEXT NOT NULL,
    cwd             TEXT NOT NULL,
    title           TEXT NOT NULL,
    status          TEXT NOT NULL,
    exit_code       INTEGER,
    cli_session_id  TEXT,
    scrollback      TEXT NOT NULL DEFAULT '',
    skip_permissions INTEGER NOT NULL DEFAULT 0,
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL
  );
`);

const sessionCols = (db.prepare(`PRAGMA table_info(sessions)`).all() as { name: string }[]).map(
  (c) => c.name,
);
// Migration: add cli_session_id to databases created before resume support.
if (!sessionCols.includes("cli_session_id")) {
  db.exec(`ALTER TABLE sessions ADD COLUMN cli_session_id TEXT`);
}
// Migration: add skip_permissions ("accept all" mode) to pre-existing databases.
if (!sessionCols.includes("skip_permissions")) {
  db.exec(`ALTER TABLE sessions ADD COLUMN skip_permissions INTEGER NOT NULL DEFAULT 0`);
}
// Migration: add worktree_path (session-owned git worktree) to older databases.
if (!sessionCols.includes("worktree_path")) {
  db.exec(`ALTER TABLE sessions ADD COLUMN worktree_path TEXT`);
}

// GitHub-PR-style inline comments anchored to a (file, side, line..end_line) range.
db.exec(`
  CREATE TABLE IF NOT EXISTS diff_comments (
    id          TEXT PRIMARY KEY,
    session_id  TEXT NOT NULL,
    file        TEXT NOT NULL,
    side        TEXT NOT NULL,
    line        INTEGER NOT NULL,
    end_line    INTEGER NOT NULL,
    body        TEXT NOT NULL,
    created_at  INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_diff_comments_session ON diff_comments(session_id);
`);

// Migration: add end_line (multi-line ranges) to pre-existing comment tables,
// backfilling single-line comments so end_line == line.
const hasEndLine = (db.prepare(`PRAGMA table_info(diff_comments)`).all() as { name: string }[]).some(
  (c) => c.name === "end_line",
);
if (!hasEndLine) {
  db.exec(`ALTER TABLE diff_comments ADD COLUMN end_line INTEGER NOT NULL DEFAULT 0`);
  db.exec(`UPDATE diff_comments SET end_line = line WHERE end_line = 0`);
}

// Cached 'Review with Claude' pass — one (latest) result per session, stored as
// the JSON-serialized ReviewResult so the schema can evolve without migrations.
db.exec(`
  CREATE TABLE IF NOT EXISTS diff_reviews (
    session_id  TEXT PRIMARY KEY,
    payload     TEXT NOT NULL,
    created_at  INTEGER NOT NULL
  );
`);

// Full-text search index over each session's title + scrollback. A contentless
// FTS5 table keyed by the session id (`session_id` is UNINDEXED so we can fetch
// and delete by it). It's a read-only mirror of `sessions` — kept in sync from
// the insert/update/delete paths below, never edited directly by callers.
db.exec(`
  CREATE VIRTUAL TABLE IF NOT EXISTS sessions_fts USING fts5(
    session_id UNINDEXED,
    title,
    scrollback
  );
`);

// Backfill the FTS index from existing sessions the first time it's empty (i.e.
// for databases created before search support, or after a rebuild).
const ftsCount = (db.prepare(`SELECT COUNT(*) AS n FROM sessions_fts`).get() as { n: number }).n;
if (ftsCount === 0) {
  db.exec(`
    INSERT INTO sessions_fts (session_id, title, scrollback)
    SELECT id, title, scrollback FROM sessions
  `);
}

interface Row {
  id: string;
  provider: string;
  cwd: string;
  title: string;
  status: string;
  exit_code: number | null;
  cli_session_id: string | null;
  skip_permissions: number;
  worktree_path: string | null;
  created_at: number;
  updated_at: number;
}

interface SearchRow extends Row {
  snippet: string;
}

/** A session matched by full-text search, plus a highlighted snippet of the hit. */
export interface SearchHit extends SessionMeta {
  /** Scrollback excerpt with the matched terms wrapped in `[` … `]`. */
  snippet: string;
}

const rowToMeta = (r: Row): SessionMeta => ({
  id: r.id,
  provider: r.provider as ProviderId,
  cwd: r.cwd,
  title: r.title,
  status: r.status === "running" ? "running" : "exited",
  exitCode: r.exit_code,
  cliSessionId: r.cli_session_id ?? null,
  skipPermissions: r.skip_permissions === 1,
  worktreePath: r.worktree_path ?? null,
  createdAt: r.created_at,
  updatedAt: r.updated_at,
});

const insertStmt = db.prepare(`
  INSERT INTO sessions (id, provider, cwd, title, status, exit_code, cli_session_id, scrollback, skip_permissions, worktree_path, created_at, updated_at)
  VALUES (@id, @provider, @cwd, @title, @status, @exitCode, @cliSessionId, '', @skipPermissions, @worktreePath, @createdAt, @updatedAt)
`);

const updateStmt = db.prepare(`
  UPDATE sessions
  SET title = @title, status = @status, exit_code = @exitCode, cli_session_id = @cliSessionId, scrollback = @scrollback, skip_permissions = @skipPermissions, worktree_path = @worktreePath, updated_at = @updatedAt
  WHERE id = @id
`);

const setCliSessionIdStmt = db.prepare(`UPDATE sessions SET cli_session_id = @cliSessionId WHERE id = @id`);
const usedCliSessionIdsStmt = db.prepare(`SELECT cli_session_id FROM sessions WHERE cli_session_id IS NOT NULL`);

const listStmt = db.prepare(`SELECT * FROM sessions ORDER BY created_at DESC`);
const getStmt = db.prepare(`SELECT * FROM sessions WHERE id = ?`);
const scrollbackStmt = db.prepare(`SELECT scrollback FROM sessions WHERE id = ?`);

// Join FTS matches back to the full session row and build a highlighted snippet
// of the scrollback (falling back to the title when the match is in the title).
// `[` / `]` mark the matched terms; ordered by relevance then recency.
const searchStmt = db.prepare(`
  SELECT s.*, snippet(sessions_fts, 2, '[', ']', '…', 12) AS snippet
  FROM sessions_fts f
  JOIN sessions s ON s.id = f.session_id
  WHERE sessions_fts MATCH @query
  ORDER BY bm25(sessions_fts), s.updated_at DESC
  LIMIT @limit
`);

const deleteSessionStmt = db.prepare(`DELETE FROM sessions WHERE id = ?`);
const deleteSessionCommentsStmt = db.prepare(`DELETE FROM diff_comments WHERE session_id = ?`);
const deleteSessionReviewStmt = db.prepare(`DELETE FROM diff_reviews WHERE session_id = ?`);

// FTS sync: the index is contentless, so a "row update" is delete-then-insert.
const ftsDeleteStmt = db.prepare(`DELETE FROM sessions_fts WHERE session_id = ?`);
const ftsInsertStmt = db.prepare(
  `INSERT INTO sessions_fts (session_id, title, scrollback) VALUES (@id, @title, @scrollback)`,
);
/** Replace a session's row in the FTS index with the current title + scrollback. */
const syncFts = db.transaction((id: string, title: string, scrollback: string): void => {
  ftsDeleteStmt.run(id);
  ftsInsertStmt.run({ id, title, scrollback });
});

/**
 * Turn free-text user input into a safe FTS5 MATCH expression. Each whitespace
 * token becomes a quoted, prefix-matched term ANDed together — so the user can
 * type plain words without worrying about FTS operator syntax, and stray quotes
 * or operators can't produce a syntax error. Returns "" when there's nothing to
 * search for.
 */
export function toFtsMatch(query: string): string {
  return query
    .trim()
    .split(/\s+/)
    .filter(Boolean)
    // Escape embedded double-quotes by doubling them, wrap as a phrase, then add
    // a trailing `*` so typing prefixes ("foo") still matches "foobar".
    .map((tok) => `"${tok.replace(/"/g, '""')}"*`)
    .join(" AND ");
}

// Atomically drop a session and everything anchored to it (incl. its FTS row).
const deleteSessionTxn = db.transaction((id: string): boolean => {
  deleteSessionCommentsStmt.run(id);
  deleteSessionReviewStmt.run(id);
  ftsDeleteStmt.run(id);
  return deleteSessionStmt.run(id).changes > 0;
});

export const sessionDb = {
  insert(meta: SessionMeta): void {
    insertStmt.run({ ...meta, skipPermissions: meta.skipPermissions ? 1 : 0 });
    syncFts(meta.id, meta.title, "");
  },

  update(meta: SessionMeta, scrollback: string): void {
    updateStmt.run({ ...meta, scrollback, skipPermissions: meta.skipPermissions ? 1 : 0 });
    syncFts(meta.id, meta.title, scrollback);
  },

  setCliSessionId(id: string, cliSessionId: string): void {
    setCliSessionIdStmt.run({ id, cliSessionId });
  },

  /** Every CLI session id already claimed — so recovery can't reuse one. */
  usedCliSessionIds(): Set<string> {
    const rows = usedCliSessionIdsStmt.all() as { cli_session_id: string }[];
    return new Set(rows.map((r) => r.cli_session_id));
  },

  list(): SessionMeta[] {
    return (listStmt.all() as Row[]).map(rowToMeta);
  },

  get(id: string): SessionMeta | undefined {
    const row = getStmt.get(id) as Row | undefined;
    return row ? rowToMeta(row) : undefined;
  },

  getScrollback(id: string): string {
    const row = scrollbackStmt.get(id) as { scrollback: string } | undefined;
    return row?.scrollback ?? "";
  },

  /**
   * Full-text search over session titles + scrollback for the given free-text
   * `query`. Returns matching sessions (by relevance, then recency) each with a
   * highlighted scrollback snippet. Returns `[]` for a blank query. `limit` caps
   * the result count.
   */
  search(query: string, limit = 50): SearchHit[] {
    const match = toFtsMatch(query);
    if (!match) return [];
    const rows = searchStmt.all({ query: match, limit }) as SearchRow[];
    return rows.map((r) => ({
      ...rowToMeta(r),
      snippet: r.snippet,
    }));
  },

  /**
   * Permanently remove a session and its associated comments + cached review.
   * Returns true when a session row was actually deleted.
   */
  delete(id: string): boolean {
    return deleteSessionTxn(id);
  },

  /**
   * On startup, any session still marked "running" is stale — its pty died with
   * the previous server process. Mark them exited so the UI shows truth.
   */
  markOrphansExited(): void {
    db.prepare(`UPDATE sessions SET status = 'exited' WHERE status = 'running'`).run();
  },
};

const insertCommentStmt = db.prepare(`
  INSERT INTO diff_comments (id, session_id, file, side, line, end_line, body, created_at)
  VALUES (@id, @sessionId, @file, @side, @line, @endLine, @body, @createdAt)
`);
const listCommentsStmt = db.prepare(
  `SELECT * FROM diff_comments WHERE session_id = ? ORDER BY created_at ASC`,
);
const deleteCommentStmt = db.prepare(`DELETE FROM diff_comments WHERE id = ? AND session_id = ?`);
const clearCommentsStmt = db.prepare(`DELETE FROM diff_comments WHERE session_id = ?`);

interface CommentRow {
  id: string;
  session_id: string;
  file: string;
  side: string;
  line: number;
  end_line: number;
  body: string;
  created_at: number;
}

const rowToComment = (r: CommentRow): DiffComment => ({
  id: r.id,
  sessionId: r.session_id,
  file: r.file,
  side: r.side === "old" ? "old" : "new",
  line: r.line,
  endLine: r.end_line,
  body: r.body,
  createdAt: r.created_at,
});

export const commentDb = {
  add(c: DiffComment): void {
    insertCommentStmt.run(c);
  },

  list(sessionId: string): DiffComment[] {
    return (listCommentsStmt.all(sessionId) as CommentRow[]).map(rowToComment);
  },

  /** Returns true when a row was deleted (i.e. it belonged to this session). */
  remove(sessionId: string, id: string): boolean {
    return deleteCommentStmt.run(id, sessionId).changes > 0;
  },

  /** Drop all comments for a session (used after a batched review is sent). */
  clear(sessionId: string): number {
    return clearCommentsStmt.run(sessionId).changes;
  },
};

const upsertReviewStmt = db.prepare(`
  INSERT INTO diff_reviews (session_id, payload, created_at)
  VALUES (@sessionId, @payload, @createdAt)
  ON CONFLICT(session_id) DO UPDATE SET payload = @payload, created_at = @createdAt
`);
const getReviewStmt = db.prepare(`SELECT payload FROM diff_reviews WHERE session_id = ?`);

export const reviewDb = {
  /** Store (overwriting) the latest review for a session. */
  save(sessionId: string, result: ReviewResult): void {
    upsertReviewStmt.run({ sessionId, payload: JSON.stringify(result), createdAt: result.createdAt });
  },

  /** The cached review for a session, or null if none has been run. */
  get(sessionId: string): ReviewResult | null {
    const row = getReviewStmt.get(sessionId) as { payload: string } | undefined;
    if (!row) return null;
    try {
      return JSON.parse(row.payload) as ReviewResult;
    } catch {
      return null;
    }
  },
};

export default db;
