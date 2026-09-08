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

impl TrackedPr {
    /// The identity of a watch: one PR number in one checkout. Two clones of a repo
    /// tracking the same PR are two watches, because their agents stand in different
    /// trees.
    pub fn key(cwd: &str, number: i64) -> String {
        format!("{cwd}#{number}")
    }

    pub fn state(&self) -> TrackState {
        derive_track_state(self.baseline.checks, !self.notifications.is_empty())
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

/// The seed prompt handed to the tracking session when a PR starts being watched.
/// Establishes the PR context and the auto-fix-vs-escalate contract once, up front.
pub fn track_seed_prompt(
    number: i64,
    title: &str,
    branch: &str,
    url: &str,
    worktree: Option<&BranchWorktree>,
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
    format!(
        "[juancode PR-tracker] You are now tracking pull request #{number} \"{title}\" \
         (branch `{branch}`): {url}{place}\n\n\
         I'll periodically tell you when there's new activity on this PR — new review comments \
         or a change in CI status. When I do:\n\
         - If it's an obvious fix (a lint/format/type error, a clearly-correct test fix, or \
         addressing a concrete review comment), make the change, commit, and push to `{branch}`.\n\
         - If it needs a real decision (ambiguous feedback, conflicting requirements, a risky \
         refactor, or a non-obvious failure), STOP and explain what you need from me instead of \
         guessing.\n\n\
         CI flakes: the Dagger checks are known to fail intermittently. If a Dagger check fails \
         and nothing in its logs points to a real problem in this PR's changes, just re-run it \
         (`gh run rerun <run-id> --failed`) rather than treating it as something to fix. Only dig \
         in or escalate if it fails again on the re-run, or the logs show a real error tied to \
         your changes.\n\n\
         Codex review fallback: this PR is normally code-reviewed by Codex, and only added to the \
         Mergify merge queue after that review. If you see a comment saying Codex has reached its \
         usage limits for code reviews (i.e. it couldn't review this PR), do the code review \
         yourself: read the full diff, post your review as a PR comment, and fix anything clearly \
         wrong per the rules above. Once your review is clean and CI is green, add the PR to the \
         Mergify queue by commenting `@mergifyio queue` on it. If your review turns up something \
         that needs a real decision, STOP and escalate to me instead of queueing.\n\n\
         Start by reviewing the PR and its diff with `gh pr view {number}` and \
         `gh pr diff {number}`."
    )
}

/// The prompt injected mid-session when a poll detects auto-fixable activity.
/// Summarises what changed and re-states the contract; the agent reads the specifics
/// itself through `gh`.
pub fn auto_fix_prompt(number: i64, branch: &str, reasons: &[String]) -> String {
    let summary = if reasons.is_empty() {
        "new activity".to_string()
    } else {
        reasons.join("; ")
    };
    format!(
        "[juancode PR-tracker] New activity on PR #{number}: {summary}. Check the latest state \
         with `gh pr view {number}`, `gh pr checks {number}`, and `gh pr diff {number}`. If it's \
         an obvious fix, make it, commit, and push to `{branch}`. If it needs a real decision, \
         STOP and tell me what you need."
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
        );
        assert!(detached.contains("DETACHED HEAD"));

        let bare = track_seed_prompt(7, "t", "feature", "u", None);
        assert!(!bare.contains("worktree"), "{bare}");
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
