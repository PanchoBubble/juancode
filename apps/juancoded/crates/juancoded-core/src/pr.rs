//! What a tracked pull request is, and how one poll's worth of GitHub activity is
//! read.
//!
//! A port of the pure half of `JuancodeServices/TrackedPr.swift`. Everything here is
//! deterministic and spawns nothing: the watch list's shape, the diff between two
//! polls, and the two prompts the agent is handed. The `gh` round-trips live in
//! [`crate::gh`] and the watch list itself in the server crate, so the interesting
//! decision — auto-fix or escalate — is testable without a process or a socket.
//!
//! The philosophy travels with the code. juancode does not review or fix a PR itself:
//! the poller detects *new* activity, classifies it as obviously-fixable or
//! needs-a-human, and hands the work to the genuine agent CLI by typing a prompt into
//! its session. Classification is a coarse, deterministic heuristic on purpose — an
//! explicit `CHANGES_REQUESTED` is a human gate, plain comments and red CI are fix
//! attempts, and the injected prompt itself tells the agent to stop and escalate when
//! it hits real ambiguity.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::model::now_ms;

/// A PR's rolled-up CI colour. The wire spellings, because a client renders them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PrChecks {
    Passing,
    Failing,
    Pending,
    /// No checks at all, which is not the same as none of them having run.
    #[default]
    None,
}

impl PrChecks {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Passing => "passing",
            Self::Failing => "failing",
            Self::Pending => "pending",
            Self::None => "none",
        }
    }
}

/// What a tracked PR is currently doing, surfaced as a badge in the UI.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrackState {
    /// CI green / nothing outstanding — just watching for new activity.
    Watching,
    /// CI is red or running, or new comments were just handed to the agent.
    Fixing,
    /// A change needs the user — the poller will NOT auto-apply it.
    NeedsDecision,
}

impl TrackState {
    /// The wire spelling, which is snake_cased where the enum is not: a client
    /// written against the Swift core reads `needs_decision` and nothing else.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Watching => "watching",
            Self::Fixing => "fixing",
            Self::NeedsDecision => "needs_decision",
        }
    }
}

/// A surfaced decision the agent should not make on its own.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrackNotification {
    pub id: String,
    pub pr_number: i64,
    pub message: String,
    pub created_at: i64,
}

impl TrackNotification {
    pub fn now(pr_number: i64, message: impl Into<String>) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            pr_number,
            message: message.into(),
            created_at: now_ms(),
        }
    }
}

/// The diffable baseline for one tracked PR: which comments and reviews have already
/// been reacted to, and the last CI colour seen.
///
/// `baselined` is false until the first successful poll, so tracking a PR that is
/// already busy does not replay its whole history as new activity.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrBaseline {
    #[serde(default)]
    pub seen_comment_ids: BTreeSet<String>,
    #[serde(default)]
    pub seen_review_ids: BTreeSet<String>,
    #[serde(default)]
    pub checks: PrChecks,
    #[serde(default)]
    pub baselined: bool,
    /// The last mergeability GitHub settled on. Held across an `UNKNOWN` poll, so a
    /// recompute after the base moves cannot read as the conflict going away and
    /// coming back.
    #[serde(default)]
    pub conflicting: bool,
}

/// One PR under continuous watch: its identity, the agent session driving fixes, the
/// diff baseline, and any outstanding decisions.
///
/// The badge `state` is derived rather than stored, so it cannot drift from the CI
/// colour and the open decisions it is a function of.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrackedPr {
    pub id: String,
    pub number: i64,
    pub title: String,
    pub url: String,
    pub branch: String,
    /// The REPO the PR belongs to, which is the identity every surface looks tracking
    /// up by — never the worktree the agent happens to be standing in.
    pub cwd: String,
    /// The agent session seeded with this PR's context, where fix prompts land.
    pub session_id: Option<String>,
    /// The repo's `owner/name`, resolved through `gh` after tracking starts. Nil until
    /// it resolves (and on rows written before it existed), so it is never a key
    /// anything requires.
    pub repo_nwo: Option<String>,
    pub baseline: PrBaseline,
    pub notifications: Vec<TrackNotification>,
    pub last_polled_at: Option<i64>,
    pub created_at: i64,
}

/// The `owner/name` a PR url names, lowercased, or `None` when the url is not a
/// GitHub PR url.
///
/// The fallback half of webhook matching: a watch stores its repo identity only once
/// a `gh repo view` has resolved it, so a PR tracked seconds ago — or one written
/// before the field existed — has `repo_nwo: None` and would match no event at all.
/// The url it was tracked with names the same repo and needs no round trip.
pub fn repo_slug_from_pr_url(url: &str) -> Option<String> {
    let rest = url.split_once("github.com/")?.1;
    let mut parts = rest.split('/');
    let owner = parts.next().filter(|s| !s.is_empty())?;
    let name = parts.next().filter(|s| !s.is_empty())?;
    // Only a PR url, so a repo url or an issue url cannot be read as one.
    (parts.next() == Some("pull")).then(|| format!("{owner}/{name}").to_lowercase())
}

