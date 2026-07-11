// Oracle control-surface operations, shared by the MCP tools. Everything the
// Oracle exposes is local to the Mac: its `bd` tracker, the append-only ask
// mailbox, and the live session list (served by the native app's embedded HTTP
// API). This module wraps those surfaces; `index.ts` maps them to MCP tools.
// Dispatch lives in dispatch.ts (WS-first with the mailbox as offline fallback).
// Keep the ask JSON line shape in lockstep with the Swift `OracleAsk` struct in
// apps/native — the native app tails the file and decodes it.

import { spawn } from "node:child_process";
import { appendFile, readFile, rm } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { WebSocket } from "ws";
import { touchChatSession, upsertChatSession } from "./chat-store.ts";

/** `~/.juancode/oracle` (the Oracle control dir), overridable to match the Swift
 *  `JUANCODE_ORACLE_DIR` so both sides point at the same tree in tests. */
export function oracleDir(): string {
  const o = process.env.JUANCODE_ORACLE_DIR;
  return o && o.length > 0 ? o : join(homedir(), ".juancode", "oracle");
}

const askFile = () => join(oracleDir(), "ask.jsonl");
/** Persists the headless chat's claude session id so the phone conversation keeps
 *  context across requests (and sidecar restarts). */
const chatSessionFile = () => join(oracleDir(), "phone-chat-session.txt");

/** Base URL of the native app's embedded HTTP server (the live session source of
 *  truth). Mirrors the Swift `JUANCODE_HOST`/`JUANCODE_PORT` defaults. */
export function nativeApiBase(): string {
  if (process.env.JUANCODE_API) return process.env.JUANCODE_API.replace(/\/$/, "");
  const port = process.env.JUANCODE_PORT || "4280";
  return `http://127.0.0.1:${port}`;
}

/** Single-quote a string for safe embedding in an `sh -c` command. */
function shellQuote(s: string): string {
  return "'" + s.replaceAll("'", "'\\''") + "'";
}

export interface BdResult {
  code: number;
  stdout: string;
  stderr: string;
}

/**
 * Run `bd` in the Oracle control dir, capturing stdout/stderr via temp files.
 *
 * `bd init`/writes cold-start a persistent `dolt sql-server` daemon that inherits
 * the child's stdout/stderr fds; if those were our pipes the daemon would hold
 * them open and our read would never see EOF (it would hang until timeout). So we
 * redirect to temp files — the daemon inherits harmless file fds — and read the
 * files once `bd` exits. This mirrors the `sh -c '… >/dev/null </dev/null'` guard
 * the Swift side uses for `bd init`.
 */
function runBdRaw(args: string[]): Promise<BdResult> {
  const bd = process.env.JUANCODE_BD_BIN || "bd";
  const out = join(tmpdir(), `oracle-bd-${randomUUID()}.out`);
  const err = join(tmpdir(), `oracle-bd-${randomUUID()}.err`);
  const cmd =
    [bd, ...args].map(shellQuote).join(" ") +
    ` >${shellQuote(out)} 2>${shellQuote(err)} </dev/null`;

  return new Promise<BdResult>((resolve) => {
    const child = spawn("sh", ["-c", cmd], { cwd: oracleDir() });
    child.on("error", () => resolve({ code: -1, stdout: "", stderr: "failed to launch bd" }));
    child.on("close", async (code) => {
      const [stdout, stderr] = await Promise.all([
        readFile(out, "utf8").catch(() => ""),
        readFile(err, "utf8").catch(() => ""),
      ]);
      await Promise.all([rm(out, { force: true }), rm(err, { force: true })]);
      resolve({ code: code ?? -1, stdout, stderr });
    });
  });
}

/** Parse `bd … --json` stdout, tolerating empty output (→ null). */
function parseBdJson(stdout: string): unknown {
  const trimmed = stdout.trim();
  if (!trimmed) return null;
  return JSON.parse(trimmed);
}

