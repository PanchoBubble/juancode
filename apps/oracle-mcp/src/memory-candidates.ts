#!/usr/bin/env node
// SessionEnd hook: propose memory facts, never write them (juancode-f2mq).
//
// The idea is borrowed from claude-mem, minus the part that lets a model edit curated
// memory. When a session ends this reads its own transcript, asks a cheap model for at
// most a few facts that were non-obvious, and APPENDS them to CANDIDATES.md next to the
// memory dir. Promoting a candidate into `memory/*.md` + `MEMORY.md` stays a manual act,
// so the curated set keeps its signal.
//
// Runs as a plain `node <this file>.ts` (Node ≥ 22.18 strips the types), so the hook has
// no dependency on this repo's node_modules and works from any project directory.
//
// Guarantees: exits 0 on every path, never blocks session exit, never touches
// `memory/*.md` or `MEMORY.md`, and skips short sessions entirely.
//
// Env:
//   JUANCODE_MEMORY_CANDIDATES=0        disable
//   JUANCODE_MEMORY_CANDIDATES_MIN_TURNS=12
//   JUANCODE_MEMORY_CANDIDATES_MODEL=claude-haiku-4-5-20251001
//   JUANCODE_MEMORY_CANDIDATES_DEBUG=1  log skips/errors to stderr

import { execFile } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { homedir } from "node:os";
import { parseTranscriptLine } from "./transcript-lines.ts";

export type CandidateType = "user" | "feedback" | "project" | "reference";

export type Candidate = {
  name: string;
  type: CandidateType;
  fact: string;
  why: string;
};

/** SessionEnd hook payload (only the fields used here). */
export type HookInput = {
  session_id?: string;
  transcript_path?: string;
  cwd?: string;
  reason?: string;
};

const MIN_TURNS = Number(process.env.JUANCODE_MEMORY_CANDIDATES_MIN_TURNS ?? 12);
const MODEL = process.env.JUANCODE_MEMORY_CANDIDATES_MODEL ?? "claude-haiku-4-5-20251001";
const CLAUDE_TIMEOUT_MS = 90_000;
/** How much of the session to show the model. Tail-biased: late turns hold the lessons. */
const MAX_DIGEST_CHARS = 24_000;
const MAX_TURN_CHARS = 800;
const MAX_CANDIDATES = 3;
const VALID_TYPES: CandidateType[] = ["user", "feedback", "project", "reference"];

const debug = (msg: string): void => {
  if (process.env.JUANCODE_MEMORY_CANDIDATES_DEBUG) process.stderr.write(`memory-candidates: ${msg}\n`);
};

/** Claude Code keeps a project's transcripts and its memory dir side by side, so the
 *  transcript path already encodes the slug. Falls back to slugifying cwd. */
export function memoryDirFor(input: HookInput): string | undefined {
  if (input.transcript_path) return join(dirname(input.transcript_path), "memory");
  if (input.cwd) {
    const slug = input.cwd.replace(/[/.]/g, "-");
    return join(homedir(), ".claude", "projects", slug, "memory");
  }
  return undefined;
}

/** Existing memory: file slugs (for name collisions) and the index text (for near-dupes). */
export function existingMemory(dir: string): { names: Set<string>; text: string } {
  const names = new Set<string>();
  let text = "";
  let files: string[] = [];
  try {
    files = readdirSync(dir).filter((f) => f.endsWith(".md"));
  } catch {
    return { names, text };
  }
  for (const f of files) {
    if (f === "MEMORY.md") continue;
    names.add(basename(f, ".md").toLowerCase());
  }
  for (const f of ["MEMORY.md", "CANDIDATES.md"]) {
    try {
      text += `${readFileSync(join(dir, f), "utf8")}\n`;
    } catch {
      // Absent on a first run.
    }
  }
  // Candidates already proposed but not yet promoted must not be proposed again.
  for (const m of text.matchAll(/^- name: ([a-z0-9-]+)$/gim)) names.add(m[1]!.toLowerCase());
  return { names, text };
}

