//! Every `gh` round-trip the daemon makes.
//!
//! Two halves with one contract. The first is what the tracked-PR poller reads, a port
//! of the three probes `PrTrackingEngine` calls out of `Gh.swift`. The second, below
//! the divider, is what a *reader* reads: a folder's open PRs, the searches that reach
//! past the page cap, the triage question and the two orders a list is shown in. Every
//! one of them is best-effort by construction: `gh` missing, unauthenticated, offline, a cwd
//! that is not a repo, or output that will not parse all come back as "could not poll
//! this tick" rather than as an error, because the poller's answer to all five is the
//! same — try again on the next pass and leave the watch list exactly as it was.
//!
//! The binary is resolved the way every other tool in this daemon is
//! ([`crate::provider::resolve_bin`]), honouring `JUANCODE_GH_BIN`. The user's own
//! `gh` auth is used untouched: no token injection, no shadow `HOME`, same rule as
//! spawning the genuine agent CLIs.

use std::collections::BTreeMap;
use std::sync::OnceLock;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

use crate::diff::parse_multi_file_diff;
use crate::git::DiffResult;
use crate::pr::{PrActivity, PrChecks, PrComment, PrReview};
use crate::provider::resolve_bin;

/// Per-call budget. A `gh` that hangs must not hold a poll pass open forever; the
/// pass simply reports nothing for that PR and the next one asks again.
const CALL_TIMEOUT: Duration = Duration::from_secs(30);

/// Cap on one call's stdout, so a pathological PR cannot be read into memory whole.
const MAX_OUTPUT_BYTES: usize = 8 * 1024 * 1024;

/// Where `gh` is, honouring `JUANCODE_GH_BIN`. Resolved per call rather than cached
/// here, because `resolve_bin` already caches and an override has to be readable by a
/// test on any call.
pub fn gh_bin() -> Option<String> {
    resolve_bin("gh", std::env::var("JUANCODE_GH_BIN").ok().as_deref())
}

/// Run `gh` in `cwd` and hand back its stdout, or `None` for any failure at all.
async fn capture(cwd: &str, args: &[&str]) -> Option<String> {
    let bin = gh_bin()?;
    let run = tokio::process::Command::new(bin)
        .args(args)
        .current_dir(cwd)
        .kill_on_drop(true)
        .output();
    let out = tokio::time::timeout(CALL_TIMEOUT, run).await.ok()?.ok()?;
    if !out.status.success() || out.stdout.len() > MAX_OUTPUT_BYTES {
        return None;
    }
    String::from_utf8(out.stdout).ok()
}

/// One PR's reviewable activity, as the poller diffs it.
pub async fn pr_activity(cwd: &str, number: i64) -> Option<PrActivity> {
    let number = number.to_string();
    let raw = capture(
        cwd,
        &[
            "pr",
            "view",
            &number,
            "--json",
            "state,statusCheckRollup,comments,reviews,author",
        ],
    )
    .await?;
    let raw: RawActivity = serde_json::from_str(&raw).ok()?;
    Some(parse_activity(raw))
}

/// The login `gh` is authenticated as in `cwd`, which is the account the tracking agent
/// posts under. Empty when it cannot be determined, which the classifier reads as "no
/// self filter" rather than as an error.
///
/// Cached for the life of the process, because a poll pass over N PRs would otherwise
/// pay N identical round-trips and nobody swaps `gh` accounts under a running daemon.
///
/// Cached PER CWD, unlike the Swift core's single box, because `gh` resolves its host
/// and its account from the checkout: two clones can be two accounts, and one of them
/// can be a directory `gh` refuses to answer for at all. A process-wide box makes the
/// first folder asked the answer for every folder after it — which is the difference
/// between a PR list that knows whose PRs are whose and one whose triage column is
/// empty because some unrelated directory was read first.
pub async fn viewer_login(cwd: &str) -> String {
    static CACHE: OnceLock<Mutex<BTreeMap<String, String>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(BTreeMap::new()));
    let mut held = cache.lock().await;
    if let Some(cached) = held.get(cwd) {
        return cached.clone();
    }
    let login = capture(cwd, &["api", "user", "--jq", ".login"])
        .await
        .map(|out| out.trim().to_string())
        .unwrap_or_default();
    held.insert(cwd.to_string(), login.clone());
    login
}

/// The repo's `owner/name`. This is the identity an inbound GitHub event carries — a
/// cwd means nothing to a webhook — so it is what lets one be matched to the tracked
/// PRs it concerns. `None` when `gh` cannot say.
pub async fn repo_nwo(cwd: &str) -> Option<String> {
    let nwo = capture(
        cwd,
        &[
            "repo",
            "view",
            "--json",
            "nameWithOwner",
            "--jq",
            ".nameWithOwner",
        ],
    )
    .await?;
    let nwo = nwo.trim();
    (!nwo.is_empty()).then(|| nwo.to_string())
}

/// Collapse a PR's individual checks into one colour. Same order of judgements as
/// `rollupChecks` in the Swift core, so both cores report the same badge for one PR.
pub fn rollup_checks(checks: &[RawCheck]) -> PrChecks {
    if checks.is_empty() {
        return PrChecks::None;
    }
    let mut pending = false;
    for c in checks {
        let conclusion = c.conclusion.as_deref().unwrap_or_default().to_uppercase();
        let state = c.state.as_deref().unwrap_or_default().to_uppercase();
        let status = c.status.as_deref().unwrap_or_default().to_uppercase();
        if matches!(
            conclusion.as_str(),
            "FAILURE" | "ERROR" | "CANCELLED" | "TIMED_OUT" | "ACTION_REQUIRED"
        ) {
            return PrChecks::Failing;
        }
        if matches!(state.as_str(), "FAILURE" | "ERROR") {
            return PrChecks::Failing;
        }
        // Not yet concluded: a CheckRun still running, or a pending commit status.
        if !status.is_empty() && status != "COMPLETED" {
            pending = true;
        }
        if state == "PENDING" {
            pending = true;
        }
    }
    if pending {
        PrChecks::Pending
    } else {
        PrChecks::Passing
    }
}

/// Map `gh pr view --json`'s shape onto the poller's. A comment or review with no id
/// is dropped: without one it cannot be deduplicated, and an item that re-surfaces on
/// every poll is an agent prompted forever.
fn parse_activity(raw: RawActivity) -> PrActivity {
    PrActivity {
        author: raw.author.and_then(|a| a.login).unwrap_or_default(),
        state: raw.state.unwrap_or_default().to_uppercase(),
        checks: rollup_checks(&raw.status_check_rollup.unwrap_or_default()),
        comments: raw
            .comments
            .unwrap_or_default()
            .into_iter()
            .filter_map(|c| {
                Some(PrComment {
                    id: c.id?,
                    author: c.author.and_then(|a| a.login).unwrap_or_default(),
                    body: c.body.unwrap_or_default(),
                })
            })
            .collect(),
        reviews: raw
            .reviews
            .unwrap_or_default()
            .into_iter()
            .filter_map(|r| {
                Some(PrReview {
                    id: r.id?,
                    author: r.author.and_then(|a| a.login).unwrap_or_default(),
                    body: r.body.unwrap_or_default(),
                    state: r.state.unwrap_or_default().to_uppercase(),
                })
            })
            .collect(),
    }
}

/// One entry of gh's `statusCheckRollup`. Both shapes are in there: a CheckRun carries
/// `status`/`conclusion`, a commit status carries `state`.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RawCheck {
    pub status: Option<String>,
    pub conclusion: Option<String>,
    pub state: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawActivity {
    state: Option<String>,
    author: Option<RawAuthor>,
    status_check_rollup: Option<Vec<RawCheck>>,
    comments: Option<Vec<RawComment>>,
    reviews: Option<Vec<RawReview>>,
}

