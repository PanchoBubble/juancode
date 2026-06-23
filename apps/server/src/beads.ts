import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { BeadsIssue, BeadsResult } from "./protocol.ts";
import { resolveBin } from "./resolveBin.ts";

const exec = promisify(execFile);

/** The `bd` binary, resolved like the user's terminal would (see resolveBin). */
const BD_BIN = resolveBin("bd", process.env.JUANCODE_BD_BIN);

const MAX_BUFFER = 16 * 1024 * 1024;
const TIMEOUT_MS = 10_000;

/**
 * Run `bd` in `cwd` and parse its JSON stdout. We pass `--sandbox` (read-only:
 * no sync/autopush) since this is a polled, view-only panel. Inherits the user's
 * real env untouched — never a shadow HOME — so bd resolves the same `.beads`
 * tracker it would in their terminal.
 */
async function bdJson<T>(cwd: string, args: string[]): Promise<T> {
  const { stdout } = await exec(BD_BIN, ["--sandbox", ...args, "--json"], {
    cwd,
    maxBuffer: MAX_BUFFER,
    timeout: TIMEOUT_MS,
    env: process.env,
  });
  return JSON.parse(stdout || "null") as T;
}

/** Raw shape from `bd list --json` — snake_case, only the fields we surface. */
interface RawIssue {
  id?: string;
  title?: string;
  status?: string;
  priority?: number;
  issue_type?: string;
  parent?: string | null;
  dependency_count?: number;
  dependent_count?: number;
}

function idsOf(value: unknown): Set<string> {
  if (!Array.isArray(value)) return new Set();
  return new Set(value.map((i) => String((i as RawIssue).id ?? "")).filter(Boolean));
}

/**
 * List a work folder's bd issues, flagged ready/blocked. Returns
 * `{ available: false }` (never throws) when bd is missing or the folder has no
 * tracker, so the UI can degrade gracefully instead of erroring.
 */
export async function getBeads(cwd: string): Promise<BeadsResult> {
  let raw: RawIssue[];
  try {
    raw = (await bdJson<RawIssue[]>(cwd, ["list"])) ?? [];
  } catch (err) {
    return { available: false, issues: [], error: describe(err) };
  }

  // ready/blocked are best-effort overlays — a failure here just leaves the
  // flags false rather than failing the whole listing.
  const [ready, blocked] = await Promise.all([
    bdJson<unknown>(cwd, ["ready", "--limit", "1000"]).then(idsOf, () => new Set<string>()),
    bdJson<unknown>(cwd, ["blocked"]).then(idsOf, () => new Set<string>()),
  ]);

  const issues: BeadsIssue[] = raw
    .filter((r) => r.id)
    .map((r) => ({
      id: String(r.id),
      title: r.title ?? "",
      status: r.status ?? "open",
      priority: typeof r.priority === "number" ? r.priority : 2,
      issueType: r.issue_type ?? "task",
      parent: r.parent ?? null,
      dependencyCount: r.dependency_count ?? 0,
      dependentCount: r.dependent_count ?? 0,
      ready: ready.has(String(r.id)),
      blocked: blocked.has(String(r.id)),
    }));

  return { available: true, issues };
}

function describe(err: unknown): string {
  const e = err as { code?: string; stderr?: string };
  if (e.code === "ENOENT") return "bd CLI not found on PATH";
  const stderr = typeof e.stderr === "string" ? e.stderr.trim() : "";
  if (stderr.includes("no beads database")) return "No beads tracker in this folder";
  return stderr || (err instanceof Error ? err.message : String(err));
}
