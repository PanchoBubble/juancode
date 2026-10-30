// Headless fallback providers for the Telegram Oracle chat (juancode-c8m).
// The Telegram bridge asks `claude -p` first (oracle.ts); when that turn is unusable
// it falls back to GPT (`codex exec`) and then Kimi (`kimi -p`). Each provider keeps
// its OWN conversation id per chat, because ids are not portable between CLIs.
//
// Like every juancode spawn, the CLIs run with the inherited environment untouched —
// no shadow HOME/CODEX_HOME/KIMI_CODE_HOME, no MCP overrides — so the user's own
// config, connectors and login apply. This module owns only the argument lists, the
// output parsing and the process capture; the ordering and persistence live in
// telegram-chat.ts. It deliberately imports nothing from oracle.ts (which imports it).

import { spawn } from "node:child_process";
import { accessSync, constants, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, join, resolve } from "node:path";

export type FallbackProvider = "codex" | "kimi";
export type ChatProvider = "claude" | FallbackProvider;

/** Order a Telegram turn tries providers in. */
export const CHAT_PROVIDER_ORDER: readonly ChatProvider[] = ["claude", "codex", "kimi"];

export const PROVIDER_LABEL: Record<ChatProvider, string> = {
  claude: "Claude",
  codex: "GPT (Codex)",
  kimi: "Kimi",
};

/** What one headless provider run produced. `sessionId` is the provider's own
 *  conversation id (null when it never reported one); `ok` is false for anything the
 *  caller must not show as the Oracle's answer. */
export interface ProviderRun {
  ok: boolean;
  reply: string;
  sessionId: string | null;
}

export interface CaptureResult {
  code: number;
  stdout: string;
  stderr: string;
  launchFailed: boolean;
}

/** Spawn `bin` and collect its output, killing it after `timeoutMs`. stdin is closed:
 *  a headless CLI that waits for input would otherwise hang until the timeout. */
export function captureProcess(
  bin: string,
  args: string[],
  opts: { cwd: string; env: NodeJS.ProcessEnv; timeoutMs: number },
): Promise<CaptureResult> {
  return new Promise((done) => {
    const child = spawn(bin, args, {
      cwd: opts.cwd,
      env: opts.env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => child.kill("SIGKILL"), opts.timeoutMs);
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", () => {
      clearTimeout(timer);
      done({ code: -1, stdout: "", stderr: `failed to launch ${bin}`, launchFailed: true });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      done({ code: code ?? -1, stdout, stderr, launchFailed: false });
    });
  });
}

