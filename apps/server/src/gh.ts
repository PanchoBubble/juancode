import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { PrChecks, PrCreateResult, PrListResult, PullRequest } from "./protocol.ts";

const exec = promisify(execFile);

const MAX_BUFFER = 16 * 1024 * 1024;
const MAX_PRS = 50;

/** The `gh pr list --json` fields we request. */
const FIELDS = "number,title,url,headRefName,isDraft,statusCheckRollup,author";

/** One entry of gh's `statusCheckRollup` array (CheckRun or StatusContext). */
interface RollupCheck {
  // CheckRun uses status/conclusion; legacy StatusContext uses state.
  status?: string;
  conclusion?: string;
  state?: string;
}

interface RawPr {
  number: number;
  title: string;
  url: string;
  headRefName: string;
  isDraft: boolean;
  statusCheckRollup?: RollupCheck[] | null;
  author?: { login?: string } | null;
}

/** Collapse a PR's individual checks into a single failing/pending/passing/none. */
export function rollupChecks(checks: RollupCheck[] | null | undefined): PrChecks {
  if (!checks || checks.length === 0) return "none";
  let pending = false;
  for (const c of checks) {
    const conclusion = (c.conclusion ?? "").toUpperCase();
    const state = (c.state ?? "").toUpperCase();
    const status = (c.status ?? "").toUpperCase();
    if (["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED"].includes(conclusion))
      return "failing";
    if (["FAILURE", "ERROR"].includes(state)) return "failing";
    // Not yet concluded: a CheckRun still running, or a pending commit status.
    if (status && status !== "COMPLETED") pending = true;
    if (state === "PENDING") pending = true;
  }
  return pending ? "pending" : "passing";
}

/** Map gh's raw JSON into our wire shape. Exported for testing. */
export function parsePrs(raw: RawPr[]): PullRequest[] {
  return raw.map((p) => ({
    number: p.number,
    title: p.title,
    url: p.url,
    branch: p.headRefName,
    draft: p.isDraft,
    checks: rollupChecks(p.statusCheckRollup),
    author: p.author?.login ?? "",
  }));
}

/**
 * The authenticated GitHub login, cached for the process lifetime. Best-effort:
 * returns "" if `gh` is missing or unauthenticated (the caller still lists PRs).
 */
let viewerLogin: string | undefined;
export async function getViewerLogin(cwd: string): Promise<string> {
  if (viewerLogin !== undefined) return viewerLogin;
  try {
    const { stdout } = await exec("gh", ["api", "user", "--jq", ".login"], { cwd, maxBuffer: MAX_BUFFER });
    viewerLogin = stdout.trim();
  } catch {
    viewerLogin = "";
  }
  return viewerLogin;
}

/**
 * List a folder's open pull requests via the real `gh` CLI (the user's own auth,
 * never a shadow env — same philosophy as spawning the genuine agent CLIs).
 *
 * Returns `{ available: false, error }` rather than throwing when gh is missing,
 * unauthenticated, or the cwd isn't a repo with a remote, so the UI can hide the
 * badge gracefully.
 */
export async function getOpenPrs(cwd: string): Promise<PrListResult> {
  let stdout: string;
  try {
    ({ stdout } = await exec("gh", ["pr", "list", "--state", "open", "--limit", String(MAX_PRS), "--json", FIELDS], {
      cwd,
      maxBuffer: MAX_BUFFER,
    }));
  } catch (err) {
    return { available: false, prs: [], error: ghErrorReason(err) };
  }
  try {
    const raw = JSON.parse(stdout) as RawPr[];
    return { available: true, prs: parsePrs(raw), viewer: await getViewerLogin(cwd) };
  } catch {
    return { available: false, prs: [], error: "Could not parse gh output" };
  }
}

/**
 * Open a pull request for the current branch via the real `gh` CLI. The caller
 * pushes the branch first, so this just creates the PR. If a PR already exists
 * for the branch, gh prints its url to stderr — we return that with
 * `created: false` rather than erroring.
 */
