import {
  CLAUDE_PROJECTS,
  CODEX_SESSIONS,
  codexRolloutFiles,
  findByBasename,
  forEachRecord,
} from "./sessionTitle.ts";
import type { ProviderId, SessionUsage } from "./protocol.ts";

/**
 * Derives per-session token usage (and a real cost, when the CLI reports one)
 * from the CLI's own transcript files — the same robust source
 * `sessionTitle.ts` reads, rather than scraping the ANSI TUI stream.
 *
 *   - Claude writes one `assistant` record per API turn into
 *     `~/.claude/projects/<encoded-cwd>/<cliSessionId>.jsonl`, each carrying a
 *     `message.usage` block. The same turn can be logged more than once, so we
 *     dedup by `message.id` + `requestId` (the key `ccusage` uses) before
 *     summing.
 *   - Codex emits a running `token_count` event whose `info.total_token_usage`
 *     is cumulative — we just take the last one.
 *
 * Cost is never estimated. We only report a dollar figure when the transcript
 * itself carries a real per-turn cost (`costUSD`); otherwise `costUsd` is null
 * and only tokens are shown. On a subscription plan the CLI reports no per-turn
 * cost, so cost simply doesn't appear — which is the intent: show cost only
 * when there's a real cost.
 *
 * Returns null when no usage is available yet (e.g. before the first turn).
 */

/** Override the transcript roots (used by tests to point at fixtures). */
export interface UsageRoots {
  claudeProjects?: string;
  codexSessions?: string;
}

/**
 * Resolving a transcript path means scanning a directory tree, wasteful to
 * repeat on every poll. Cache the resolved path per CLI session id once found.
 */
const fileCache = new Map<string, string>();

const empty = (): SessionUsage => ({
  inputTokens: 0,
  outputTokens: 0,
  cacheReadTokens: 0,
  cacheWriteTokens: 0,
  totalTokens: 0,
  costUsd: null,
});

/** Token usage (+ real cost, if the transcript reports one) for a Claude session. */
export async function deriveClaudeUsage(
  cliSessionId: string,
  root: string = CLAUDE_PROJECTS,
): Promise<SessionUsage | null> {
  let file = fileCache.get(cliSessionId);
  if (!file) {
    const found = await findByBasename(root, `${cliSessionId}.jsonl`);
    if (!found) return null;
    fileCache.set(cliSessionId, found);
    file = found;
  }

  const usage = empty();
  const seen = new Set<string>();
  let sawTurn = false;

  await forEachRecord(file, (rec) => {
    if (rec.type !== "assistant") return;
    const msg = rec.message as
      | { id?: string; model?: string; usage?: Record<string, number> }
      | undefined;
    const u = msg?.usage;
    if (!u) return;

    // Dedup: the same API response is sometimes written multiple times.
    const key = `${msg?.id ?? ""}:${(rec.requestId as string) ?? ""}`;
    if (key !== ":" && seen.has(key)) return;
    seen.add(key);

    const model = msg?.model ?? "";
    if (model === "<synthetic>") return; // local message, not a billed API call

    sawTurn = true;
    usage.inputTokens += u.input_tokens ?? 0;
    usage.outputTokens += u.output_tokens ?? 0;
    usage.cacheReadTokens += u.cache_read_input_tokens ?? 0;
    usage.cacheWriteTokens += u.cache_creation_input_tokens ?? 0;

    // Only a real cost the CLI wrote — never estimated. Absent on subscription
    // plans, so cost stays null and only tokens are shown.
    const cost = typeof rec.costUSD === "number" ? rec.costUSD : null;
    if (cost != null) usage.costUsd = (usage.costUsd ?? 0) + cost;
  });

  if (!sawTurn) return null;
  usage.totalTokens =
    usage.inputTokens + usage.outputTokens + usage.cacheReadTokens + usage.cacheWriteTokens;
  return usage;
}

/** Token usage for a Codex session: the last cumulative `token_count` event. */
export async function deriveCodexUsage(
  cliSessionId: string,
  root: string = CODEX_SESSIONS,
): Promise<SessionUsage | null> {
  const cached = fileCache.get(cliSessionId);
  const files = cached ? [cached] : await codexRolloutFiles(root);

  for (const full of files) {
    let isMatch = cached === full;
    let total: Record<string, number> | null = null;
    await forEachRecord(full, (rec) => {
      const payload = rec.payload as
        | { type?: string; id?: string; info?: { total_token_usage?: Record<string, number> } }
        | undefined;
      if (rec.type === "session_meta") {
        if (payload?.id !== cliSessionId) return false; // wrong file — bail
        isMatch = true;
        return;
      }
      // Cumulative tally; keep the latest. (When reading a cached file directly
      // we never see session_meta, but isMatch is already true.)
      if (isMatch && payload?.type === "token_count" && payload.info?.total_token_usage) {
        total = payload.info.total_token_usage;
      }
    });
    if (isMatch) {
      fileCache.set(cliSessionId, full);
      if (!total) return null; // matched the session but no turn has run yet
      // Codex `input_tokens` already includes the cached portion, so subtract
      // it out to report fresh input separately. No per-token price → no cost.
      const t: Record<string, number> = total;
      const cacheRead = t.cached_input_tokens ?? 0;
      const input = Math.max(0, (t.input_tokens ?? 0) - cacheRead);
      const output = t.output_tokens ?? 0;
      return {
        inputTokens: input,
        outputTokens: output,
        cacheReadTokens: cacheRead,
        cacheWriteTokens: 0,
        totalTokens: t.total_tokens ?? input + output + cacheRead,
        costUsd: null,
      };
    }
  }
  return null;
}

export function deriveSessionUsage(
  provider: ProviderId,
  cliSessionId: string,
  roots: UsageRoots = {},
): Promise<SessionUsage | null> {
  return provider === "claude"
    ? deriveClaudeUsage(cliSessionId, roots.claudeProjects)
    : deriveCodexUsage(cliSessionId, roots.codexSessions);
}