export interface OracleIssue {
  id: string;
  title: string;
  status: string;
  priority: number;
  issueType: string;
  parent: string | null;
  ready: boolean;
}

function asRecord(v: unknown): Record<string, unknown> {
  return v && typeof v === "object" ? (v as Record<string, unknown>) : {};
}

/** List the Oracle's global tracker items, flagging which are ready (unblocked).
 *  Read-only (`--sandbox`), so it never cold-starts the dolt daemon. */
export async function listIssues(): Promise<OracleIssue[]> {
  const listed = await runBdRaw(["--sandbox", "list", "--json"]);
  if (listed.code !== 0) {
    throw new Error(listed.stderr.trim() || `bd list exited ${listed.code}`);
  }
  const rows = parseBdJson(listed.stdout);
  if (!Array.isArray(rows)) return [];

  // ready overlay — best-effort; a failure just leaves every flag false.
  const readyRes = await runBdRaw(["--sandbox", "ready", "--limit", "1000", "--json"]);
  const readyRaw = readyRes.code === 0 ? parseBdJson(readyRes.stdout) : null;
  const readyIds = new Set<string>(
    Array.isArray(readyRaw) ? readyRaw.map((r) => String(asRecord(r).id ?? "")) : [],
  );

  return rows
    .map(asRecord)
    .filter((r) => typeof r.id === "string" && r.id.length > 0)
    .map((r) => {
      const id = String(r.id);
      return {
        id,
        title: typeof r.title === "string" ? r.title : "",
        status: typeof r.status === "string" ? r.status : "open",
        priority: typeof r.priority === "number" ? r.priority : 2,
        issueType: typeof r.issue_type === "string" ? r.issue_type : "task",
        parent: typeof r.parent === "string" ? r.parent : null,
        ready: readyIds.has(id),
      };
    });
}

/** Create a global tracker item. A write, so no `--sandbox` (it would block the
 *  write/sync); the temp-file capture in `runBdRaw` keeps the dolt daemon from
 *  stalling us. Returns the new issue id when bd reports one. */
export async function createIssue(opts: {
  title: string;
  description?: string;
  type?: string;
  priority?: number;
}): Promise<{ id: string | null; raw: unknown }> {
  const args = ["create", opts.title];
  if (opts.description) args.push(`--description=${opts.description}`);
  args.push("-t", opts.type ?? "task");
  args.push("-p", String(opts.priority ?? 2));
  args.push("--json");

  const res = await runBdRaw(args);
  if (res.code !== 0) {
    throw new Error(res.stderr.trim() || `bd create exited ${res.code}`);
  }
  const raw = parseBdJson(res.stdout);
  const rec = asRecord(Array.isArray(raw) ? raw[0] : raw);
  const id = typeof rec.id === "string" ? rec.id : null;
  return { id, raw };
}

/** Append one ask line for the native app to tail and deliver to the live Oracle
 *  session. Shape MUST match Swift `OracleAsk`. */
export async function appendAsk(text: string): Promise<void> {
  await appendFile(askFile(), JSON.stringify({ text }) + "\n", "utf8");
}

/** Fetch the live + persisted session list from the native app's embedded server.
 *  Throws a clear error when the app isn't running (the pty host must be up). */
export async function listSessions(): Promise<unknown> {
  const url = `${nativeApiBase()}/api/sessions`;
  let res: Response;
  try {
    res = await fetch(url);
  } catch {
    throw new Error(
      `Couldn't reach the juancode app at ${nativeApiBase()} — is the native app running on the Mac?`,
    );
  }
  if (!res.ok) throw new Error(`GET /api/sessions returned ${res.status}`);
  return res.json();
}

/** Permanently delete a session via the native app's embedded server: it kills the
 *  pty, drops the row from sqlite, and removes any auto-created worktree (best-effort).
 *  Throws a clear error when the app isn't running. */
