import { readdir, stat } from "node:fs/promises";
import { createReadStream, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import type { ProviderId } from "./protocol.ts";

/**
 * Recover the resumable CLI session id for an *old* session that was created
 * before we started capturing it (Claude) or whose post-spawn discovery never
 * landed (Codex). Both CLIs persist a transcript per conversation that records
 * the working directory it ran in, so we match on `cwd` and pick the transcript
 * whose start time is closest to when our session was created — the same
 * cwd-plus-time heuristic `codexSession.ts` uses for live Codex discovery.
 *
 * A transcript can't predate our spawn, and a match more than a few minutes off
 * is almost certainly a *different* conversation in the same folder, so we bound
 * the window on both sides and never reuse an id already claimed by another
 * session. When nothing fits we return null and the session stays unresumable.
 */

const CLAUDE_PROJECTS = join(homedir(), ".claude", "projects");
const CODEX_SESSIONS = join(homedir(), ".codex", "sessions");

/** A transcript can't start before we spawned it; allow small clock skew. */
const GRACE_BEFORE_MS = 5_000;
/** Beyond this gap a cwd match is untrustworthy (likely a later session). */
const MAX_GAP_MS = 15 * 60_000;

/** Override the transcript roots (used by tests to point at fixtures). */
export interface RecoverRoots {
  claudeProjects?: string;
  codexSessions?: string;
}

/** A resumable conversation found on disk: its CLI id and when it began. */
interface Candidate {
  id: string;
  startMs: number;
}

/** Read JSONL lines, calling `onRecord`; stop early when it returns false. */
async function forEachRecord(
  file: string,
  onRecord: (rec: Record<string, unknown>) => boolean | void,
): Promise<void> {
  const stream = createReadStream(file, { encoding: "utf8" });
  const rl = createInterface({ input: stream, crlfDelay: Infinity });
  try {
    for await (const line of rl) {
      if (!line.trim()) continue;
      let rec: Record<string, unknown>;
      try {
        rec = JSON.parse(line) as Record<string, unknown>;
      } catch {
        continue;
      }
      if (onRecord(rec) === false) return;
    }
  } finally {
    rl.close();
    stream.destroy();
  }
}

/**
 * Claude encodes a cwd into a project-dir name by replacing path separators
 * (and, in newer versions, dots) with dashes. We try both encodings, and fall
 * back to scanning every project dir if neither exists — the transcript's own
 * `cwd` field is the source of truth either way.
 */
function claudeDirs(root: string, cwd: string): string[] {
  const variants = [...new Set([cwd.replace(/[/.]/g, "-"), cwd.replace(/\//g, "-")])];
  const direct = variants.map((v) => join(root, v)).filter((d) => existsSync(d));
  return direct.length > 0 ? direct : [];
}

/** First record carrying both a cwd and a timestamp (Claude transcripts). */
async function claudeHeader(file: string): Promise<{ cwd: string; startMs: number } | null> {
  let result: { cwd: string; startMs: number } | null = null;
  await forEachRecord(file, (rec) => {
    if (typeof rec.cwd === "string" && typeof rec.timestamp === "string") {
      const startMs = Date.parse(rec.timestamp);
      if (!Number.isNaN(startMs)) {
        result = { cwd: rec.cwd, startMs };
        return false;
      }
    }
  });
  return result;
}

async function claudeCandidates(root: string, cwd: string): Promise<Candidate[]> {
  let dirs = claudeDirs(root, cwd);
  if (dirs.length === 0) {
    // Unknown encoding — scan every project dir and trust the in-file cwd.
    try {
      const names = await readdir(root, { withFileTypes: true });
      dirs = names.filter((e) => e.isDirectory()).map((e) => join(root, e.name));
    } catch {
      return [];
    }
  }
  const candidates: Candidate[] = [];
  for (const dir of dirs) {
    let files: string[];
    try {
      files = await readdir(dir);
    } catch {
      continue;
    }
    for (const f of files) {
      if (!f.endsWith(".jsonl")) continue;
      const header = await claudeHeader(join(dir, f));
      // The file's basename IS Claude's session id.
      if (header && header.cwd === cwd) {
        candidates.push({ id: f.slice(0, -".jsonl".length), startMs: header.startMs });
      }
    }
  }
  return candidates;
}

/** Codex session_meta header: the resumable id and the cwd it ran in. */
async function codexHeader(file: string): Promise<{ id: string; cwd: string } | null> {
  let result: { id: string; cwd: string } | null = null;
  await forEachRecord(file, (rec) => {
    if (rec.type === "session_meta") {
      const payload = rec.payload as { id?: string; cwd?: string } | undefined;
      if (payload?.id && payload.cwd) result = { id: payload.id, cwd: payload.cwd };
    }
    return false; // header is the first non-empty line
  });
  return result;
}

async function codexCandidates(root: string, cwd: string): Promise<Candidate[]> {
  let entries: string[];
  try {
    entries = await readdir(root, { recursive: true });
  } catch {
    return [];
  }
  const candidates: Candidate[] = [];
  for (const rel of entries) {
    if (!rel.endsWith(".jsonl") || !rel.includes("rollout-")) continue;
    const full = join(root, rel);
    const header = await codexHeader(full);
    if (!header || header.cwd !== cwd) continue;
    // Codex has no in-record start time we can rely on; the rollout file's
    // creation time is when the session began.
    let startMs: number;
    try {
      const s = await stat(full);
      startMs = s.birthtimeMs || s.mtimeMs;
    } catch {
      continue;
    }
    candidates.push({ id: header.id, startMs });
  }
  return candidates;
}

/** Pick the candidate that began nearest to (and not well before) `createdAtMs`. */
function chooseNearest(cands: Candidate[], createdAtMs: number, exclude: Set<string>): string | null {
  let best: { id: string; gap: number } | null = null;
  for (const c of cands) {
    if (exclude.has(c.id)) continue;
    if (c.startMs < createdAtMs - GRACE_BEFORE_MS) continue;
    if (c.startMs - createdAtMs > MAX_GAP_MS) continue;
    const gap = Math.abs(c.startMs - createdAtMs);
    if (!best || gap < best.gap) best = { id: c.id, gap };
  }
  return best?.id ?? null;
}

/**
 * Find the on-disk CLI conversation for an orphaned session, or null when none
 * can be matched confidently. `excludeIds` are ids already claimed by other
 * sessions, so two orphans in one folder can't both grab the same transcript.
 */
export async function recoverCliSessionId(
  provider: ProviderId,
  cwd: string,
  createdAtMs: number,
  excludeIds: Set<string>,
  roots: RecoverRoots = {},
): Promise<string | null> {
  const cands =
    provider === "claude"
      ? await claudeCandidates(roots.claudeProjects ?? CLAUDE_PROJECTS, cwd)
      : await codexCandidates(roots.codexSessions ?? CODEX_SESSIONS, cwd);
  return chooseNearest(cands, createdAtMs, excludeIds);
}

/**
 * A resumable CLI conversation found on disk for a `cwd`: which CLI produced it,
 * its resumable id, and when it began. The lightweight result of
 * {@link listExternalSessions} — just enough to build a `SessionMeta` and adopt it.
 * Distinct from `recoverCliSessionId`, which matches *one* id to an existing
 * orphaned session row; this surfaces *every* candidate so the caller can offer
 * them for adoption.
 */
export interface ResumableCliSession {
  /** The CLI that owns this transcript (`claude` or `codex`). */
  provider: ProviderId;
  /** The id to resume with (`claude --resume <id>` / a Codex rollout id). */
  cliSessionId: string;
  /** When the conversation began, ms since epoch. */
  startMs: number;
}

/**
 * List every resumable CLI conversation (Claude + Codex) whose transcript ran in
 * `cwd`, newest first. Reuses the same header parsing as {@link recoverCliSessionId}
 * (Claude: basename = id, cwd+timestamp on the first matching line; Codex:
 * `session_meta` payload id+cwd) but applies no time window and no exclusion — it
 * surfaces *all* candidates so the caller can offer them for adoption. Dedupe
 * against already-adopted ids (`db.usedCliSessionIds()`) at the call site, not here.
 *
 * Ported from native `listExternalSessions` (juancode-723) to give the Node/TS
 * server the same external-session surfacing.
 */
export async function listExternalSessions(
  cwd: string,
  roots: RecoverRoots = {},
): Promise<ResumableCliSession[]> {
  const [claude, codex] = await Promise.all([
    claudeCandidates(roots.claudeProjects ?? CLAUDE_PROJECTS, cwd),
    codexCandidates(roots.codexSessions ?? CODEX_SESSIONS, cwd),
  ]);
  const sessions: ResumableCliSession[] = [
    ...claude.map((c) => ({ provider: "claude" as const, cliSessionId: c.id, startMs: c.startMs })),
    ...codex.map((c) => ({ provider: "codex" as const, cliSessionId: c.id, startMs: c.startMs })),
  ];
  return sessions.sort((a, b) => b.startMs - a.startMs);
}