impl TrackedPr {
    /// The identity of a watch: one PR number in one checkout. Two clones of a repo
    /// tracking the same PR are two watches, because their agents stand in different
    /// trees.
    pub fn key(cwd: &str, number: i64) -> String {
        format!("{cwd}#{number}")
    }

    pub fn state(&self) -> TrackState {
        let state = derive_track_state(self.baseline.checks, !self.notifications.is_empty());
        if state == TrackState::Watching && self.baseline.conflicting {
            return TrackState::Fixing;
        }
        state
    }
}

/// Derive the badge state from CI colour plus outstanding decisions, so the row a
/// client renders is a pure function of the tracked PR's data.
pub fn derive_track_state(checks: PrChecks, has_open_decision: bool) -> TrackState {
    if has_open_decision {
        return TrackState::NeedsDecision;
    }
    match checks {
        PrChecks::Failing | PrChecks::Pending => TrackState::Fixing,
        PrChecks::Passing | PrChecks::None => TrackState::Watching,
    }
}

/// One issue comment on a PR (`gh pr view --json comments`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrComment {
    pub id: String,
    pub author: String,
    pub body: String,
}

/// One review on a PR. `state` is GitHub's own review state, upper-cased:
/// APPROVED / CHANGES_REQUESTED / COMMENTED / DISMISSED / PENDING.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrReview {
    pub id: String,
    pub author: String,
    pub body: String,
    pub state: String,
}

/// A snapshot of a PR's reviewable activity: what the poller diffs each tick.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrActivity {
    /// GitHub's PR state, upper-cased: OPEN / CLOSED / MERGED. Drives auto-untrack.
    pub state: String,
    pub checks: PrChecks,
    pub comments: Vec<PrComment>,
    pub reviews: Vec<PrReview>,
    /// `Some(true)` when the PR conflicts with its base, `None` while GitHub is still
    /// computing it.
    pub conflicting: Option<bool>,
    /// The branch the PR merges into, empty when gh did not say.
    pub base_branch: String,
    /// The repo's default branch, empty when gh did not say. A PR whose base is some
    /// other branch is stacked on another PR, see [`stacked_base`].
    pub default_branch: String,
    /// The PR author's login, empty when GitHub reported none. Read in the same call as
    /// everything else here, and carried because "is this PR mine" is the first of
    /// GitHub Desktop's notification rules (juancode-2vlz) and a poll has nowhere else
    /// to learn it from.
    pub author: String,
}

/// A classified change detected between two polls.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TrackEvent {
    /// The agent should attempt this on its own, with a human reason for the UI.
    AutoFix(String),
    /// Surface to the user; do NOT auto-apply.
    NeedsDecision(String),
    /// The PR is no longer open (merged or closed) — stop tracking it.
    Closed(String),
}

/// One poll's outcome: the advanced baseline plus the events detected.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrClassification {
    pub baseline: PrBaseline,
    pub events: Vec<TrackEvent>,
}

/// Diff a freshly-polled [`PrActivity`] against the prior baseline and classify what
/// changed.
///
/// On the first poll (`!prev.baselined`) only the baseline is recorded and no events
/// are emitted, so tracking an already-busy PR does not replay its history.
///
/// `viewer_login` is the authenticated `gh` account the tracking agent posts as. Its
/// own comments and reviews — its code review, its `@mergifyio queue`, its replies —
/// are not new activity: reacting to them re-fires the poller and drives the agent to
/// comment again, an echo loop. So self-authored items go into the baseline (they
/// never re-surface) and generate nothing. Empty means no filter.
pub fn classify_pr_activity(
    prev: &PrBaseline,
    activity: &PrActivity,
    viewer_login: &str,
) -> PrClassification {
    let next = PrBaseline {
        seen_comment_ids: activity.comments.iter().map(|c| c.id.clone()).collect(),
        seen_review_ids: activity.reviews.iter().map(|r| r.id.clone()).collect(),
        checks: activity.checks,
        baselined: true,
        conflicting: activity.conflicting.unwrap_or(prev.conflicting),
    };

    // A merged/closed PR is terminal. Emitted even before the first baseline, so
    // tracking an already-merged PR untracks immediately, and nothing else is
    // classified: there is no longer anything to fix or decide.
    if activity.state == "MERGED" || activity.state == "CLOSED" {
        let reason = if activity.state == "MERGED" {
            "PR was merged — stopped tracking"
        } else {
            "PR was closed — stopped tracking"
        };
        return PrClassification {
            baseline: next,
            events: vec![TrackEvent::Closed(reason.into())],
        };
    }

    if !prev.baselined {
        return PrClassification {
            baseline: next,
            events: Vec::new(),
        };
    }

    let viewer = viewer_login.to_lowercase();
    let is_self = |author: &str| !viewer.is_empty() && author.to_lowercase() == viewer;

    let mut events = Vec::new();

    let new_comments: Vec<&PrComment> = activity
        .comments
        .iter()
        .filter(|c| !prev.seen_comment_ids.contains(&c.id) && !is_self(&c.author))
        .collect();
    if !new_comments.is_empty() {
        let who = ordered_unique_authors(new_comments.iter().map(|c| c.author.as_str()));
        let n = new_comments.len();
        let plural = if n == 1 { "" } else { "s" };
        let from = if who.is_empty() {
            String::new()
        } else {
            format!(" from {who}")
        };
        events.push(TrackEvent::AutoFix(format!(
            "{n} new comment{plural}{from}"
        )));
    }

    let new_reviews: Vec<&PrReview> = activity
        .reviews
        .iter()
        .filter(|r| !prev.seen_review_ids.contains(&r.id) && !is_self(&r.author))
        .collect();
    for r in &new_reviews {
        let who = if r.author.is_empty() {
            "a reviewer".to_string()
        } else {
            format!("@{}", r.author)
        };
        match r.state.as_str() {
            "CHANGES_REQUESTED" => events.push(TrackEvent::NeedsDecision(format!(
                "{who} requested changes"
            ))),
            "COMMENTED" if !r.body.trim().is_empty() => {
                events.push(TrackEvent::AutoFix(format!("New review from {who}")))
            }
            // APPROVED / DISMISSED / PENDING, and an empty COMMENTED body:
            // informational, no action.
            _ => {}
        }
    }

    if prev.checks != PrChecks::Failing && activity.checks == PrChecks::Failing {
        events.push(TrackEvent::AutoFix("CI checks are failing".into()));
    }

    // GitHub does not run `pull_request` CI on a PR it cannot merge, so a conflict
    // usually arrives with green or empty checks and has to be its own signal.
    if !prev.conflicting && next.conflicting {
        events.push(TrackEvent::AutoFix(conflict_reason(
            &activity.base_branch,
            stacked_base(&activity.base_branch, &activity.default_branch).is_some(),
        )));
    }

    // Codex normally reviews a PR before it is queued for merge. When it posts that it
    // is out of review capacity, Claude has to step in and review the PR itself (see
    // `track_seed_prompt`), so that is its own auto-fix signal.
    let codex_tapped_out = new_comments
        .iter()
        .any(|c| is_codex_review_limit_notice(&c.body))
        || new_reviews
            .iter()
            .any(|r| is_codex_review_limit_notice(&r.body));
    if codex_tapped_out {
        events.push(TrackEvent::AutoFix(
            "Codex is out of review capacity — review the PR yourself, then `@mergifyio queue`"
                .into(),
        ));
    }

    PrClassification {
        baseline: next,
        events,
    }
}

