// The reader for the native server's three per-session reads: the retained pty
// bytes, the structured transcript records the daemon kept, and those records in
// chat shape.
//
// Everything else the sidecar knows about a session is a subscription — the phone
// console follows `subscribeScreen` row diffs over the shared WS. That is right for a
// live pane and wrong for everything that asks once and leaves: a Telegram command
// printing the last few turns, a notification quoting what the agent just said, an
// MCP tool answering "what is that session doing". Those routes answered 501 on the
// rust core until juancode-ag1e; this is the client for them.
//
// The one thing that must not be dropped on the way through: `cols`/`rows` on a
// scrollback read. A byte ring replayed at a width it was not parsed at lands every
// hard wrap and absolute cursor move in the wrong cell, and the width is not
// recoverable from the bytes — so it travels with them, all the way to whoever
// renders.

import { nativeApiBase } from "./oracle.ts";

/** Retained pty bytes with the grid they were parsed at. Never one without the other. */
export interface SessionScrollback {
  sessionId: string;
  /** The width these bytes were parsed at. Parse at this or draw garbage. */
  cols: number;
  rows: number;
  scrollback: string;
}

/** One structured transcript record, as `subscribeTranscript` sends it. `kind` is one
 *  of turnStart, turnEnd, step, assistant, thinking, toolCall, toolResult, usage. */
export interface TranscriptRecord {
  session: string;
  source: string;
  seq: number;
  kind: string;
  atMs?: number;
  turn?: string;
  [field: string]: unknown;
}

export interface SessionTranscript {
  sessionId: string;
  /** Oldest first. */
  records: TranscriptRecord[];
}

/** One prose-bearing record in chat shape — the projection the native server serves
 *  at `/messages`, not a second source. */
export interface SessionMessage {
  seq: number;
  atMs?: number;
  turn?: string;
  role: "user" | "assistant" | "thinking" | "toolCall" | "toolResult";
  tool?: string;
  ok?: boolean;
  text: string;
}

export interface SessionMessages {
  sessionId: string;
  messages: SessionMessage[];
}

/** Raised when the core behind the native server does not serve a read (HTTP 501),
 *  so a caller can say "this core cannot" rather than "this session is empty". The
 *  distinction is the whole reason the routes 501 instead of answering `[]`. */
export class UnservedRead extends Error {}

/** Raised when the session id is not one the core holds. */
export class NoSuchSession extends Error {}

async function read<T>(id: string, leaf: string, params?: URLSearchParams): Promise<T> {
  const query = params && [...params.keys()].length > 0 ? `?${params}` : "";
  const url = `${nativeApiBase()}/api/sessions/${encodeURIComponent(id)}/${leaf}${query}`;
  let res: Response;
  try {
    res = await fetch(url);
  } catch {
    throw new Error(
      `Couldn't reach the juancode app at ${nativeApiBase()} — is the native app running on the Mac?`,
    );
  }
  if (res.status === 404) throw new NoSuchSession(`Session ${id} not found`);
  if (res.status === 501) {
    throw new UnservedRead(
      `The core serving ${nativeApiBase()} doesn't serve /${leaf} — ${await errorText(res)}`,
    );
  }
  if (!res.ok) throw new Error(`GET /api/sessions/${id}/${leaf} returned ${res.status}`);
  return (await res.json()) as T;
}

/** The `error` field of a JSON error body, or the status line when there isn't one. */
async function errorText(res: Response): Promise<string> {
  try {
    const body = (await res.json()) as { error?: unknown };
    if (typeof body.error === "string") return body.error;
  } catch {
    // A non-JSON body from an intermediary; the status is all there is to report.
  }
  return `HTTP ${res.status}`;
}

/** A session's retained pty bytes and the grid they were parsed at. */
export function fetchScrollback(id: string): Promise<SessionScrollback> {
  return read<SessionScrollback>(id, "scrollback");
}

/** A session's stored transcript records, oldest first. `limit` is how much of the
 *  tail to take; 0 is everything the daemon kept. */
export function fetchTranscript(id: string, limit?: number): Promise<SessionTranscript> {
  return read<SessionTranscript>(id, "transcript", limitParams(limit));
}

/** The same records in chat shape, with the ones carrying no prose dropped. */
export function fetchMessages(id: string, limit?: number): Promise<SessionMessages> {
  return read<SessionMessages>(id, "messages", limitParams(limit));
}

function limitParams(limit?: number): URLSearchParams | undefined {
  if (limit === undefined) return undefined;
  return new URLSearchParams({ limit: String(limit) });
}

/** How much of one message's text a transcript digest shows before it is cut. Long
 *  enough for a prompt or a short answer, short enough that a tool result the size of
 *  a file does not bury the turn it belongs to. */
export const DIGEST_CHARS = 400;

/** Render messages as the plain-text digest a phone or a Telegram reply shows.
 *  Separate from the fetch so it can be tested without a server, and so a caller that
 *  wants the structure is not handed prose it has to parse back. */
export function digest(messages: SessionMessage[], maxChars = DIGEST_CHARS): string {
  if (messages.length === 0) return "(no transcript records for this session yet)";
  return messages
    .map((m) => {
      const label = m.role === "toolCall" || m.role === "toolResult" ? labelFor(m) : m.role;
      return `${label}: ${clip(m.text.trim(), maxChars)}`;
    })
    .join("\n\n");
}

function labelFor(m: SessionMessage): string {
  const tool = m.tool ? ` ${m.tool}` : "";
  if (m.role === "toolCall") return `tool${tool}`;
  return `tool${tool} ${m.ok === false ? "failed" : "ok"}`;
}

function clip(text: string, maxChars: number): string {
  return text.length <= maxChars ? text : `${text.slice(0, maxChars)}…`;
}
