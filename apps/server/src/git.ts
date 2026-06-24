import { execFile } from "node:child_process";
import { mkdirSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { promisify } from "node:util";
import type {
  CommitResult,
  DiffFile,
  DiffResult,
  FileStatus,
  GitState,
  PushResult,
  Worktree,
} from "./protocol.ts";

const exec = promisify(execFile);

/** Empty-tree object — used as the diff base when a repo has no commits yet. */
const EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

const MAX_FILES = 300;
const MAX_DIFF_BYTES = 400_000; // per-file cap; larger diffs are summarized, not sent
const MAX_BUFFER = 64 * 1024 * 1024;

/** Run git, returning stdout. `git diff` exits 1 when differences exist — not an error. */
async function git(cwd: string, args: string[]): Promise<string> {
  try {
    const { stdout } = await exec("git", ["-c", "core.quotepath=false", ...args], {
      cwd,
      maxBuffer: MAX_BUFFER,
    });
    return stdout;
  } catch (err) {
    // execFile rejects on non-zero exit; `git diff` uses 1 to signal "has changes".
    const e = err as { code?: number; stdout?: string };
    if (e.code === 1 && typeof e.stdout === "string") return e.stdout;
    throw err;
  }
}

/**
 * Run git with no special-casing of exit codes — any non-zero rejects, so write
 * operations (commit/push) surface real failures (hook rejected, no remote, …)
 * instead of being swallowed like a `git diff` "has changes" exit-1.
 */
async function gitStrict(cwd: string, args: string[]): Promise<{ stdout: string; stderr: string }> {
  const { stdout, stderr } = await exec("git", ["-c", "core.quotepath=false", ...args], {
    cwd,
    maxBuffer: MAX_BUFFER,
  });
  return { stdout, stderr };
}

/** First useful line of a git failure (stderr, then stdout), for a clean UI error. */
function gitErr(err: unknown, fallback: string): string {
  const e = err as { stderr?: string; stdout?: string };
  const text = `${e.stderr ?? ""}\n${e.stdout ?? ""}`.trim();
  return text.split("\n").find((l) => l.trim()) ?? fallback;
}

function countChanges(diff: string): { additions: number; deletions: number; binary: boolean } {
  let additions = 0;
  let deletions = 0;
  for (const line of diff.split("\n")) {
    // Binary markers appear as unprefixed header lines — guard against matching
    // the same text occurring inside an added/removed (+/-) content line.
    if (line.startsWith("Binary files ") || line.startsWith("GIT binary patch")) {
      return { additions: 0, deletions: 0, binary: true };
    }
    if (line.startsWith("+") && !line.startsWith("+++")) additions++;
    else if (line.startsWith("-") && !line.startsWith("---")) deletions++;
  }
  return { additions, deletions, binary: false };
}

const STATUS_MAP: Record<string, FileStatus> = { M: "modified", A: "added", D: "deleted" };

/**
 * Compute the working-tree diff vs HEAD for a session's cwd: every tracked
 * change (staged + unstaged) plus untracked files, each as its own unified
 * diff. Returns `{ git: false }` for a non-git cwd rather than throwing.
 */
export async function getDiff(cwd: string): Promise<DiffResult> {
  // Confirm this is a git work tree.
  let root: string;
  try {
    const inside = (await git(cwd, ["rev-parse", "--is-inside-work-tree"])).trim();
    if (inside !== "true") return { git: false, files: [] };
    root = (await git(cwd, ["rev-parse", "--show-toplevel"])).trim();
  } catch {
    return { git: false, files: [] };
  }

  // Diff base: HEAD if it exists, else the empty tree (fresh repo, no commits).
  let base = "HEAD";
  try {
    await git(cwd, ["rev-parse", "--verify", "HEAD"]);
  } catch {
    base = EMPTY_TREE;
  }

  const files: DiffFile[] = [];

  // Tracked changes vs base, via name-status (handles renames with -M).
  const nameStatus = await git(cwd, ["diff", "--name-status", "-M", base]);
  for (const raw of nameStatus.split("\n")) {
    if (!raw.trim()) continue;
    if (files.length >= MAX_FILES) break;
    const parts = raw.split("\t");
    const code = parts[0] ?? "";
    if (code.startsWith("R") && parts[1] && parts[2]) {
      const oldPath = parts[1];
      const newPath = parts[2];
      const diff = await git(cwd, ["diff", "-M", base, "--", oldPath, newPath]);
      files.push(buildFile(newPath, oldPath, "renamed", diff));
    } else if (parts[1]) {
      const path = parts[1];
      const status = STATUS_MAP[code[0] ?? ""] ?? "modified";
      const diff = await git(cwd, ["diff", base, "--", path]);
      files.push(buildFile(path, null, status, diff));
    }
  }

  // Untracked files — shown as full additions via diff against /dev/null.
  const untracked = await git(cwd, ["ls-files", "--others", "--exclude-standard"]);
  for (const path of untracked.split("\n")) {
    if (!path.trim()) continue;
    if (files.length >= MAX_FILES) break;
    // --no-index exits 1 when files differ; git() tolerates that.
    const diff = await git(cwd, ["diff", "--no-index", "--", "/dev/null", path]);
    files.push(buildFile(path, null, "untracked", diff));
  }

  files.sort((a, b) => a.path.localeCompare(b.path));
  const truncatedFiles = files.length >= MAX_FILES;
  return { git: true, root, files, truncatedFiles };
}

/**
 * List the linked worktrees of the repo containing `cwd` (the main worktree is
 * first, flagged `main`). Returns `[]` for a non-git cwd. Parses the stable
 * `--porcelain` format: blank-line-separated blocks of `key value` lines.
 */
export async function listWorktrees(cwd: string): Promise<Worktree[]> {
  let out: string;
  try {
    out = await git(cwd, ["worktree", "list", "--porcelain"]);
  } catch {
    return [];
  }
  const trees: Worktree[] = [];
  for (const block of out.split(/\n\s*\n/)) {
    let path = "";
    let branch: string | null = null;
    let head: string | null = null;
    for (const line of block.split("\n")) {
      if (line.startsWith("worktree ")) path = line.slice("worktree ".length).trim();
      else if (line.startsWith("HEAD ")) head = line.slice("HEAD ".length).trim();
      else if (line.startsWith("branch ")) {
        branch = line.slice("branch ".length).trim().replace(/^refs\/heads\//, "");
      }
    }
    if (path) trees.push({ path, branch, head, main: trees.length === 0 });
  }
  return trees;
}

/** A freshly created session worktree — its checkout path and the branch on it. */
export interface CreatedWorktree {
  /** Absolute path to the new worktree's root (the session's cwd). */
  path: string;
  /** The new branch checked out in it (`juancode/<name>`). */
  branch: string;
}

/**
 * Create a fresh linked worktree off the repo containing `repoCwd`, checked out
 * on a new `juancode/<name>` branch, so a session can work the repo in parallel
 * without sharing the main working tree. The worktree lives in a sibling
 * `<repo>-worktrees/<name>` directory (discoverable, doesn't clutter the repo).
 * Throws a clean message if `repoCwd` isn't a git work tree or the repo has no
 * commit yet to branch from.
 */
export async function createWorktree(repoCwd: string, name: string): Promise<CreatedWorktree> {
  let root: string;
  try {
    if ((await git(repoCwd, ["rev-parse", "--is-inside-work-tree"])).trim() !== "true") {
      throw new Error("not a work tree");
    }
    root = (await git(repoCwd, ["rev-parse", "--show-toplevel"])).trim();
  } catch {
    throw new Error("Not a git repository — can't isolate this session in a worktree.");
  }
  const branch = `juancode/${name}`;
  const dir = join(dirname(root), `${basename(root)}-worktrees`, name);
  mkdirSync(dirname(dir), { recursive: true });
  try {
    await gitStrict(repoCwd, ["worktree", "add", "-b", branch, dir]);
  } catch (err) {
    throw new Error(gitErr(err, "Failed to create worktree"));
  }
  return { path: dir, branch };
}

/**
 * Remove a session-owned worktree (created by {@link createWorktree}) and its
 * directory. Runs the removal from the repo's main worktree — git refuses to
 * remove the worktree you're standing in — and `--force`s past any uncommitted
 * changes, since the owning session is being deleted. The branch is left intact
 * so committed work survives. Throws if git can't remove it.
 */
export async function removeWorktree(worktreePath: string): Promise<void> {
  const trees = await listWorktrees(worktreePath);
  const from = trees.find((t) => t.main)?.path ?? worktreePath;
  try {
    await gitStrict(from, ["worktree", "remove", "--force", worktreePath]);
  } catch (err) {
    throw new Error(gitErr(err, "Failed to remove worktree"));
  }
}

/**
 * Working-tree git state for `cwd`: branch, upstream, ahead/behind counts, and
 * whether the tree is dirty — everything the commit/push/PR CTAs need to decide
 * what's actionable. Returns a `{ git: false }` shape (never throws) for a
 * non-git cwd, mirroring {@link getDiff}.
 */
export async function getGitState(cwd: string): Promise<GitState> {
  const none: GitState = {
    git: false,
    branch: null,
    detached: false,
    upstream: null,
    ahead: 0,
    behind: 0,
    dirty: false,
    remote: false,
  };
  try {
    if ((await git(cwd, ["rev-parse", "--is-inside-work-tree"])).trim() !== "true") return none;
  } catch {
    return none;
  }

  // Branch (fails on a detached HEAD).
  let branch: string | null = null;
  let detached = false;
  try {
    branch = (await git(cwd, ["symbolic-ref", "--short", "HEAD"])).trim() || null;
  } catch {
    detached = true;
  }

  let remote = false;
  try {
    remote = (await git(cwd, ["remote"])).trim().length > 0;
  } catch {
    /* no remotes */
  }

  // Upstream + ahead/behind. With no upstream, treat every local commit as ahead.
  let upstream: string | null = null;
  let ahead = 0;
  let behind = 0;
  try {
    upstream =
      (await git(cwd, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])).trim() ||
      null;
  } catch {
    upstream = null;
  }
  if (upstream) {
    try {
      const counts = (await git(cwd, ["rev-list", "--left-right", "--count", `${upstream}...HEAD`])).trim();
      const [b, a] = counts.split(/\s+/).map((n) => parseInt(n, 10) || 0);
      behind = b ?? 0;
      ahead = a ?? 0;
    } catch {
      /* leave zero */
    }
  } else {
    try {
      ahead = parseInt((await git(cwd, ["rev-list", "--count", "HEAD"])).trim(), 10) || 0;
    } catch {
      /* no commits yet */
    }
  }

  let dirty = false;
  try {
    dirty = (await git(cwd, ["status", "--porcelain"])).trim().length > 0;
  } catch {
    /* leave clean */
  }

  return { git: true, branch, detached, upstream, ahead, behind, dirty, remote };
}

/** Stage every change (`git add -A`) and commit it with `message`. */
export async function commitAll(cwd: string, message: string): Promise<CommitResult> {
  await gitStrict(cwd, ["add", "-A"]);
  if (!(await gitStrict(cwd, ["diff", "--cached", "--name-only"])).stdout.trim()) {
    throw new Error("Nothing to commit.");
  }
  try {
    await gitStrict(cwd, ["commit", "-m", message]);
  } catch (err) {
    throw new Error(gitErr(err, "Commit failed"));
  }
  const sha = (await gitStrict(cwd, ["rev-parse", "--short", "HEAD"])).stdout.trim();
  const subject = (await gitStrict(cwd, ["log", "-1", "--pretty=%s"])).stdout.trim();
  return { sha, subject };
}

/** Push the current branch, setting the upstream to origin on first push. */
export async function pushCurrent(cwd: string): Promise<PushResult> {
  const branch = (await gitStrict(cwd, ["symbolic-ref", "--short", "HEAD"]).catch(() => ({ stdout: "" }))).stdout.trim();
  if (!branch) throw new Error("Detached HEAD — checkout a branch to push.");
  let hasUpstream = true;
  try {
    await gitStrict(cwd, ["rev-parse", "--abbrev-ref", "@{upstream}"]);
  } catch {
    hasUpstream = false;
  }
  const args = hasUpstream ? ["push"] : ["push", "-u", "origin", branch];
  try {
    const { stdout, stderr } = await gitStrict(cwd, args);
    // git reports a successful push on stderr; fall back to a friendly default.
    return { branch, output: `${stdout}${stderr}`.trim() || "Pushed." };
  } catch (err) {
    throw new Error(gitErr(err, "Push failed"));
  }
}

function buildFile(path: string, oldPath: string | null, status: FileStatus, diff: string): DiffFile {
  const { additions, deletions, binary } = countChanges(diff);
  const tooLarge = diff.length > MAX_DIFF_BYTES;
  return {
    path,
    oldPath,
    status,
    additions,
    deletions,
    binary,
    diff: binary || tooLarge ? "" : diff,
    truncated: tooLarge,
  };
}
