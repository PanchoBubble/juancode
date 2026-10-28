// Handing a long session off to a fresh one (juancode-u5q). Cache reads are most of
// the token spend: a session at 400k+ context re-reads all of it on every turn, so
// past ~250k the cheaper way on is a new session seeded with a short note.
//
// The flow, never automatic — a person (or the Oracle, asked by one) starts it:
//
//   1. Queue the note request into the session through the ordinary queue, so it lands
//      on the next idle and never types over a draft.
//   2. When the session settles after that prompt, read its reply from the daemon's
//      transcript and take the note from between the explicit markers. No note, no
//      handoff: the session is left exactly as it was.
//   3. Spawn the successor in the same checkout, provider, model, preset and permission
//      mode, with the note itself as its first prompt — no file to read, so no extra turn.
//   4. Record the handoff in the daemon's chain handoff history (old session → new,
//      summary = the note), putting the old session in a chain first if it has none.
//      Nothing is written to the repo or the worktree, and the note outlives a sweep.
//   5. Put the old session to sleep: dormant, not killed, so it stays resumable.
//
// Both entry points — the MCP tool and the native row action (via HTTP) — run this one
// function, so they cannot disagree about what a handoff is.

import { randomUUID } from "node:crypto";
import { basename } from "node:path";

import { readBook, defaultChainDeps } from "./chains.ts";
import { wsCreate, type WsCreateReply } from "./dispatch.ts";
import {
  createChain,
  createHandoff,
  onSessionEvent,
  sessionActivity,
  setChainMember,
  sleepSession,
  supportsHandoffs,
  type Chain,
  type ChainResult,
  type HandoffInput,
  type HandoffResult,
  type SessionActivityEvent,
} from "./native-events.ts";
import { listSessions, queueMessages } from "./oracle.ts";
import { fetchMessages, fetchTranscript, type SessionMessage } from "./session-reads.ts";
import { resolveSessionRef, parseSessionList } from "./telegram-format.ts";

export const HANDOFF_BEGIN = "<<<HANDOFF>>>";
export const HANDOFF_END = "<<<END HANDOFF>>>";
export const HANDOFF_MAX_LINES = 60;

/** How long a handoff waits for the note by default: the request may sit in the queue
 *  behind a turn that is still running. */
export const DEFAULT_HANDOFF_TIMEOUT_MS = 15 * 60_000;

/** How many idle readings in a row may show the request delivered but no note before
 *  the handoff gives up. More than one, because the transcript can trail the idle edge. */
const MISSING_NOTE_READINGS = 3;

/** The note request, queued into the old session. One line, so it arrives as one
 *  message however the queue delivers it. */
export function handoffRequestPrompt(): string {
  return (
    "Context handoff: this session is being replaced by a fresh one so the long context " +
    "stops being re-read every turn. Do not continue the task. Reply with a handoff note " +
    `of at most ${HANDOFF_MAX_LINES} lines between a line ${HANDOFF_BEGIN} and a line ` +
    `${HANDOFF_END}, covering: the goal; the current state (done, in progress, uncommitted); ` +
    "the exact next step; key file:line locations; open beads ids. Then stop."
  );
}

/** The successor's first prompt: the note, with just enough framing to act on it. */
export function successorPrompt(note: string, from: { id: string; title: string }): string {
  return (
    `You are taking over from the juancode session "${from.title}" (${from.id.slice(0, 8)}), ` +
    "which handed off to keep its context small. Its handoff note follows. Trust it, re-read " +
    "only what you need, and continue from its next step.\n\n" +
    note
  );
}

/** The note between the LAST pair of markers in `text`, or null when there is none or
 *  it is empty. The last, so a reply that quotes the markers before writing the note
 *  still yields the note. */
export function extractHandoffNote(text: string): string | null {
  const end = text.lastIndexOf(HANDOFF_END);
  if (end < 0) return null;
  const begin = text.lastIndexOf(HANDOFF_BEGIN, end);
  if (begin < 0) return null;
  const note = text.slice(begin + HANDOFF_BEGIN.length, end).trim();
  return note ? note : null;
}

/** What the handoff needs to know about the session it replaces. */
export interface HandoffSource {
  id: string;
  title: string;
  provider: string;
  cwd: string;
  /** Its juancode-owned worktree, when it has one; the successor runs there too. */
  worktreePath?: string;
  skipPermissions: boolean;
  status: string;
  kind?: string;
  contextWindow?: number;
  /** The preset it was created with; the successor is started with the same one. */
  preset?: string;
  /** The model it was created pinned to. The transcript's model wins when it names one,
   *  since a `/model` switch moves the session off its pin. */
  pinnedModel?: string;
}

