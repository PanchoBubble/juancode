// Git reality about every worktree of a checkout, in one place.
//
// This started as the body of worktree-status.mjs and moved here when
// worktree-sweep.mjs needed the same facts. Both callers ask the same
// question — "is there anything in this tree that exists nowhere else?" —
// and the sweeper answers it by deleting, so the two must never drift apart.
//
// Order of sources matters and is the reason gh is not the primary one: a
// branch with local commits and no upstream is invisible to gh, so it looks
// clean and is not. Git first, gh and bd layered on top.

import { execFileSync } from "node:child_process";

export const BD_ID_RE = /\b([a-z][a-z0-9]*-[a-z0-9]{3,})\b/g;

/** Run git in `cwd`, returning trimmed stdout or `fallback` on any failure. */
export function git(cwd, cmdArgs, fallback = "") {
  try {
    return execFileSync("git", ["-C", cwd, ...cmdArgs], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      maxBuffer: 32 * 1024 * 1024,
    }).trim();
  } catch {
    return fallback;
  }
}

/** Top level of the checkout `cwd` sits in, or "" when it is not a repo. */
export function repoRootOf(cwd) {
  return git(cwd, ["rev-parse", "--show-toplevel"]);
}

/** Refresh remote-tracking refs. Best effort: offline is not an error. */
export function fetchRemotes(repoRoot) {
  try {
    execFileSync("git", ["-C", repoRoot, "fetch", "--all", "--quiet", "--prune"], {
      stdio: "ignore",
    });
    return true;
  } catch {
    return false;
  }
}

/**
 * The MAIN checkout, given any path inside the repo — including inside one of
 * its worktrees, where `rev-parse --show-toplevel` answers with the worktree.
 * Anything that reasons about worktrees as a set has to start here, or it calls
 * whichever tree it was invoked from "the main one".
 */
export function mainCheckoutOf(cwd) {
  const common = git(cwd, ["rev-parse", "--path-format=absolute", "--git-common-dir"]);
  if (!common) return repoRootOf(cwd);
  return common.replace(/\/\.git\/?$/, "");
}

/** Every worktree of `repoRoot`, main checkout first (git lists it first). */
export function parseWorktrees(repoRoot) {
  const out = git(repoRoot, ["worktree", "list", "--porcelain"]);
  const trees = [];
  let cur = null;
  for (const line of out.split("\n")) {
    if (line.startsWith("worktree ")) {
      cur = { path: line.slice(9), head: "", branch: null, detached: false, locked: false };
      trees.push(cur);
    } else if (!cur) {
      continue;
    } else if (line.startsWith("HEAD ")) {
      cur.head = line.slice(5);
    } else if (line.startsWith("branch ")) {
      cur.branch = line.slice(7).replace("refs/heads/", "");
    } else if (line === "detached") {
      cur.detached = true;
    } else if (line === "locked" || line.startsWith("locked ")) {
      cur.locked = true;
    }
  }
  return trees;
}

/** Open/closed/merged PRs by head branch. Empty when gh is missing or unauthed. */
export function loadPrsByBranch() {
  const map = new Map();
  try {
    const raw = execFileSync(
      "gh",
      [
        "pr",
        "list",
        "--state",
        "all",
        "--limit",
        "200",
        "--json",
        "number,title,headRefName,state,isDraft,mergedAt,url",
      ],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    );
    for (const pr of JSON.parse(raw)) map.set(pr.headRefName, pr);
    return { prs: map, ok: true };
  } catch {
    return { prs: map, ok: false };
  }
}

