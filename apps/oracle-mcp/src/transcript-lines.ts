// Parsing for Claude Code transcript JSONL (~/.claude/projects/<slug>/<sessionId>.jsonl).
// Shared by the FTS index (`transcript-index.ts`) and the SessionEnd memory-candidate hook
// (`memory-candidates.ts`) — the hook must stay dependency-free, so this file deliberately
// imports nothing.

/** A transcript line reduced to indexable prose. */
export type TranscriptEntry = {
  sessionId: string;
  project: string;
  branch: string;
  ts: string;
  role: "user" | "assistant";
  text: string;
};

/** Per-entry cap. Long tool results (whole-file reads) are searchable at their head and
 *  the underlying file is still on disk, so storing megabytes buys nothing. */
export const MAX_ENTRY_CHARS = 4000;

/** Flatten a message's content into plain text: prose, tool names with a compact input,
 *  and nested tool results. `thinking` blocks are skipped — mostly base64 signatures,
 *  and reasoning is not what recall is for. */
export function textOfBlocks(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  for (const block of content) {
    if (!block || typeof block !== "object") continue;
    const b = block as Record<string, unknown>;
    switch (b.type) {
      case "text":
        if (typeof b.text === "string") parts.push(b.text);
        break;
      case "tool_use": {
        const name = typeof b.name === "string" ? b.name : "tool";
        parts.push(`[${name}] ${JSON.stringify(b.input ?? {}).slice(0, 600)}`);
        break;
      }
      case "tool_result":
        parts.push(textOfBlocks(b.content));
        break;
      default:
        break;
    }
  }
  return parts.filter(Boolean).join("\n");
}

/** Map one transcript line to an entry, or undefined if it carries no prose. */
export function parseTranscriptLine(line: string): TranscriptEntry | undefined {
  let raw: unknown;
  try {
    raw = JSON.parse(line);
  } catch {
    return undefined;
  }
  if (!raw || typeof raw !== "object") return undefined;
  const rec = raw as Record<string, unknown>;
  const role = rec.type;
  if (role !== "user" && role !== "assistant") return undefined;
  const message = rec.message;
  if (!message || typeof message !== "object") return undefined;
  const text = textOfBlocks((message as Record<string, unknown>).content).trim();
  if (!text) return undefined;
  return {
    sessionId: typeof rec.sessionId === "string" ? rec.sessionId : "",
    project: typeof rec.cwd === "string" ? rec.cwd : "",
    branch: typeof rec.gitBranch === "string" ? rec.gitBranch : "",
    ts: typeof rec.timestamp === "string" ? rec.timestamp : "",
    role,
    text: text.slice(0, MAX_ENTRY_CHARS),
  };
}