/// Level-triggered recovery for a tracked PR whose CI is red with nobody on it.
///
/// [`classify_pr_activity`] is edge-triggered: it reports failing CI only on the
/// transition *into* failing. That is right for "CI just broke", and it means a PR
/// whose driving session died while CI was already red would never be worked again —
/// every later poll sees failing → failing, emits nothing, and the revive ladder never
/// runs. So each poll also asks this: red CI must always have a live agent on it.
///
/// Nothing when the session is live (an agent already working the PR must not be
/// re-prompted every tick) or when the poll already produced fix work (that prompt
/// revives the session by itself).
pub fn stalled_ci_fix_reason(
    checks: PrChecks,
    session_live: bool,
    has_pending_fixes: bool,
) -> Option<String> {
    if checks != PrChecks::Failing || session_live || has_pending_fixes {
        return None;
    }
    Some("CI is still failing and the session that was working this PR is gone".into())
}

/// The conflict counterpart of [`stalled_ci_fix_reason`]: a PR that conflicts with its
/// base must always have a live agent on it, for the same edge-triggered reason.
pub fn stalled_conflict_fix_reason(
    conflicting: bool,
    session_live: bool,
    has_pending_fixes: bool,
) -> Option<String> {
    if !conflicting || session_live || has_pending_fixes {
        return None;
    }
    Some("The PR still conflicts with its base and the session that was working it is gone".into())
}

/// The base a PR is stacked on, or `None` when it merges into the repo's default
/// branch — or when either side is unknown, because then there is nothing to say it is
/// stacked and the seed prompt's own "check the base" rule still covers it.
pub fn stacked_base<'a>(base_branch: &'a str, default_branch: &str) -> Option<&'a str> {
    let default = default_branch
        .strip_prefix("origin/")
        .unwrap_or(default_branch);
    (!base_branch.is_empty() && !default.is_empty() && base_branch != default)
        .then_some(base_branch)
}

fn conflict_reason(base_branch: &str, stacked: bool) -> String {
    if stacked {
        return format!(
            "Conflicts with `{base_branch}`, the PR this one is stacked on: rebase this \
             branch onto `origin/{base_branch}` (do not merge it in), resolve the conflicts, \
             run the tests and `git push --force-with-lease`"
        );
    }
    let base = if base_branch.is_empty() {
        "its base branch".to_string()
    } else {
        format!("`{base_branch}`")
    };
    format!(
        "Merge conflicts with {base}: fetch it, merge it into this branch, resolve the \
         conflicts, run the tests and push"
    )
}

