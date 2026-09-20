// Dispatching an agent into a project, WS-first with a durable offline fallback
// (juancode-2kz.1). The old path appended a line to `dispatch.jsonl` and reported
// success no matter what — with the native app down (or the path bogus) the work
// silently vanished. Now:
//
//   1. Open a short-lived WS to the native server and send a `create` carrying the
//      prompt as `initialInput` plus a minted `dispatchId`. The server's ack is the
//      truth: `created` → real success with the sessionId; `error` → a real,
//      caller-visible failure (bad path, unknown provider, spawn failure).
//   2. Only when the app is unreachable (connect failure / no ack) append the same
//      dispatch — same `dispatchId` — to `dispatch.jsonl` and report "queued". The
//      native app replays the mailbox from a persisted offset on launch, and its
//      dispatch ledger dedupes by id, so a dispatch that raced onto both paths
//      still starts exactly once.
//
// That ledger only dedupes ONE dispatch id, though, and a caller that retries mints
// a new one. Two guards in front of the create close that (juancode-nwrb, see
// dispatch-guard.ts): an identical request inside a short window collapses onto the
// first dispatch, and a bd ticket that already has a live session is refused
// outright. Both are overridable with `force`.
//
// Keep the mailbox line shape in lockstep with the Swift `OracleDispatch` struct
// in apps/native — the app tails the file and decodes each line.

import { appendFile } from "node:fs/promises";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { WebSocket } from "ws";
import { nativeApiBase, nativeWsUrl, oracleDir } from "./oracle.ts";
import { markQueuedDispatch } from "./dispatch-results.ts";
import { recordDispatch, type TriggerOrigin } from "./dispatch-registry.ts";
import {
  listDispatchStatuses,
  type DispatchStatus,
  type SessionsFetcher,
} from "./dispatch-status.ts";
import {
  findDuplicate,
  findTicketConflict,
  liveDispatches,
  requestFingerprint,
  ticketIdsInPrompt,
} from "./dispatch-guard.ts";

export interface DispatchRequest {
  /** Absolute path of the target project / work dir. */
  project: string;
  /** The seed instruction sent to the agent once its TUI is up. */
  prompt: string;
  provider?: "claude" | "codex" | "opencode";
  /** Isolate the agent in a fresh git worktree off `project`. */
  worktree?: boolean;
  /** The Telegram chat the dispatch originated from, when it did. Recorded in the
   *  dispatch registry so lifecycle events (needs input / finished) route back to
   *  that chat; never sent to the native app. */
  telegramChatId?: number | null;
  /** Set when a trigger (cron schedule / GitHub label) asked for this dispatch
   *  instead of a human. Recorded in the registry so Telegram can say where the
   *  session came from; never sent to the native app. */
  trigger?: TriggerOrigin | null;
  /** The bd ticket this dispatch works, when the caller knows it. Declaring it is
   *  better than letting the guard read it out of the prompt, but not required. */
  ticket?: string | null;
  /** A caller-chosen retry key. Two posts carrying the same key are the same
   *  dispatch even if their prompts differ. */
  idempotencyKey?: string | null;
  /** Skip both guards. For "yes, I really do want a second session on this". */
  force?: boolean;
}

export interface DispatchOutcome {
  dispatchId: string;
  /** What happened, in one word a caller can switch on. `duplicate` means this
   *  request collapsed onto an earlier dispatch and created nothing. */
  state: "started" | "queued" | "duplicate";
  /** The native app acked the create — the session is really running. */
  started: boolean;
  /** The app was unreachable; the dispatch is queued in the mailbox. */
  queued: boolean;
  /** The dispatch is accepted and will produce exactly one session — whether that
   *  already happened (`started`) or happens when the app is next up (`queued`).
   *  False only if nothing is coming, which today never happens without a throw.
   *  Read THIS rather than `started` before deciding to post again. */
  willStart: boolean;
  /** The earlier dispatch this request collapsed onto, when it did. */
  duplicateOf: string | null;
  sessionId: string | null;
  /** The bd ticket the guards keyed on, declared or read out of the prompt. */
  ticket: string | null;
  /** Why the dispatch is queued rather than started: the app was unreachable, or
   *  it was reachable but did not ack in time. Null unless queued. */
  queuedReason: "unreachable" | "no-ack" | null;
  /** What a caller that only reads JSON should do next. */
  advice: string;
  /** Human-readable summary for the MCP tool / console / Telegram. */
  message: string;
}

