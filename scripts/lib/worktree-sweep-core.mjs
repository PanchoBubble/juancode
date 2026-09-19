// The verdict half of the worktree sweeper: given everything we know about one
// worktree, may it be removed?
//
// Pure on purpose. This function is the whole ticket — the LaunchAgent and the
// `git worktree remove` call are plumbing — so it is separated from every source
// of truth it depends on and tested against a fixture of fake worktrees. No
// filesystem, no network, no git.
//
// THE ONE RULE: a KEEP is cheap and a REMOVE is not. A worktree kept by mistake
// costs disk. A worktree removed by mistake costs work that existed nowhere
// else. Those are not comparable, so every ambiguity below resolves to KEEP —
// including "we could not tell".

export const DEFAULT_MAX_AGE_DAYS = 2;
export const DAY_MS = 24 * 60 * 60 * 1000;

/** Is `p` inside (or equal to) `root`? Prefix-safe: /a/bc is not inside /a/b. */
export function isUnder(p, root) {
  if (!p || !root) return false;
  const a = p.replace(/\/+$/, "");
  const b = root.replace(/\/+$/, "");
  return a === b || a.startsWith(b + "/");
}

export function formatAge(ms) {
  if (!Number.isFinite(ms) || ms < 0) return "unknown";
  const h = ms / 3600000;
  if (h < 48) return `${h.toFixed(1)}h`;
  return `${(h / 24).toFixed(1)}d`;
}

/**
 * @param {object} c   candidate: the git facts (see inspectWorktree) plus
 *                     `mtimeMs` and `liveReasons` (strings; non-empty = live).
 * @param {object} opts { nowMs, maxAgeMs, protectedPaths }
 * @returns {{ verdict: "remove"|"keep", code: string, reason: string, ageMs: number }}
 */
export function decide(c, opts = {}) {
  const nowMs = opts.nowMs ?? Date.now();
  const maxAgeMs = opts.maxAgeMs ?? DEFAULT_MAX_AGE_DAYS * DAY_MS;
  const protectedPaths = opts.protectedPaths ?? [];
  const ageMs = Number.isFinite(c.mtimeMs) ? nowMs - c.mtimeMs : NaN;
  const keep = (code, reason) => ({ verdict: "keep", code, reason, ageMs });

  // --- things that are never candidates, whatever their git state ----------
  if (c.readable === false) {
    return keep("UNREADABLE", "git could not report this tree's status — never guess");
  }
  if (c.isMain) return keep("MAIN_CHECKOUT", "the main checkout");
  if (c.onMainBranch) return keep("MAIN_BRANCH", "checked out on main");
  for (const p of protectedPaths) {
    if (isUnder(c.path, p)) return keep("PROTECTED", `inside a protected path (${p})`);
  }
  if (c.locked) return keep("LOCKED", "git worktree is locked");

  // --- somebody is sitting in it -------------------------------------------
  // Re-derived immediately before every removal, not once per run: agent
  // sessions start and stop while this script is walking the list.
  if (c.liveReasons && c.liveReasons.length) {
    return keep("LIVE", `live session: ${c.liveReasons.join("; ")}`);
  }

  // --- work that exists only here ------------------------------------------
  if (c.dirty > 0) return keep("DIRTY", `${c.dirty} uncommitted file(s)`);

  // pushed === false: ahead of its own remote branch. pushed === null: there is
  // no remote branch at all, so gh has never seen it and neither has anyone
  // else. Both mean the commits live only in this tree.
  if (c.aheadMain > 0 && c.pushed !== true) {
    const why = c.pushed === null ? "no origin branch" : `ahead of origin/${c.branch}`;
    return keep("UNPUSHED", `${c.aheadMain} unpushed commit(s) (${why})`);
  }
  if (c.aheadMain > 0 && !(c.pr && c.pr.merged)) {
    const pr = c.pr ? `PR #${c.pr.number} ${c.pr.state}` : "no PR";
    return keep("UNMERGED", `${c.aheadMain} commit(s) not in origin/main (${pr})`);
  }
  if (c.pr && c.pr.state === "OPEN" && !c.pr.merged) {
    return keep("PR_OPEN", `open PR #${c.pr.number}`);
  }

  // --- age, measured from last MODIFIED ------------------------------------
  if (!Number.isFinite(ageMs)) {
    return keep("NO_MTIME", "could not read a modification time");
  }
  if (ageMs < maxAgeMs) {
    return keep("FRESH", `modified ${formatAge(ageMs)} ago`);
  }

  const settled =
    c.pr && c.pr.merged ? `PR #${c.pr.number} merged` : "nothing ahead of origin/main";
  return {
    verdict: "remove",
    code: "STALE",
    reason: `idle ${formatAge(ageMs)}, clean, ${settled}, nothing running in it`,
    ageMs,
  };
}