/** Tail-biased plain-text rendering of a transcript, plus the count of real turns. */
export function buildDigest(lines: string[]): { turns: number; digest: string } {
  const turns: string[] = [];
  for (const line of lines) {
    const entry = parseTranscriptLine(line);
    if (!entry) continue;
    const text = entry.text.replace(/\s+/g, " ").trim().slice(0, MAX_TURN_CHARS);
    if (text) turns.push(`${entry.role}: ${text}`);
  }
  let digest = "";
  // Walk backwards so the budget is spent on the end of the session.
  const kept: string[] = [];
  for (let i = turns.length - 1; i >= 0; i -= 1) {
    const next = turns[i]!;
    if (digest.length + next.length + 1 > MAX_DIGEST_CHARS) break;
    kept.unshift(next);
    digest = `${next}\n${digest}`;
  }
  return { turns: turns.length, digest: kept.join("\n") };
}

const SECRET_PATTERNS: RegExp[] = [
  /[\w.+-]+@[\w-]+\.[\w.]+/, // email address
  /\b(?:sk|pk)-[A-Za-z0-9_-]{12,}/, // API key
  /\bghp_[A-Za-z0-9]{16,}/, // GitHub token
  /\bxox[abposr]-[A-Za-z0-9-]{10,}/, // Slack token
  /\bAKIA[0-9A-Z]{12,}/, // AWS access key id
  /\bBearer\s+[A-Za-z0-9._-]{16,}/i,
  /\beyJ[A-Za-z0-9_-]{16,}\./, // JWT
  /\b\d{12,}\b/, // long digit run (card / account-like)
];

/** Reject anything that smells like a credential or a real person's contact detail.
 *  Candidates are meant to record how things work, not who or what the values are. */
export function looksSensitive(text: string): boolean {
  return SECRET_PATTERNS.some((re) => re.test(text));
}

const slugify = (s: string): string =>
  s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 60);

/** Tolerant extraction: the model may wrap its JSON in prose or a fenced block. */
export function parseCandidates(raw: string): Candidate[] {
  const start = raw.indexOf("[");
  const end = raw.lastIndexOf("]");
  if (start < 0 || end <= start) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw.slice(start, end + 1));
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) return [];
  const out: Candidate[] = [];
  for (const item of parsed) {
    if (!item || typeof item !== "object") continue;
    const c = item as Record<string, unknown>;
    const fact = typeof c.fact === "string" ? c.fact.trim() : "";
    if (!fact) continue;
    const type = VALID_TYPES.includes(c.type as CandidateType) ? (c.type as CandidateType) : "project";
    const name = slugify(typeof c.name === "string" && c.name.trim() ? c.name : fact);
    if (!name) continue;
    out.push({ name, type, fact, why: typeof c.why === "string" ? c.why.trim() : "" });
  }
  return out.slice(0, MAX_CANDIDATES);
}

/** Drop candidates that already exist, repeat each other, or carry sensitive values. */
export function filterCandidates(
  candidates: Candidate[],
  existing: { names: Set<string>; text: string },
): Candidate[] {
  const seen = new Set<string>();
  const haystack = existing.text.toLowerCase();
  const out: Candidate[] = [];
  for (const c of candidates) {
    if (existing.names.has(c.name) || seen.has(c.name)) continue;
    if (looksSensitive(`${c.fact} ${c.why}`)) {
      debug(`dropped candidate ${c.name}: looks sensitive`);
      continue;
    }
    // Cheap near-dupe check: every distinctive word already appears in the index.
    const words = c.fact.toLowerCase().match(/[a-z0-9][a-z0-9._/-]{4,}/g) ?? [];
    if (words.length >= 3 && words.every((w) => haystack.includes(w))) continue;
    seen.add(c.name);
    out.push(c);
  }
  return out;
}

/** The markdown block appended to CANDIDATES.md. */
export function renderCandidates(
  candidates: Candidate[],
  meta: { sessionId: string; project: string; when: string },
): string {
  const lines = [
    "",
    `## ${meta.when} — ${meta.project} (session ${meta.sessionId.slice(0, 8)})`,
    "",
  ];
  for (const c of candidates) {
    lines.push(`- name: ${c.name}`);
    lines.push(`  type: ${c.type}`);
    lines.push(`  fact: ${c.fact}`);
    if (c.why) lines.push(`  why: ${c.why}`);
    lines.push("");
  }
  return lines.join("\n");
}