/** A dispatch the ticket guard refused. Distinct from a server-side rejection so
 *  HTTP callers get a 409 ("you already have one of these") rather than a 500
 *  ("something broke") — the two want opposite responses from a retrying caller. */
export class DispatchConflictError extends Error {
  readonly ticket: string;
  readonly conflictingDispatchId: string;
  readonly conflictingSessionId: string | null;
  constructor(
    message: string,
    ticket: string,
    conflictingDispatchId: string,
    conflictingSessionId: string | null,
  ) {
    super(message);
    this.name = "DispatchConflictError";
    this.ticket = ticket;
    this.conflictingDispatchId = conflictingDispatchId;
    this.conflictingSessionId = conflictingSessionId;
  }
}

/** Everything the guards need to look at the world, injectable for tests. */
export interface DispatchDeps {
  /** How the guards read the native app's session list. */
  fetchSessions?: SessionsFetcher;
  now?: () => number;
}

const dispatchFile = () => join(oracleDir(), "dispatch.jsonl");

/** How long to wait for the native server's create ack. Worktree isolation runs
 *  `git worktree add` before the ack, so this is generous. */
const CREATE_ACK_TIMEOUT_MS = 15_000;

/** How many recent dispatches the guards look back over. */
const GUARD_LOOKBACK = 100;

const POLL_ADVICE =
  "Poll GET /api/dispatches (or oracle_dispatch_status) with this dispatchId instead of posting again.";

/** Append one dispatch line for the native app to tail and spawn an agent from.
 *  The offline fallback — shape MUST match Swift `OracleDispatch`. */
export async function appendDispatch(opts: DispatchRequest, dispatchId: string): Promise<void> {
  const line =
    JSON.stringify({
      project: opts.project,
      prompt: opts.prompt,
      provider: opts.provider ?? "claude",
      worktree: opts.worktree ?? false,
      dispatchId,
    }) + "\n";
  await appendFile(dispatchFile(), line, "utf8");
}

type WsCreateReply =
  | { kind: "created"; sessionId: string }
  /** The server answered with a real error — do NOT queue, surface it. */
  | { kind: "rejected"; message: string }
  /** No server / no ack — fall back to the durable mailbox. `connected` separates
   *  "the app isn't there" from "the app is there and too busy to answer", which
   *  are very different things to tell a caller. */
  | { kind: "unreachable"; reason: string; connected: boolean };

/** One `create` round-trip over a short-lived WS to the native server. Resolves
 *  (never rejects): connectivity problems come back as `unreachable` so the caller
 *  can queue, while a server-sent `error` is a genuine rejection. */
function wsCreate(
  opts: DispatchRequest,
  dispatchId: string,
  timeoutMs: number,
): Promise<WsCreateReply> {
  return new Promise((resolve) => {
    let sock: WebSocket;
    try {
      sock = new WebSocket(nativeWsUrl());
    } catch (e) {
      resolve({
        kind: "unreachable",
        reason: e instanceof Error ? e.message : String(e),
        connected: false,
      });
      return;
    }
    let settled = false;
    let connected = false;
    const settle = (reply: WsCreateReply) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        sock.close();
      } catch {
        /* already closing */
      }
      resolve(reply);
    };
    const timer = setTimeout(
      () =>
        settle({
          kind: "unreachable",
          reason: "timed out waiting for the app's create ack",
          connected,
        }),
      timeoutMs,
    );
    sock.on("error", (e) =>
      settle({
        kind: "unreachable",
        reason: e instanceof Error ? e.message : String(e),
        connected,
      }),
    );
    sock.on("close", () =>
      settle({
        kind: "unreachable",
        reason: "connection closed before the create ack",
        connected,
      }),
    );
    sock.on("open", () => {
      connected = true;
      sock.send(
        JSON.stringify({
          type: "create",
          provider: opts.provider ?? "claude",
          cwd: opts.project,
          // No grid: a dispatch has no viewport of its own, so the app boots the
          // CLI at the desktop's real terminal size. Sending a nominal one printed
          // the entire first turn at that width, and no later resize can rewrap
          // what's already in the scrollback.
          initialInput: opts.prompt,
          skipPermissions: true,
          isolateWorktree: opts.worktree ?? false,
          dispatchId,
        }),
      );
    });
    sock.on("message", (data) => {
      let msg: Record<string, unknown>;
      try {
        msg = JSON.parse(data.toString()) as Record<string, unknown>;
      } catch {
        return; // ignore non-JSON noise
      }
      // Only the create's outcome matters; serverInfo/activity/attached/… pass by.
      if (msg.type === "created") {
        const session = msg.session as Record<string, unknown> | undefined;
        const id = session && typeof session.id === "string" ? session.id : null;
        if (id) settle({ kind: "created", sessionId: id });
        else settle({ kind: "rejected", message: "the app acked the create without a session id" });
      } else if (msg.type === "error") {
        settle({
          kind: "rejected",
          message: typeof msg.message === "string" && msg.message ? msg.message : "create failed",
        });
      }
    });
  });
}