export async function deleteSession(id: string): Promise<void> {
  const url = `${nativeApiBase()}/api/sessions/${encodeURIComponent(id)}`;
  let res: Response;
  try {
    res = await fetch(url, { method: "DELETE" });
  } catch {
    throw new Error(
      `Couldn't reach the juancode app at ${nativeApiBase()} — is the native app running on the Mac?`,
    );
  }
  if (res.status === 404) throw new Error(`Session ${id} not found`);
  if (!res.ok) throw new Error(`DELETE /api/sessions/${id} returned ${res.status}`);
}

/** The native server's WebSocket URL, derived from the same base as the HTTP API. */
export function nativeWsUrl(): string {
  return nativeApiBase().replace(/^http/, "ws") + "/ws";
}

/**
 * Deliver a typed reply into a live session's pty from the phone. The native
 * server's `input` message writes straight to the pty by sessionId (no attach
 * needed), so we open a short-lived WS, bracketed-paste the text so the CLI's TUI
 * treats it as one paste, pause, then send CR to submit — mirroring apps/server's
 * `Session.respond`. Throws a clear error if the native app isn't reachable.
 */
export async function deliverReply(sessionId: string, text: string): Promise<void> {
  const url = nativeWsUrl();
  await new Promise<void>((resolve, reject) => {
    const sock = new WebSocket(url);
    const fail = (e: unknown) => {
      try {
        sock.close();
      } catch {
        /* already closing */
      }
      reject(
        e instanceof Error
          ? e
          : new Error(`Couldn't reach the juancode app at ${nativeApiBase()} — is it running?`),
      );
    };
    const timer = setTimeout(() => fail(new Error("timed out reaching the native app")), 5000);
    sock.on("error", (e) => {
      clearTimeout(timer);
      fail(e);
    });
    sock.on("open", () => {
      try {
        sock.send(JSON.stringify({ type: "input", sessionId, data: `\x1b[200~${text}\x1b[201~` }));
        // Give the TUI a beat to ingest the paste before the submitting CR, then a
        // tick to flush before closing.
        setTimeout(() => {
          sock.send(JSON.stringify({ type: "input", sessionId, data: "\r" }));
          setTimeout(() => {
            clearTimeout(timer);
            try {
              sock.close();
            } catch {
              /* already closing */
            }
            resolve();
          }, 80);
        }, 80);
      } catch (e) {
        clearTimeout(timer);
        fail(e);
      }
    });
  });
}

/**
 * Queue one or more messages to a live session for in-order delivery on its next
 * idle (juancode-r82). Unlike {@link deliverReply} — which types straight into the
 * pty right now — this hands the text to the native server's persisted per-session
 * queue (`queueMessage`), which flushes one message at a time on each idle edge, so
 * the agent receives them in order even while it's still busy. The native server
 * owns the ordering / idle logic; we just enqueue. Messages are queued in the order
 * given. Throws a clear error if the native app isn't reachable.
 */
export async function queueMessages(sessionId: string, texts: string[]): Promise<void> {
  const items = texts.map((t) => t.trim()).filter((t) => t.length > 0);
  if (items.length === 0) return;
  const url = nativeWsUrl();
  await new Promise<void>((resolve, reject) => {
    const sock = new WebSocket(url);
    const fail = (e: unknown) => {
      try {
        sock.close();
      } catch {
        /* already closing */
      }
      reject(
        e instanceof Error
          ? e
          : new Error(`Couldn't reach the juancode app at ${nativeApiBase()} — is it running?`),
      );
    };
    const timer = setTimeout(() => fail(new Error("timed out reaching the native app")), 5000);
    sock.on("error", (e) => {
      clearTimeout(timer);
      fail(e);
    });
    sock.on("open", () => {
      try {
        // Send each queueMessage in order; the native queue preserves insertion
        // order (rowid), so delivery order matches. A short tick lets the writes
        // flush before we close.
        for (const text of items) {
          sock.send(JSON.stringify({ type: "queueMessage", sessionId, text }));
        }
        setTimeout(() => {
          clearTimeout(timer);
          try {
            sock.close();
          } catch {
            /* already closing */
          }
          resolve();
        }, 80);
      } catch (e) {
        clearTimeout(timer);
        fail(e);
      }
    });
  });
}