export function buildPrompt(digest: string, existingIndex: string): string {
  return [
    "You are reviewing a finished Claude Code session to propose CANDIDATE memory facts.",
    "A good fact was non-obvious and will still matter next week: a footgun, a decided",
    "convention, a port or path that surprises, a de-scoped direction. Skip anything the",
    "repo already records (code structure, git history, CLAUDE.md), anything that only",
    "mattered inside this session, and anything already listed below.",
    "",
    "Never include names, email addresses, phone numbers, customer or earnings data,",
    "credentials or tokens. Describe how things work, not who or what the values are.",
    "",
    "Already recorded:",
    existingIndex.slice(0, 4000) || "(nothing yet)",
    "",
    "Session transcript (abridged):",
    digest,
    "",
    `Reply with ONLY a JSON array of at most ${MAX_CANDIDATES} objects, or [] if nothing`,
    "qualifies — an empty array is the right answer for most sessions. Shape:",
    '[{"name":"kebab-case-slug","type":"user|feedback|project|reference",',
    '  "fact":"one sentence","why":"why it was non-obvious"}]',
  ].join("\n");
}

function runClaude(prompt: string): Promise<string> {
  // This child session ends too, firing SessionEnd again — the guard stops the hook from
  // recursing forever. ANTHROPIC_API_KEY is dropped so the child uses the same claude.ai
  // login the interactive CLI does (same reasoning as oracle.ts).
  const env: Record<string, string | undefined> = {
    ...process.env,
    JUANCODE_MEMORY_CANDIDATES: "0",
  };
  delete env.ANTHROPIC_API_KEY;
  return new Promise((resolve) => {
    const child = execFile(
      process.env.JUANCODE_CLAUDE_BIN || "claude",
      // `--allowed-tools` with a name no tool has = no tools, so this stays a single
      // text completion (the CLI has no "tools off" flag).
      ["-p", prompt, "--model", MODEL, "--allowed-tools", "none"],
      { timeout: CLAUDE_TIMEOUT_MS, maxBuffer: 4_000_000, env },
      (err, stdout) => {
        if (err) debug(`claude failed: ${err.message}`);
        resolve(stdout ?? "");
      },
    );
    child.stdin?.end();
  });
}

function readStdin(): Promise<string> {
  return new Promise((resolve) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (c) => {
      data += c;
    });
    process.stdin.on("end", () => resolve(data));
    process.stdin.on("error", () => resolve(data));
  });
}

export async function main(): Promise<void> {
  if (process.env.JUANCODE_MEMORY_CANDIDATES === "0") return;
  let input: HookInput;
  try {
    input = JSON.parse(await readStdin()) as HookInput;
  } catch {
    debug("no usable hook payload on stdin");
    return;
  }
  const memoryDir = memoryDirFor(input);
  if (!memoryDir || !input.transcript_path || !existsSync(input.transcript_path)) {
    debug("no transcript / memory dir");
    return;
  }

  const { turns, digest } = buildDigest(readFileSync(input.transcript_path, "utf8").split("\n"));
  if (turns < MIN_TURNS) {
    debug(`skipped: ${turns} turns < ${MIN_TURNS}`);
    return;
  }

  const existing = existingMemory(memoryDir);
  const candidates = filterCandidates(
    parseCandidates(await runClaude(buildPrompt(digest, existing.text))),
    existing,
  );
  if (!candidates.length) {
    debug("no candidates worth appending");
    return;
  }

  mkdirSync(memoryDir, { recursive: true });
  const path = join(memoryDir, "CANDIDATES.md");
  const header = existsSync(path)
    ? ""
    : "# Memory candidates\n\nProposed by the SessionEnd hook, never promoted automatically.\nPromote what is worth keeping into `memory/<name>.md` + `MEMORY.md`, then delete the entry.\n";
  appendFileSync(
    path,
    header +
      renderCandidates(candidates, {
        sessionId: input.session_id ?? "unknown",
        project: input.cwd ?? "unknown",
        when: new Date().toISOString().slice(0, 10),
      }),
  );
  debug(`appended ${candidates.length} candidate(s) to ${path}`);
}

// Only run when invoked as the hook, so tests can import the pure helpers.
if (process.argv[1] && import.meta.url.endsWith(basename(process.argv[1]))) {
  main().catch((e) => debug(`unexpected: ${e instanceof Error ? e.message : String(e)}`));
}
