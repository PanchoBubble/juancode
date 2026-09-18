// The reader for the native server's per-session reads: the retained pty bytes, the
// rendered screen, the structured transcript records the daemon kept, those records in
// chat shape, and the session's git working tree — diff, branch state, worktrees, and
// one file out of it.
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

import type { ScreenRowUpdate } from "./native-events.ts";
import { nativeApiBase } from "./oracle.ts";

/** The RENDERED screen of a live session: the parsed grid, not a byte log
 *  (`GET /api/sessions/:id/screen?json=1`, juancode-tyd9). Ordered, fully redrawn, and
 *  width-correct by construction — nothing here has to be replayed at a width, which is
 *  the failure mode `SessionScrollback` exists to work around.
 *
 *  `lines` is the `subscribeScreen` row shape, so the stream's decoder reads it too.
 *  History rows (asked for with `scrollback`) carry NEGATIVE row indices, which leaves
 *  the visible grid at 0 … rows-1 exactly as a screen frame has it. */
export interface SessionScreen {
  sessionId: string;
  cols: number;
  rows: number;
  cursor: { x: number; y: number; visible: boolean };
  alt: boolean;
  title?: string;
  /** How many of `lines` are history rows. */
  scrollback: number;
  lines: ScreenRowUpdate[];
}

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
/** One file's change in a session's working tree, as `GET /api/sessions/:id/diff`
 *  answers it (juancode-52e8.14.5). `diff` is the raw unified patch; it is empty for a
 *  binary file and for one past the core's per-file cap, which `truncated` tells apart
 *  from a file with no changed lines. */
export interface DiffFile {
  path: string;
  oldPath?: string;
  status: "modified" | "added" | "deleted" | "renamed" | "untracked";
  additions: number;
  deletions: number;
  binary: boolean;
  diff: string;
  truncated: boolean;
}

/** A session's working-tree diff. `git: false` is a session in a directory that is not
 *  a repo — which is normal, and is NOT an error: a caller draws "not a repo" rather
 *  than "nothing changed", because those are different things to tell somebody. */
export interface SessionDiff {
  git: boolean;
  root?: string;
  files: DiffFile[];
  truncatedFiles?: boolean;
}

/** A session's branch state: what to say about committing and pushing. With no
 *  upstream, `ahead` counts every commit on the branch, not the unpushed ones. */
export interface SessionGitState {
  git: boolean;
  branch: string | null;
  detached: boolean;
  upstream: string | null;
  ahead: number;
  behind: number;
  dirty: boolean;
  remote: boolean;
}

/** One linked worktree of the repo a session's cwd belongs to. */
export interface SessionWorktree {
  path: string;
  branch: string | null;
  head: string | null;
  main: boolean;
  lockedReason?: string;
}

export class UnservedRead extends Error {}

/** Raised when the session id is not one the core holds. */
export class NoSuchSession extends Error {}

/** Raised when the session exists but has no live pty, so a read that can only come
 *  from the running process (the rendered screen) has nothing to answer with. */
export class SessionNotRunning extends Error {}

/** One read, with the status codes mapped to the distinctions a caller acts on. The
 *  body is left to the caller: `/screen` answers text/plain unless asked for JSON. */
async function request(id: string, leaf: string, params?: URLSearchParams): Promise<Response> {
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
  if (res.status === 409) throw new SessionNotRunning(await errorText(res));
  if (res.status === 501) {
    throw new UnservedRead(
      `The core serving ${nativeApiBase()} doesn't serve /${leaf} — ${await errorText(res)}`,
    );
  }
  if (!res.ok) throw new Error(`GET /api/sessions/${id}/${leaf} returned ${res.status}`);
  return res;
}

async function read<T>(id: string, leaf: string, params?: URLSearchParams): Promise<T> {
  return (await (await request(id, leaf, params)).json()) as T;
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

/** How much history a screen read asks for by default when it asks at all: enough for
 *  the turn that just happened, far short of the model's 500-row cap. */
export const SCREEN_SCROLLBACK_ROWS = 200;

/** The rendered screen as text — the default body of `/screen`, which is what anyone
 *  answering "what does that pane look like" actually wants. `scrollback` rows of
 *  history are flowed in above it when asked for. */
export async function fetchScreenText(id: string, scrollback = 0): Promise<string> {
  return (await request(id, "screen", screenParams(scrollback))).text();
}

/** The same screen as styled rows in the `subscribeScreen` shape. */
export function fetchScreen(id: string, scrollback = 0): Promise<SessionScreen> {
  const params = screenParams(scrollback);
  params.set("json", "1");
  return read<SessionScreen>(id, "screen", params);
}

function screenParams(scrollback: number): URLSearchParams {
  const params = new URLSearchParams();
  if (scrollback > 0) params.set("scrollback", String(scrollback));
  return params;
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

/** The session's working-tree diff vs HEAD (juancode-52e8.14.5).
 *
 *  Both cores serve this path, but only one answers it: the Swift core does not
 *  advertise `changes` and 501s, which surfaces here as `UnservedRead` — the same
 *  distinction the transcript reads make between "this core cannot" and "this session
 *  has nothing", and the reason a caller must not render a 501 as an empty diff. */
export function fetchDiff(id: string): Promise<SessionDiff> {
  return read<SessionDiff>(id, "diff");
}

/** The session's branch, upstream and dirtiness. */
export function fetchGitState(id: string): Promise<SessionGitState> {
  return read<SessionGitState>(id, "git");
}

/** Every linked worktree of the session's repo, main one first. */
export function fetchWorktrees(id: string): Promise<SessionWorktree[]> {
  return read<SessionWorktree[]>(id, "worktrees");
}

/** One file out of the session's worktree. A path that leaves the tree is refused by
 *  the core, and arrives here as an ordinary not-found. */
export function fetchWorktreeFile(id: string, path: string): Promise<{ path: string; content: string }> {
  return read<{ path: string; content: string }>(id, "file", new URLSearchParams({ path }));
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
