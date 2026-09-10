// Parsing for opencode's session store (~/.local/share/opencode/opencode.db), the
// sibling of `transcript-lines.ts`. opencode keeps one row per message and one row per
// part, each with its payload as JSON in a `data` column, so the shapes below are what
// those two columns hold. Pure functions, no imports — the DB reading itself lives in
// `transcript-index.ts`.

import { MAX_ENTRY_CHARS } from "./transcript-lines.ts";

/** What a `message.data` payload tells us that the columns do not. */
export type OpencodeMessage = {
  role: "user" | "assistant";
  /** The message's own cwd; absent on user messages, where the session's directory wins. */
  cwd: string;
};

/** Per-tool caps. The full call is still in opencode's DB, so storing megabytes of tool
 *  output in the index buys nothing that the entry cap would not throw away anyway. */
const MAX_TOOL_INPUT_CHARS = 600;
const MAX_TOOL_OUTPUT_CHARS = 2000;

/** Map a `message.data` blob to its role and cwd, or undefined if it is not a turn we index. */
export function parseOpencodeMessage(data: string): OpencodeMessage | undefined {
  let raw: unknown;
  try {
    raw = JSON.parse(data);
  } catch {
    return undefined;
  }
  if (!raw || typeof raw !== "object") return undefined;
  const rec = raw as Record<string, unknown>;
  const role = rec.role;
  if (role !== "user" && role !== "assistant") return undefined;
  const path = rec.path;
  const cwd =
    path && typeof path === "object" && typeof (path as Record<string, unknown>).cwd === "string"
      ? ((path as Record<string, unknown>).cwd as string)
      : "";
  return { role, cwd };
}

/** Flatten one message's parts into indexable prose. Unlike Claude Code's transcripts,
 *  opencode stores reasoning as plain text, so recall gets the real thinking too. */
export function textOfParts(parts: readonly string[]): string {
  const out: string[] = [];
  for (const data of parts) {
    let raw: unknown;
    try {
      raw = JSON.parse(data);
    } catch {
      continue;
    }
    if (!raw || typeof raw !== "object") continue;
    const p = raw as Record<string, unknown>;
    switch (p.type) {
      case "text":
      case "reasoning":
        if (typeof p.text === "string") out.push(p.text);
        break;
      case "tool": {
        const name = typeof p.tool === "string" ? p.tool : "tool";
        const state = (p.state ?? {}) as Record<string, unknown>;
        out.push(`[${name}] ${JSON.stringify(state.input ?? {}).slice(0, MAX_TOOL_INPUT_CHARS)}`);
        if (typeof state.output === "string" && state.output) {
          out.push(state.output.slice(0, MAX_TOOL_OUTPUT_CHARS));
        }
        break;
      }
      case "file":
        // Never the `url`: attachments are inlined as base64 data URIs.
        if (typeof p.filename === "string") out.push(`[file] ${p.filename}`);
        break;
      default:
        // step-start / step-finish / patch / compaction carry no prose.
        break;
    }
  }
  return out
    .filter(Boolean)
    .join("\n")
    .trim()
    .slice(0, MAX_ENTRY_CHARS);
}
