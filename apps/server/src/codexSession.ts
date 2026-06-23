import { readdir, stat } from "node:fs/promises";
import { createReadStream } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";

/**
 * Discovers a Codex session's resumable id by watching its rollout files.
 *
 * Codex has no flag to pin a session id at start (unlike Claude's `--session-id`),
 * so after spawning `codex` we find the rollout file it just created and read the
 * id out of its `session_meta` header. Files live at:
 *
 *   ~/.codex/sessions/YYYY/MM/DD/rollout-<ISO-ts>-<uuid>.jsonl
 *
 * and the first JSONL line is `{ type: "session_meta", payload: { id, cwd, ... } }`.
 * We match on `cwd` (so concurrent sessions in other folders don't confuse us)
 * and pick the newest file created at/after the spawn time.
 */

const SESSIONS_ROOT = join(homedir(), ".codex", "sessions");

interface SessionMetaHeader {
  id: string;
  cwd: string;
}

/** Read just the first JSONL line and pull out the session_meta payload. */
async function readHeader(file: string): Promise<SessionMetaHeader | null> {
  const stream = createReadStream(file, { encoding: "utf8" });
  const rl = createInterface({ input: stream, crlfDelay: Infinity });
  try {
    for await (const line of rl) {
      if (!line.trim()) continue;
      try {
        const rec = JSON.parse(line) as { type?: string; payload?: { id?: string; cwd?: string } };
        if (rec.type === "session_meta" && rec.payload?.id && rec.payload.cwd) {
          return { id: rec.payload.id, cwd: rec.payload.cwd };
        }
      } catch {
        // Not JSON yet (partial write) — give up on this file for now.
      }
      return null; // Only the first non-empty line is the header.
    }
    return null;
  } finally {
    rl.close();
    stream.destroy();
  }
}

/** One scan pass: newest rollout file for `cwd` modified at/after `sinceMs`. */
async function scanOnce(cwd: string, sinceMs: number): Promise<string | null> {
  let entries: string[];
  try {
    entries = await readdir(SESSIONS_ROOT, { recursive: true });
  } catch {
    return null; // No ~/.codex/sessions yet.
  }
  const rollouts = entries.filter((e) => e.endsWith(".jsonl") && e.includes("rollout-"));

  let best: { id: string; mtimeMs: number } | null = null;
  for (const rel of rollouts) {
    const full = join(SESSIONS_ROOT, rel);
    let mtimeMs: number;
    try {
      ({ mtimeMs } = await stat(full));
    } catch {
      continue;
    }
    // Allow a small clock-skew grace window before the spawn timestamp.
    if (mtimeMs < sinceMs - 2000) continue;
    if (best && mtimeMs <= best.mtimeMs) continue;
    const header = await readHeader(full);
    if (header && header.cwd === cwd) best = { id: header.id, mtimeMs };
  }
  return best?.id ?? null;
}

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/**
 * Poll for the Codex session id created at/after `sinceMs` in `cwd`. Resolves
 * with the id once the rollout file appears, or null if it never shows within
 * the timeout (e.g. Codex exited before writing one).
 */
export async function captureCodexSessionId(
  cwd: string,
  sinceMs: number,
  { timeoutMs = 30_000, intervalMs = 1500 }: { timeoutMs?: number; intervalMs?: number } = {},
): Promise<string | null> {
  const deadline = sinceMs + timeoutMs;
  for (;;) {
    const id = await scanOnce(cwd, sinceMs);
    if (id) return id;
    if (Date.now() >= deadline) return null;
    await sleep(intervalMs);
  }
}
