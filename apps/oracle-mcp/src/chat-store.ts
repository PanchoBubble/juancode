// Phone-chat session persistence for the Oracle sidecar. The headless phone chat
// (`oracleChat` in oracle.ts) resumes a `claude` conversation by session id; this
// store keeps the LIST of those sessions so the web console can show past chats and
// continue any of them — the same way the per-project session list works. We only
// persist the lightweight session record (id + title + timestamps), never the
// transcript: continuity comes from `claude --resume`, which carries the real
// conversation context. The store is a flat JSON array under `JUANCODE_ORACLE_DIR`
// (same control dir as the dispatch/ask mailboxes + push store), tolerant of a
// missing/corrupt file, and unit-tested in chat-store.test.ts.

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { oracleDir } from "./oracle.ts";

/** One persisted phone-chat session. `id` is the `claude` session id used with
 *  `--resume`; `title` is a human label derived from the opening prompt. */
export interface ChatSession {
  id: string;
  title: string;
  createdAt: number;
  updatedAt: number;
}

const sessionsFile = () => join(oracleDir(), "oracle-chat-sessions.json");
/** Legacy single-session pointer (pre-multi-session); imported once on first read. */
const legacySessionFile = () => join(oracleDir(), "phone-chat-session.txt");

async function ensureDir(): Promise<void> {
  await mkdir(oracleDir(), { recursive: true });
}

function isChatSession(v: unknown): v is ChatSession {
  if (!v || typeof v !== "object") return false;
  const r = v as Record<string, unknown>;
  return (
    typeof r.id === "string" &&
    r.id.length > 0 &&
    typeof r.title === "string" &&
    typeof r.createdAt === "number" &&
    typeof r.updatedAt === "number"
  );
}

/** Read the raw store, tolerating a missing/corrupt file (→ []). Unsorted. */
async function readStore(): Promise<ChatSession[]> {
  const raw = await readFile(sessionsFile(), "utf8").catch(() => "");
  if (!raw.trim()) return [];
  try {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(isChatSession);
  } catch {
    return [];
  }
}

async function writeStore(sessions: ChatSession[]): Promise<void> {
  await ensureDir();
  await writeFile(sessionsFile(), JSON.stringify(sessions, null, 2), "utf8");
}

/** One-time migration: if the store is empty but the legacy single-session file
 *  exists, adopt that id as one session so the prior phone conversation isn't lost. */
async function migrateLegacy(now: number): Promise<ChatSession[]> {
  const prev = (await readFile(legacySessionFile(), "utf8").catch(() => "")).trim();
  if (!prev) return [];
  const migrated: ChatSession[] = [{ id: prev, title: "Earlier chat", createdAt: now, updatedAt: now }];
  await writeStore(migrated);
  return migrated;
}

/** List persisted chat sessions, most-recently-updated first. `now` seeds the
 *  legacy-migration timestamps (injected so the store stays deterministic in tests). */
export async function listChatSessions(now = Date.now()): Promise<ChatSession[]> {
  let sessions = await readStore();
  if (sessions.length === 0) sessions = await migrateLegacy(now);
  return [...sessions].sort((a, b) => b.updatedAt - a.updatedAt);
}

/** Insert or update a session by id. A new id is created with `title` (falling back
 *  to "New chat"); an existing id keeps its title unless a non-empty one is given,
 *  and always bumps `updatedAt`. Returns the full list after the change. */
export async function upsertChatSession(
  id: string,
  title?: string,
  now = Date.now(),
): Promise<ChatSession[]> {
  if (!id) throw new Error("chat session id is required");
  const sessions = await readStore();
  const existing = sessions.find((s) => s.id === id);
  if (existing) {
    if (title && title.trim()) existing.title = title.trim();
    existing.updatedAt = now;
  } else {
    sessions.push({
      id,
      title: title?.trim() || "New chat",
      createdAt: now,
      updatedAt: now,
    });
  }
  await writeStore(sessions);
  return sessions;
}

/** Bump a session's `updatedAt` (no-op if unknown). Returns the full list. */
export async function touchChatSession(id: string, now = Date.now()): Promise<ChatSession[]> {
  const sessions = await readStore();
  const existing = sessions.find((s) => s.id === id);
  if (existing) {
    existing.updatedAt = now;
    await writeStore(sessions);
  }
  return sessions;
}

/** Remove a session by id. Returns the full list after the change. */
export async function removeChatSession(id: string): Promise<ChatSession[]> {
  const sessions = await readStore();
  const next = sessions.filter((s) => s.id !== id);
  if (next.length !== sessions.length) await writeStore(next);
  return next;
}
