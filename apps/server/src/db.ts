import { mkdirSync } from "node:fs";
import { join } from "node:path";
import Database from "better-sqlite3";
import { DATA_DIR } from "./config.ts";
import type { DiffComment, ProviderId, SessionMeta } from "./protocol.ts";

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
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL
  );
`);

// Migration: add cli_session_id to databases created before resume support.
const hasCliSessionId = (db.prepare(`PRAGMA table_info(sessions)`).all() as { name: string }[]).some(
  (c) => c.name === "cli_session_id",
);
if (!hasCliSessionId) {
  db.exec(`ALTER TABLE sessions ADD COLUMN cli_session_id TEXT`);
}

// GitHub-PR-style inline comments anchored to a (file, side, line) in a diff.
db.exec(`
  CREATE TABLE IF NOT EXISTS diff_comments (
    id          TEXT PRIMARY KEY,
    session_id  TEXT NOT NULL,
    file        TEXT NOT NULL,
    side        TEXT NOT NULL,
    line        INTEGER NOT NULL,
    body        TEXT NOT NULL,
    created_at  INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_diff_comments_session ON diff_comments(session_id);
`);

interface Row {
  id: string;
  provider: string;
  cwd: string;
  title: string;
  status: string;
  exit_code: number | null;
  cli_session_id: string | null;
  created_at: number;
  updated_at: number;
}

const rowToMeta = (r: Row): SessionMeta => ({
  id: r.id,
  provider: r.provider as ProviderId,
  cwd: r.cwd,
  title: r.title,
  status: r.status === "running" ? "running" : "exited",
  exitCode: r.exit_code,
  cliSessionId: r.cli_session_id ?? null,
  createdAt: r.created_at,
  updatedAt: r.updated_at,
});

const insertStmt = db.prepare(`
  INSERT INTO sessions (id, provider, cwd, title, status, exit_code, cli_session_id, scrollback, created_at, updated_at)
  VALUES (@id, @provider, @cwd, @title, @status, @exitCode, @cliSessionId, '', @createdAt, @updatedAt)
`);

const updateStmt = db.prepare(`
  UPDATE sessions
  SET status = @status, exit_code = @exitCode, cli_session_id = @cliSessionId, scrollback = @scrollback, updated_at = @updatedAt
  WHERE id = @id
`);

const setCliSessionIdStmt = db.prepare(`UPDATE sessions SET cli_session_id = @cliSessionId WHERE id = @id`);

const listStmt = db.prepare(`SELECT * FROM sessions ORDER BY created_at DESC`);
const getStmt = db.prepare(`SELECT * FROM sessions WHERE id = ?`);
const scrollbackStmt = db.prepare(`SELECT scrollback FROM sessions WHERE id = ?`);

export const sessionDb = {
  insert(meta: SessionMeta): void {
    insertStmt.run(meta);
  },

  update(meta: SessionMeta, scrollback: string): void {
    updateStmt.run({ ...meta, scrollback });
  },

  setCliSessionId(id: string, cliSessionId: string): void {
    setCliSessionIdStmt.run({ id, cliSessionId });
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
   * On startup, any session still marked "running" is stale — its pty died with
   * the previous server process. Mark them exited so the UI shows truth.
   */
  markOrphansExited(): void {
    db.prepare(`UPDATE sessions SET status = 'exited' WHERE status = 'running'`).run();
  },
};

const insertCommentStmt = db.prepare(`
  INSERT INTO diff_comments (id, session_id, file, side, line, body, created_at)
  VALUES (@id, @sessionId, @file, @side, @line, @body, @createdAt)
`);
const listCommentsStmt = db.prepare(
  `SELECT * FROM diff_comments WHERE session_id = ? ORDER BY created_at ASC`,
);
const deleteCommentStmt = db.prepare(`DELETE FROM diff_comments WHERE id = ? AND session_id = ?`);

interface CommentRow {
  id: string;
  session_id: string;
  file: string;
  side: string;
  line: number;
  body: string;
  created_at: number;
}

const rowToComment = (r: CommentRow): DiffComment => ({
  id: r.id,
  sessionId: r.session_id,
  file: r.file,
  side: r.side === "old" ? "old" : "new",
  line: r.line,
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
};

export default db;