export interface ChatReply {
  reply: string;
  isError: boolean;
  sessionId: string | null;
}

/** Where a chat turn came from, when the caller knows. A Telegram origin is
 *  threaded into the Oracle's system prompt so dispatches it makes during the
 *  turn carry the chat id — the lifecycle back-channel's correlation. */
export interface ChatOrigin {
  telegramChatId?: number;
}

/** Run one headless Oracle turn: `claude -p` in the control dir, returning clean
 *  text (no TUI) suitable for the phone console. We strip `ANTHROPIC_API_KEY` from
 *  the subprocess env so claude uses the user's claude.ai subscription + connectors
 *  — matching the GUI Oracle (the key is only present in interactive shells via
 *  ~/.zshrc, never in the GUI app's login env). Continuity comes from `--resume`
 *  with `sessionId`; if that id is stale we retry once fresh. The resulting session is
 *  recorded in the chat-session store so the console can list + continue it later. */
export async function oracleChat(
  text: string,
  sessionId?: string | null,
  origin?: ChatOrigin,
): Promise<ChatReply> {
  const resume = sessionId && sessionId.length > 0 ? sessionId : null;
  const extraSystem = originSystemPrompt(origin);
  let result = await runClaude(text, resume, extraSystem);
  // A stale/unknown resume id makes claude exit with "No conversation found" — start
  // a fresh conversation rather than surfacing that as the Oracle's answer.
  if (result.processError && resume) result = await runClaude(text, null, extraSystem);
  const reply = result.reply;
  await persistChatSession(resume, text, reply.sessionId);
  return reply;
}

/** The per-turn system-prompt addendum for a known origin; "" when there is none.
 *  Exported for unit testing — this is the contract that makes Telegram-originated
 *  dispatches carry their chat id. */
export function originSystemPrompt(origin?: ChatOrigin): string {
  if (origin?.telegramChatId == null) return "";
  return (
    `This request came from Telegram chat ${origin.telegramChatId}. ` +
    `When you dispatch via POST /api/dispatch during this turn, include ` +
    `"telegramChatId": ${origin.telegramChatId} in the JSON body so the dispatched ` +
    `agent's lifecycle pings (needs input / finished) route back to this chat.`
  );
}

/** Record a finished turn's session so the console can list + continue it. Continuing
 *  the same id just bumps its timestamp; anything else (a new chat, or a fresh id after
 *  a stale resume) is recorded with a title derived from the prompt. Shared by the
 *  blocking (`oracleChat`) and streaming (`oracleChatStream`) paths. */
async function persistChatSession(
  resume: string | null,
  text: string,
  sessionId: string | null,
): Promise<void> {
  if (!sessionId) return;
  if (resume && sessionId === resume) await touchChatSession(sessionId);
  else await upsertChatSession(sessionId, deriveTitle(text));
}

/** A short, single-line label for a chat session, from its opening prompt. */
function deriveTitle(text: string): string {
  const firstLine = text.trim().split(/\r?\n/, 1)[0]?.trim() ?? "";
  if (!firstLine) return "New chat";
  return firstLine.length > 50 ? firstLine.slice(0, 49).trimEnd() + "…" : firstLine;
}

/** Injected so the headless turn embodies Oracle (claude's default system prompt
 *  otherwise dominates and it answers as generic Claude Code). Mirrors the role the
 *  GUI Oracle gets from its seed prompt + AGENTS.md, plus phone-screen brevity. */
