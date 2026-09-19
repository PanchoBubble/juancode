#!/usr/bin/env node
// Global "loose work" scanner for parallel-agent workflows.
//
// Reads git reality first (worktrees + dirty trees + unpushed commits), then
// layers GitHub PR state and bd (beads) ticket state on top, joined by the bd
// ID embedded in commit messages (e.g. "... (juancode-nez)"). gh only sees
// pushed PRs, so it can never be the primary source: a dirty or unpushed tree
// is invisible to it. This walks the worktrees, so nothing needs to register.
//
// The git/gh/bd reading lives in lib/worktree-scan.mjs, shared with
// worktree-sweep.mjs — the sweeper deletes trees this scanner calls clean, so
// they must answer "is anything here unique to this tree?" the same way.
//
// Usage:
//   node scripts/worktree-status.mjs            human table
//   node scripts/worktree-status.mjs --json     machine output (for agents/hooks)
//   node scripts/worktree-status.mjs --fetch    refresh remote-tracking refs first (slower)
//   node scripts/worktree-status.mjs --loose    only rows that need attention (exit 1 if any)

import {
  bdIdsFromBranch,
  classifyLooseness,
  fetchRemotes,
  inspectWorktree,
  loadBdById,
  loadPrsByBranch,
  parseWorktrees,
  repoRootOf,
} from "./lib/worktree-scan.mjs";

const args = new Set(process.argv.slice(2));
const asJson = args.has("--json");
const doFetch = args.has("--fetch");
const looseOnly = args.has("--loose");

const repoRoot = repoRootOf(process.cwd());
if (!repoRoot) {
  console.error("not inside a git repository");
  process.exit(2);
}

if (doFetch) fetchRemotes(repoRoot);

const { prs: prsByBranch } = loadPrsByBranch();
const bdById = loadBdById();

function classify(t) {
  const info = inspectWorktree(t, { repoRoot, prs: prsByBranch });
  const { state, hint } = classifyLooseness(info);
  const bdIds = bdIdsFromBranch(t.path);
  const bd = bdIds.map((id) => (bdById.get(id) ? `${id}:${bdById.get(id).status}` : `${id}:gone`));
  return {
    state,
    path: info.path,
    short: info.short,
    branch: info.branch,
    dirty: info.dirty,
    aheadMain: info.aheadMain,
    pushed: info.pushed,
    pr: info.pr
      ? { number: info.pr.number, state: info.pr.state, draft: info.pr.draft, url: info.pr.url }
      : null,
    bd,
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

let rows = parseWorktrees(repoRoot).map(classify);

// ---- bd tickets in_progress with no matching branch (claimed, not started) ----
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

// ---- Output ---------------------------------------------------------------
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
