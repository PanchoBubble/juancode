// Decide whether a headless Oracle turn should `--resume` its conversation or start a
// fresh one. Every resumed turn re-sends the whole conversation; while the prompt cache
// is warm that is a cheap cache read, but phone chats arrive hours apart, so a resume
// after the cache has expired re-writes the entire context at the full write price.
// Past an idle gap (or past a size where even warm reads dominate) a fresh session that
// carries only the last few exchanges as plain text costs a fraction of that.

import { readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

/** Longer than the 1h prompt-cache TTL: past this the resume is a full cache rebuild. */
export const IDLE_ROTATE_MS = 65 * 60_000;
/** An idle conversation smaller than this is cheap enough to rebuild; keep continuity. */
export const IDLE_ROTATE_MIN_TOKENS = 40_000;
/** Rotate regardless of idle time once the context is this large. */
export const MAX_CONTEXT_TOKENS = 150_000;

const CARRY_MESSAGES = 6;
const CARRY_MESSAGE_CHARS = 600;

export type ResumeDecision =
  | { action: "resume" }
  | { action: "fresh"; reason: string; carry: string };

/** Claude Code's transcript for session `id` run with cwd `dir`. */
export function transcriptPath(dir: string, id: string, home: string = homedir()): string {
  return join(home, ".claude", "projects", dir.replace(/[^a-zA-Z0-9]/g, "-"), `${id}.jsonl`);
}

interface TranscriptSummary {
  contextTokens: number;
  messages: { role: "user" | "assistant"; text: string }[];
}

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((b) =>
      b && typeof b === "object" && (b as { type?: unknown }).type === "text"
        ? String((b as { text?: unknown }).text ?? "")
        : "",
    )
    .join("")
    .trim();
}

/** The last request's context size and the conversation's plain-text messages
 *  (tool calls, tool results and meta entries left out). */
export function summarizeTranscript(raw: string): TranscriptSummary {
  let contextTokens = 0;
  const messages: TranscriptSummary["messages"] = [];
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    let entry: Record<string, unknown>;
    try {
      entry = JSON.parse(line) as Record<string, unknown>;
    } catch {
      continue;
    }
    if (entry.isMeta === true || entry.isSidechain === true) continue;
    const message = entry.message as Record<string, unknown> | undefined;
    if (!message || typeof message !== "object") continue;
    const usage = message.usage as Record<string, number> | undefined;
    if (usage && entry.type === "assistant") {
      contextTokens =
        (usage.input_tokens ?? 0) +
        (usage.cache_read_input_tokens ?? 0) +
        (usage.cache_creation_input_tokens ?? 0);
    }
    if (entry.type !== "user" && entry.type !== "assistant") continue;
    const text = textOf(message.content);
    if (text) messages.push({ role: entry.type, text });
  }
  return { contextTokens, messages };
}

/** The opening of a fresh session's first prompt: the last few exchanges of the
 *  conversation it replaces, so "that dispatch" or "the earlier ticket" still resolve. */
export function carryOverText(messages: TranscriptSummary["messages"]): string {
  const recent = messages.slice(-CARRY_MESSAGES);
  if (recent.length === 0) return "";
  const lines = recent.map((m) => {
    const t =
      m.text.length > CARRY_MESSAGE_CHARS
        ? m.text.slice(0, CARRY_MESSAGE_CHARS - 1).trimEnd() + "…"
        : m.text;
    return `${m.role === "user" ? "User" : "Oracle"}: ${t}`;
  });
  return (
    "[The previous conversation was closed to save tokens. Its last messages, for context:]\n" +
    lines.join("\n\n") +
    "\n[End of earlier conversation. New message follows.]\n\n"
  );
}

export function decideResume(
  idleMs: number,
  summary: TranscriptSummary,
): ResumeDecision {
  const tokens = summary.contextTokens;
  let reason: string | null = null;
  if (tokens >= MAX_CONTEXT_TOKENS) reason = `context ${tokens} tokens`;
  else if (idleMs >= IDLE_ROTATE_MS && tokens >= IDLE_ROTATE_MIN_TOKENS) {
    reason = `idle ${Math.round(idleMs / 60_000)}m with ${tokens} tokens`;
  }
  if (!reason) return { action: "resume" };
  return { action: "fresh", reason, carry: carryOverText(summary.messages) };
}

/** Read session `id`'s transcript and decide. Anything unreadable resumes as before:
 *  a stale id is already handled by the callers' fresh retry. */
export async function assessResume(
  dir: string,
  id: string,
  now: number = Date.now(),
): Promise<ResumeDecision> {
  const path = transcriptPath(dir, id);
  try {
    const [info, raw] = await Promise.all([stat(path), readFile(path, "utf8")]);
    return decideResume(now - info.mtimeMs, summarizeTranscript(raw));
  } catch {
    return { action: "resume" };
  }
}