export interface HandoffDeps {
  /** The session by id or unique id prefix, or null when there is none. */
  source: (ref: string) => Promise<HandoffSource | null>;
  /** Whether the core records handoffs at all. */
  supported: () => boolean;
  activity: (sessionId: string) => SessionActivityEvent["state"] | undefined;
  subscribe: (listener: (ev: SessionActivityEvent) => void) => () => void;
  /** The tail of the session's transcript in chat shape, oldest first. */
  messages: (sessionId: string) => Promise<SessionMessage[]>;
  /** The model the session's last turn ran on, when the transcript says. */
  model: (sessionId: string) => Promise<string | undefined>;
  queue: (sessionId: string, text: string) => Promise<void>;
  create: (frame: Record<string, unknown>) => Promise<WsCreateReply>;
  /** The chain book, once the core has sent it. */
  book: () => Promise<Chain[]>;
  createChain: (id: string, name: string) => Promise<ChainResult>;
  setMember: (member: { kind: "session"; ref: string; slug: string }) => Promise<ChainResult>;
  createHandoff: (handoff: HandoffInput) => Promise<HandoffResult>;
  /** Sleep the session; false when the core cannot. */
  sleep: (sessionId: string) => boolean;
  newId?: () => string;
  now?: () => number;
  /** How often the session is re-read between activity events. */
  recheckMs?: number;
}

export interface HandoffOptions {
  timeoutMs?: number;
  /** Ends the wait early; the handoff then refuses as timed out. */
  signal?: AbortSignal;
}

export interface HandoffOutcome {
  sessionId: string;
  successorId: string;
  chainSlug: string;
  /** The recorded handoff's id, or null when recording it failed (see `warnings`). */
  handoffId: string | null;
  note: string;
  /** Whether the old session was put to sleep. */
  slept: boolean;
  /** Steps after the spawn that did not land; the successor is running regardless. */
  warnings: string[];
}

/** A handoff that did not happen, in words a person can act on. Nothing was spawned. */
export class HandoffRefused extends Error {}

const inFlight = new Map<string, Promise<HandoffOutcome>>();

/** Hand `ref` off to a fresh session. A second request for a session already handing
 *  off joins the first rather than queueing a second note request. */
export async function handOffSession(
  ref: string,
  deps: HandoffDeps = defaultHandoffDeps(),
  opts: HandoffOptions = {},
): Promise<HandoffOutcome> {
  const source = await deps.source(ref);
  if (!source) throw new HandoffRefused(`No session "${ref}".`);
  const running = inFlight.get(source.id);
  if (running) return running;
  const attempt = runHandoff(source, deps, opts).finally(() => inFlight.delete(source.id));
  inFlight.set(source.id, attempt);
  return attempt;
}

async function runHandoff(
  source: HandoffSource,
  deps: HandoffDeps,
  opts: HandoffOptions,
): Promise<HandoffOutcome> {
  const name = `"${source.title}"`;
  if (source.kind && source.kind !== "agent") {
    throw new HandoffRefused(`${name} is not an agent session; there is nothing to hand off.`);
  }
  if (source.status !== "running") {
    throw new HandoffRefused(
      `${name} is not running, so it cannot write its handoff note. Wake it first.`,
    );
  }
  if (!deps.supported()) {
    throw new HandoffRefused(
      "This core does not record handoffs (no chainHandoffs capability); nothing was done.",
    );
  }
  if (deps.activity(source.id) === "waiting_input") {
    throw new HandoffRefused(`${name} is waiting for input. Answer it first, then hand off.`);
  }

  const note = await requestNote(source, deps, opts);

  const newId = deps.newId ?? randomUUID;
  const chainSlug = await chainFor(source, deps, newId);

  const transcriptModel = await deps.model(source.id).catch(() => undefined);
  const model = transcriptModel ? withLongContext(transcriptModel, source) : source.pinnedModel;
  const reply = await deps.create({
    type: "create",
    provider: source.provider,
    // The checkout the old session was editing, in place: the successor continues the
    // same uncommitted work, so a fresh worktree would be the wrong tree.
    cwd: source.worktreePath ?? source.cwd,
    initialInput: successorPrompt(note, source),
    skipPermissions: source.skipPermissions,
    ...(model ? { model } : {}),
    ...(source.preset ? { preset: source.preset } : {}),
  });
  if (reply.kind !== "created") {
    const why = reply.kind === "rejected" ? reply.message : reply.reason;
    throw new HandoffRefused(
      `Could not start the successor (${why}). ${name} was left running. The note was:\n\n${note}`,
    );
  }
  const successorId = reply.sessionId;

  const warnings: string[] = [];
  const joined = await deps.setMember({ kind: "session", ref: successorId, slug: chainSlug });
  if (!joined.ok) warnings.push(`the successor was not added to the chain (${joined.error})`);

  const handoffId = newId();
  const recorded = await deps.createHandoff({
    id: handoffId,
    chainSlug,
    source: { kind: "session", sessionId: source.id },
    target: { kind: "session", sessionId: successorId },
    summary: note,
  });
  if (!recorded.ok) warnings.push(`the handoff was not recorded (${recorded.error})`);

  const slept = deps.sleep(source.id);
  if (!slept) warnings.push(`${name} could not be put to sleep; it is still running`);

  return {
    sessionId: source.id,
    successorId,
    chainSlug,
    handoffId: recorded.ok ? handoffId : null,
    note,
    slept,
    warnings,
  };
}