const ORACLE_SYSTEM =
  "You are Oracle, the global orchestrator for this machine (see ./AGENTS.md). " +
  "Operate at the GLOBAL level across every project: manage the global bd tracker " +
  "(prefix oracle-), read ./state.json to see running sessions, and dispatch agents " +
  "into projects through the sidecar: " +
  "`curl -sS -X POST http://127.0.0.1:4281/api/dispatch -H 'content-type: application/json' " +
  '-d \'{"project":"<abs path>","prompt":"<instruction>"}\'` (optional fields: ' +
  '"provider":"codex", "worktree":true, and "telegramChatId":<id> when told the ' +
  "request came from a Telegram chat). The reply carries the real outcome — dispatchId " +
  "plus sessionId, queued, or the actual error — so report it instead of assuming success. " +
  "DISPATCH BY DEFAULT: you are an orchestrator, not a worker. Any task that touches " +
  "a project's code, files, tests, or git you dispatch to an agent in that project — " +
  "never read, edit, or run a project's contents yourself, even if it seems quick. " +
  "Only act inline when the request is purely global, or no project in state.json " +
  "matches (then say so and ask for the path). When unsure, assume it's project work " +
  "and dispatch. " +
  "DISPATCH STATUS: to answer 'what happened to my dispatch / that agent', check " +
  "`curl -sS http://127.0.0.1:4281/api/dispatches` — recent dispatches with their " +
  "durable outcomes and current session state (remote MCP clients have the same data " +
  "as the oracle_dispatch_status tool). Summarize conversationally: started/queued/" +
  "failed, and whether the session is still running. " +
  "OBSERVE: when the user asks you to 'observe', 'watch', or 'keep me posted on' a " +
  "session, subscribe them to its Telegram alerts by POSTing its id to the sidecar: " +
  "`curl -sS -X POST http://127.0.0.1:4281/api/observe -H 'content-type: application/json' " +
  '-d \'{"sessionId":"<id>"}\'` (and /api/unobserve to stop). They\'ll then be pinged on ' +
  "Telegram only when that session needs input or finishes. Dispatches that carried a " +
  "telegramChatId notify their originating chat automatically — no observe needed. " +
  "You are talking to the user on a phone — keep replies short and skimmable.";

