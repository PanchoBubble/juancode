import { mkdirSync } from "node:fs";
import { join } from "node:path";
import Database from "better-sqlite3";
import { DATA_DIR } from "./config.ts";
import type { ProviderId, SessionMeta } from "./protocol.ts";

mkdirSync(DATA_DIR, { recursive: true });

const db = new Database(join(DATA_DIR, "juancode.db"));
db.pragma("journal_mode = WAL");

db.exec(`
  CREATE TABLE IF NOT EXISTS sessions (
    id          TEXT PRIMARY KEY,
    provider    TEXT NOT NULL,
    cwd         TEXT NOT NULL,
    title       TEXT NOT NULL,
    status      TEXT NOT NULL,
    exit_code   INTEGER,
    scrollback  TEXT NOT NULL DEFAULT '',
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL
  );
`);

interface Row {
  id: string;
  provider: string;
  cwd: string;
  title: string;
  status: string;
  exit_code: number | null;
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
  createdAt: r.created_at,
  updatedAt: r.updated_at,
});

const insertStmt = db.prepare(`
  INSERT INTO sessions (id, provider, cwd, title, status, exit_code, scrollback, created_at, updated_at)
  VALUES (@id, @provider, @cwd, @title, @status, @exitCode, '', @createdAt, @updatedAt)
`);

const updateStmt = db.prepare(`
  UPDATE sessions
  SET status = @status, exit_code = @exitCode, scrollback = @scrollback, updated_at = @updatedAt
  WHERE id = @id
`);

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

export default db;