#[derive(Debug, Deserialize)]
struct RawAuthor {
    login: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawComment {
    id: Option<String>,
    author: Option<RawAuthor>,
    body: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawReview {
    id: Option<String>,
    author: Option<RawAuthor>,
    body: Option<String>,
    state: Option<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
// The PR list surface (juancode-52e8.14.6)
//
// Everything above this line is what the tracked-PR poller needs. Everything below
// is what a *reader* needs: the folder's open PRs, the searches that reach past the
// firehose cap, the triage question ("does this one want me?"), and the two orders
// the list is shown in. It is a port of the uncovered half of `Gh.swift`, and it is
// here rather than in a module of its own because it is the same binary, the same
// best-effort contract and the same raw JSON shapes as the poller's probes.
//
// One rule carried over unchanged from a3ef8c6: a list is one `gh` call, never one
// per folder. `fork+exec` costs 257ms on the machine this is developed on, so a
// fan-out over N checkouts is N quarter-seconds before GitHub is even asked.
// ─────────────────────────────────────────────────────────────────────────────

use std::collections::BTreeSet;

/// How many open PRs one `gh pr list` pass returns. A folder whose list comes back
/// exactly this long may be truncated — a caller that needs a *specific* branch's PR
/// rather than the newest ones falls back to [`pr_for_branch`].
pub const GH_PR_LIST_LIMIT: usize = 100;

/// The `gh pr list --json` fields the wire shape is built from. `assignees` powers the
/// "assigned to me" filter, `createdAt`/`reviewDecision`/`reviewRequests` drive the age
/// chip and the triage group, and the three size fields let a shipped PR read the way
/// the working tree does.
const LIST_FIELDS: &str = "number,title,url,headRefName,isDraft,statusCheckRollup,author,\
assignees,createdAt,reviewDecision,reviewRequests,additions,deletions,changedFiles";

/// One open pull request as a client renders it. The field names are the Swift core's,
/// because the phone console and the desktop decode the same JSON off both cores.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequest {
    pub number: i64,
    pub title: String,
    pub url: String,
    pub branch: String,
    pub draft: bool,
    pub checks: PrChecks,
    /// Total `statusCheckRollup` entries, 0 when there are none. Shown as
    /// `passed/total` beside the rolled-up colour rather than as a phrase.
    #[serde(default)]
    pub check_count: i64,
    /// Checks that concluded successfully — SUCCESS plus skipped/neutral, i.e. anything
    /// neither failing nor still running.
    #[serde(default)]
    pub passed_count: i64,
    /// Unresolved review threads on the PR, 0 when there are none or the extra GraphQL
    /// call did not answer. Merged in after the list parse, never part of it.
    #[serde(default)]
    pub unresolved_comments: i64,
    /// The author's login, empty when GitHub did not report one (a ghost account).
    #[serde(default)]
    pub author: String,
    #[serde(default)]
    pub assignees: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_at: Option<String>,
    /// GitHub's rolled-up verdict, raw: an unrecognised value must never fail the
    /// decode of a whole list, so the string is carried and interpreted at the edge.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_decision: Option<String>,
    /// Logins (users) and slugs (teams) with a review requested on this PR.
    #[serde(default)]
    pub review_requests: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub additions: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deletions: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub changed_files: Option<i64>,
}

impl PullRequest {
    /// Whether the viewer owns this PR: they opened it, or it is assigned to them.
    fn is_mine(&self, viewer: &str) -> bool {
        self.author == viewer || self.assignees.iter().any(|a| a == viewer)
    }

    fn changes_requested(&self) -> bool {
        self.review_decision
            .as_deref()
            .map(|d| d.to_uppercase() == "CHANGES_REQUESTED")
            .unwrap_or(false)
    }
}

/// What a folder's PR list read came back as. `available: false` rather than an error,
/// because "gh is not installed", "this is not a repo" and "you are not logged in" all
/// mean the same thing to the row that wanted to draw a badge: there is nothing to
/// draw, and saying why is more use than failing.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrListResult {
    pub available: bool,
    pub prs: Vec<PullRequest>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub viewer: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// What one `gh` call did, including the exit code and stderr the poller's `capture`
/// throws away. The list surface needs both: a non-zero exit carries the reason a
/// client shows, and `gh pr checks` exits non-zero *while printing the JSON asked for*.
struct GhOutput {
    ok: bool,
    code: i32,
    stdout: String,
    stderr: String,
    /// The binary could not be launched at all — the ENOENT case, which is the one
    /// failure with a better sentence than whatever stderr says.
    launch_failed: bool,
}

async fn capture_full(cwd: &str, args: &[&str]) -> GhOutput {
    let Some(bin) = gh_bin() else {
        return GhOutput {
            ok: false,
            code: -1,
            stdout: String::new(),
            stderr: String::new(),
            launch_failed: true,
        };
    };
    let run = tokio::process::Command::new(bin)
        .args(args)
        .current_dir(cwd)
        .kill_on_drop(true)
        .output();
    match tokio::time::timeout(CALL_TIMEOUT, run).await {
        Ok(Ok(out)) => GhOutput {
            ok: out.status.success() && out.stdout.len() <= MAX_OUTPUT_BYTES,
            code: out.status.code().unwrap_or(-1),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
            launch_failed: false,
        },
        Ok(Err(_)) => GhOutput {
            ok: false,
            code: -1,
            stdout: String::new(),
            stderr: String::new(),
            launch_failed: true,
        },
        Err(_) => GhOutput {
            ok: false,
            code: -1,
            stdout: String::new(),
            stderr: "gh timed out".into(),
            launch_failed: false,
        },
    }
}

/// Turn one failed `gh` call into the short sentence a client shows. The order is the
/// Swift core's: a binary that is not there, then the two failures whose stderr is
/// unreadable to anyone who is not holding gh's source, then gh's own first line.
fn gh_error_reason(out: &GhOutput) -> String {
    if out.launch_failed {
        return "gh CLI not installed".into();
    }
    let lower = out.stderr.to_lowercase();
    if lower.contains("no git remotes") || lower.contains("not a git repository") {
        return "Not a GitHub repo".into();
    }
    if lower.contains("auth") || lower.contains("logged") {
        return "gh not authenticated".into();
    }
    let first = out.stderr.trim().lines().next().unwrap_or_default().trim();
    if first.is_empty() {
        format!("gh failed (exit {})", out.code)
    } else {
        first.to_string()
    }
}

/// A folder's open pull requests, ready to render: the list, who `gh` is logged in as,
/// and the unresolved-thread count folded in.
///
/// Three round-trips at most, and never one per folder: the list, the viewer login
/// (cached for the process), and one repo-scoped GraphQL call for every PR's thread
/// count. Failure is `available: false` with a reason, never an error.
pub async fn open_prs(cwd: &str) -> PrListResult {
    let limit = GH_PR_LIST_LIMIT.to_string();
    let out = capture_full(
        cwd,
        &[
            "pr",
            "list",
            "--state",
            "open",
            "--limit",
            &limit,
            "--json",
            LIST_FIELDS,
        ],
    )
    .await;
    if !out.ok {
        return PrListResult {
            available: false,
            error: Some(gh_error_reason(&out)),
            ..Default::default()
        };
    }
    let Ok(raw) = serde_json::from_str::<Vec<RawPr>>(&out.stdout) else {
        return PrListResult {
            available: false,
            error: Some("Could not parse gh output".into()),
            ..Default::default()
        };
    };
    let viewer = viewer_login(cwd).await;
    let mut prs = parse_prs(raw);
    let counts = unresolved_thread_counts(cwd, &prs).await;
    merge_unresolved_counts(&mut prs, &counts);
    PrListResult {
        available: true,
        prs,
        viewer: Some(viewer),
        error: None,
    }
}

/// The open PR whose head is `branch`, asked of GitHub directly.
///
/// [`open_prs`] caps at the newest [`GH_PR_LIST_LIMIT`] open PRs across all authors, so
/// on a loud repo a session's own PR can sit outside that window and read as "no PR".
/// This asks for the one branch instead of the firehose, so the answer does not depend
/// on how busy the repo is. A branch has at most one open PR.
pub async fn pr_for_branch(cwd: &str, branch: &str) -> Option<PullRequest> {
    let branch = branch.trim();
    if branch.is_empty() {
        return None;
    }
    let raw = capture(
        cwd,
        &[
            "pr",
            "list",
            "--state",
            "open",
            "--head",
            branch,
            "--limit",
            "1",
            "--json",
            LIST_FIELDS,
        ],
    )
    .await?;
    let raw: Vec<RawPr> = serde_json::from_str(&raw).ok()?;
    parse_prs(raw).into_iter().next()
}

/// PRs matching a repo-scoped GitHub search — the backfill behind the PR popover.
///
/// [`open_prs`] is a page of the newest open PRs, so an older PR of the viewer's (or
/// one matched by a text filter) can fall outside it and never reach a client at all.
/// This is fired with the active filters spelled as qualifiers and unioned into the
/// cached list. Empty on any failure, so the caller simply keeps what it has.
pub async fn search_open_prs(cwd: &str, search: &str) -> Vec<PullRequest> {
    let query = search.trim();
    if query.is_empty() {
        return Vec::new();
    }
    let limit = GH_PR_LIST_LIMIT.to_string();
    let Some(raw) = capture(
        cwd,
        &[
            "pr",
            "list",
            "--search",
            query,
            "--limit",
            &limit,
            "--json",
            LIST_FIELDS,
        ],
    )
    .await
    else {
        return Vec::new();
    };
    serde_json::from_str::<Vec<RawPr>>(&raw)
        .map(parse_prs)
        .unwrap_or_default()
}

/// The search qualifiers for that backfill, or `None` when the active filters add
/// nothing beyond `state:open` — the firehose page already covers that view, so
/// re-querying would only repeat it. Mine/assigned are dropped while the viewer login
/// is unknown for the same reason: unscoped, they are the firehose again.
pub fn pr_backfill_query(mine: bool, assigned: bool, query: &str, viewer: &str) -> Option<String> {
    let text = query.trim();
    let mut qualifiers = String::from("state:open");
    if mine && !viewer.is_empty() {
        qualifiers.push_str(&format!(" author:{viewer}"));
    }
    if assigned && !viewer.is_empty() {
        qualifiers.push_str(&format!(" assignee:{viewer}"));
    }
    if !text.is_empty() {
        qualifiers.push(' ');
        qualifiers.push_str(text);
    }
    (qualifiers != "state:open").then_some(qualifiers)
}

/// Union `extra` into `base` by PR number: `base` is kept exactly as it is — same
/// entries, same order, same identity — and only the genuinely new PRs are appended,
/// newest-first among themselves.
///
/// Preserving `base` order is the point. The backfill lands seconds after the instant
/// client-side filter, so a re-sort here would visibly reshuffle every row already on
/// screen. Appending keeps shown rows put and folds the beyond-the-page matches in at
/// the end. `base` entries also carry enrichment (`unresolved_comments`) the backfill
/// does not have, so a same-numbered `extra` entry must never replace one.
pub fn merge_pr_lists(base: Vec<PullRequest>, extra: Vec<PullRequest>) -> Vec<PullRequest> {
    let present: BTreeSet<i64> = base.iter().map(|p| p.number).collect();
    let mut newcomers: Vec<PullRequest> = extra
        .into_iter()
        .filter(|p| !present.contains(&p.number))
        .collect();
    newcomers.sort_by(|a, b| b.number.cmp(&a.number));
    let mut out = base;
    out.extend(newcomers);
    out
}

/// Whether a PR matches a free-text filter, case-insensitively, over its title, author,
/// branch and number. An empty query matches everything. A digits query (optionally
/// `#`-prefixed) matches the number as a prefix, so `48` finds #4821 — and it still
/// matches text too, because `48` can legitimately be in a title.
pub fn pr_matches_query(pr: &PullRequest, query: &str) -> bool {
    let q = query.trim().to_lowercase();
    if q.is_empty() {
        return true;
    }
    if pr.title.to_lowercase().contains(&q)
        || pr.author.to_lowercase().contains(&q)
        || pr.branch.to_lowercase().contains(&q)
    {
        return true;
    }
    let digits = q.strip_prefix('#').unwrap_or(&q);
    if digits.is_empty() || !digits.chars().all(|c| c.is_ascii_digit()) {
        return false;
    }
    pr.number.to_string().starts_with(digits)
}

/// Why a PR is waiting on the viewer, most urgent first. The rank orders the pinned
/// triage group; the string is the label a row shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PrAttentionReason {
    /// Yours, and a reviewer asked for changes — the ball is squarely with you.
    ChangesRequested,
    /// Yours, and CI is red, so it cannot merge.
    CiFailing,
    /// Yours, with review threads still open.
    Unresolved,
    /// Someone asked you, or a team of yours, to review it.
    ReviewRequested,
}

impl PrAttentionReason {
    /// The label, which is the wire spelling too: a client renders the words this core
    /// chose rather than inventing its own for the same rank.
    pub fn label(self) -> &'static str {
        match self {
            Self::ChangesRequested => "changes requested",
            Self::CiFailing => "CI failing",
            Self::Unresolved => "unresolved threads",
            Self::ReviewRequested => "review requested",
        }
    }

    pub fn rank(self) -> u8 {
        match self {
            Self::ChangesRequested => 0,
            Self::CiFailing => 1,
            Self::Unresolved => 2,
            Self::ReviewRequested => 3,
        }
    }
}

