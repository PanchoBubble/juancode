import type { PrActivity } from "./gh.ts";
import type { PrChecks, TrackState } from "./protocol.ts";

/**
 * Pure tracked-PR classification + prompt builders for the Node dev server
 * (juancode-yow). A faithful port of the native engine's `JuancodeServices/
 * TrackedPr.swift`: the poller's only jobs are (1) detect *new* activity (comments,
 * reviews, CI status) via the real `gh` CLI, (2) classify each change as
 * auto-fixable vs needs-a-human-decision, and (3) hand the work to the genuine
 * agent CLI by injecting a prompt into its session, exactly as if the user typed
 * it. The agent then uses its own `gh`/`git` to read CI logs, amend, and push.
 *
 * Classification is a coarse, deterministic heuristic at this layer (the agent
 * makes the real call): an explicit `CHANGES_REQUESTED` review is a human gate →
 * needs-decision; plain comments, `COMMENTED` reviews, and CI going red →
 * auto-fix. The injected fix prompt itself instructs the agent to stop and
 * escalate if it hits genuine ambiguity.
 *
 * Kept pure (no `gh`/session side effects) so it can be unit-tested in isolation,
 * exactly like the Swift original.
 */

/**
 * The diffable baseline for one tracked PR: which comments/reviews we've already
 * reacted to, and the last CI status we saw. `baselined` is false until the first
 * successful poll, so we don't fire events for activity that predates tracking.
 */
export interface PrTrackSnapshot {
  seenCommentIds: Set<string>;
  seenReviewIds: Set<string>;
  checks: PrChecks;
  baselined: boolean;
}

/** A fresh, un-baselined snapshot (nothing seen yet). */
export function emptySnapshot(): PrTrackSnapshot {
  return { seenCommentIds: new Set(), seenReviewIds: new Set(), checks: "none", baselined: false };
}

/** A classified change detected between two polls. */
export type TrackEvent =
  /** The agent should attempt this autonomously (with a human reason for the UI). */
  | { kind: "autoFix"; reason: string }
  /** Surface to the user; do NOT auto-apply. */
  | { kind: "needsDecision"; reason: string };

/** Result of classifying one poll: the advanced baseline + the events detected. */
export interface PrClassification {
  snapshot: PrTrackSnapshot;
  events: TrackEvent[];
}

/**
 * Diff a freshly-polled `PrActivity` against the prior baseline and classify what
 * changed. Pure and deterministic — the heart of the poller, unit-tested without
 * spawning anything.
 *
 * On the first poll (`!prev.baselined`) we only record the baseline and emit no
 * events, so tracking an already-busy PR doesn't replay its whole history.
 */
export function classifyPrActivity(prev: PrTrackSnapshot, activity: PrActivity): PrClassification {
  const next: PrTrackSnapshot = {
    seenCommentIds: new Set(activity.comments.map((c) => c.id)),
    seenReviewIds: new Set(activity.reviews.map((r) => r.id)),
    checks: activity.checks,
    baselined: true,
  };

  if (!prev.baselined) return { snapshot: next, events: [] };

  const events: TrackEvent[] = [];

  const newComments = activity.comments.filter((c) => !prev.seenCommentIds.has(c.id));
  if (newComments.length > 0) {
    const who = orderedUniqueAuthors(newComments.map((c) => c.author));
    const n = newComments.length;
    events.push({
      kind: "autoFix",
      reason: `${n} new comment${n === 1 ? "" : "s"}${who ? ` from ${who}` : ""}`,
    });
  }

  for (const r of activity.reviews) {
    if (prev.seenReviewIds.has(r.id)) continue;
    const who = r.author ? `@${r.author}` : "a reviewer";
    if (r.state === "CHANGES_REQUESTED") {
      events.push({ kind: "needsDecision", reason: `${who} requested changes` });
    } else if (r.state === "COMMENTED" && r.body.trim() !== "") {
      events.push({ kind: "autoFix", reason: `New review from ${who}` });
    }
    // APPROVED / DISMISSED / PENDING — informational, no action.
  }

  if (prev.checks !== "failing" && activity.checks === "failing") {
    events.push({ kind: "autoFix", reason: "CI checks are failing" });
  }

  return { snapshot: next, events };
}

/**
 * Comma-join distinct, non-empty `@author`s in first-seen order (for summaries).
 * Mirrors the Swift `orderedUniqueAuthors`.
 */
export function orderedUniqueAuthors(logins: string[]): string {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const l of logins) {
    if (l && !seen.has(l)) {
      seen.add(l);
      out.push(`@${l}`);
    }
  }
  return out.join(", ");
}

/**
 * Derive the badge state from CI status + outstanding decisions. Deterministic so
 * the UI is a pure function of the tracked PR's data. Mirrors Swift's
 * `deriveTrackState` (with the wire's snake_case `needs_decision`).
 */
export function deriveTrackState(checks: PrChecks, hasOpenDecision: boolean): TrackState {
  if (hasOpenDecision) return "needs_decision";
  switch (checks) {
    case "failing":
    case "pending":
      return "fixing";
    case "passing":
    case "none":
      return "watching";
  }
}

/**
 * The seed prompt handed to the tracking session when the user clicks "Track".
 * Establishes the PR context and the auto-fix-vs-escalate contract once, up front.
 */
export function trackSeedPrompt(opts: {
  number: number;
  title: string;
  branch: string;
  url: string;
}): string {
  const { number, title, branch, url } = opts;
  return `[juancode PR-tracker] You are now tracking pull request #${number} "${title}" (branch \`${branch}\`): ${url}

I'll periodically tell you when there's new activity on this PR — new review comments or a change in CI status. When I do:
- If it's an obvious fix (a lint/format/type error, a clearly-correct test fix, or addressing a concrete review comment), make the change, commit, and push to \`${branch}\`.
- If it needs a real decision (ambiguous feedback, conflicting requirements, a risky refactor, or a non-obvious failure), STOP and explain what you need from me instead of guessing.

Start by reviewing the PR and its diff with \`gh pr view ${number}\` and \`gh pr diff ${number}\`.`;
}

/**
 * The prompt injected mid-session when the poller detects auto-fixable activity.
 * Summarises what changed and re-states the fix-or-escalate contract; the agent
 * reads the specifics itself via `gh`.
 */
export function autoFixPrompt(opts: { number: number; branch: string; reasons: string[] }): string {
  const { number, branch, reasons } = opts;
  const summary = reasons.length === 0 ? "new activity" : reasons.join("; ");
  return `[juancode PR-tracker] New activity on PR #${number}: ${summary}. Check the latest state with \`gh pr view ${number}\`, \`gh pr checks ${number}\`, and \`gh pr diff ${number}\`. If it's an obvious fix, make it, commit, and push to \`${branch}\`. If it needs a real decision, STOP and tell me what you need.`;
}