/** bd issues by id. Empty when bd is absent or the tracker is empty. */
export function loadBdById() {
  const map = new Map();
  try {
    // Redirect stdin/stderr: bd's dolt daemon can otherwise hold the pipe open.
    const raw = execFileSync("sh", ["-c", "bd list --json 2>/dev/null </dev/null"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    const parsed = JSON.parse(raw);
    const list = Array.isArray(parsed) ? parsed : (parsed.issues ?? []);
    for (const it of list) if (it && it.id) map.set(it.id, it);
  } catch {
    /* bd absent/empty */
  }
  return map;
}

/** bd ids referenced by the commits this tree has beyond origin/main. */
export function bdIdsFromBranch(cwd) {
  const body = git(cwd, ["log", "origin/main..HEAD", "--format=%B"], "");
  const ids = new Set();
  for (const m of body.matchAll(BD_ID_RE)) ids.add(m[1]);
  return [...ids];
}

/**
 * The git facts about one worktree, before any policy is applied.
 *
 * `pushed` is deliberately tri-state: false means the local branch is ahead of
 * its remote-tracking ref, null means there is NO remote branch at all. Both
 * mean "these commits exist only here"; collapsing them to a boolean is how a
 * tree full of unpushed work gets read as clean.
 */
export function inspectWorktree(t, ctx) {
  const { repoRoot, prs = new Map() } = ctx;
  const short = t.path.includes("-worktrees/")
    ? "wt:" + t.path.split("-worktrees/").pop()
    : t.path === repoRoot
      ? "."
      : t.path.replace(repoRoot + "/", "");
  const branch = t.branch ?? (t.detached ? "(detached)" : "?");

  // --porcelain without -uno: an untracked file is work too.
  const statusOut = git(t.path, ["status", "--porcelain"], null);
  const readable = statusOut !== null;
  const dirtyLines = (statusOut ?? "").split("\n").filter(Boolean);

  const aheadMain = Number(git(t.path, ["rev-list", "--count", "origin/main..HEAD"], "0")) || 0;

  let pushed = null; // null = no remote branch
  if (t.branch) {
    const remoteSha = git(
      t.path,
      ["rev-parse", "--verify", "--quiet", `refs/remotes/origin/${t.branch}`],
      "",
    );
    if (remoteSha) pushed = remoteSha === t.head;
  }

  const pr = t.branch ? prs.get(t.branch) : undefined;

  return {
    path: t.path,
    short,
    branch,
    head: t.head,
    detached: t.detached,
    locked: t.locked,
    isMain: t.path === repoRoot,
    onMainBranch: t.branch === "main",
    readable,
    dirty: dirtyLines.length,
    aheadMain,
    pushed,
    pr: pr
      ? {
          number: pr.number,
          state: pr.state,
          draft: pr.isDraft,
          merged: pr.state === "MERGED" || Boolean(pr.mergedAt),
          url: pr.url,
        }
      : null,
  };
}

/** The loose-work state machine behind `pnpm loose`. Most-loose first. */
export function classifyLooseness(info) {
  const { dirty, aheadMain, pushed, pr, branch } = info;
  const isMain = branch === "main";
  const prMerged = pr && pr.merged;

  if (dirty > 0) {
    return { state: "DIRTY", hint: `${dirty} uncommitted file(s) — commit or stash` };
  }
  if (aheadMain > 0 && pushed === false) {
    return {
      state: "UNPUSHED",
      hint: `${aheadMain} commit(s) ahead, local is ahead of origin/${branch} — push`,
    };
  }
  if (aheadMain > 0 && pushed === null && !isMain) {
    return { state: "UNPUSHED", hint: `${aheadMain} commit(s) ahead, no origin branch — push` };
  }
  if (aheadMain > 0 && !pr && !isMain) {
    return { state: "NO_PR", hint: `pushed, ${aheadMain} commit(s) ahead, no PR — open one` };
  }
  if (pr && !prMerged && pr.state === "OPEN") {
    return {
      state: pr.draft ? "PR_DRAFT" : "PR_OPEN",
      hint: `PR #${pr.number} ${pr.draft ? "(draft)" : "in review"} — ${pr.url}`,
    };
  }
  if (prMerged && !isMain) {
    return {
      state: "MERGED_STALE",
      hint: `PR #${pr.number} merged — prune: git worktree remove ${info.path} && git branch -D ${branch}`,
    };
  }
  if (!isMain && aheadMain === 0 && dirty === 0) {
    return {
      state: "ORPHAN",
      hint: `at origin/main, no diff, no changes — prune: git worktree remove ${info.path} && git branch -D ${branch}`,
    };
  }
  return { state: "CLEAN", hint: isMain ? "main working tree" : "" };
}