export async function createPr(
  cwd: string,
  opts: { title: string; body: string; draft: boolean },
): Promise<PrCreateResult> {
  const args = ["pr", "create", "--title", opts.title, "--body", opts.body];
  if (opts.draft) args.push("--draft");
  try {
    const { stdout } = await exec("gh", args, { cwd, maxBuffer: MAX_BUFFER });
    const url = stdout.match(/https?:\/\/\S+/)?.[0] ?? stdout.trim();
    return { url, created: true };
  } catch (err) {
    const stderr = (err as { stderr?: string }).stderr ?? "";
    const existing = stderr.match(/already exists[:\s]+(https?:\/\/\S+)/i);
    if (existing) return { url: existing[1]!, created: false };
    throw new Error(ghErrorReason(err));
  }
}

// ── PR activity (for the tracked-PR poller, juancode-yow) ────────────────────

/**
 * One issue-level PR comment, as returned by `gh pr view --json comments`. We keep
 * only the fields the poller needs to dedup and summarise new activity. Mirrors the
 * native `PrComment` (apps/native/.../Gh.swift).
 */
export interface PrComment {
  id: string;
  author: string;
  body: string;
}

/**
 * One PR review (`gh pr view --json reviews`). `state` is GitHub's review state
 * (APPROVED / CHANGES_REQUESTED / COMMENTED / DISMISSED / PENDING), upper-cased.
 */
export interface PrReview {
  id: string;
  author: string;
  body: string;
  state: string;
}

/**
 * A snapshot of a PR's reviewable activity: rolled-up CI status, issue comments,
 * and reviews. What the tracked-PR poller diffs each tick to detect new events.
 */
export interface PrActivity {
  checks: PrChecks;
  comments: PrComment[];
  reviews: PrReview[];
}

/** Raw `gh pr view --json comments/reviews` element shapes. */
interface RawPrComment {
  id?: string;
  author?: { login?: string } | null;
  body?: string;
}
interface RawPrReview {
  id?: string;
  author?: { login?: string } | null;
  body?: string;
  state?: string;
}
interface RawPrActivity {
  statusCheckRollup?: RollupCheck[] | null;
  comments?: RawPrComment[] | null;
  reviews?: RawPrReview[] | null;
}

/**
 * Map gh's raw activity JSON onto our wire shape. Exported for testing. Drops any
 * comment/review missing an `id` (can't be deduped reliably without one).
 */
export function parsePrActivity(raw: RawPrActivity): PrActivity {
  return {
    checks: rollupChecks(raw.statusCheckRollup),
    comments: (raw.comments ?? []).flatMap((c) =>
      c.id ? [{ id: c.id, author: c.author?.login ?? "", body: c.body ?? "" }] : [],
    ),
    reviews: (raw.reviews ?? []).flatMap((r) =>
      r.id
        ? [{ id: r.id, author: r.author?.login ?? "", body: r.body ?? "", state: (r.state ?? "").toUpperCase() }]
        : [],
    ),
  };
}

/**
 * Read a single PR's reviewable activity via the real `gh` CLI. Returns null when
 * gh is missing/unauthenticated, the cwd isn't a repo, or the output won't parse —
 * the poller treats null as "couldn't poll this tick" and tries again later.
 */
export async function getPrActivity(cwd: string, number: number): Promise<PrActivity | null> {
  let stdout: string;
  try {
    ({ stdout } = await exec(
      "gh",
      ["pr", "view", String(number), "--json", "statusCheckRollup,comments,reviews"],
      { cwd, maxBuffer: MAX_BUFFER },
    ));
  } catch {
    return null;
  }
  try {
    return parsePrActivity(JSON.parse(stdout) as RawPrActivity);
  } catch {
    return null;
  }
}

/** Turn an execFile failure into a short, user-facing reason. */
function ghErrorReason(err: unknown): string {
  const e = err as { code?: string | number; stderr?: string };
  if (e.code === "ENOENT") return "gh CLI not installed";
  const stderr = (e.stderr ?? "").toLowerCase();
  if (stderr.includes("no git remotes") || stderr.includes("not a git repository"))
    return "Not a GitHub repo";
  if (stderr.includes("auth") || stderr.includes("logged")) return "gh not authenticated";
  return (e.stderr ?? "gh failed").trim().split("\n")[0] || "gh failed";
}