/// Why this PR needs the viewer, or `None` when it does not. The first match in
/// priority order wins, so a PR appears once, under its most urgent reason.
///
/// `teams` are the viewer's team slugs when they are known, so a team review request
/// counts as an ask. Drafts are excluded from `CiFailing` only: red CI on a draft is
/// the ordinary state of work in progress, whereas a human asking for changes or a
/// review on a draft is still a real ask. A PR of the viewer's own never joins the
/// review queue, even when GitHub lists them as a requested reviewer on it.
pub fn pr_attention_reason(
    pr: &PullRequest,
    viewer: &str,
    teams: &BTreeSet<String>,
) -> Option<PrAttentionReason> {
    if viewer.is_empty() {
        return None;
    }
    if pr.is_mine(viewer) {
        if pr.changes_requested() {
            return Some(PrAttentionReason::ChangesRequested);
        }
        if pr.checks == PrChecks::Failing && !pr.draft {
            return Some(PrAttentionReason::CiFailing);
        }
        if pr.unresolved_comments > 0 {
            return Some(PrAttentionReason::Unresolved);
        }
        return None;
    }
    let asked = pr
        .review_requests
        .iter()
        .any(|r| r == viewer || teams.contains(r));
    asked.then_some(PrAttentionReason::ReviewRequested)
}

/// One row of the pinned triage list: the PR, where it lives, and why it is there.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NeedsYou {
    pub cwd: String,
    pub pr: PullRequest,
    pub reason: PrAttentionReason,
    /// The reason spelled the way a row shows it, so a client never has to keep its own
    /// table of these four strings.
    pub label: String,
}

/// One folder's contribution to that list: its path, its PRs, and the login `gh` is
/// authenticated as *there* (two checkouts can be two accounts).
pub struct FolderPrs {
    pub cwd: String,
    pub prs: Vec<PullRequest>,
    pub viewer: String,
}

/// The pinned triage list across every shown folder: each PR that needs the viewer,
/// ordered by reason and then newest-first, carrying the folder it came from.
pub fn prs_needing_you(by_folder: &[FolderPrs], teams: &BTreeSet<String>) -> Vec<NeedsYou> {
    let mut rows: Vec<NeedsYou> = Vec::new();
    for folder in by_folder {
        for pr in &folder.prs {
            let Some(reason) = pr_attention_reason(pr, &folder.viewer, teams) else {
                continue;
            };
            rows.push(NeedsYou {
                cwd: folder.cwd.clone(),
                pr: pr.clone(),
                reason,
                label: reason.label().to_string(),
            });
        }
    }
    rows.sort_by(|a, b| {
        a.reason
            .rank()
            .cmp(&b.reason.rank())
            .then(b.pr.number.cmp(&a.pr.number))
    });
    rows
}

/// Order a folder's open PRs for the GitHub view: tracked ones first, because those are
/// the ones being actively driven, with each band keeping its incoming newest-first
/// order.
pub fn sort_prs_tracked_first(prs: Vec<PullRequest>, tracked: &BTreeSet<i64>) -> Vec<PullRequest> {
    let (lead, rest): (Vec<_>, Vec<_>) = prs.into_iter().partition(|p| tracked.contains(&p.number));
    let mut out = lead;
    out.extend(rest);
    out
}

/// Order a folder's open PRs strictly by submit date, newest first. GitHub assigns PR
/// numbers sequentially at creation, so descending number *is* descending submit date
/// and there is no second field to fetch.
pub fn sort_prs_by_submit_date(mut prs: Vec<PullRequest>) -> Vec<PullRequest> {
    prs.sort_by(|a, b| b.number.cmp(&a.number));
    prs
}

/// A PR's age as one compact token ("4h", "2d", "3w", "1y") from gh's ISO-8601
/// `createdAt`, or `None` when the stamp is missing or will not parse.
///
/// Deliberately coarse: the row needs "is this rotting?", not a duration. The minute
/// count is rounded rather than truncated, because a fractional-second stamp otherwise
/// lands 239.99 minutes after creation and reads as "3h" when it is four hours old.
pub fn pr_age_label(iso: Option<&str>, now_ms: i64) -> Option<String> {
    let created = iso8601_ms(iso?)?;
    let seconds = ((now_ms - created).max(0) as f64) / 1000.0;
    let minutes = (seconds / 60.0).round() as i64;
    if minutes < 60 {
        return Some(format!("{}m", minutes.max(1)));
    }
    let hours = minutes / 60;
    if hours < 24 {
        return Some(format!("{hours}h"));
    }
    let days = hours / 24;
    if days < 14 {
        return Some(format!("{days}d"));
    }
    let weeks = days / 7;
    if weeks < 52 {
        return Some(format!("{weeks}w"));
    }
    Some(format!("{}y", days / 365))
}

/// `owner` and `name` from a `https://github.com/<owner>/<repo>/pull/<n>` url, with
/// their case intact — GraphQL wants the repo spelled as GitHub spells it, whereas
/// [`crate::pr::repo_slug_from_pr_url`] lower-cases because a webhook's `full_name` is
/// matched case-insensitively. Two callers, two needs, one parse each.
pub fn repo_owner_name(url: &str) -> Option<(String, String)> {
    let rest = url.split_once("github.com/")?.1;
    let mut parts = rest.split('/');
    let owner = parts.next().filter(|s| !s.is_empty())?;
    let name = parts.next().filter(|s| !s.is_empty())?;
    (parts.next() == Some("pull")).then(|| (owner.to_string(), name.to_string()))
}

/// One `gh api graphql` call: the query, its string variables and its integer ones.
///
/// A helper rather than an argv built at each call site because `gh` spells the two
/// kinds of variable differently — `-f` is a string, `-F` coerces — and a number passed
/// as `-f` is a type error GitHub reports from the far side of the network, which is a
/// long way to go to find out.
pub async fn graphql(
    cwd: &str,
    query: &str,
    strings: &[(&str, &str)],
    numbers: &[(&str, i64)],
) -> Option<String> {
    let mut args: Vec<String> = vec![
        "api".into(),
        "graphql".into(),
        "-f".into(),
        format!("query={query}"),
    ];
    for (k, v) in strings {
        args.push("-f".into());
        args.push(format!("{k}={v}"));
    }
    for (k, v) in numbers {
        args.push("-F".into());
        args.push(format!("{k}={v}"));
    }
    let borrowed: Vec<&str> = args.iter().map(String::as_str).collect();
    capture(cwd, &borrowed).await
}

/// Unresolved review threads per open PR, from one repo-scoped GraphQL call. The repo
/// is lifted from a PR url already in hand, so this costs no extra `gh repo view`.
/// Empty on any failure: the list still renders, just without the count.
pub async fn unresolved_thread_counts(cwd: &str, prs: &[PullRequest]) -> BTreeMap<i64, i64> {
    let Some((owner, name)) = prs.iter().find_map(|p| repo_owner_name(&p.url)) else {
        return BTreeMap::new();
    };
    let query = format!(
        "query($owner: String!, $name: String!) {{\n\
           repository(owner: $owner, name: $name) {{\n\
             pullRequests(states: OPEN, first: {GH_PR_LIST_LIMIT}) {{\n\
               nodes {{ number reviewThreads(first: 100) {{ nodes {{ isResolved }} }} }}\n\
             }}\n\
           }}\n\
         }}"
    );
    let Some(out) = graphql(
        cwd,
        &query,
        &[("owner", owner.as_str()), ("name", name.as_str())],
        &[],
    )
    .await
    else {
        return BTreeMap::new();
    };
    parse_unresolved_thread_counts(&out)
}

/// Parse that response into number → unresolved-thread count. A thread counts as
/// unresolved when `isResolved` is false or absent.
pub fn parse_unresolved_thread_counts(json: &str) -> BTreeMap<i64, i64> {
    let Ok(decoded) = serde_json::from_str::<ThreadCountsResponse>(json) else {
        return BTreeMap::new();
    };
    let Some(nodes) = decoded
        .data
        .and_then(|d| d.repository)
        .and_then(|r| r.pull_requests)
        .and_then(|p| p.nodes)
    else {
        return BTreeMap::new();
    };
    let mut out = BTreeMap::new();
    for node in nodes {
        let Some(number) = node.number else { continue };
        let unresolved = node
            .review_threads
            .and_then(|t| t.nodes)
            .unwrap_or_default()
            .iter()
            .filter(|t| t.is_resolved != Some(true))
            .count() as i64;
        out.insert(number, unresolved);
    }
    out
}

/// Overlay those counts onto parsed PRs, keyed by number. A PR with no entry keeps its
/// default of 0 rather than losing the count it already had.
pub fn merge_unresolved_counts(prs: &mut [PullRequest], counts: &BTreeMap<i64, i64>) {
    for pr in prs.iter_mut() {
        if let Some(n) = counts.get(&pr.number) {
            pr.unresolved_comments = *n;
        }
    }
}

/// Map gh's raw list JSON onto the wire shape. `unresolved_comments` stays 0 here: the
/// list call cannot see thread resolution, so it is merged in separately.
pub fn parse_prs(raw: Vec<RawPr>) -> Vec<PullRequest> {
    raw.into_iter()
        .map(|p| {
            let rollup = p.status_check_rollup.unwrap_or_default();
            PullRequest {
                number: p.number,
                title: p.title,
                url: p.url,
                branch: p.head_ref_name,
                draft: p.is_draft,
                checks: rollup_checks(&rollup),
                check_count: rollup.len() as i64,
                passed_count: count_passed_checks(&rollup),
                unresolved_comments: 0,
                author: p.author.and_then(|a| a.login).unwrap_or_default(),
                assignees: p
                    .assignees
                    .unwrap_or_default()
                    .into_iter()
                    .filter_map(|a| a.login)
                    .collect(),
                created_at: p.created_at,
                review_decision: p.review_decision,
                review_requests: p
                    .review_requests
                    .unwrap_or_default()
                    .into_iter()
                    .filter_map(|r| r.handle())
                    .collect(),
                additions: p.additions,
                deletions: p.deletions,
                changed_files: p.changed_files,
            }
        })
        .collect()
}

/// Count the checks that concluded successfully — anything neither failing nor still
/// running, so SUCCESS plus skipped and neutral. Classifies each check exactly as
/// [`rollup_checks`] does, so `passed_count`/`check_count` can never disagree with the
/// rolled-up colour beside them.
pub fn count_passed_checks(checks: &[RawCheck]) -> i64 {
    let mut passed = 0;
    for c in checks {
        let conclusion = c.conclusion.as_deref().unwrap_or_default().to_uppercase();
        let state = c.state.as_deref().unwrap_or_default().to_uppercase();
        let status = c.status.as_deref().unwrap_or_default().to_uppercase();
        if matches!(
            conclusion.as_str(),
            "FAILURE" | "ERROR" | "CANCELLED" | "TIMED_OUT" | "ACTION_REQUIRED"
        ) || matches!(state.as_str(), "FAILURE" | "ERROR")
        {
            continue;
        }
        if (!status.is_empty() && status != "COMPLETED") || state == "PENDING" {
            continue;
        }
        passed += 1;
    }
    passed
}

