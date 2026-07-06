#!/usr/bin/env node
// Global "loose work" scanner for parallel-agent workflows.
//
// Reads git reality first (worktrees + dirty trees + unpushed commits), then
// layers GitHub PR state and bd (beads) ticket state on top, joined by the bd
// ID embedded in commit messages (e.g. "... (juancode-nez)"). gh only sees
// pushed PRs, so it can never be the primary source: a dirty or unpushed tree
// is invisible to it. This walks the worktrees, so nothing needs to register.
//
// Usage:
//   node scripts/worktree-status.mjs            human table
//   node scripts/worktree-status.mjs --json     machine output (for agents/hooks)
//   node scripts/worktree-status.mjs --fetch    refresh remote-tracking refs first (slower)
//   node scripts/worktree-status.mjs --loose    only rows that need attention (exit 1 if any)

import { execFileSync } from "node:child_process";

const args = new Set(process.argv.slice(2));
const asJson = args.has("--json");
const doFetch = args.has("--fetch");
const looseOnly = args.has("--loose");

const BD_ID_RE = /\b([a-z][a-z0-9]*-[a-z0-9]{3,})\b/g;

function git(cwd, cmdArgs, fallback = "") {
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

const repoRoot = git(process.cwd(), ["rev-parse", "--show-toplevel"]);
if (!repoRoot) {
  console.error("not inside a git repository");
  process.exit(2);
}

if (doFetch) {
  try {
    execFileSync("git", ["-C", repoRoot, "fetch", "--all", "--quiet", "--prune"], {
      stdio: "ignore",
    });
  } catch {
    /* offline is fine */
  }
}

// ---- 1. Parse worktrees ---------------------------------------------------
function parseWorktrees() {
  const out = git(repoRoot, ["worktree", "list", "--porcelain"]);
  const trees = [];
  let cur = null;
  for (const line of out.split("\n")) {
    if (line.startsWith("worktree ")) {
      cur = { path: line.slice(9), head: "", branch: null, detached: false };
      trees.push(cur);
    } else if (!cur) {
      continue;
    } else if (line.startsWith("HEAD ")) {
      cur.head = line.slice(5);
    } else if (line.startsWith("branch ")) {
      cur.branch = line.slice(7).replace("refs/heads/", "");
    } else if (line === "detached") {
      cur.detached = true;
    }
  }
  return trees;
}

// ---- 2. Enrichment sources (gh + bd), best-effort -------------------------
function loadPrsByBranch() {
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
  } catch {
    /* gh missing / not authed: PR column stays blank */
  }
  return map;
}

function loadBdById() {
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
    /* bd absent/empty: BD column stays blank */
  }
  return map;
}

const prsByBranch = loadPrsByBranch();
const bdById = loadBdById();

// ---- 3. Classify each worktree -------------------------------------------
function bdIdsFromBranch(cwd) {
  const body = git(cwd, ["log", "origin/main..HEAD", "--format=%B"], "");
  const ids = new Set();
  for (const m of body.matchAll(BD_ID_RE)) {
    // ignore obvious non-ids like short sha-ish tokens; require a letter-led prefix
    ids.add(m[1]);
  }
  return [...ids];
}

function classify(t) {
  const short = t.path.includes("-worktrees/")
    ? "wt:" + t.path.split("-worktrees/").pop()
    : t.path === repoRoot
      ? "."
      : t.path.replace(repoRoot + "/", "");
  const branch = t.branch ?? (t.detached ? "(detached)" : "?");

  const dirtyLines = t.path
    ? git(t.path, ["status", "--porcelain"]).split("\n").filter(Boolean)
    : [];
  const dirty = dirtyLines.length;

  const aheadMain = Number(git(t.path, ["rev-list", "--count", "origin/main..HEAD"], "0")) || 0;

  // pushed? compare local branch tip to its remote-tracking ref
  let pushed = null; // null = unknown/no remote branch
  if (t.branch) {
    const remoteSha = git(
      t.path,
      ["rev-parse", "--verify", "--quiet", `refs/remotes/origin/${t.branch}`],
      "",
    );
    if (remoteSha) pushed = remoteSha === t.head;
  }

  const pr = t.branch ? prsByBranch.get(t.branch) : undefined;
  const bdIds = bdIdsFromBranch(t.path);
  const bdStatuses = bdIds.map((id) =>
    bdById.get(id) ? `${id}:${bdById.get(id).status}` : `${id}:gone`,
  );

  // ---- state machine, most-loose first ----
  let state, hint;
  const prMerged = pr && (pr.state === "MERGED" || pr.mergedAt);
  const isMain = t.branch === "main";

  if (dirty > 0) {
    state = "DIRTY";
    hint = `${dirty} uncommitted file(s) — commit or stash`;
  } else if (aheadMain > 0 && pushed === false) {
    state = "UNPUSHED";
    hint = `${aheadMain} commit(s) ahead, local is ahead of origin/${t.branch} — push`;
  } else if (aheadMain > 0 && pushed === null && !isMain) {
    state = "UNPUSHED";
    hint = `${aheadMain} commit(s) ahead, no origin branch — push`;
  } else if (aheadMain > 0 && !pr && !isMain) {
    state = "NO_PR";
    hint = `pushed, ${aheadMain} commit(s) ahead, no PR — open one`;
  } else if (pr && !prMerged && pr.state === "OPEN") {
    state = pr.isDraft ? "PR_DRAFT" : "PR_OPEN";
    hint = `PR #${pr.number} ${pr.isDraft ? "(draft)" : "in review"} — ${pr.url}`;
  } else if (prMerged && !isMain) {
    state = "MERGED_STALE";
    hint = `PR #${pr.number} merged — prune: git worktree remove ${t.path} && git branch -D ${t.branch}`;
  } else if (!isMain && aheadMain === 0 && dirty === 0) {
    state = "ORPHAN";
    hint = `at origin/main, no diff, no changes — prune: git worktree remove ${t.path} && git branch -D ${t.branch}`;
  } else {
    state = "CLEAN";
    hint = isMain ? "main working tree" : "";
  }

  return {
    state,
    path: t.path,
    short,
    branch,
    dirty,
    aheadMain,
    pushed,
    pr: pr ? { number: pr.number, state: pr.state, draft: pr.isDraft, url: pr.url } : null,
    bd: bdStatuses,
    hint,
  };
}