function isExecutable(path: string): boolean {
  try {
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/** The binary to launch: the `JUANCODE_<NAME>_BIN` override, else `name` found on PATH
 *  or in the CLI's own install dir (the sidecar can start from a GUI login whose PATH
 *  lacks `~/.kimi-code/bin`), else the bare name so the spawn error says what is missing. */
export function resolveProviderBin(
  name: FallbackProvider,
  env: NodeJS.ProcessEnv = process.env,
  home = homedir(),
): string {
  const override = env[`JUANCODE_${name.toUpperCase()}_BIN`]?.trim();
  if (override) return override;
  const extra = name === "kimi" ? [join(home, ".kimi-code", "bin")] : [];
  const dirs = [...(env.PATH ?? "").split(delimiter), ...extra].filter(Boolean);
  for (const dir of dirs) {
    const candidate = join(dir, name);
    if (isExecutable(candidate)) return candidate;
  }
  return name;
}

/** The single prompt a fallback CLI gets. Neither CLI has `--append-system-prompt`, so
 *  the Oracle persona rides in the user turn, and a resumed conversation simply sees it
 *  again — harmless, and it keeps the persona if the provider's own config changed. */
export function fallbackPrompt(system: string, text: string): string {
  return `${system}\n\n---\nUser message (via Telegram):\n${text}`;
}

/** `codex exec` args. The prompt is last and always starts with the persona text, so it
 *  can never be parsed as a flag. Resume is `exec resume <id>`: `-C` is not accepted
 *  there, so the working directory is the spawn cwd for both paths. */
export function codexArgs(prompt: string, resume: string | null): string[] {
  const common = ["--json", "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox"];
  return resume ? ["exec", "resume", ...common, resume, prompt] : ["exec", ...common, prompt];
}

/** `kimi -p` args. Print mode uses its `auto` permission policy and rejects `--yolo` /
 *  `--auto`, so no permission flag is passed. `-S <id>` resumes. */
export function kimiArgs(prompt: string, resume: string | null): string[] {
  return [...(resume ? ["-S", resume] : []), "-p", prompt, "--output-format", "stream-json"];
}

function asRecord(v: unknown): Record<string, unknown> {
  return v && typeof v === "object" ? (v as Record<string, unknown>) : {};
}

function jsonLines(stdout: string): Record<string, unknown>[] {
  const out: Record<string, unknown>[] = [];
  for (const line of stdout.split(/\r?\n/)) {
    const t = line.trim();
    if (!t.startsWith("{")) continue;
    try {
      out.push(asRecord(JSON.parse(t)));
    } catch {
      /* a partial or non-JSON line is not an event */
    }
  }
  return out;
}

function firstLine(s: string, max = 300): string {
  const line =
    s
      .trim()
      .split(/\r?\n/)
      .find((l) => l.trim()) ?? "";
  return line.length > max ? `${line.slice(0, max - 1)}…` : line;
}

/** Fold `codex exec --json` events: `thread.started` carries the resumable id, each
 *  `item.completed` with an `agent_message` is assistant text (the last one is the
 *  answer), and `turn.failed` / `error` carry the failure. */
export function parseCodexRun(code: number, stdout: string, stderr: string): ProviderRun {
  let sessionId: string | null = null;
  let reply = "";
  let failure = "";
  for (const ev of jsonLines(stdout)) {
    if (ev.type === "thread.started" && typeof ev.thread_id === "string") sessionId = ev.thread_id;
    if (ev.type === "item.completed") {
      const item = asRecord(ev.item);
      if (item.type === "agent_message" && typeof item.text === "string" && item.text.trim()) {
        reply = item.text;
      }
    }
    if (ev.type === "turn.failed") {
      const msg = asRecord(ev.error).message;
      failure = typeof msg === "string" ? msg : "turn failed";
    }
    if (ev.type === "error" && !failure) {
      failure = typeof ev.message === "string" ? ev.message : "error";
    }
  }
  if (code !== 0 || failure || !reply.trim()) {
    return {
      ok: false,
      reply:
        failure ||
        firstLine(stderr) ||
        (code !== 0 ? `codex exited ${code}` : "codex returned no reply"),
      sessionId,
    };
  }
  return { ok: true, reply, sessionId };
}

/** Text of one kimi `stream-json` assistant message: a plain string `content`, or the
 *  `text` parts of a content array. Thinking/tool parts are not the answer. */
function kimiMessageText(msg: Record<string, unknown>): string {
  const content = msg.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map(asRecord)
    .filter((p) => p.type === "text" && typeof p.text === "string")
    .map((p) => p.text as string)
    .join("");
}

/** Fold kimi `stream-json` lines: the answer is the last assistant message that has
 *  text and no tool calls (earlier ones are progress notes between tool calls). The
 *  `role: "meta"` lines are version chatter. Kimi's stdout has no session id. */
export function parseKimiRun(code: number, stdout: string, stderr: string): ProviderRun {
  let reply = "";
  for (const ev of jsonLines(stdout)) {
    if (ev.role !== "assistant") continue;
    const calls = ev.tool_calls;
    if (Array.isArray(calls) && calls.length > 0) continue;
    const text = kimiMessageText(ev);
    if (text.trim()) reply = text;
  }
  if (code !== 0 || !reply.trim()) {
    const err = stderr
      .split(/\r?\n/)
      .map((l) => l.trim())
      .find((l) => l.startsWith("error:"));
    return {
      ok: false,
      reply:
        err?.replace(/^error:\s*/, "") ||
        firstLine(stderr) ||
        (code !== 0 ? `kimi exited ${code}` : "kimi returned no reply"),
      sessionId: null,
    };
  }
  return { ok: true, reply, sessionId: null };
}

/** Kimi records every conversation, including a failed one, as a line of
 *  `<KIMI_CODE_HOME or ~/.kimi-code>/session_index.jsonl` carrying its `workDir`. Its
 *  stdout never names the session, so the id of a fresh run is the new index line for
 *  our cwd. Returns the index lines as `{sessionId, workDir}` in file order. */
export function readKimiIndex(
  env: NodeJS.ProcessEnv = process.env,
  home = homedir(),
): { sessionId: string; workDir: string }[] {
  const dir = env.KIMI_CODE_HOME?.trim() || join(home, ".kimi-code");
  let raw = "";
  try {
    raw = readFileSync(join(dir, "session_index.jsonl"), "utf8");
  } catch {
    return [];
  }
  return jsonLines(raw).flatMap((r) =>
    typeof r.sessionId === "string" && typeof r.workDir === "string"
      ? [{ sessionId: r.sessionId, workDir: r.workDir }]
      : [],
  );
}

function realDir(p: string): string {
  try {
    return realpathSync(p);
  } catch {
    return resolve(p);
  }
}

/** The session kimi created for `cwd` since `before` was read, if any. The sidecar's
 *  control dir is its own, so a new entry for it is this run's. Dirs are compared by
 *  real path, since macOS reports `/tmp` dirs under `/private`. */
export function newKimiSession(
  before: { sessionId: string }[],
  after: { sessionId: string; workDir: string }[],
  cwd: string,
): string | null {
  const known = new Set(before.map((s) => s.sessionId));
  const want = realDir(cwd);
  const fresh = after.filter((s) => !known.has(s.sessionId) && realDir(s.workDir) === want);
  return fresh.length > 0 ? fresh[fresh.length - 1]!.sessionId : null;
}

const TIMEOUT_MS = 180_000;

/** One headless GPT turn through `codex exec`. */
export async function runCodex(
  prompt: string,
  resume: string | null,
  cwd: string,
  env: NodeJS.ProcessEnv = process.env,
): Promise<ProviderRun> {
  const r = await captureProcess(resolveProviderBin("codex", env), codexArgs(prompt, resume), {
    cwd,
    env,
    timeoutMs: TIMEOUT_MS,
  });
  return parseCodexRun(r.code, r.stdout, r.stderr);
}

/** One headless Kimi turn through `kimi -p`. A fresh run's session id is read back from
 *  kimi's index; a resumed run keeps the id it was given. */
export async function runKimi(
  prompt: string,
  resume: string | null,
  cwd: string,
  env: NodeJS.ProcessEnv = process.env,
): Promise<ProviderRun> {
  const before = resume ? [] : readKimiIndex(env);
  const r = await captureProcess(resolveProviderBin("kimi", env), kimiArgs(prompt, resume), {
    cwd,
    env,
    timeoutMs: TIMEOUT_MS,
  });
  const run = parseKimiRun(r.code, r.stdout, r.stderr);
  const sessionId = resume ?? newKimiSession(before, readKimiIndex(env), cwd);
  return { ...run, sessionId };
}
