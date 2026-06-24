import { spawn } from "node:child_process";
import { PROVIDERS } from "./providers.ts";
import type { DiffFile } from "./protocol.ts";

/**
 * Draft a commit message for a working-tree diff by running the genuine `claude`
 * CLI in headless print mode — same fidelity as 'Review with Claude' (real env,
 * no shadow HOME, nothing overridden). Plain-text output, no JSON schema: the
 * model's reply *is* the message.
 */

const MAX_PROMPT_BYTES = 100_000;
const TIMEOUT_MS = 120_000;
const MAX_BUFFER = 8 * 1024 * 1024;

const SYSTEM_PROMPT =
  "You write a single git commit message for the given working-tree diff. " +
  "Use Conventional Commits style for the subject (e.g. 'feat: …', 'fix: …'), " +
  "imperative mood, ideally under 72 characters. Add a short body (blank line, then " +
  "concise bullet points) only when it genuinely clarifies the change. " +
  "Respond with ONLY the raw commit message — no code fences, no surrounding quotes, no preamble.";

/** Compact the diff into a prompt, capping size so a huge change set is bounded. */
function buildDiffPrompt(files: DiffFile[]): string {
  const parts: string[] = ["Write a commit message for these changes.\n"];
  for (const f of files) {
    const header = f.oldPath ? `${f.oldPath} → ${f.path}` : f.path;
    parts.push(`### ${header} (${f.status}, +${f.additions} −${f.deletions})`);
    if (f.binary) parts.push("(binary file)");
    else if (f.truncated) parts.push("(diff too large — omitted)");
    else if (f.diff) parts.push("```diff\n" + f.diff + "\n```");
    parts.push("");
  }
  let prompt = parts.join("\n");
  if (prompt.length > MAX_PROMPT_BYTES) {
    prompt = prompt.slice(0, MAX_PROMPT_BYTES) + "\n\n[diff truncated for length]";
  }
  return prompt;
}

/** Strip any code fences / wrapping quotes the model may add around the message. */
function cleanMessage(raw: string): string {
  return raw
    .trim()
    .replace(/^```[a-zA-Z]*\n?/, "")
    .replace(/\n?```$/, "")
    .trim();
}

export async function generateCommitMessage(cwd: string, files: DiffFile[]): Promise<string> {
  if (files.length === 0) throw new Error("No changes to describe.");
  const spec = PROVIDERS.claude;
  const prompt = buildDiffPrompt(files);
  const stdout = await new Promise<string>((resolve, reject) => {
    const child = spawn(spec.command, ["-p", "--append-system-prompt", SYSTEM_PROMPT], {
      cwd,
      env: process.env,
    });
    let out = "";
    let err = "";
    let settled = false;
    const finish = (fn: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      fn();
    };
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish(() => reject(new Error("Commit-message generation timed out.")));
    }, TIMEOUT_MS);

    child.stdout.on("data", (d: Buffer) => {
      out += d.toString();
      if (out.length > MAX_BUFFER) {
        child.kill("SIGKILL");
        finish(() => reject(new Error("Output too large.")));
      }
    });
    child.stderr.on("data", (d: Buffer) => {
      err += d.toString();
    });
    child.on("error", (e) => finish(() => reject(e)));
    child.on("close", (code) => {
      if (out.trim()) finish(() => resolve(out));
      else finish(() => reject(new Error(err.trim() || `claude exited with code ${code}`)));
    });
    child.stdin.on("error", () => {
      /* CLI may close stdin early; ignore EPIPE. */
    });
    child.stdin.end(prompt);
  });
  const message = cleanMessage(stdout);
  if (!message) throw new Error("Empty commit message.");
  return message;
}