/** Queue the request and wait for the note. Refuses when the session stops to ask for
 *  input, settles without a note, or the wait runs out. */
async function requestNote(
  source: HandoffSource,
  deps: HandoffDeps,
  opts: HandoffOptions,
): Promise<string> {
  const name = `"${source.title}"`;
  const now = deps.now ?? Date.now;
  const recheckMs = deps.recheckMs ?? 2_000;
  const deadline = now() + (opts.timeoutMs ?? DEFAULT_HANDOFF_TIMEOUT_MS);

  // Everything the transcript already holds is from before the request; only what
  // comes after it can be the reply.
  const before = await deps.messages(source.id).catch((e: unknown) => {
    throw new HandoffRefused(
      `Cannot read ${name}'s transcript, so its note could not be collected: ${errorText(e)}`,
    );
  });
  const baseline = before.reduce((max, m) => Math.max(max, m.seq), -1);

  let wake: (() => void) | null = null;
  const unsubscribe = deps.subscribe((ev) => {
    if (ev.sessionId === source.id) wake?.();
  });
  const onAbort = () => wake?.();
  opts.signal?.addEventListener("abort", onAbort);

  try {
    await deps.queue(source.id, handoffRequestPrompt());
    let missing = 0;
    for (;;) {
      const state = deps.activity(source.id);
      if (state === "waiting_input") {
        throw new HandoffRefused(
          `${name} stopped to ask for input instead of writing its note. Answer it, then ` +
            "hand off again (a request still in its queue goes out on the next idle).",
        );
      }
      if (state === "idle") {
        const after = (await deps.messages(source.id).catch(() => [])).filter(
          (m) => m.seq > baseline,
        );
        const note = latestNote(after);
        if (note) return note;
        // Only a reply to the request can be missing its note: an idle before the
        // queue delivered it is the previous turn ending.
        const delivered = after.some((m) => m.role === "user" && m.text.includes(HANDOFF_BEGIN));
        if (delivered && ++missing >= MISSING_NOTE_READINGS) {
          throw new HandoffRefused(
            `${name} answered without a handoff note between ${HANDOFF_BEGIN} and ${HANDOFF_END}; nothing was handed off.`,
          );
        }
      }
      const remaining = deadline - now();
      if (remaining <= 0 || opts.signal?.aborted) {
        throw new HandoffRefused(
          `Timed out waiting for ${name} to write its handoff note; nothing was handed off. ` +
            "The request may still be in its queue.",
        );
      }
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, Math.min(recheckMs, remaining));
        wake = () => {
          clearTimeout(timer);
          resolve();
        };
      });
      wake = null;
    }
  } finally {
    unsubscribe();
    opts.signal?.removeEventListener("abort", onAbort);
  }
}

/** The newest note among the assistant's messages. */
function latestNote(messages: SessionMessage[]): string | null {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i]!;
    if (m.role !== "assistant") continue;
    const note = extractHandoffNote(m.text);
    if (note) return note;
  }
  return null;
}

/** The chain the handoff is recorded in: the old session's own, or a new one named
 *  after it, with the old session put in it. */
