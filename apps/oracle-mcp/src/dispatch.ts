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
// Keep the mailbox line shape in lockstep with the Swift `OracleDispatch` struct
// in apps/native — the app tails the file and decodes each line.

import { appendFile } from "node:fs/promises";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { WebSocket } from "ws";
import { nativeApiBase, nativeWsUrl, oracleDir } from "./oracle.ts";
import { markQueuedDispatch } from "./dispatch-results.ts";
import { recordDispatch } from "./dispatch-registry.ts";

export interface DispatchRequest {
  /** Absolute path of the target project / work dir. */
  project: string;
  /** The seed instruction sent to the agent once its TUI is up. */
  prompt: string;
  provider?: "claude" | "codex";
  /** Isolate the agent in a fresh git worktree off `project`. */
  worktree?: boolean;
  /** The Telegram chat the dispatch originated from, when it did. Recorded in the
   *  dispatch registry so lifecycle events (needs input / finished) route back to
   *  that chat; never sent to the native app. */
  telegramChatId?: number | null;
}

export interface DispatchOutcome {
  dispatchId: string;
  /** The native app acked the create — the session is really running. */
  started: boolean;
  /** The app was unreachable; the dispatch is queued in the mailbox. */
  queued: boolean;
  sessionId: string | null;
  /** Human-readable summary for the MCP tool / console / Telegram. */
  message: string;
}

const dispatchFile = () => join(oracleDir(), "dispatch.jsonl");

/** How long to wait for the native server's create ack. Worktree isolation runs
 *  `git worktree add` before the ack, so this is generous. */
const CREATE_ACK_TIMEOUT_MS = 15_000;

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
  /** No server / no ack — fall back to the durable mailbox. */
  | { kind: "unreachable"; reason: string };

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
      resolve({ kind: "unreachable", reason: e instanceof Error ? e.message : String(e) });
      return;
    }
    let settled = false;
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
      () => settle({ kind: "unreachable", reason: "timed out waiting for the app's create ack" }),
      timeoutMs,
    );
    sock.on("error", (e) =>
      settle({ kind: "unreachable", reason: e instanceof Error ? e.message : String(e) }),
    );
    sock.on("close", () =>
      settle({ kind: "unreachable", reason: "connection closed before the create ack" }),
    );
    sock.on("open", () => {
      sock.send(
        JSON.stringify({
          type: "create",
          provider: opts.provider ?? "claude",
          cwd: opts.project,
          // A nominal boot grid; the desktop viewer claims ownership and resizes
          // on attach, same as any remotely created session.
          cols: 120,
          rows: 40,
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

/**
 * Dispatch an agent into a project: WS `create` with ack when the native app is up
 * (real success with sessionId / real error), mailbox fallback when it isn't
 * ("queued — starts when the app is next up"). Throws on a genuine server-side
 * rejection so MCP/HTTP callers surface it verbatim.
 */
export async function dispatch(
  opts: DispatchRequest,
  timeoutMs = CREATE_ACK_TIMEOUT_MS,
): Promise<DispatchOutcome> {
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
      outcome,
      sessionId,
      error,
      at: Date.now(),
    }).catch((e) =>
      console.warn("dispatch registry write failed:", e instanceof Error ? e.message : e),
    );
  switch (reply.kind) {
    case "created":
      await record("started", reply.sessionId, null);
      return {
        dispatchId,
        started: true,
        queued: false,
        sessionId: reply.sessionId,
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
      return {
        dispatchId,
        started: false,
        queued: true,
        sessionId: null,
        message:
          `The juancode app isn't reachable at ${nativeApiBase()} (${reply.reason}) — ` +
          `dispatch queued; it will start when the app is next up.`,
      };
    }
  }
}