/// How a branch takes in its base's new commits, which depends on whether the PR is
/// stacked. A PR against the default branch merges the base in, so its history is
/// never rewritten under a reviewer. A stacked PR is rebased instead: merging the parent
/// in leaves a merge commit on every child each time the parent is pushed, and those
/// are what get in the way when the stack is rebased onto main.
///
/// `stacked_on` is the parent's branch when the tracker knows it; `None` states both
/// rules and leaves the agent to check which one this PR is.
fn base_update_rule(number: i64, stacked_on: Option<&str>) -> String {
    let rebase = |base: &str| {
        format!(
            "update it by REBASING onto the current parent, never by merging the parent in: \
             `git fetch origin`, then `git rebase --onto origin/{base} <old-parent-commit>` \
             (or a plain `git rebase origin/{base}` if that is cleaner), resolve, run the \
             tests and `git push --force-with-lease`. Drop any earlier \
             \"Merge remote-tracking branch 'origin/{base}'\" or \"Merge branch '{base}'\" \
             commits during the rebase. Keep the PR open and keep `{base}` as its base, and \
             never merge one stack branch into another"
        )
    };
    match stacked_on {
        Some(base) => format!(
            "- This PR is STACKED on `{base}` (another PR's branch, not the repo's default \
             branch). When it conflicts with `{base}` or `{base}` moves, {}.",
            rebase(base)
        ),
        None => format!(
            "- Check the PR's base first (`gh pr view {number} --json baseRefName` against \
             `gh repo view --json defaultBranchRef`). If the base is NOT the repo's default \
             branch, this PR is stacked on another PR: when it conflicts with its base or the \
             base moves, {}.",
            rebase("<base>")
        ),
    }
}

/// True when a comment or review body is Codex reporting it could not review the PR
/// because it hit its usage limits — the signal for Claude to review it instead.
fn is_codex_review_limit_notice(body: &str) -> bool {
    body.to_lowercase()
        .contains("usage limits for code reviews")
}

/// Comma-join distinct, non-empty `@author`s in first-seen order, for a summary line.
fn ordered_unique_authors<'a>(logins: impl Iterator<Item = &'a str>) -> String {
    let mut seen = BTreeSet::new();
    let mut out = Vec::new();
    for login in logins {
        if login.is_empty() || !seen.insert(login) {
            continue;
        }
        out.push(format!("@{login}"));
    }
    out.join(", ")
}

/// Where the tracking agent is standing, for the seed prompt.
///
/// `branch: None` is a detached checkout: git allows one worktree per branch, so a PR
/// branch already open elsewhere can only be read from a detached HEAD, and an agent
/// told that up front is one that does not discover it halfway through a fix.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BranchWorktree {
    pub path: String,
    pub branch: Option<String>,
}

/// Where a repo keeps its own `/pr` skill, relative to the checkout root. luma-core
/// ships one; the server crate stats it and hands the answer to the prompts below as
/// `pr_skill`.
pub const PR_SKILL_PATH: &str = ".claude/skills/pr/SKILL.md";

/// The seed prompt handed to the tracking session when a PR starts being watched.
/// Establishes the PR context and the auto-fix-vs-escalate contract once, up front.
///
/// `pr_skill` (the checkout has a [`PR_SKILL_PATH`]) adds the repo's own workflow on top of the
/// contract, and with it the house rules that only hold in that repo — the Dagger
/// flakes and the Codex → Mergify merge path are luma-core's, not every repo's.
pub fn track_seed_prompt(
    number: i64,
    title: &str,
    branch: &str,
    url: &str,
    worktree: Option<&BranchWorktree>,
    stacked_on: Option<&str>,
    pr_skill: bool,
) -> String {
    let place = match worktree {
        None => String::new(),
        Some(wt) => match &wt.branch {
            Some(b) => format!(
                "\n\nYou're on a dedicated worktree for this PR at `{}`, with `{b}` checked out \
                 — it's yours, so commit and push here freely without touching the main checkout.",
                wt.path
            ),
            None => format!(
                "\n\nYou're on a dedicated worktree for this PR at `{}`. `{branch}` is already \
                 checked out elsewhere, so this one is on a DETACHED HEAD at that branch's head: \
                 to push a fix, create your own branch here first and open it against `{branch}`, \
                 or tell me and I'll free the branch up.",
                wt.path
            ),
        },
    };
    let house = if pr_skill {
        pr_skill_rules(branch, stacked_on.is_some())
    } else {
        String::new()
    };
    let base_rule = base_update_rule(number, stacked_on);
    let default_rule = if stacked_on.is_some() {
        ""
    } else {
        " If its base IS the default branch, merge the base in instead (do not rebase or \
         force-push)."
    };
    format!(
        "[juancode PR-tracker] You are now tracking pull request #{number} \"{title}\" \
         (branch `{branch}`): {url}{place}\n\n\
         Never merge or close a PR yourself (no `gh pr merge`, no `gh pr close`), this one or any other.\n\
         {base_rule}{default_rule}\n\n\
         I'll periodically tell you when there's new activity on this PR — new review comments, \
         a change in CI status, or merge conflicts with its base. When I do:\n\
         - If it's an obvious fix (a lint/format/type error, a clearly-correct test fix, or \
         addressing a concrete review comment), make the change, commit, and push to `{branch}`.\n\
         - If the PR conflicts with its base, bring the base in by the rule above, resolve the \
         conflicts and push. If both sides changed the same logic in ways that do not \
         obviously combine, STOP and show me the conflict instead of picking a side.\n\
         - If it needs a real decision (ambiguous feedback, conflicting requirements, a risky \
         refactor, or a non-obvious failure), STOP and explain what you need from me instead of \
         guessing.{house}\n\n\
         Start by reviewing the PR and its diff with `gh pr view {number}` and \
         `gh pr diff {number}`."
    )
}