async function chainFor(
  source: HandoffSource,
  deps: HandoffDeps,
  newId: () => string,
): Promise<string> {
  const book = await deps.book();
  const existing = book.find((c) =>
    c.members.some((m) => m.kind === "session" && m.ref === source.id),
  );
  if (existing) return existing.slug;
  const slug = newId();
  const where = basename(source.worktreePath ?? source.cwd);
  const created = await deps.createChain(slug, `${source.title} (${where})`.slice(0, 200));
  if (!created.ok) {
    throw new HandoffRefused(
      `Could not create a chain to record the handoff in (${created.error}); nothing was spawned.`,
    );
  }
  const joined = await deps.setMember({ kind: "session", ref: source.id, slug });
  if (!joined.ok) {
    throw new HandoffRefused(
      `Could not put the session in its new chain (${joined.error}); nothing was spawned.`,
    );
  }
  return slug;
}

/** The transcript names the model without the long-context marker the CLI was started
 *  with, so a session that was running a 1M window says so explicitly again. */
function withLongContext(model: string, source: HandoffSource): string {
  const long = (source.contextWindow ?? 0) >= 1_000_000;
  if (source.provider === "claude" && long && !/\[1m\]/i.test(model)) return `${model}[1m]`;
  return model;
}

function errorText(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

/** The session rows as /api/sessions serves them, with the fields a handoff reads. */
export function parseHandoffSources(raw: unknown): HandoffSource[] {
  const list = Array.isArray(raw) ? raw : ((raw as { sessions?: unknown[] })?.sessions ?? []);
  if (!Array.isArray(list)) return [];
  const out: HandoffSource[] = [];
  for (const item of list) {
    if (!item || typeof item !== "object") continue;
    const r = item as Record<string, unknown>;
    if (typeof r.id !== "string" || !r.id || typeof r.cwd !== "string") continue;
    const usage = (r.usage ?? {}) as Record<string, unknown>;
    out.push({
      id: r.id,
      title: typeof r.title === "string" && r.title.trim() ? r.title.trim() : r.id.slice(0, 8),
      provider: typeof r.provider === "string" ? r.provider : "claude",
      cwd: r.cwd,
      ...(typeof r.worktreePath === "string" && r.worktreePath
        ? { worktreePath: r.worktreePath }
        : {}),
      skipPermissions: r.skipPermissions === true,
      status: typeof r.status === "string" ? r.status : "unknown",
      ...(typeof r.kind === "string" ? { kind: r.kind } : {}),
      ...(typeof usage.contextWindow === "number" ? { contextWindow: usage.contextWindow } : {}),
      ...(typeof r.preset === "string" && r.preset ? { preset: r.preset } : {}),
      ...(typeof r.pinnedModel === "string" && r.pinnedModel ? { pinnedModel: r.pinnedModel } : {}),
    });
  }
  return out;
}

/** How many transcript records to scan for the model and the reply. */
const TRANSCRIPT_TAIL = 200;

/** The real collaborators. */
export function defaultHandoffDeps(): HandoffDeps {
  const chainDeps = defaultChainDeps();
  return {
    source: async (ref) => {
      const raw = await listSessions();
      const rows = parseHandoffSources(raw);
      const id = resolveSessionRef(parseSessionList(raw), ref.trim());
      return rows.find((r) => r.id === id) ?? null;
    },
    supported: supportsHandoffs,
    activity: sessionActivity,
    subscribe: onSessionEvent,
    messages: async (id) => (await fetchMessages(id, TRANSCRIPT_TAIL)).messages,
    model: async (id) => {
      const { records } = await fetchTranscript(id, TRANSCRIPT_TAIL);
      for (let i = records.length - 1; i >= 0; i--) {
        const model = records[i]!.model;
        if (typeof model === "string" && model) return model;
      }
      return undefined;
    },
    queue: (id, text) => queueMessages(id, [text]),
    create: (frame) => wsCreate(() => frame, false, 15_000),
    book: () => readBook(chainDeps),
    createChain: (id, name) => createChain(id, name),
    setMember: (member) => setChainMember(member),
    createHandoff,
    sleep: sleepSession,
  };
}

/** The outcome in words, for the MCP tool and the HTTP caller. */
export function handoffSummary(outcome: HandoffOutcome): string {
  const lines = [
    `Handed off ${outcome.sessionId.slice(0, 8)} → ${outcome.successorId.slice(0, 8)} ` +
      `(chain ${outcome.chainSlug}). The successor started with this note as its first prompt:`,
    "",
    outcome.note,
  ];
  if (outcome.warnings.length > 0) lines.push("", `Note: ${outcome.warnings.join("; ")}.`);
  return lines.join("\n");
}