/// gh's `pr list --json` element, before it is mapped onto [`PullRequest`].
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RawPr {
    pub number: i64,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub head_ref_name: String,
    #[serde(default)]
    pub is_draft: bool,
    pub status_check_rollup: Option<Vec<RawCheck>>,
    pub author: Option<RawListAuthor>,
    pub assignees: Option<Vec<RawListAuthor>>,
    pub created_at: Option<String>,
    pub review_decision: Option<String>,
    pub review_requests: Option<Vec<RawReviewRequest>>,
    pub additions: Option<i64>,
    pub deletions: Option<i64>,
    pub changed_files: Option<i64>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct RawListAuthor {
    pub login: Option<String>,
}

/// One entry of gh's `reviewRequests`: a user carries `login`, a team carries `slug`
/// (and sometimes only a display `name`).
#[derive(Debug, Clone, Default, Deserialize)]
pub struct RawReviewRequest {
    pub login: Option<String>,
    pub slug: Option<String>,
    pub name: Option<String>,
}

impl RawReviewRequest {
    /// The handle to match a viewer login or a team slug against.
    pub(crate) fn handle(self) -> Option<String> {
        self.login.or(self.slug).or(self.name)
    }
}

#[derive(Debug, Deserialize)]
struct ThreadCountsResponse {
    data: Option<ThreadCountsData>,
}
#[derive(Debug, Deserialize)]
struct ThreadCountsData {
    repository: Option<ThreadCountsRepo>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThreadCountsRepo {
    pull_requests: Option<ThreadCountsPrs>,
}
#[derive(Debug, Deserialize)]
struct ThreadCountsPrs {
    nodes: Option<Vec<ThreadCountsNode>>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThreadCountsNode {
    number: Option<i64>,
    review_threads: Option<ThreadCountsThreads>,
}
#[derive(Debug, Deserialize)]
struct ThreadCountsThreads {
    nodes: Option<Vec<ThreadCountsThread>>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThreadCountsThread {
    is_resolved: Option<bool>,
}

// ── CI checks, their logs, and the two writes a reader makes ─────────────────

/// One CI check on a PR, from `gh pr checks --json`. `bucket` is gh's coarse outcome
/// (pass/fail/pending/skipping/cancel); `link` is the details URL an Actions run id can
/// be lifted out of.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrCheckRun {
    pub name: String,
    pub state: String,
    pub bucket: String,
    pub link: String,
}

impl PrCheckRun {
    /// Whether this check counts as failed: gh's `fail` bucket, or a raw FAILURE/ERROR
    /// state for the older commit-status shape that has no bucket.
    pub fn failed(&self) -> bool {
        self.bucket == "fail" || self.state == "FAILURE" || self.state == "ERROR"
    }
}

#[derive(Debug, Deserialize)]
struct RawCheckRun {
    name: Option<String>,
    state: Option<String>,
    bucket: Option<String>,
    link: Option<String>,
}

/// Map `gh pr checks --json` onto [`PrCheckRun`], normalising case so `failed()` cannot
/// be fooled by gh spelling a state in lower case.
pub fn parse_check_runs(json: &str) -> Vec<PrCheckRun> {
    serde_json::from_str::<Vec<RawCheckRun>>(json)
        .unwrap_or_default()
        .into_iter()
        .map(|r| PrCheckRun {
            name: r.name.unwrap_or_default(),
            state: r.state.unwrap_or_default().to_uppercase(),
            bucket: r.bucket.unwrap_or_default().to_lowercase(),
            link: r.link.unwrap_or_default(),
        })
        .collect()
}

/// The GitHub Actions run id in a check's details URL (`…/actions/runs/<id>/job/<n>`),
/// or `None` for a check that is not an Actions run.
pub fn run_id_from_check_link(link: &str) -> Option<String> {
    let rest = link.split_once("/actions/runs/")?.1;
    let id: String = rest.chars().take_while(char::is_ascii_digit).collect();
    (!id.is_empty()).then_some(id)
}

/// A PR's CI checks. `gh pr checks` exits non-zero when checks are failing or pending
/// *and still prints the JSON that was asked for*, so stdout is parsed whatever the
/// exit code was — a red PR is the case this exists to report on.
pub async fn pr_check_runs(cwd: &str, number: i64) -> Vec<PrCheckRun> {
    let number = number.to_string();
    let out = capture_full(
        cwd,
        &["pr", "checks", &number, "--json", "name,state,bucket,link"],
    )
    .await;
    parse_check_runs(&out.stdout)
}

/// Cap on captured CI-log text, so one pathological run cannot fill a panel or a
/// prompt. The tail is kept, because that is where a failure surfaces.
const MAX_LOG_CHARS: usize = 20_000;

/// The failing-step logs behind a PR's red checks: each failing Actions check is
/// resolved to its run id and `gh run view <id> --log-failed` is read, concatenated
/// under a banner per run. Empty when nothing is failing or the logs will not read.
///
/// The banner is not decoration — [`crate::actions_log`] parses it back out to label
/// the sections, so the two ends of this string are one format.
pub async fn failed_check_logs(cwd: &str, number: i64, max_runs: usize) -> String {
    let failing: Vec<PrCheckRun> = pr_check_runs(cwd, number)
        .await
        .into_iter()
        .filter(PrCheckRun::failed)
        .collect();
    let mut seen = BTreeSet::new();
    let mut run_ids = Vec::new();
    for check in &failing {
        if let Some(id) = run_id_from_check_link(&check.link) {
            if seen.insert(id.clone()) {
                run_ids.push(id);
            }
        }
    }
    let mut sections = Vec::new();
    for id in run_ids.into_iter().take(max_runs) {
        let Some(log) = failed_run_log(cwd, &id).await else {
            continue;
        };
        if log.is_empty() {
            continue;
        }
        sections.push(format!("===== run {id} (failed steps) =====\n{log}"));
    }
    sections.join("\n\n")
}

/// `gh run view <id> --log-failed`, capped to the trailing [`MAX_LOG_CHARS`].
async fn failed_run_log(cwd: &str, run_id: &str) -> Option<String> {
    let log = capture(cwd, &["run", "view", run_id, "--log-failed"]).await?;
    if log.chars().count() <= MAX_LOG_CHARS {
        return Some(log);
    }
    let tail: String = log
        .chars()
        .skip(log.chars().count() - MAX_LOG_CHARS)
        .collect();
    Some(format!("…(truncated)\n{tail}"))
}

/// A `gh` write that failed, carrying the sentence a client shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GhError(pub String);

impl std::fmt::Display for GhError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}
impl std::error::Error for GhError {}

/// Run a `gh` write, turning a launch failure or a non-zero exit into a clean reason.
async fn gh_write(cwd: &str, args: &[&str]) -> Result<String, GhError> {
    let out = capture_full(cwd, args).await;
    if out.ok {
        Ok(out.stdout)
    } else {
        Err(GhError(gh_error_reason(&out)))
    }
}

/// Post a top-level comment on a PR.
pub async fn comment_on_pr(cwd: &str, number: i64, body: &str) -> Result<(), GhError> {
    gh_write(cwd, &["pr", "comment", &number.to_string(), "--body", body])
        .await
        .map(|_| ())
}

/// Reply to an inline review-thread comment. `comment_id` is the REST id of the
/// comment being replied to, which GitHub requires to be a *top-level* review comment:
/// replying to a reply is a 422, which is why a thread's reply target is always its
/// first comment. gh fills `{owner}`/`{repo}` from the checkout.
pub async fn reply_to_review_comment(
    cwd: &str,
    number: i64,
    comment_id: i64,
    body: &str,
) -> Result<(), GhError> {
    let path = format!("repos/{{owner}}/{{repo}}/pulls/{number}/comments/{comment_id}/replies");
    gh_write(
        cwd,
        &[
            "api",
            "--method",
            "POST",
            &path,
            "-f",
            &format!("body={body}"),
        ],
    )
    .await
    .map(|_| ())
}

/// Re-run a PR's CI. `failed_only` passes `--failed`, which is GitHub's "re-run failed
/// jobs"; otherwise every job of every run behind the PR's checks is re-run. This is
/// always user-initiated — a button — and never something a poll does.
pub async fn rerun_checks(cwd: &str, number: i64, failed_only: bool) -> Result<(), GhError> {
    let checks = pr_check_runs(cwd, number).await;
    let mut seen = BTreeSet::new();
    let mut run_ids = Vec::new();
    for c in checks.iter().filter(|c| !failed_only || c.failed()) {
        if let Some(id) = run_id_from_check_link(&c.link) {
            if seen.insert(id.clone()) {
                run_ids.push(id);
            }
        }
    }
    if run_ids.is_empty() {
        return Err(GhError(
            if failed_only {
                "No failed GitHub Actions runs to re-run"
            } else {
                "No GitHub Actions runs to re-run"
            }
            .into(),
        ));
    }
    for id in run_ids {
        let args: Vec<&str> = if failed_only {
            vec!["run", "rerun", &id, "--failed"]
        } else {
            vec!["run", "rerun", &id]
        };
        gh_write(cwd, &args).await?;
    }
    Ok(())
}

// ── the writes and the reads the desktop kept for itself ─────────────────────
//
// `create_pr`, `pr_diff` and the viewer queue below are the last three `gh` calls the
// SwiftUI app was still making in its own process (juancode-h0l6). They are here for
// the reason the rest of this module is: a phone cannot shell out to `gh`, and a
// second implementation of "did this PR already exist" or "which of my PRs is on
// fire" would eventually disagree with this one.

/// A PR that was opened, or the one that was already there.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrCreateResult {
    pub url: String,
    /// `false` when a PR already existed for the branch, whose url this is. Not an
    /// error: the caller asked for a PR to exist and one does.
    pub created: bool,
}

/// Open a pull request for the checkout's current branch. The caller pushes first, so
/// this only creates the PR.
///
/// `gh` reports "a PR already exists" as a non-zero exit with the url on stderr, and
/// that is an answer rather than a failure — the alternative is a client that has to
/// parse gh's stderr itself to tell the two apart.
pub async fn create_pr(
    cwd: &str,
    title: &str,
    body: &str,
    draft: bool,
) -> Result<PrCreateResult, GhError> {
    let mut args = vec!["pr", "create", "--title", title, "--body", body];
    if draft {
        args.push("--draft");
    }
    let out = capture_full(cwd, &args).await;
    if out.ok {
        let url = first_url(&out.stdout).unwrap_or_else(|| out.stdout.trim().to_string());
        return Ok(PrCreateResult { url, created: true });
    }
    if let Some(existing) = existing_pr_url(&out.stderr) {
        return Ok(PrCreateResult {
            url: existing,
            created: false,
        });
    }
    Err(GhError(gh_error_reason(&out)))
}

/// The first `http(s)://…` run in `s`.
fn first_url(s: &str) -> Option<String> {
    s.split_whitespace()
        .find(|t| t.starts_with("https://") || t.starts_with("http://"))
        .map(str::to_string)
}

/// The url gh names in "a pull request for branch … already exists: <url>", which it
/// writes to stderr and exits non-zero on.
fn existing_pr_url(s: &str) -> Option<String> {
    let lower = s.to_lowercase();
    let at = lower.find("already exists")?;
    first_url(&s[at + "already exists".len()..])
}

/// Per-PR-diff cap, the same 300 the working tree uses.
const MAX_PR_FILES: usize = 300;

/// An open PR's net diff, in the same per-file shape `/api/git/diff` answers with, so
/// the panel that draws a working tree draws a PR unchanged.
///
/// Deliberately not `gh pr diff --patch`: that emits a mailbox patch *series*, one per
/// commit, so a file touched in three commits parses into three same-path entries —
/// duplicate ids in the list and per-commit rather than net counts. The plain form is
/// the PR's net diff.
pub async fn pr_diff(cwd: &str, number: i64) -> Result<DiffResult, GhError> {
    let out = capture_full(cwd, &["pr", "diff", &number.to_string()]).await;
    if !out.ok {
        return Err(GhError(gh_error_reason(&out)));
    }
    let mut files = parse_multi_file_diff(&out.stdout);
    let truncated = files.len() > MAX_PR_FILES;
    if truncated {
        files.truncate(MAX_PR_FILES);
    }
    files.sort_by(|a, b| a.path.to_lowercase().cmp(&b.path.to_lowercase()));
    Ok(DiffResult {
        git: true,
        root: None,
        files,
        truncated_files: Some(truncated),
    })
}

// ── the viewer's own queue ───────────────────────────────────────────────────

/// How many rows each half of the queue returns. GitHub's search caps a page at 100;
/// 50 each is the window the desktop read and the badge has never wanted more.
const MAX_VIEWER_PRS: i64 = 50;

/// Why a PR is in your queue. A PR you authored that also lists you as a reviewer is
/// yours — authorship wins, so each PR appears once.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ViewerPrReason {
    Mine,
    ReviewRequested,
}