/// The `/pr` skill half of [`track_seed_prompt`]: which subcommand answers which kind
/// of activity, and the ones that must never run here. `grind` and an `approve` loop
/// poll CI themselves and `ship`/`merge` stop for a person, while this session runs
/// unattended and the poller is already the loop — so every hand-off is one pass.
fn pr_skill_rules(branch: &str, stacked: bool) -> String {
    // `/pr grind` merges the base and never force-pushes. A stacked PR takes its base by
    // the rebase rule instead, which is the one exception to that.
    let base = if stacked {
        "rebase onto the parent as above rather than merging it, minimal fixes, no other \
         force-push"
    } else {
        "bring the base in by the rule above, minimal fixes, no other rebase or force-push"
    };
    format!(
        "\n\n\
         This repo ships its own `/pr` skill (`{PR_SKILL_PATH}`). Use it — through the Skill \
         tool, one subcommand at a time — rather than improvising:\n\
         - New review comments or reviews: `/pr resolve`. Address every thread, and reply to \
         each one with the commit that fixed it or the reason you are not acting on it.\n\
         - CI failing: fix it by the `/pr grind` rules ({base}), but make ONE pass — push to `{branch}` and stop. I am \
         already watching CI and will tell you if it is still red, so do not poll checks in \
         a loop.\n\
         - Never run `/pr ship`, `/pr merge`, a full `/pr grind` or an `approve` loop from \
         this session: they wait on CI or on a person, and nobody is at this terminal. If a \
         step asks me to confirm something, skip it and tell me at the end instead.\n\n\
         CI flakes: the Dagger checks are known to fail intermittently. If a Dagger check fails \
         and nothing in its logs points to a real problem in this PR's changes, just re-run it \
         (`gh run rerun <run-id> --failed`) rather than treating it as something to fix. Only dig \
         in or escalate if it fails again on the re-run, or the logs show a real error tied to \
         your changes.\n\n\
         Codex review fallback: this PR is normally code-reviewed by Codex, and only added to the \
         Mergify merge queue after that review. If you see a comment saying Codex has reached its \
         usage limits for code reviews (i.e. it couldn't review this PR), do the code review \
         yourself with `/pr review` then `/pr post`, and fix anything clearly wrong per the \
         rules above. Once your review is clean and CI is green, add the PR to the \
         Mergify queue by commenting `@mergifyio queue` on it. If your review turns up something \
         that needs a real decision, STOP and escalate to me instead of queueing."
    )
}