/** In-flight dispatches by fingerprint. The registry record is only written after
 *  the create round-trip, so without this a retry that lands inside the 15s ack
 *  window — exactly when a caller retries — would sail past the registry guard. */
const inFlight = new Map<string, Promise<DispatchOutcome>>();

/** The outcome for a request that collapsed onto `first` instead of creating a
 *  second session. Deliberately carries `first`'s dispatchId: a caller that tracks
 *  the id it got back then tracks the dispatch that actually exists. */
function asDuplicate(first: DispatchOutcome, why: string): DispatchOutcome {
  return {
    ...first,
    state: "duplicate",
    duplicateOf: first.dispatchId,
    advice: `No second session was created. ${POLL_ADVICE}`,
    message: `Not dispatched again — ${why}. ${
      first.sessionId
        ? `It is session ${first.sessionId} (dispatch ${first.dispatchId}).`
        : `It is dispatch ${first.dispatchId}, still queued.`
    }`,
  };
}

/**
 * Dispatch an agent into a project: WS `create` with ack when the native app is up
 * (real success with sessionId / real error), mailbox fallback when it isn't
 * ("queued — starts when the app is next up"). Throws on a genuine server-side
 * rejection, and on a ticket that already has a live session, so MCP/HTTP callers
 * surface it verbatim.
 */
export async function dispatch(
  opts: DispatchRequest,
  timeoutMs = CREATE_ACK_TIMEOUT_MS,
  deps: DispatchDeps = {},
): Promise<DispatchOutcome> {
  if (opts.force) return runDispatch(opts, timeoutMs, deps);

  const fingerprint = requestFingerprint(opts);
  const pending = inFlight.get(fingerprint);
  if (pending) {
    return asDuplicate(await pending, "an identical dispatch was already in flight");
  }
  const run = runDispatch(opts, timeoutMs, deps, fingerprint);
  inFlight.set(fingerprint, run);
  void run
    .catch(() => {
      /* the caller of `run` owns the error; this arm only exists to settle */
    })
    .finally(() => {
      if (inFlight.get(fingerprint) === run) inFlight.delete(fingerprint);
    });
  return run;
}