async function runClaude(
  text: string,
  resume: string | null,
  extraSystem = "",
): Promise<{ reply: ChatReply; processError: boolean }> {
  const claude = process.env.JUANCODE_CLAUDE_BIN || "claude";
  const args = [
    "-p",
    text,
    "--output-format",
    "json",
    "--dangerously-skip-permissions",
    "--append-system-prompt",
    extraSystem ? `${ORACLE_SYSTEM}\n${extraSystem}` : ORACLE_SYSTEM,
  ];
  if (resume) args.push("--resume", resume);

  const env = { ...process.env };
  delete env.ANTHROPIC_API_KEY;

  const { code, stdout, stderr } = await new Promise<{
    code: number;
    stdout: string;
    stderr: string;
  }>((resolve) => {
    const child = spawn(claude, args, { cwd: oracleDir(), env, stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    let err = "";
    const timer = setTimeout(() => child.kill("SIGKILL"), 180_000);
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("error", () => {
      clearTimeout(timer);
      resolve({ code: -1, stdout: "", stderr: "failed to launch claude" });
    });
    child.on("close", (c) => {
      clearTimeout(timer);
      resolve({ code: c ?? -1, stdout: out, stderr: err });
    });
  });

  if (code !== 0 || !stdout.trim()) {
    return {
      reply: { reply: stderr.trim() || `claude exited ${code}`, isError: true, sessionId: null },
      processError: true,
    };
  }

  let parsed: Record<string, unknown>;
  try {
    parsed = asRecord(JSON.parse(stdout.trim()));
  } catch {
    return { reply: { reply: stdout.trim(), isError: true, sessionId: null }, processError: false };
  }

  const sessionId = typeof parsed.session_id === "string" ? parsed.session_id : null;
  const result = typeof parsed.result === "string" ? parsed.result : "";
  return {
    reply: { reply: result, isError: parsed.is_error === true, sessionId },
    processError: false,
  };
}

// ── Streaming chat (live SSE) ────────────────────────────────────────────────
// The phone console upgrades the chat into a live stream: instead of blocking on a
// single `claude -p --output-format json` call (up to 180s with only a typing dot),
// it consumes `--output-format stream-json` and renders the Oracle's reply as it is
// produced. `oracleChatStream` runs the turn and invokes `onDelta` for each chunk of
// assistant text; the HTTP layer (index.ts) relays those over Server-Sent Events.

/** Pull the text out of a `content_block_delta` partial event (token-level streaming
 *  from `--include-partial-messages`); "" for any other event. */
function partialDeltaText(event: unknown): string {
  const e = asRecord(event);
  if (e.type !== "content_block_delta") return "";
  const delta = asRecord(e.delta);
  return delta.type === "text_delta" && typeof delta.text === "string" ? delta.text : "";
}

/** Concatenate the text blocks of a whole `assistant` message (used when a run emits
 *  no token-level partials), ignoring tool-use / thinking blocks. */
function assistantMessageText(message: unknown): string {
  const content = asRecord(message).content;
  if (!Array.isArray(content)) return "";
  return content
    .map(asRecord)
    .filter((b) => b.type === "text" && typeof b.text === "string")
    .map((b) => b.text as string)
    .join("");
}

/**
 * Stateful reducer over claude's `--output-format stream-json` NDJSON. Each line is
 * one of:
 *   - {type:"system",subtype:"init",session_id}                     → carries the id
 *   - {type:"stream_event",event:{type:"content_block_delta",delta:{type:"text_delta",text}}}
 *                                                                    → token partials
 *   - {type:"assistant",message:{content:[{type:"text",text}]},session_id}
 *                                                                    → a whole message
 *   - {type:"result",subtype,result,is_error,session_id}            → final summary
 * We prefer token partials; if a run produces none we fall back to whole assistant
 * messages; if neither yields text the final `result` is surfaced via `fallbackText`.
 * Exported for unit testing — the parsing contract is the fragile part.
 */
export class ChatStreamReducer {
  sessionId: string | null = null;
  isError = false;
  done = false;
  /** The final `result` text — only emitted when nothing streamed (see fallbackText). */
  private finalText = "";
  private sawPartial = false;
  private emittedText = false;

  /** Feed one parsed NDJSON object; returns assistant text to append (already deduped). */
  push(obj: Record<string, unknown>): string[] {
    const sid = obj.session_id;
    if (typeof sid === "string" && sid) this.sessionId = sid;

    switch (obj.type) {
      case "stream_event": {
        const text = partialDeltaText(obj.event);
        if (!text) return [];
        this.sawPartial = true;
        this.emittedText = true;
        return [text];
      }
      case "assistant": {
        if (this.sawPartial) return []; // already streamed this turn token-by-token
        const text = assistantMessageText(obj.message);
        if (!text) return [];
        this.emittedText = true;
        return [text];
      }
      case "result": {
        this.done = true;
        if (obj.is_error === true) this.isError = true;
        if (typeof obj.result === "string") this.finalText = obj.result;
        return [];
      }
      default:
        return [];
    }
  }

  /** Text to emit after the stream ends if nothing streamed live; "" otherwise. */
  fallbackText(): string {
    return this.emittedText ? "" : this.finalText;
  }
}

interface StreamRunResult {
  sessionId: string | null;
  isError: boolean;
  emittedAny: boolean;
  /** The process failed to produce a usable turn (non-zero exit, nothing emitted). */
  processError: boolean;
  errorText: string;
}

/** Spawn one `claude -p --output-format stream-json` turn, invoking `onDelta` for each
 *  chunk of assistant text as it arrives. Mirrors `runClaude`'s env handling (strips
 *  ANTHROPIC_API_KEY so claude uses the claude.ai subscription). `signal` aborts the
 *  child if the client disconnects. */
async function runClaudeStream(
  text: string,
  resume: string | null,
  onDelta: (text: string) => void,
  signal?: AbortSignal,
): Promise<StreamRunResult> {
  const claude = process.env.JUANCODE_CLAUDE_BIN || "claude";
  const args = [
    "-p",
    text,
    "--output-format",
    "stream-json",
    "--verbose", // required by claude for stream-json under -p
    "--include-partial-messages", // token-level deltas, not just whole messages
    "--dangerously-skip-permissions",
    "--append-system-prompt",
    ORACLE_SYSTEM,
  ];
  if (resume) args.push("--resume", resume);

  const env = { ...process.env };
  delete env.ANTHROPIC_API_KEY;

  const reducer = new ChatStreamReducer();
  let emittedAny = false;
  let stderr = "";

  const code = await new Promise<number>((resolve) => {
    const child = spawn(claude, args, { cwd: oracleDir(), env, stdio: ["ignore", "pipe", "pipe"] });
    const timer = setTimeout(() => child.kill("SIGKILL"), 180_000);
    const onAbort = () => child.kill("SIGKILL");
    if (signal) {
      if (signal.aborted) onAbort();
      else signal.addEventListener("abort", onAbort, { once: true });
    }
    let buf = "";
    child.stdout.on("data", (d: Buffer) => {
      buf += d.toString();
      let nl: number;
      // Line-buffer the NDJSON stream; a chunk can split mid-line.
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (!line) continue;
        let obj: unknown;
        try {
          obj = JSON.parse(line);
        } catch {
          continue; // ignore any non-JSON noise on stdout
        }
        for (const piece of reducer.push(asRecord(obj))) {
          emittedAny = true;
          onDelta(piece);
        }
      }
    });
    child.stderr.on("data", (d) => (stderr += d));
    const finish = (c: number) => {
      clearTimeout(timer);
      if (signal) signal.removeEventListener("abort", onAbort);
      resolve(c);
    };
    child.on("error", () => finish(-1));
    child.on("close", (c) => finish(c ?? -1));
  });

  // If the turn produced no streamed text, fall back to the final `result` body.
  const fallback = reducer.fallbackText();
  if (fallback) {
    emittedAny = true;
    onDelta(fallback);
  }

  return {
    sessionId: reducer.sessionId,
    isError: reducer.isError || code !== 0,
    emittedAny,
    processError: code !== 0 && !emittedAny,
    errorText: stderr.trim() || `claude exited ${code}`,
  };
}

export interface ChatStreamDone {
  sessionId: string | null;
  isError: boolean;
}

/** Run one streaming Oracle turn. Calls `onDelta` for each chunk of reply text, then
 *  resolves once the turn is done. A stale `--resume` id (nothing streamed, non-zero
 *  exit) is retried once as a fresh conversation, matching `oracleChat`. The finished
 *  session is persisted so the console can list + continue it. */
export async function oracleChatStream(
  text: string,
  sessionId: string | null | undefined,
  onDelta: (text: string) => void,
  signal?: AbortSignal,
): Promise<ChatStreamDone> {
  const resume = sessionId && sessionId.length > 0 ? sessionId : null;
  let res = await runClaudeStream(text, resume, onDelta, signal);
  // Stale/unknown resume id → claude exits non-zero with nothing streamed; retry fresh
  // (but only when nothing was shown, so we never double up a visible reply).
  if (res.processError && resume && !res.emittedAny && !signal?.aborted) {
    res = await runClaudeStream(text, null, onDelta, signal);
  }
  if (res.processError && !res.emittedAny) {
    // Nothing usable came back — surface the failure as the reply body.
    onDelta(res.errorText);
    return { sessionId: res.sessionId, isError: true };
  }
  await persistChatSession(resume, text, res.sessionId);
  return { sessionId: res.sessionId, isError: res.isError };
}

/** Reset the phone chat conversation (next `oracleChat` starts fresh). */
export async function resetChat(): Promise<void> {
  await rm(chatSessionFile(), { force: true });
}
