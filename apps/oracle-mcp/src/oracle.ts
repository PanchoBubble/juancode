// Oracle control-surface operations, shared by the MCP tools. Everything the
// Oracle exposes is local to the Mac: its `bd` tracker, the append-only dispatch
// and ask mailboxes, and the live session list (served by the native app's
// embedded HTTP API). This module wraps those four surfaces; `index.ts` maps them
// to MCP tools. Keep the dispatch/ask JSON line shapes in lockstep with the Swift
// `OracleDispatch` / `OracleAsk` structs in apps/native — the native app tails
// these files and decodes them.

import { spawn } from "node:child_process";
import { appendFile, readFile, rm, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

/** `~/.juancode/oracle` (the Oracle control dir), overridable to match the Swift
 *  `JUANCODE_ORACLE_DIR` so both sides point at the same tree in tests. */
export function oracleDir(): string {
  const o = process.env.JUANCODE_ORACLE_DIR;
  return o && o.length > 0 ? o : join(homedir(), ".juancode", "oracle");
}

const dispatchFile = () => join(oracleDir(), "dispatch.jsonl");
const askFile = () => join(oracleDir(), "ask.jsonl");
/** Persists the headless chat's claude session id so the phone conversation keeps
 *  context across requests (and sidecar restarts). */
const chatSessionFile = () => join(oracleDir(), "phone-chat-session.txt");

/** Base URL of the native app's embedded HTTP server (the live session source of
 *  truth). Mirrors the Swift `JUANCODE_HOST`/`JUANCODE_PORT` defaults. */
function nativeApiBase(): string {
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

/** Append one dispatch line for the native app to tail and spawn an agent from.
 *  Shape MUST match Swift `OracleDispatch`. */
export async function appendDispatch(opts: {
  project: string;
  prompt: string;
  provider?: "claude" | "codex";
  worktree?: boolean;
}): Promise<void> {
  const line =
    JSON.stringify({
      project: opts.project,
      prompt: opts.prompt,
      provider: opts.provider ?? "claude",
      worktree: opts.worktree ?? false,
    }) + "\n";
  await appendFile(dispatchFile(), line, "utf8");
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

export interface ChatReply {
  reply: string;
  isError: boolean;
  sessionId: string | null;
}

/** Run one headless Oracle turn: `claude -p` in the control dir, returning clean
 *  text (no TUI) suitable for the phone console. We strip `ANTHROPIC_API_KEY` from
 *  the subprocess env so claude uses the user's claude.ai subscription + connectors
 *  — matching the GUI Oracle (the key is only present in interactive shells via
 *  ~/.zshrc, never in the GUI app's login env). Continuity comes from `--resume`
 *  with the persisted session id; if that id is stale we retry once fresh. */
export async function oracleChat(text: string): Promise<ChatReply> {
  const prev = (await readFile(chatSessionFile(), "utf8").catch(() => "")).trim();
  const first = await runClaude(text, prev || null);
  // A stale/unknown resume id makes claude exit with "No conversation found" — start
  // a fresh conversation rather than surfacing that as the Oracle's answer.
  if (first.processError && prev) return (await runClaude(text, null)).reply;
  return first.reply;
}

/** Injected so the headless turn embodies Oracle (claude's default system prompt
 *  otherwise dominates and it answers as generic Claude Code). Mirrors the role the
 *  GUI Oracle gets from its seed prompt + AGENTS.md, plus phone-screen brevity. */
const ORACLE_SYSTEM =
  "You are Oracle, the global orchestrator for this machine (see ./AGENTS.md). " +
  "Operate at the GLOBAL level across every project: manage the global bd tracker " +
  "(prefix oracle-), read ./state.json to see running sessions, and dispatch agents " +
  "into projects by appending one JSON line to ./dispatch.jsonl. You are talking to " +
  "the user on a phone — keep replies short and skimmable.";

async function runClaude(
  text: string,
  resume: string | null,
): Promise<{ reply: ChatReply; processError: boolean }> {
  const claude = process.env.JUANCODE_CLAUDE_BIN || "claude";
  const args = [
    "-p",
    text,
    "--output-format",
    "json",
    "--dangerously-skip-permissions",
    "--append-system-prompt",
    ORACLE_SYSTEM,
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
  if (sessionId) await writeFile(chatSessionFile(), sessionId, "utf8").catch(() => {});
  const result = typeof parsed.result === "string" ? parsed.result : "";
  return {
    reply: { reply: result, isError: parsed.is_error === true, sessionId },
    processError: false,
  };
}

/** Reset the phone chat conversation (next `oracleChat` starts fresh). */
export async function resetChat(): Promise<void> {
  await rm(chatSessionFile(), { force: true });
}
