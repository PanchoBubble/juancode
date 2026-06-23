import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { DiffFile, DiffResult, FileStatus } from "./protocol.ts";

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