const ORDER = {
  DIRTY: 0,
  UNPUSHED: 1,
  NO_PR: 2,
  PR_DRAFT: 3,
  PR_OPEN: 4,
  MERGED_STALE: 5,
  ORPHAN: 6,
  CLEAN: 7,
};
const LOOSE = new Set(["DIRTY", "UNPUSHED", "NO_PR", "PR_DRAFT"]);

let rows = parseWorktrees().map(classify);

// ---- 4. bd tickets in_progress with no matching branch (claimed, not started)
const branchBdIds = new Set(rows.flatMap((r) => r.bd.map((s) => s.split(":")[0])));
const strandedBd = [];
for (const [id, it] of bdById) {
  const st = (it.status || "").toLowerCase();
  if ((st === "in_progress" || st === "in-progress") && !branchBdIds.has(id)) {
    strandedBd.push({ id, title: it.title || "", status: it.status });
  }
}

rows.sort((a, b) => ORDER[a.state] - ORDER[b.state] || a.short.localeCompare(b.short));
if (looseOnly) rows = rows.filter((r) => LOOSE.has(r.state));

// ---- 5. Output ------------------------------------------------------------
if (asJson) {
  console.log(JSON.stringify({ worktrees: rows, strandedBd }, null, 2));
} else {
  const pad = (s, n) => String(s).padEnd(n);
  const c = process.stdout.isTTY
    ? {
        red: "\x1b[31m",
        yel: "\x1b[33m",
        grn: "\x1b[32m",
        dim: "\x1b[2m",
        cyan: "\x1b[36m",
        rst: "\x1b[0m",
        bold: "\x1b[1m",
      }
    : { red: "", yel: "", grn: "", dim: "", cyan: "", rst: "", bold: "" };
  const color = (st) =>
    st === "DIRTY" || st === "UNPUSHED" || st === "NO_PR"
      ? c.red
      : st === "PR_DRAFT" || st === "PR_OPEN"
        ? c.yel
        : st === "MERGED_STALE" || st === "ORPHAN"
          ? c.dim
          : c.grn;

  console.log(`${c.bold}loose-work scan${c.rst} ${c.dim}(${repoRoot})${c.rst}\n`);
  console.log(
    `${c.dim}${pad("STATE", 13)}${pad("LOCATION", 14)}${pad("BRANCH", 26)}${pad("DIRTY", 6)}${pad("AHEAD", 6)}${pad("PR", 8)}BD${c.rst}`,
  );
  for (const r of rows) {
    const prCell = r.pr ? `#${r.pr.number}${r.pr.draft ? "d" : ""}` : "-";
    const bdCell = r.bd.length ? r.bd.join(",") : "-";
    console.log(
      `${color(r.state)}${pad(r.state, 13)}${c.rst}${pad(r.short, 14)}${pad(r.branch, 26)}${pad(r.dirty || "-", 6)}${pad(r.aheadMain || "-", 6)}${pad(prCell, 8)}${bdCell}`,
    );
    if (r.hint) console.log(`  ${c.dim}↳ ${r.hint}${c.rst}`);
  }

  if (strandedBd.length) {
    console.log(`\n${c.bold}bd tickets in_progress with no branch:${c.rst}`);
    for (const b of strandedBd) console.log(`  ${c.cyan}${b.id}${c.rst} ${b.title}`);
  }

  const loose = rows.filter((r) => LOOSE.has(r.state)).length;
  const cleanup = rows.filter((r) => r.state === "MERGED_STALE" || r.state === "ORPHAN").length;
  console.log(
    `\n${c.bold}summary:${c.rst} ${loose} loose · ${cleanup} prunable · ${rows.length} worktrees${strandedBd.length ? ` · ${strandedBd.length} stranded bd` : ""}`,
  );
}

if (looseOnly && rows.length > 0) process.exit(1);