async function runDispatch(
  opts: DispatchRequest,
  timeoutMs: number,
  deps: DispatchDeps,
  fingerprint = requestFingerprint(opts),
): Promise<DispatchOutcome> {
  const now = deps.now ?? Date.now;
  const tickets = opts.ticket ? [opts.ticket.toLowerCase()] : ticketIdsInPrompt(opts.prompt);
  const ticket = tickets[0] ?? null;

  if (!opts.force) {
    // One read of the merged registry/results/sessions view answers both guards.
    // Unreachable app ⇒ no live sessions, so the guards degrade to the durable
    // records rather than throwing into a dispatch.
    const statuses = await listDispatchStatuses(GUARD_LOOKBACK, deps.fetchSessions).catch(
      (): DispatchStatus[] => [],
    );
    const at = now();

    const earlier = findDuplicate(statuses, fingerprint, at);
    if (earlier) {
      const ageS = Math.max(0, Math.round((at - earlier.at) / 1000));
      return asDuplicate(
        {
          dispatchId: earlier.dispatchId,
          state: earlier.outcome === "started" ? "started" : "queued",
          started: earlier.outcome === "started",
          queued: earlier.outcome === "queued",
          willStart: true,
          duplicateOf: null,
          sessionId: earlier.sessionId,
          ticket: earlier.ticket ?? ticket,
          queuedReason: null,
          advice: "",
          message: "",
        },
        `the same dispatch was posted ${ageS}s ago`,
      );
    }

    const conflict = findTicketConflict(liveDispatches(statuses, at), tickets);
    if (conflict) {
      const clash = conflict.tickets.find((t) => tickets.includes(t)) ?? ticket ?? "";
      throw new DispatchConflictError(
        `Refusing: bd ticket ${clash} already has a ${
          conflict.state === "running" ? "live agent session" : "queued dispatch"
        }${conflict.sessionId ? ` (session ${conflict.sessionId})` : ""} from dispatch ${
          conflict.dispatchId
        } in ${conflict.project}. Kill that session first, or re-post with "force": true if two ` +
          `agents on one ticket is really what you want.`,
        clash,
        conflict.dispatchId,
        conflict.sessionId,
      );
    }
  }

  const dispatchId = randomUUID();
  const provider = opts.provider ?? "claude";
  const reply = await wsCreate(opts, dispatchId, timeoutMs);
  // Every outcome lands in the durable dispatch registry (args + origin chat), so
  // dispatch-status can answer for it later and lifecycle events can route back to
  // the originating Telegram chat. Best-effort: a registry write failure must not
  // fail (or mask) the dispatch itself.
  const record = (
    outcome: "started" | "queued" | "rejected",
    sessionId: string | null,
    error: string | null,
  ) =>
    recordDispatch({
      dispatchId,
      project: opts.project,
      prompt: opts.prompt,
      provider,
      worktree: opts.worktree ?? false,
      telegramChatId: opts.telegramChatId ?? null,
      trigger: opts.trigger ?? null,
      ticket,
      fingerprint,
      idempotencyKey: opts.idempotencyKey ?? null,
      outcome,
      sessionId,
      error,
      at: now(),
    }).catch((e) =>
      console.warn("dispatch registry write failed:", e instanceof Error ? e.message : e),
    );
  switch (reply.kind) {
    case "created":
      await record("started", reply.sessionId, null);
      return {
        dispatchId,
        state: "started",
        started: true,
        queued: false,
        willStart: true,
        duplicateOf: null,
        sessionId: reply.sessionId,
        ticket,
        queuedReason: null,
        advice: `Running now. ${POLL_ADVICE}`,
        message: `Started ${provider} session ${reply.sessionId} in ${opts.project}${
          opts.worktree ? " (worktree)" : ""
        }.`,
      };
    case "rejected":
      await record("rejected", null, reply.message);
      throw new Error(reply.message);
    case "unreachable": {
      await appendDispatch(opts, dispatchId);
      // Remember the id so the results relay can confirm on Telegram when the
      // queued dispatch actually starts (or report why it didn't).
      markQueuedDispatch(dispatchId);
      await record("queued", null, null);
      // "queued" used to be reported as `started:false, sessionId:null` and nothing
      // else, which reads as "nothing happened" — that misreading is what put two
      // agents on one destructive ticket. Say plainly that it IS going to run.
      const where = reply.connected
        ? `The juancode app didn't ack the create within ${Math.round(timeoutMs / 1000)}s (${
            reply.reason
          }) — it may just be loaded.`
        : `The juancode app isn't reachable at ${nativeApiBase()} (${reply.reason}).`;
      return {
        dispatchId,
        state: "queued",
        started: false,
        queued: true,
        willStart: true,
        duplicateOf: null,
        sessionId: null,
        ticket,
        queuedReason: reply.connected ? "no-ack" : "unreachable",
        advice: `ACCEPTED, not yet started. Do NOT post this dispatch again — re-posting is what creates a second session. ${POLL_ADVICE}`,
        message:
          `${where} The dispatch is durably queued and starts by itself — exactly once, ` +
          `whether from the create that may still be in flight or from the mailbox (both carry ` +
          `dispatchId ${dispatchId}, and the app dedupes on it). Do not re-post it.`,
      };
    }
  }
}
