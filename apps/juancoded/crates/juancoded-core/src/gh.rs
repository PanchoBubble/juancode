//! The `gh` round-trips the tracked-PR poller needs, and nothing else.
//!
//! A port of the three probes `PrTrackingEngine` calls out of `Gh.swift`. Every one of
//! them is best-effort by construction: `gh` missing, unauthenticated, offline, a cwd
//! that is not a repo, or output that will not parse all come back as "could not poll
//! this tick" rather than as an error, because the poller's answer to all five is the
//! same — try again on the next pass and leave the watch list exactly as it was.
//!
//! The binary is resolved the way every other tool in this daemon is
//! ([`crate::provider::resolve_bin`]), honouring `JUANCODE_GH_BIN`. The user's own
//! `gh` auth is used untouched: no token injection, no shadow `HOME`, same rule as
//! spawning the genuine agent CLIs.

use std::sync::OnceLock;
use std::time::Duration;

use serde::Deserialize;
use tokio::sync::Mutex;

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
            "state,statusCheckRollup,comments,reviews",
        ],
    )
    .await?;
    let raw: RawActivity = serde_json::from_str(&raw).ok()?;
    Some(parse_activity(raw))
}

/// The login `gh` is authenticated as, which is the account the tracking agent posts
/// under. Empty when it cannot be determined, which the classifier reads as "no self
/// filter" rather than as an error.
///
/// Cached for the life of the process, like the Swift core's box: a poll pass over N
/// PRs would otherwise pay N identical round-trips, and nobody swaps `gh` accounts
/// under a running daemon.
pub async fn viewer_login(cwd: &str) -> String {
    static CACHE: OnceLock<Mutex<Option<String>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(None));
    let mut held = cache.lock().await;
    if let Some(cached) = held.as_ref() {
        return cached.clone();
    }
    let login = capture(cwd, &["api", "user", "--jq", ".login"])
        .await
        .map(|out| out.trim().to_string())
        .unwrap_or_default();
    *held = Some(login.clone());
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

#[cfg(test)]
mod tests {
    use super::*;

    fn check(status: Option<&str>, conclusion: Option<&str>, state: Option<&str>) -> RawCheck {
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
