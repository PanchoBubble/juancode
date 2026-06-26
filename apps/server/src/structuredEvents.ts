import type { ProviderId, StructuredEvent } from "./protocol.ts";

/**
 * Normalizes the CLI's own stream-json transcript records into provider-agnostic
 * {@link StructuredEvent}s — the data behind the opt-in structured (message /
 * tool-bubble) view, the alternative to scraping the ANSI TUI.
 *
 * The transcript files the CLIs write as they run carry the same message
 * objects they would stream under `--output-format stream-json`, so we read
 * them straight off disk (the same robust source `sessionTitle.ts` and
 * `sessionUsage.ts` use) rather than spawning a second headless process — this
 * keeps the genuine interactive pty as the single source of truth while still
 * giving a structured render of exactly what it's doing.
 *
 *   - Claude: one record per `user` / `assistant` turn; `assistant.message.content`
 *     is a list of `text` / `thinking` / `tool_use` blocks, and a `user` record
 *     is either a string prompt or a list of `tool_result` blocks.
 *   - Codex: each `payload` carries a `type` — `user_message`, `agent_message`,
 *     `reasoning`, `function_call` / `custom_tool_call` (+ their `_output`s).
 *
 * `recordToEvents` is pure (record in, events out) and assigns each event a
 * `seq`-derived id that is stable across re-reads of the append-only transcript,
 * so an incremental tailer can dedup without re-sending the whole backlog.
 */

/** Cap a single bubble's text so one giant tool result can't blow up the wire. */
const MAX_TEXT = 20_000;

function clip(text: string): string {
  return text.length > MAX_TEXT ? `${text.slice(0, MAX_TEXT)}\n… (truncated)` : text;
}

/** Flatten a Claude content value (string, or a list of `{type:"text",text}`) to text. */
function contentToText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((b) => {
        if (typeof b === "string") return b;
        if (b && typeof b === "object") {
          const obj = b as { type?: string; text?: string; content?: unknown };
          if (typeof obj.text === "string") return obj.text;
          if (obj.content !== undefined) return contentToText(obj.content);
        }
        return "";
      })
      .join("");
  }
  return "";
}

/** Pretty-print a tool input/arguments value for display in a tool bubble. */
function formatToolInput(input: unknown): string {
  if (input == null) return "";
  if (typeof input === "string") {
    // Codex passes `arguments` as a JSON string — pretty-print when it parses.
    try {
      return clip(JSON.stringify(JSON.parse(input), null, 2));
    } catch {
      return clip(input);
    }
  }
  try {
    return clip(JSON.stringify(input, null, 2));
  } catch {
    return "";
  }
}

function isoTimestamp(rec: Record<string, unknown>): string | null {
  return typeof rec.timestamp === "string" ? rec.timestamp : null;
}

/** Claude transcript record → events. */
function claudeRecordToEvents(rec: Record<string, unknown>, seq: number): StructuredEvent[] {
  // Sub-agent (Task tool) turns are logged on a sidechain; skip them so the main
  // conversation stays clean — the Task tool_use/result still show on the main
  // thread.
  if (rec.isSidechain === true) return [];
  const ts = isoTimestamp(rec);
  const message = rec.message as { role?: string; content?: unknown } | undefined;
  if (!message) return [];

  if (rec.type === "user") {
    const content = message.content;
    if (typeof content === "string") {
      const text = content.trim();
      return text ? [{ id: `c${seq}`, kind: "user", text: clip(text), ts }] : [];
    }
    if (Array.isArray(content)) {
      const events: StructuredEvent[] = [];
      content.forEach((block, i) => {
        const b = block as {
          type?: string;
          tool_use_id?: string;
          content?: unknown;
          is_error?: boolean;
        };
        if (b.type === "tool_result") {
          events.push({
            id: `c${seq}:${i}`,
            kind: "tool_result",
            text: clip(contentToText(b.content)),
            toolUseId: b.tool_use_id,
            isError: b.is_error === true,
            ts,
          });
        }
      });
      return events;
    }
    return [];
  }

  if (rec.type === "assistant" && Array.isArray(message.content)) {
    const events: StructuredEvent[] = [];
    message.content.forEach((block, i) => {
      const b = block as {
        type?: string;
        text?: string;
        thinking?: string;
        id?: string;
        name?: string;
        input?: unknown;
      };
      if (b.type === "text" && b.text?.trim()) {
        events.push({ id: `c${seq}:${i}`, kind: "assistant", text: clip(b.text), ts });
      } else if (b.type === "thinking" && b.thinking?.trim()) {
        events.push({ id: `c${seq}:${i}`, kind: "thinking", text: clip(b.thinking), ts });
      } else if (b.type === "tool_use") {
        events.push({
          id: b.id ?? `c${seq}:${i}`,
          kind: "tool_use",
          text: "",
          toolName: b.name ?? "tool",
          toolInput: formatToolInput(b.input),
          ts,
        });
      }
    });
    return events;
  }

  return [];
}

/** Codex rollout record → events (the discriminator lives on `payload.type`). */
function codexRecordToEvents(rec: Record<string, unknown>, seq: number): StructuredEvent[] {
  const payload = rec.payload as
    | {
        type?: string;
        message?: string;
        summary?: unknown;
        name?: string;
        arguments?: unknown;
        input?: unknown;
        output?: unknown;
        call_id?: string;
      }
    | undefined;
  if (!payload?.type) return [];
  const ts = isoTimestamp(rec);

  switch (payload.type) {
    case "user_message":
      return payload.message?.trim()
        ? [{ id: `x${seq}`, kind: "user", text: clip(payload.message), ts }]
        : [];
    case "agent_message":
      return payload.message?.trim()
        ? [{ id: `x${seq}`, kind: "assistant", text: clip(payload.message), ts }]
        : [];
    case "reasoning": {
      // Most reasoning is encrypted (`summary: []`); only surface a text summary.
      const text = contentToText(payload.summary).trim();
      return text ? [{ id: `x${seq}`, kind: "thinking", text: clip(text), ts }] : [];
    }
    case "function_call":
    case "custom_tool_call":
      return [
        {
          id: `x${seq}`,
          kind: "tool_use",
          text: "",
          toolName: payload.name ?? "tool",
          toolInput: formatToolInput(payload.arguments ?? payload.input),
          toolUseId: payload.call_id,
          ts,
        },
      ];
    case "function_call_output":
    case "custom_tool_call_output":
      return [
        {
          id: `x${seq}`,
          kind: "tool_result",
          text: clip(contentToText(payload.output)),
          toolUseId: payload.call_id,
          ts,
        },
      ];
    default:
      // token_count / task_started / session_meta / raw `message` items, etc.
      return [];
  }
}

/** Normalize one parsed transcript record into zero or more structured events. */
export function recordToEvents(
  provider: ProviderId,
  rec: Record<string, unknown>,
  seq: number,
): StructuredEvent[] {
  return provider === "claude" ? claudeRecordToEvents(rec, seq) : codexRecordToEvents(rec, seq);
}