/// One row of the viewer queue: the PR, the repo it lives in (`owner/name` — these
/// rows span repos, so the folder name a folder-scoped row shows does not exist here),
/// why it is on your plate, and whether it wants something from you.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ViewerPr {
    pub pr: PullRequest,
    pub repo: String,
    pub reason: ViewerPrReason,
    /// Why this row wants the viewer, decided here rather than in each client for the
    /// same reason `needs_you` is: it is four rules with a priority between them.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attention: Option<PrAttentionReason>,
    /// `attention` spelled the way a row shows it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attention_label: Option<String>,
}

/// The viewer queue as one fetch. `available: false` when gh is missing,
/// unauthenticated or the search failed, so a client can stay quiet rather than claim
/// an empty queue.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ViewerPrResult {
    pub available: bool,
    pub rows: Vec<ViewerPr>,
    pub viewer: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl ViewerPrResult {
    fn unavailable(error: impl Into<String>) -> Self {
        Self {
            available: false,
            rows: Vec::new(),
            viewer: String::new(),
            error: Some(error.into()),
        }
    }
}

/// The search qualifiers for each half of the queue.
pub fn viewer_pr_search(mine: bool) -> String {
    let base = "is:open is:pr archived:false sort:updated";
    if mine {
        format!("{base} author:@me")
    } else {
        format!("{base} review-requested:@me")
    }
}

/// The two searches as one GraphQL document with aliases — one round trip for both
/// halves of the queue, returning the same shape `gh pr list --json` does, so a row
/// renders with no follow-up fetch.
const VIEWER_PR_QUERY: &str = r#"
query($mine: String!, $reviews: String!, $first: Int!) {
  mine: search(query: $mine, type: ISSUE, first: $first) { nodes { ...prBits } }
  reviews: search(query: $reviews, type: ISSUE, first: $first) { nodes { ...prBits } }
}
fragment prBits on PullRequest {
  number title url isDraft createdAt headRefName additions deletions changedFiles
  repository { nameWithOwner }
  author { login }
  assignees(first: 10) { nodes { login } }
  reviewDecision
  reviewRequests(first: 10) {
    nodes { requestedReviewer { ... on User { login } ... on Team { slug } } }
  }
  reviewThreads(first: 100) { nodes { isResolved } }
  rollup: commits(last: 1) {
    nodes {
      commit {
        statusCheckRollup {
          contexts(first: 100) {
            nodes {
              ... on CheckRun { status conclusion }
              ... on StatusContext { state }
            }
          }
        }
      }
    }
  }
}
"#;

/// Every open PR the viewer authored, plus every one that asked for their review,
/// across all repos — not just the folders a client happens to have open.
///
/// `cwd` only has to be a directory that exists: the search is not repo-scoped, which
/// is the whole point of it next to `open_prs`. `teams` are the viewer's team slugs, so
/// a team review request counts as an ask, exactly as it does for `needs_you`.
pub async fn viewer_prs(cwd: &str, teams: &BTreeSet<String>) -> ViewerPrResult {
    let out = capture_full(
        cwd,
        &[
            "api",
            "graphql",
            "-f",
            &format!("query={VIEWER_PR_QUERY}"),
            "-f",
            &format!("mine={}", viewer_pr_search(true)),
            "-f",
            &format!("reviews={}", viewer_pr_search(false)),
            "-F",
            &format!("first={MAX_VIEWER_PRS}"),
        ],
    )
    .await;
    if !out.ok {
        return ViewerPrResult::unavailable(gh_error_reason(&out));
    }
    let Some(mut rows) = parse_viewer_prs(&out.stdout) else {
        return ViewerPrResult::unavailable("Could not parse gh output");
    };
    let viewer = viewer_login(cwd).await;
    for row in &mut rows {
        // A review request is a reason in itself: `pr_attention_reason` can only see
        // the request when the PR carries it, and the search has already answered that
        // by putting the row in the `reviews` bucket.
        let reason = if row.reason == ViewerPrReason::ReviewRequested {
            Some(PrAttentionReason::ReviewRequested)
        } else {
            pr_attention_reason(&row.pr, &viewer, teams)
        };
        row.attention = reason;
        row.attention_label = reason.map(|r| r.label().to_string());
    }
    ViewerPrResult {
        available: true,
        rows,
        viewer,
        error: None,
    }
}

/// gh's GraphQL envelope for the two aliased searches.
#[derive(Debug, Deserialize)]
struct ViewerSearchEnvelope {
    data: Option<ViewerSearchPayload>,
}

#[derive(Debug, Deserialize)]
struct ViewerSearchPayload {
    mine: Option<ViewerBucket>,
    reviews: Option<ViewerBucket>,
}

#[derive(Debug, Deserialize)]
struct ViewerBucket {
    nodes: Option<Vec<RawViewerPr>>,
}