/// The prompt injected mid-session when a poll detects auto-fixable activity.
/// Summarises what changed and re-states the contract; the agent reads the specifics
/// itself through `gh`.
///
/// With `pr_skill` it re-points at the repo's `/pr` skill as well. The seed said so
/// once, but a long-lived tracking session compacts, and a revived one may never have
/// read it.
pub fn auto_fix_prompt(
    number: i64,
    branch: &str,
    reasons: &[String],
    stacked_on: Option<&str>,
    pr_skill: bool,
) -> String {
    let summary = if reasons.is_empty() {
        "new activity".to_string()
    } else {
        reasons.join("; ")
    };
    let stack = match stacked_on {
        Some(base) => format!(
            " This PR is stacked on `{base}`: take in `{base}` by rebasing onto \
             `origin/{base}` and `git push --force-with-lease`, never by merging it in, and \
             drop any earlier merge commits of `{base}`."
        ),
        None => String::new(),
    };
    let skill = if pr_skill {
        " Use this repo's `/pr` skill for it — `/pr resolve` for review feedback (reply to \
         every thread), the `/pr grind` rules for CI — and make one pass: no polling loops, no \
         `ship`, `merge` or `approve`."
    } else {
        ""
    };
    format!(
        "[juancode PR-tracker] New activity on PR #{number}: {summary}. Check the latest state \
         with `gh pr view {number}`, `gh pr checks {number}`, and `gh pr diff {number}`. If it's \
         an obvious fix, make it, commit, and push to `{branch}`.{stack}{skill} Never merge or \
         close a PR yourself. If it needs a real decision, STOP and tell me what you need."
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn activity(state: &str, checks: PrChecks) -> PrActivity {
        PrActivity {
            state: state.into(),
            checks,
            comments: Vec::new(),
            reviews: Vec::new(),
            conflicting: Some(false),
            base_branch: "main".into(),
            default_branch: "main".into(),
            author: "octocat".into(),
        }
    }

    fn comment(id: &str, author: &str, body: &str) -> PrComment {
        PrComment {
            id: id.into(),
            author: author.into(),
            body: body.into(),
        }
    }

    fn review(id: &str, author: &str, state: &str, body: &str) -> PrReview {
        PrReview {
            id: id.into(),
            author: author.into(),
            body: body.into(),
            state: state.into(),
        }
    }

    /// The first poll is a baseline and nothing else: a PR with a hundred comments on
    /// it does not arrive as a hundred fix prompts.
    #[test]
    fn the_first_poll_records_a_baseline_and_emits_nothing() {
        let mut act = activity("OPEN", PrChecks::Failing);
        act.comments = vec![comment("c1", "someone", "look at this")];
        let out = classify_pr_activity(&PrBaseline::default(), &act, "");
        assert!(out.events.is_empty(), "{:?}", out.events);
        assert!(out.baseline.baselined);
        assert!(out.baseline.seen_comment_ids.contains("c1"));
        assert_eq!(out.baseline.checks, PrChecks::Failing);
    }

    /// The auto-fix/escalate split, which is the whole decision this layer makes.
    #[test]
    fn changes_requested_escalates_and_a_plain_comment_does_not() {
        let prev = PrBaseline {
            baselined: true,
            ..Default::default()
        };
        let mut act = activity("OPEN", PrChecks::Passing);
        act.comments = vec![comment("c1", "reviewer", "nit")];
        act.reviews = vec![review("r1", "reviewer", "CHANGES_REQUESTED", "no")];
        let out = classify_pr_activity(&prev, &act, "");
        assert_eq!(
            out.events,
            vec![
                TrackEvent::AutoFix("1 new comment from @reviewer".into()),
                TrackEvent::NeedsDecision("@reviewer requested changes".into()),
            ]
        );
    }

    /// The echo loop this filter exists to stop: the agent's own comment is recorded
    /// as seen but never handed back to it as work.
    #[test]
    fn the_agents_own_activity_is_baselined_but_never_an_event() {
        let prev = PrBaseline {
            baselined: true,
            ..Default::default()
        };
        let mut act = activity("OPEN", PrChecks::Passing);
        act.comments = vec![comment("c1", "TrackerBot", "pushed a fix")];
        let out = classify_pr_activity(&prev, &act, "trackerbot");
        assert!(out.events.is_empty(), "{:?}", out.events);
        assert!(
            out.baseline.seen_comment_ids.contains("c1"),
            "seen, so it cannot re-surface once the login changes"
        );
    }

    /// Red CI is an edge, not a level — and the level is covered separately, which is
    /// the pair that keeps a red PR from being abandoned.
    #[test]
    fn failing_ci_fires_once_and_the_stall_check_covers_the_rest() {
        let prev = PrBaseline {
            baselined: true,
            checks: PrChecks::Passing,
            ..Default::default()
        };
        let broke = classify_pr_activity(&prev, &activity("OPEN", PrChecks::Failing), "");
        assert_eq!(
            broke.events,
            vec![TrackEvent::AutoFix("CI checks are failing".into())]
        );
        let still = classify_pr_activity(&broke.baseline, &activity("OPEN", PrChecks::Failing), "");
        assert!(still.events.is_empty(), "{:?}", still.events);

        assert!(stalled_ci_fix_reason(PrChecks::Failing, true, false).is_none());
        assert!(stalled_ci_fix_reason(PrChecks::Failing, false, true).is_none());
        assert!(stalled_ci_fix_reason(PrChecks::Passing, false, false).is_none());
        assert!(stalled_ci_fix_reason(PrChecks::Failing, false, false).is_some());
    }

    /// A conflict arrives with green checks, because GitHub will not run CI on a PR
    /// it cannot merge, so it is its own auto-fix, once per transition.
    #[test]
    fn a_new_conflict_is_an_auto_fix_and_a_standing_one_is_not() {
        let clean = PrBaseline {
            baselined: true,
            checks: PrChecks::Passing,
            ..Default::default()
        };
        let mut act = activity("OPEN", PrChecks::Passing);
        act.conflicting = Some(true);
        let out = classify_pr_activity(&clean, &act, "");
        assert!(out.baseline.conflicting);
        assert!(
            matches!(&out.events[..], [TrackEvent::AutoFix(r)] if r.contains("`main`")),
            "{:?}",
            out.events
        );

        let again = classify_pr_activity(&out.baseline, &act, "");
        assert!(again.events.is_empty(), "{:?}", again.events);
    }

    /// A PR against the default branch merges its base in; one stacked on another PR
    /// rebases onto it, because merging the parent into every child on every parent push
    /// is what buries a stack in merge commits.
    #[test]
    fn a_conflict_is_merged_against_the_default_branch_and_rebased_when_stacked() {
        let clean = PrBaseline {
            baselined: true,
            ..Default::default()
        };
        let mut act = activity("OPEN", PrChecks::Passing);
        act.conflicting = Some(true);
        let reason = |act: &PrActivity| match &classify_pr_activity(&clean, act, "").events[..] {
            [TrackEvent::AutoFix(r)] => r.clone(),
            other => panic!("{other:?}"),
        };

        let plain = reason(&act);
        assert!(plain.contains("merge it into this branch"), "{plain}");
        assert!(!plain.contains("rebase"), "{plain}");

        act.base_branch = "pr3".into();
        let stacked = reason(&act);
        assert!(stacked.contains("stacked"), "{stacked}");
        assert!(
            stacked.contains("rebase this branch onto `origin/pr3`"),
            "{stacked}"
        );
        assert!(stacked.contains("--force-with-lease"), "{stacked}");
        assert!(!stacked.contains("merge it into"), "{stacked}");

        // A default branch read as a ref (`origin/main`) is still the default branch.
        act.base_branch = "main".into();
        act.default_branch = "origin/main".into();
        assert!(reason(&act).contains("merge it into this branch"));
    }

    #[test]
    fn a_pr_is_stacked_only_when_its_base_is_known_and_not_the_default_branch() {
        assert_eq!(stacked_base("pr3", "main"), Some("pr3"));
        assert_eq!(stacked_base("pr3", "origin/main"), Some("pr3"));
        assert_eq!(stacked_base("main", "main"), None);
        assert_eq!(stacked_base("main", "origin/main"), None);
        assert_eq!(stacked_base("develop", "develop"), None);
        assert_eq!(stacked_base("", "main"), None);
        assert_eq!(stacked_base("pr3", ""), None);
    }

    /// GitHub answers UNKNOWN while it recomputes after a push to the base. Reading
    /// that as clean would re-fire the conflict on the next poll.
    #[test]
    fn an_unknown_mergeable_keeps_the_last_settled_answer() {
        let conflicted = PrBaseline {
            baselined: true,
            conflicting: true,
            ..Default::default()
        };
        let mut act = activity("OPEN", PrChecks::Passing);
        act.conflicting = None;
        let out = classify_pr_activity(&conflicted, &act, "");
        assert!(out.baseline.conflicting);
        assert!(out.events.is_empty(), "{:?}", out.events);

        act.conflicting = Some(false);
        let resolved = classify_pr_activity(&out.baseline, &act, "");
        assert!(!resolved.baseline.conflicting);
        assert!(resolved.events.is_empty(), "{:?}", resolved.events);
    }

    #[test]
    fn a_standing_conflict_with_nobody_on_it_revives_the_session() {
        assert!(stalled_conflict_fix_reason(true, true, false).is_none());
        assert!(stalled_conflict_fix_reason(true, false, true).is_none());
        assert!(stalled_conflict_fix_reason(false, false, false).is_none());
        assert!(stalled_conflict_fix_reason(true, false, false).is_some());
    }

    #[test]
    fn a_conflicting_pr_with_green_ci_badges_as_fixing() {
        let pr = TrackedPr {
            id: "x".into(),
            number: 1,
            title: String::new(),
            url: String::new(),
            branch: "b".into(),
            cwd: "/r".into(),
            session_id: None,
            repo_nwo: None,
            baseline: PrBaseline {
                baselined: true,
                checks: PrChecks::Passing,
                conflicting: true,
                ..Default::default()
            },
            notifications: Vec::new(),
            last_polled_at: None,
            created_at: 0,
        };
        assert_eq!(pr.state(), TrackState::Fixing);
    }

    /// Terminal, and terminal before the baseline: tracking a PR that merged while you
    /// were reading it stops immediately instead of watching a closed PR forever.
    #[test]
    fn a_merged_pr_is_closed_even_on_the_first_poll() {
        let out = classify_pr_activity(
            &PrBaseline::default(),
            &activity("MERGED", PrChecks::Passing),
            "",
        );
        assert_eq!(
            out.events,
            vec![TrackEvent::Closed(
                "PR was merged — stopped tracking".into()
            )]
        );
    }

    #[test]
    fn the_badge_state_follows_ci_unless_a_decision_is_open() {
        assert_eq!(
            derive_track_state(PrChecks::Passing, false),
            TrackState::Watching
        );
        assert_eq!(
            derive_track_state(PrChecks::Failing, false),
            TrackState::Fixing
        );
        assert_eq!(
            derive_track_state(PrChecks::Passing, true),
            TrackState::NeedsDecision
        );
        assert_eq!(TrackState::NeedsDecision.as_str(), "needs_decision");
    }

    /// The seed says where the agent is standing, because "commit and push to the
    /// branch" is a lie on a detached checkout.
    #[test]
    fn the_seed_prompt_names_a_detached_worktree_as_detached() {
        let attached = track_seed_prompt(
            7,
            "t",
            "feature",
            "u",
            Some(&BranchWorktree {
                path: "/w/pr-7".into(),
                branch: Some("feature".into()),
            }),
            None,
            false,
        );
        assert!(attached.contains("with `feature` checked out"));
        assert!(!attached.contains("DETACHED"));

        let detached = track_seed_prompt(
            7,
            "t",
            "feature",
            "u",
            Some(&BranchWorktree {
                path: "/w/pr-7".into(),
                branch: None,
            }),
            None,
            false,
        );
        assert!(detached.contains("DETACHED HEAD"));

        let bare = track_seed_prompt(7, "t", "feature", "u", None, None, false);
        assert!(!bare.contains("worktree"), "{bare}");
    }

    /// A repo with its own `/pr` skill gets that workflow, one pass at a time, and only
    /// that repo gets luma-core's house rules — Dagger flakes and the Codex → Mergify
    /// path mean nothing in a repo that has neither.
    #[test]
    fn the_seed_points_at_the_repos_pr_skill_only_when_it_has_one() {
        let plain = track_seed_prompt(7, "t", "feature", "u", None, None, false);
        assert!(!plain.contains("/pr resolve"), "{plain}");
        assert!(!plain.contains("Dagger"), "{plain}");
        assert!(!plain.contains("mergifyio"), "{plain}");
        assert!(plain.ends_with("`gh pr diff 7`."), "{plain}");

        let skilled = track_seed_prompt(7, "t", "feature", "u", None, None, true);
        assert!(skilled.contains(PR_SKILL_PATH));
        assert!(skilled.contains("`/pr resolve`"));
        assert!(skilled.contains("ONE pass"));
        assert!(skilled.contains("Never run `/pr ship`, `/pr merge`"));
        assert!(skilled.contains("Dagger"));
        assert!(skilled.contains("`/pr review` then `/pr post`"));
        assert!(skilled.ends_with("`gh pr diff 7`."), "{skilled}");
    }

    /// The fix prompt re-states the skill on every hand-off, because the seed that said
    /// it first may have been compacted away by then.
    #[test]
    fn the_fix_prompt_repeats_the_pr_skill_only_when_the_repo_has_one() {
        let reasons = vec!["CI checks are failing".to_string()];
        let plain = auto_fix_prompt(7, "feature", &reasons, None, false);
        assert!(plain.contains("CI checks are failing"));
        assert!(!plain.contains("/pr"), "{plain}");

        let skilled = auto_fix_prompt(7, "feature", &reasons, None, true);
        assert!(skilled.contains("`/pr resolve`"));
        assert!(skilled.contains("one pass"));
        assert!(skilled.ends_with("tell me what you need."), "{skilled}");
    }

    /// The stacked rule is stated up front in the seed, so a compacted or revived
    /// session still has it, and repeated on every fix hand-off of a stacked PR.
    #[test]
    fn the_prompts_tell_a_stacked_pr_to_rebase_and_never_to_merge_its_base() {
        for skill in [false, true] {
            let stacked = track_seed_prompt(7, "t", "child", "u", None, Some("pr3"), skill);
            let rule = stacked.find("STACKED on `pr3`").expect(&stacked);
            assert!(
                rule < stacked.find("I'll periodically").unwrap(),
                "{stacked}"
            );
            assert!(
                stacked.contains("git rebase --onto origin/pr3"),
                "{stacked}"
            );
            assert!(stacked.contains("git push --force-with-lease"), "{stacked}");
            assert!(stacked.contains("Merge remote-tracking branch 'origin/pr3'"));
            assert!(stacked.contains("keep `pr3` as its base"), "{stacked}");
            assert!(
                stacked.contains("Never merge or close a PR yourself"),
                "{stacked}"
            );
            assert!(!stacked.contains("merge the base in"), "{stacked}");
            assert!(!stacked.contains("rebase or force-push"), "{stacked}");

            let fix = auto_fix_prompt(7, "child", &["x".into()], Some("pr3"), skill);
            assert!(fix.contains("stacked on `pr3`"), "{fix}");
            assert!(fix.contains("--force-with-lease"), "{fix}");
            assert!(fix.contains("never by merging it in"), "{fix}");
            assert!(fix.contains("Never merge or close a PR"), "{fix}");
        }
    }

    /// Against the default branch the base is still merged in, and when the tracker
    /// does not know the base the seed gives both rules and how to tell them apart.
    #[test]
    fn the_prompts_keep_merging_the_base_for_a_pr_against_the_default_branch() {
        let seed = track_seed_prompt(7, "t", "feature", "u", None, None, true);
        assert!(
            seed.contains("merge the base in instead (do not rebase"),
            "{seed}"
        );
        assert!(
            seed.contains("gh repo view --json defaultBranchRef"),
            "{seed}"
        );
        assert!(
            seed.contains("If the base is NOT the repo's default branch"),
            "{seed}"
        );
        assert!(seed.contains("git rebase --onto origin/<base>"), "{seed}");
        assert!(
            seed.contains("Never merge or close a PR yourself"),
            "{seed}"
        );

        let fix = auto_fix_prompt(7, "feature", &["x".into()], None, false);
        assert!(!fix.contains("stacked"), "{fix}");
        assert!(!fix.contains("force-with-lease"), "{fix}");
    }

    /// The fallback half of webhook matching. Lowercased on the way out, because the
    /// thing it is compared against is a webhook's slug and GitHub's are case-insensitive.
    #[test]
    fn a_pr_url_names_the_repo_a_webhook_would_call_it() {
        assert_eq!(
            repo_slug_from_pr_url("https://github.com/PanchoBubble/juancode/pull/42"),
            Some("panchobubble/juancode".into())
        );
        assert_eq!(
            repo_slug_from_pr_url("https://github.com/o/n/pull/1/files#r7"),
            Some("o/n".into())
        );
        // Not a PR url, so not an answer: an issue and the repo root both name the repo
        // and neither is a pull request this core could be watching.
        assert_eq!(
            repo_slug_from_pr_url("https://github.com/o/n/issues/1"),
            None
        );
        assert_eq!(repo_slug_from_pr_url("https://github.com/o/n"), None);
        assert_eq!(repo_slug_from_pr_url(""), None);
    }

    #[test]
    fn the_watch_key_is_one_pr_in_one_checkout() {
        assert_eq!(TrackedPr::key("/w/repo", 42), "/w/repo#42");
        assert_ne!(
            TrackedPr::key("/w/repo", 42),
            TrackedPr::key("/w/other", 42)
        );
    }
}