/// One search hit. Everything past `number` is optional so a field GitHub declines to
/// serve — or a node that is not a PullRequest at all, which the fragment renders as
/// `{}` — costs that row and not the whole queue.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawViewerPr {
    number: Option<i64>,
    title: Option<String>,
    url: Option<String>,
    is_draft: Option<bool>,
    created_at: Option<String>,
    head_ref_name: Option<String>,
    additions: Option<i64>,
    deletions: Option<i64>,
    changed_files: Option<i64>,
    repository: Option<RawViewerRepo>,
    author: Option<RawListAuthor>,
    assignees: Option<RawViewerLogins>,
    review_decision: Option<String>,
    review_requests: Option<RawViewerRequests>,
    review_threads: Option<RawViewerThreads>,
    rollup: Option<RawViewerRollup>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawViewerRepo {
    name_with_owner: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawViewerLogins {
    nodes: Option<Vec<RawListAuthor>>,
}

#[derive(Debug, Deserialize)]
struct RawViewerRequests {
    nodes: Option<Vec<RawViewerRequest>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawViewerRequest {
    requested_reviewer: Option<RawReviewRequest>,
}

#[derive(Debug, Deserialize)]
struct RawViewerThreads {
    nodes: Option<Vec<RawViewerThread>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawViewerThread {
    is_resolved: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct RawViewerRollup {
    nodes: Option<Vec<RawViewerCommitNode>>,
}

#[derive(Debug, Deserialize)]
struct RawViewerCommitNode {
    commit: Option<RawViewerCommit>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawViewerCommit {
    status_check_rollup: Option<RawViewerStatus>,
}

#[derive(Debug, Deserialize)]
struct RawViewerStatus {
    contexts: Option<RawViewerContexts>,
}

#[derive(Debug, Deserialize)]
struct RawViewerContexts {
    nodes: Option<Vec<RawCheck>>,
}

impl RawViewerPr {
    /// The head commit's check contexts, flattened — the same `[RawCheck]` shape
    /// `gh pr list --json statusCheckRollup` produces, so one rollup classifies both.
    fn check_contexts(&self) -> Vec<RawCheck> {
        self.rollup
            .as_ref()
            .and_then(|r| r.nodes.as_ref())
            .and_then(|n| n.first())
            .and_then(|n| n.commit.as_ref())
            .and_then(|c| c.status_check_rollup.as_ref())
            .and_then(|s| s.contexts.as_ref())
            .and_then(|c| c.nodes.clone())
            .unwrap_or_default()
    }
}

/// Map one search hit onto the wire `PullRequest`, or `None` when it carries no PR
/// identity.
fn viewer_pull_request(raw: &RawViewerPr) -> Option<PullRequest> {
    let number = raw.number?;
    let url = raw.url.clone()?;
    let contexts = raw.check_contexts();
    let unresolved = raw
        .review_threads
        .as_ref()
        .and_then(|t| t.nodes.as_ref())
        .map(|n| n.iter().filter(|t| t.is_resolved == Some(false)).count() as i64)
        .unwrap_or(0);
    Some(PullRequest {
        number,
        title: raw.title.clone().unwrap_or_default(),
        url,
        branch: raw.head_ref_name.clone().unwrap_or_default(),
        draft: raw.is_draft.unwrap_or(false),
        checks: rollup_checks(&contexts),
        check_count: contexts.len() as i64,
        passed_count: count_passed_checks(&contexts),
        unresolved_comments: unresolved,
        author: raw
            .author
            .as_ref()
            .and_then(|a| a.login.clone())
            .unwrap_or_default(),
        assignees: raw
            .assignees
            .as_ref()
            .and_then(|a| a.nodes.as_ref())
            .map(|n| n.iter().filter_map(|a| a.login.clone()).collect())
            .unwrap_or_default(),
        created_at: raw.created_at.clone(),
        review_decision: raw.review_decision.clone(),
        review_requests: raw
            .review_requests
            .as_ref()
            .and_then(|r| r.nodes.as_ref())
            .map(|n| {
                n.iter()
                    .filter_map(|r| {
                        r.requested_reviewer
                            .clone()
                            .and_then(RawReviewRequest::handle)
                    })
                    .collect()
            })
            .unwrap_or_default(),
        additions: raw.additions,
        deletions: raw.deletions,
        changed_files: raw.changed_files,
    })
}

/// Parse the two aliased buckets into one deduped queue: authored PRs first, in the
/// order GitHub returned them, then review requests that are not already listed.
///
/// `None` when the payload is not the envelope we asked for; an empty queue is `[]`,
/// which is a real answer and not a failure.
pub fn parse_viewer_prs(stdout: &str) -> Option<Vec<ViewerPr>> {
    let envelope: ViewerSearchEnvelope = serde_json::from_str(stdout).ok()?;
    let payload = envelope.data?;
    let mut rows: Vec<ViewerPr> = Vec::new();
    let mut seen: BTreeSet<String> = BTreeSet::new();
    for (bucket, reason) in [
        (payload.mine, ViewerPrReason::Mine),
        (payload.reviews, ViewerPrReason::ReviewRequested),
    ] {
        for raw in bucket.and_then(|b| b.nodes).unwrap_or_default() {
            let Some(pr) = viewer_pull_request(&raw) else {
                continue;
            };
            let repo = raw
                .repository
                .as_ref()
                .and_then(|r| r.name_with_owner.clone())
                .or_else(|| repo_owner_name(&pr.url).map(|(o, n)| format!("{o}/{n}")))
                .unwrap_or_default();
            let key = format!("{repo}#{}", pr.number);
            if !seen.insert(key) {
                continue;
            }
            rows.push(ViewerPr {
                pr,
                repo,
                reason,
                attention: None,
                attention_label: None,
            });
        }
    }
    Some(rows)
}

// ── ISO-8601, without a date crate ───────────────────────────────────────────

/// Milliseconds since the epoch for an RFC-3339 stamp, or `None` when it will not
/// parse. Accepts a `Z` or a numeric offset and any number of fractional digits, which
/// is what GitHub and GitHub Actions between them actually emit (Actions writes seven
/// fractional digits, more than most date parsers accept).
///
/// Hand-rolled because this core has no date dependency and this is the only thing it
/// would be for: one civil-date-to-days conversion and a fixed-shape scan.
pub fn iso8601_ms(s: &str) -> Option<i64> {
    let s = s.trim();
    let bytes = s.as_bytes();
    if bytes.len() < 19 || bytes[4] != b'-' || bytes[7] != b'-' {
        return None;
    }
    if bytes[10] != b'T' && bytes[10] != b' ' {
        return None;
    }
    if bytes[13] != b':' || bytes[16] != b':' {
        return None;
    }
    let year: i64 = s[0..4].parse().ok()?;
    let month: i64 = s[5..7].parse().ok()?;
    let day: i64 = s[8..10].parse().ok()?;
    let hour: i64 = s[11..13].parse().ok()?;
    let minute: i64 = s[14..16].parse().ok()?;
    let second: i64 = s[17..19].parse().ok()?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    if hour > 23 || minute > 59 || second > 60 {
        return None;
    }

    let mut rest = &s[19..];
    let mut millis = 0i64;
    if let Some(stripped) = rest.strip_prefix('.') {
        let digits: String = stripped.chars().take_while(char::is_ascii_digit).collect();
        if digits.is_empty() {
            return None;
        }
        // Three digits is milliseconds; anything longer is truncated, anything shorter
        // is padded, so `.1` is 100ms and Actions' seven digits do not overflow.
        let mut frac = digits.chars().take(3).collect::<String>();
        while frac.len() < 3 {
            frac.push('0');
        }
        millis = frac.parse().ok()?;
        rest = &rest[1 + digits.len()..];
    }

    let offset_minutes = match rest.as_bytes().first() {
        None => 0,
        Some(b'Z') | Some(b'z') if rest.len() == 1 => 0,
        Some(sign @ (b'+' | b'-')) => {
            let sign = if *sign == b'-' { -1 } else { 1 };
            let body = &rest[1..];
            let (h, m) = match body.len() {
                5 if body.as_bytes()[2] == b':' => (&body[0..2], &body[3..5]),
                4 => (&body[0..2], &body[2..4]),
                2 => (&body[0..2], "00"),
                _ => return None,
            };
            sign * (h.parse::<i64>().ok()? * 60 + m.parse::<i64>().ok()?)
        }
        _ => return None,
    };

    let days = days_from_civil(year, month, day);
    let secs = days * 86_400 + hour * 3600 + minute * 60 + second - offset_minutes * 60;
    Some(secs * 1000 + millis)
}

/// Days from 1970-01-01 to a civil date, by Howard Hinnant's `days_from_civil`. Exact
/// for every proleptic Gregorian date, and no table.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(super) fn check(
        status: Option<&str>,
        conclusion: Option<&str>,
        state: Option<&str>,
    ) -> RawCheck {
        RawCheck {
            status: status.map(str::to_string),
            conclusion: conclusion.map(str::to_string),
            state: state.map(str::to_string),
        }
    }

    #[test]
    fn no_checks_is_none_and_one_failure_is_failing() {
        assert_eq!(rollup_checks(&[]), PrChecks::None);
        assert_eq!(
            rollup_checks(&[
                check(Some("COMPLETED"), Some("SUCCESS"), None),
                check(Some("COMPLETED"), Some("FAILURE"), None),
            ]),
            PrChecks::Failing,
            "one red check is a red PR, whatever else passed"
        );
    }

    #[test]
    fn a_check_that_has_not_concluded_is_pending_not_passing() {
        assert_eq!(
            rollup_checks(&[
                check(Some("COMPLETED"), Some("SUCCESS"), None),
                check(Some("IN_PROGRESS"), None, None),
            ]),
            PrChecks::Pending
        );
        assert_eq!(
            rollup_checks(&[check(None, None, Some("PENDING"))]),
            PrChecks::Pending
        );
        assert_eq!(
            rollup_checks(&[check(Some("COMPLETED"), Some("SKIPPED"), None)]),
            PrChecks::Passing,
            "skipped is not failing and not running, so the rollup is green"
        );
    }

    /// The state gh reports is upper-cased on the way in, because the classifier
    /// compares it to `MERGED`/`CLOSED` literals and gh has spelled it both ways.
    #[test]
    fn the_activity_parse_upcases_states_and_drops_id_less_items() {
        let raw: RawActivity = serde_json::from_str(
            r#"{
              "state": "merged",
              "statusCheckRollup": [],
              "comments": [
                {"id": "c1", "author": {"login": "someone"}, "body": "hi"},
                {"author": {"login": "ghost"}, "body": "no id"}
              ],
              "reviews": [{"id": "r1", "state": "changes_requested"}]
            }"#,
        )
        .expect("gh's shape parses");
        let act = parse_activity(raw);
        assert_eq!(act.state, "MERGED");
        assert_eq!(act.checks, PrChecks::None);
        assert_eq!(act.comments.len(), 1, "the id-less comment is dropped");
        assert_eq!(act.comments[0].author, "someone");
        assert_eq!(act.reviews[0].state, "CHANGES_REQUESTED");
        assert_eq!(
            act.reviews[0].author, "",
            "an absent author is empty, not a failure"
        );
    }

    /// Every probe answers `None`/empty for a `gh` that failed, which is the contract
    /// the poll loop is built on: a failed pass changes nothing.
    #[tokio::test]
    async fn a_failing_gh_polls_nothing_rather_than_erroring() {
        temp_env("JUANCODE_GH_BIN", "/usr/bin/false");
        assert!(pr_activity("/tmp", 1).await.is_none());
        assert!(repo_nwo("/tmp").await.is_none());
    }

    /// The one variable this module reads, pointed at a binary that always fails.
    /// Process-global, and nothing else in this crate's tests reads it.
    fn temp_env(key: &str, value: &str) {
        std::env::set_var(key, value);
    }
}

/// The reader's half: the list parse, the two orders, the triage question and the
/// date arithmetic the age chip is made of. Ported from `GhTests.swift`, whose
/// expectations are the contract both cores answer to — a row that reads "4h" on the
/// desktop must read "4h" on the phone.
#[cfg(test)]
mod list_tests {
    use super::tests::check;
    use super::*;

    fn raw(number: i64) -> RawPr {
        RawPr {
            number,
            title: format!("t{number}"),
            url: format!("https://github.com/o/r/pull/{number}"),
            head_ref_name: "b".into(),
            ..Default::default()
        }
    }

    fn pr(number: i64) -> PullRequest {
        parse_prs(vec![raw(number)]).remove(0)
    }

    fn author(login: &str) -> RawListAuthor {
        RawListAuthor {
            login: Some(login.into()),
        }
    }

    #[test]
    fn the_list_parse_maps_gh_onto_the_wire_shape_and_rolls_up_its_checks() {
        let out = parse_prs(vec![
            RawPr {
                number: 42,
                title: "Fix login".into(),
                url: "https://github.com/o/r/pull/42".into(),
                head_ref_name: "fix-login".into(),
                status_check_rollup: Some(vec![check(Some("COMPLETED"), Some("SUCCESS"), None)]),
                author: Some(author("octocat")),
                // An assignee with no login is dropped rather than added as "": a blank
                // handle would match a blank viewer and put a stranger's PR in your queue.
                assignees: Some(vec![
                    author("octocat"),
                    RawListAuthor::default(),
                    author("hubber"),
                ]),
                ..Default::default()
            },
            RawPr {
                number: 7,
                title: "WIP toggle".into(),
                url: "https://github.com/o/r/pull/7".into(),
                head_ref_name: "toggle".into(),
                is_draft: true,
                ..Default::default()
            },
        ]);
        assert_eq!(out[0].branch, "fix-login");
        assert_eq!(out[0].checks, PrChecks::Passing);
        assert_eq!(out[0].author, "octocat");
        assert_eq!(out[0].assignees, vec!["octocat", "hubber"]);
        assert_eq!((out[0].check_count, out[0].passed_count), (1, 1));
        assert!(out[1].draft);
        assert_eq!(out[1].checks, PrChecks::None, "no checks is not no colour");
        assert_eq!(out[1].author, "", "a ghost author is empty, not a failure");
    }

    #[test]
    fn passed_counts_exclude_the_failing_and_the_still_running() {
        let checks = [
            check(Some("COMPLETED"), Some("SUCCESS"), None),
            check(Some("COMPLETED"), Some("SKIPPED"), None),
            check(Some("COMPLETED"), Some("NEUTRAL"), None),
            check(Some("COMPLETED"), Some("FAILURE"), None),
            check(Some("IN_PROGRESS"), None, None),
            check(None, None, Some("PENDING")),
            check(None, None, Some("SUCCESS")),
        ];
        assert_eq!(count_passed_checks(&checks), 4);
        assert_eq!(count_passed_checks(&[]), 0);
    }

    #[test]
    fn an_unrecognised_review_decision_survives_as_itself() {
        let out = parse_prs(vec![RawPr {
            review_decision: Some("SOMETHING_NEW".into()),
            review_requests: Some(vec![
                RawReviewRequest {
                    login: Some("hubber".into()),
                    ..Default::default()
                },
                RawReviewRequest {
                    slug: Some("platform".into()),
                    ..Default::default()
                },
                RawReviewRequest::default(),
            ]),
            ..raw(9)
        }]);
        assert_eq!(out[0].review_decision.as_deref(), Some("SOMETHING_NEW"));
        assert!(
            !out[0].changes_requested(),
            "a decision this core does not know is not a demand for changes"
        );
        assert_eq!(out[0].review_requests, vec!["hubber", "platform"]);
    }

    #[test]
    fn the_backfill_query_only_fires_when_it_scopes_past_the_page() {
        assert_eq!(
            pr_backfill_query(true, false, "", "octocat").as_deref(),
            Some("state:open author:octocat")
        );
        assert_eq!(
            pr_backfill_query(true, true, " 403 ", "octocat").as_deref(),
            Some("state:open author:octocat assignee:octocat 403")
        );
        assert_eq!(
            pr_backfill_query(false, false, "fix flake", "").as_deref(),
            Some("state:open fix flake")
        );
        // Nothing to add: the page already is this view.
        assert_eq!(pr_backfill_query(false, false, "   ", "octocat"), None);
        // And mine/assigned cannot scope while the login is unknown, so firing would
        // only repeat the unscoped page.
        assert_eq!(pr_backfill_query(true, true, "", ""), None);
    }

    #[test]
    fn a_backfill_is_unioned_in_without_disturbing_what_is_already_on_screen() {
        let mut base = vec![pr(50), pr(40)];
        base[0].unresolved_comments = 4;
        let extra = vec![pr(50), pr(12)];
        let merged = merge_pr_lists(base, extra);
        assert_eq!(
            merged.iter().map(|p| p.number).collect::<Vec<_>>(),
            vec![50, 40, 12],
            "shown rows keep their places and the older match lands at the end"
        );
        assert_eq!(
            merged[0].unresolved_comments, 4,
            "the enriched entry wins over the backfill's thinner copy of the same PR"
        );
    }

    #[test]
    fn the_two_orders_are_the_two_questions_the_list_answers() {
        let prs = vec![pr(50), pr(40), pr(30), pr(20)];
        let tracked = BTreeSet::from([40, 20]);
        assert_eq!(
            sort_prs_tracked_first(prs.clone(), &tracked)
                .iter()
                .map(|p| p.number)
                .collect::<Vec<_>>(),
            vec![40, 20, 50, 30],
            "tracked leads, and both bands keep the order they came in"
        );
        assert_eq!(
            sort_prs_tracked_first(prs.clone(), &BTreeSet::new())
                .iter()
                .map(|p| p.number)
                .collect::<Vec<_>>(),
            vec![50, 40, 30, 20]
        );
        assert_eq!(
            sort_prs_by_submit_date(vec![pr(20), pr(50), pr(30), pr(40)])
                .iter()
                .map(|p| p.number)
                .collect::<Vec<_>>(),
            vec![50, 40, 30, 20]
        );
    }

    #[test]
    fn the_text_filter_reads_the_number_as_a_prefix_and_the_rest_as_text() {
        let mut p = pr(4821);
        p.title = "Fix login redirect".into();
        p.branch = "juan/fix-login".into();
        p.author = "octocat".into();
        for q in [
            "", "   ", "LOGIN", "octo", "juan/fix", "#4821", "4821", "48",
        ] {
            assert!(pr_matches_query(&p, q), "{q:?} should match");
        }
        for q in ["logout", "#99", "#"] {
            assert!(!pr_matches_query(&p, q), "{q:?} should not match");
        }
    }

    fn triage(
        number: i64,
        author: &str,
        assignees: &[&str],
        checks: PrChecks,
        unresolved: i64,
        draft: bool,
        decision: Option<&str>,
        requests: &[&str],
    ) -> PullRequest {
        PullRequest {
            author: author.into(),
            assignees: assignees.iter().map(|s| s.to_string()).collect(),
            checks,
            unresolved_comments: unresolved,
            draft,
            review_decision: decision.map(str::to_string),
            review_requests: requests.iter().map(|s| s.to_string()).collect(),
            ..pr(number)
        }
    }

    #[test]
    fn nothing_needs_a_viewer_this_core_cannot_name() {
        let p = triage(1, "octocat", &[], PrChecks::Failing, 0, false, None, &[]);
        assert_eq!(pr_attention_reason(&p, "", &BTreeSet::new()), None);
    }

    #[test]
    fn your_own_pr_is_ranked_changes_then_ci_then_threads() {
        let none = BTreeSet::new();
        let with_all = triage(
            1,
            "octocat",
            &[],
            PrChecks::Failing,
            2,
            false,
            Some("CHANGES_REQUESTED"),
            &[],
        );
        assert_eq!(
            pr_attention_reason(&with_all, "octocat", &none),
            Some(PrAttentionReason::ChangesRequested)
        );
        let red = triage(1, "octocat", &[], PrChecks::Failing, 2, false, None, &[]);
        assert_eq!(
            pr_attention_reason(&red, "octocat", &none),
            Some(PrAttentionReason::CiFailing)
        );
        let threads = triage(1, "octocat", &[], PrChecks::Passing, 2, false, None, &[]);
        assert_eq!(
            pr_attention_reason(&threads, "octocat", &none),
            Some(PrAttentionReason::Unresolved)
        );
        let clean = triage(1, "octocat", &[], PrChecks::Passing, 0, false, None, &[]);
        assert_eq!(pr_attention_reason(&clean, "octocat", &none), None);
        // Assigned is as much yours as authored.
        let assigned = triage(
            1,
            "hubber",
            &["octocat"],
            PrChecks::Failing,
            0,
            false,
            None,
            &[],
        );
        assert_eq!(
            pr_attention_reason(&assigned, "octocat", &none),
            Some(PrAttentionReason::CiFailing)
        );
    }

    /// The one asymmetry in the rule, and the reason for it: red CI on a draft is what
    /// a draft is for, but a human asking for changes on one is still a human asking.
    #[test]
    fn red_ci_on_a_draft_is_not_an_ask_but_a_human_still_is() {
        let none = BTreeSet::new();
        let red_draft = triage(1, "octocat", &[], PrChecks::Failing, 0, true, None, &[]);
        assert_eq!(pr_attention_reason(&red_draft, "octocat", &none), None);
        let asked_draft = triage(
            1,
            "octocat",
            &[],
            PrChecks::Passing,
            0,
            true,
            Some("CHANGES_REQUESTED"),
            &[],
        );
        assert_eq!(
            pr_attention_reason(&asked_draft, "octocat", &none),
            Some(PrAttentionReason::ChangesRequested)
        );
    }

    #[test]
    fn someone_elses_pr_only_lands_when_your_review_is_the_one_requested() {
        let none = BTreeSet::new();
        let theirs = triage(1, "hubber", &[], PrChecks::Failing, 0, false, None, &[]);
        assert_eq!(
            pr_attention_reason(&theirs, "octocat", &none),
            None,
            "somebody else's red CI is not your queue"
        );
        let asked = triage(
            1,
            "hubber",
            &[],
            PrChecks::Passing,
            0,
            false,
            None,
            &["octocat"],
        );
        assert_eq!(
            pr_attention_reason(&asked, "octocat", &none),
            Some(PrAttentionReason::ReviewRequested)
        );
        let team = triage(
            1,
            "hubber",
            &[],
            PrChecks::Passing,
            0,
            false,
            None,
            &["platform"],
        );
        assert_eq!(
            pr_attention_reason(&team, "octocat", &BTreeSet::from(["platform".to_string()])),
            Some(PrAttentionReason::ReviewRequested)
        );
        // And your own PR never joins the review queue, however GitHub lists you on it.
        let own = triage(
            1,
            "octocat",
            &[],
            PrChecks::Passing,
            0,
            false,
            None,
            &["octocat"],
        );
        assert_eq!(pr_attention_reason(&own, "octocat", &none), None);
    }

    #[test]
    fn the_triage_list_orders_by_reason_then_newest_across_every_folder() {
        let a = vec![
            triage(10, "octocat", &[], PrChecks::Passing, 1, false, None, &[]),
            triage(20, "octocat", &[], PrChecks::Failing, 0, false, None, &[]),
            triage(
                30,
                "octocat",
                &[],
                PrChecks::Passing,
                0,
                false,
                Some("APPROVED"),
                &[],
            ),
        ];
        let b = vec![
            triage(40, "octocat", &[], PrChecks::Failing, 0, false, None, &[]),
            triage(
                50,
                "hubber",
                &[],
                PrChecks::Passing,
                0,
                false,
                None,
                &["octocat"],
            ),
        ];
        let rows = prs_needing_you(
            &[
                FolderPrs {
                    cwd: "/a".into(),
                    prs: a,
                    viewer: "octocat".into(),
                },
                FolderPrs {
                    cwd: "/b".into(),
                    prs: b,
                    viewer: "octocat".into(),
                },
            ],
            &BTreeSet::new(),
        );
        assert_eq!(
            rows.iter().map(|r| r.pr.number).collect::<Vec<_>>(),
            vec![40, 20, 10, 50],
            "#30 is clean, and the rest sort by reason before number"
        );
        assert_eq!(rows[0].cwd, "/b");
        assert_eq!(rows[0].label, "CI failing");
        assert_eq!(rows[3].reason, PrAttentionReason::ReviewRequested);
    }

    /// The counts are merged rather than parsed with the list because the list call
    /// cannot see thread resolution at all — one GraphQL call answers for every PR.
    #[test]
    fn unresolved_counts_are_read_per_pr_and_overlaid_on_the_list() {
        let counts = parse_unresolved_thread_counts(
            r#"{"data":{"repository":{"pullRequests":{"nodes":[
                 {"number":10,"reviewThreads":{"nodes":[
                   {"isResolved":false},{"isResolved":true},{"isResolved":false}]}},
                 {"number":11,"reviewThreads":{"nodes":[]}},
                 {"number":12,"reviewThreads":{"nodes":[{"isResolved":true}]}}
               ]}}}}"#,
        );
        assert_eq!(counts.get(&10), Some(&2));
        assert_eq!(counts.get(&11), Some(&0));
        assert_eq!(counts.get(&12), Some(&0));
        for garbage in ["", "not json", "{}"] {
            assert!(parse_unresolved_thread_counts(garbage).is_empty());
        }

        let mut prs = vec![pr(10), pr(11)];
        merge_unresolved_counts(&mut prs, &counts);
        assert_eq!(prs[0].unresolved_comments, 2);
        assert_eq!(prs[1].unresolved_comments, 0);
    }

    #[test]
    fn a_pr_urls_owner_and_name_keep_their_case_for_graphql() {
        assert_eq!(
            repo_owner_name("https://github.com/owner-X/repo.y/pull/42"),
            Some(("owner-X".into(), "repo.y".into())),
            "lower-casing here would ask GraphQL about a repo GitHub does not have"
        );
        assert_eq!(repo_owner_name("https://example.com/o/r/pull/1"), None);
        assert_eq!(repo_owner_name(""), None);
    }

    #[test]
    fn check_runs_normalise_case_so_a_red_check_cannot_hide_behind_it() {
        let runs = parse_check_runs(
            r#"[{"name":"build","state":"SUCCESS","bucket":"pass",
                 "link":"https://github.com/o/r/actions/runs/100/job/1"},
                {"name":"test","state":"failure","bucket":"Fail",
                 "link":"https://github.com/o/r/actions/runs/101/job/2"}]"#,
        );
        assert_eq!(runs.len(), 2);
        assert!(!runs[0].failed());
        assert_eq!(
            (runs[1].state.as_str(), runs[1].bucket.as_str()),
            ("FAILURE", "fail")
        );
        assert!(runs[1].failed());
        for garbage in ["", "not json", "[]"] {
            assert!(parse_check_runs(garbage).is_empty());
        }
    }

    #[test]
    fn a_run_id_comes_out_of_an_actions_link_and_nothing_else() {
        assert_eq!(
            run_id_from_check_link("https://github.com/o/r/actions/runs/123456/job/789").as_deref(),
            Some("123456")
        );
        assert_eq!(
            run_id_from_check_link("https://github.com/o/r/actions/runs/42").as_deref(),
            Some("42")
        );
        assert_eq!(
            run_id_from_check_link("https://example.com/ci/build/9"),
            None
        );
        assert_eq!(run_id_from_check_link(""), None);
    }

    #[test]
    fn the_age_chip_is_coarse_on_purpose_and_never_reads_negative() {
        let now = iso8601_ms("2026-08-05T12:00:00Z").expect("a parseable now");
        let at = |s: &str| pr_age_label(Some(s), now);
        assert_eq!(at("2026-08-05T11:35:00Z").as_deref(), Some("25m"));
        assert_eq!(at("2026-08-05T08:00:00Z").as_deref(), Some("4h"));
        assert_eq!(at("2026-08-03T12:00:00Z").as_deref(), Some("2d"));
        assert_eq!(at("2026-07-01T12:00:00Z").as_deref(), Some("5w"));
        assert_eq!(at("2025-01-01T12:00:00Z").as_deref(), Some("1y"));
        assert_eq!(at("2026-08-05T11:59:59Z").as_deref(), Some("1m"));
        assert_eq!(
            at("2026-08-05T12:05:00Z").as_deref(),
            Some("1m"),
            "a clock-skewed future stamp reads as brand new, not as -5m"
        );
        // Rounded rather than truncated: 239.99 minutes is four hours old, not three.
        assert_eq!(at("2026-08-05T08:00:00.500Z").as_deref(), Some("4h"));
        assert_eq!(pr_age_label(None, now), None);
        assert_eq!(pr_age_label(Some("yesterday"), now), None);
    }

    /// The date arithmetic the chip rests on, checked against stamps whose epoch values
    /// are known, including the two the hand-rolled parser could plausibly get wrong:
    /// an offset that is not `Z`, and Actions' seven fractional digits.
    #[test]
    fn the_iso_parse_handles_what_github_actually_emits() {
        assert_eq!(iso8601_ms("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(iso8601_ms("2026-08-05T12:00:00Z"), Some(1_785_931_200_000));
        assert_eq!(
            iso8601_ms("2026-08-05T13:00:00+01:00"),
            iso8601_ms("2026-08-05T12:00:00Z"),
            "an offset is honoured, not ignored"
        );
        assert_eq!(
            iso8601_ms("2026-08-05T12:00:00.1234567Z"),
            Some(1_785_931_200_123),
            "seven fractional digits truncate to milliseconds rather than failing"
        );
        assert_eq!(
            iso8601_ms("2026-08-05T12:00:00.1Z"),
            Some(1_785_931_200_100)
        );
        // A leap day, because the era arithmetic is where a hand-rolled parser goes wrong.
        assert_eq!(iso8601_ms("2024-02-29T00:00:00Z"), Some(1_709_164_800_000));
        for bad in [
            "",
            "yesterday",
            "2026-08-05",
            "2026-13-01T00:00:00Z",
            "2026-08-05T25:00:00Z",
        ] {
            assert_eq!(iso8601_ms(bad), None, "{bad:?} is not a timestamp");
        }
    }

    /// The whole reader half answers "nothing to show" for a `gh` that failed, the same
    /// contract the poller's probes have, because a folder that is not a GitHub repo is
    /// the common case and not an error anybody wants raised.
    #[tokio::test]
    async fn a_failing_gh_reads_as_unavailable_with_a_reason_rather_than_erroring() {
        std::env::set_var("JUANCODE_GH_BIN", "/usr/bin/false");
        let list = open_prs("/tmp").await;
        assert!(!list.available);
        assert!(list.prs.is_empty());
        assert!(list.error.is_some(), "a hidden badge still says why");
        assert!(pr_for_branch("/tmp", "main").await.is_none());
        assert!(search_open_prs("/tmp", "state:open").await.is_empty());
        assert!(pr_check_runs("/tmp", 1).await.is_empty());
        assert_eq!(failed_check_logs("/tmp", 1, 5).await, "");
        assert!(comment_on_pr("/tmp", 1, "hi").await.is_err());
    }

    /// And a branch nobody named never reaches `gh` at all: an empty `--head` would ask
    /// GitHub for the newest PR of any branch and answer as if it were this one's.
    #[tokio::test]
    async fn a_blank_branch_is_answered_without_launching_anything() {
        std::env::set_var("JUANCODE_GH_BIN", "/does/not/exist/gh");
        assert!(pr_for_branch("/tmp", "   ").await.is_none());
    }
}

#[cfg(test)]
mod viewer_tests {
    use super::*;

    fn envelope(mine: &str, reviews: &str) -> String {
        format!(r#"{{"data":{{"mine":{{"nodes":[{mine}]}},"reviews":{{"nodes":[{reviews}]}}}}}}"#)
    }

    fn node(number: i64, repo: &str, author: &str) -> String {
        format!(
            r#"{{"number":{number},"title":"t","url":"https://github.com/{repo}/pull/{number}",
                 "isDraft":false,"createdAt":"2026-09-01T09:00:00Z","headRefName":"b",
                 "additions":1,"deletions":2,"changedFiles":3,
                 "repository":{{"nameWithOwner":"{repo}"}},"author":{{"login":"{author}"}},
                 "assignees":{{"nodes":[]}},"reviewDecision":null,
                 "reviewRequests":{{"nodes":[{{"requestedReviewer":{{"login":"octocat"}}}}]}},
                 "reviewThreads":{{"nodes":[{{"isResolved":false}},{{"isResolved":true}}]}},
                 "rollup":{{"nodes":[{{"commit":{{"statusCheckRollup":{{"contexts":{{"nodes":[
                   {{"status":"COMPLETED","conclusion":"SUCCESS"}},
                   {{"status":"COMPLETED","conclusion":"FAILURE"}}]}}}}}}}}]}}}}"#
        )
    }

    #[test]
    fn a_hit_carries_the_same_shape_the_folder_list_does() {
        let rows = parse_viewer_prs(&envelope(&node(42, "o/r", "octocat"), "")).unwrap();
        assert_eq!(rows.len(), 1);
        let row = &rows[0];
        assert_eq!(row.repo, "o/r");
        assert_eq!(row.reason, ViewerPrReason::Mine);
        // One green and one red is a red PR with passed_count 1, same rollup as the list.
        assert_eq!(row.pr.checks, PrChecks::Failing);
        assert_eq!(row.pr.check_count, 2);
        assert_eq!(row.pr.passed_count, 1);
        assert_eq!(row.pr.unresolved_comments, 1);
        assert_eq!(row.pr.review_requests, vec!["octocat".to_string()]);
        assert_eq!(row.pr.changed_files, Some(3));
    }

    #[test]
    fn authorship_wins_so_a_pr_appears_once() {
        let same = node(42, "o/r", "octocat");
        let rows = parse_viewer_prs(&envelope(&same, &same)).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].reason, ViewerPrReason::Mine);
    }

    #[test]
    fn the_two_buckets_keep_their_order_and_their_reason() {
        let rows = parse_viewer_prs(&envelope(
            &node(42, "o/r", "octocat"),
            &node(7, "o/r", "hubber"),
        ))
        .unwrap();
        assert_eq!(
            rows.iter()
                .map(|r| (r.pr.number, r.reason))
                .collect::<Vec<_>>(),
            vec![
                (42, ViewerPrReason::Mine),
                (7, ViewerPrReason::ReviewRequested)
            ]
        );
    }

    #[test]
    fn a_node_that_is_not_a_pull_request_costs_that_row_only() {
        let rows = parse_viewer_prs(&envelope(
            &format!("{{}},{}", node(42, "o/r", "octocat")),
            "",
        ))
        .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].pr.number, 42);
    }

    #[test]
    fn a_payload_that_is_not_the_envelope_is_not_an_empty_queue() {
        assert!(parse_viewer_prs("{\"errors\":[{\"message\":\"bad credentials\"}]}").is_none());
        assert!(parse_viewer_prs("not json").is_none());
        // An envelope with empty buckets IS an answer.
        assert_eq!(parse_viewer_prs(&envelope("", "")).unwrap().len(), 0);
    }

    #[test]
    fn a_repo_the_search_did_not_name_is_lifted_from_the_url() {
        let raw = r#"{"number":9,"url":"https://github.com/lifted/name/pull/9"}"#;
        let rows = parse_viewer_prs(&envelope(raw, "")).unwrap();
        assert_eq!(rows[0].repo, "lifted/name");
    }

    #[test]
    fn the_two_searches_ask_for_different_halves() {
        assert!(viewer_pr_search(true).contains("author:@me"));
        assert!(viewer_pr_search(false).contains("review-requested:@me"));
        for q in [viewer_pr_search(true), viewer_pr_search(false)] {
            assert!(q.contains("is:open is:pr archived:false sort:updated"));
        }
    }

    #[test]
    fn an_already_exists_stderr_is_an_answer_and_not_a_failure() {
        let msg = "a pull request for branch \"x\" into branch \"main\" already exists: \
                   https://github.com/o/r/pull/12\n";
        assert_eq!(
            existing_pr_url(msg),
            Some("https://github.com/o/r/pull/12".to_string())
        );
        assert_eq!(existing_pr_url("gh: not authenticated"), None);
    }

    #[test]
    fn the_created_url_is_the_first_url_gh_printed() {
        assert_eq!(
            first_url("Creating pull request\nhttps://github.com/o/r/pull/3\n"),
            Some("https://github.com/o/r/pull/3".to_string())
        );
        assert_eq!(first_url("nothing here"), None);
    }
}
