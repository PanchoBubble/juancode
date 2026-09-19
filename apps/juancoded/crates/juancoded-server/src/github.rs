//! The GitHub reads and the review surface, over HTTP.
//!
//! Requests and replies rather than frames, because every one of them is a question
//! somebody asks once and leaves: which PRs are open here, what was said on this one,
//! why is it red, what did the review find. Nothing streams and nothing subscribes, so
//! a subscription would be a socket held open for a single answer.
//!
//! These are the routes `CoreProxyServer` answered 501 for under this core: `/api/prs`
//! and the whole review surface were the desktop's own in-process `gh` calls, which
//! meant the phone console had no PR view at all and the sidecar could not read one.
//! The data layer they serve is `juancoded_core::{gh, gh_convo, pr_timeline,
//! actions_log, review}`; this module is the HTTP shape over it and holds no logic of
//! its own beyond deciding what is a 400, a 404 and a 502.
//!
//! One rule travels with them, from a3ef8c6: a list is one `gh` call and never one per
//! folder. Every route here is scoped to a single `cwd` the caller names, so a client
//! that wants five folders makes five requests it can run in parallel — rather than a
//! route that fans out and pays `fork+exec` (257ms on the machine this was measured on)
//! five times in series before GitHub is even asked.

use std::collections::BTreeSet;

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use juancoded_core::actions_log::parse_actions_log;
use juancoded_core::gh;
use juancoded_core::gh_convo::{self, PrConversation};
use juancoded_core::model::now_ms;
use juancoded_core::pr_timeline::{self, PrTimelineItem};
use juancoded_core::review::{self, CommentSide, DiffComment, ReviewResult};

use crate::serve::CoreHandles;

pub fn routes() -> Router<CoreHandles> {
    Router::new()
        .route("/api/prs", get(prs))
        .route("/api/prs/search", get(search_prs))
        .route("/api/prs/viewer", get(viewer_prs))
        .route("/api/pr/for-branch", get(pr_for_branch))
        .route("/api/pr/diff", get(pr_diff))
        .route("/api/pr/create", post(create_pr))
        .route("/api/pr/comment", post(comment))
        .route("/api/pr/rerun", post(rerun))
        .route("/api/repo", get(repo))
        .route("/api/pr/conversation", get(conversation))
        .route("/api/pr/timeline", get(timeline))
        .route("/api/pr/checks", get(checks))
        .route("/api/pr/actions-log", get(actions_log))
        .route(
            "/api/sessions/{id}/review",
            get(get_review).post(post_review),
        )
        .route(
            "/api/sessions/{id}/comments",
            get(list_comments).post(add_comment).delete(clear_comments),
        )
        .route(
            "/api/sessions/{id}/comments/{commentId}",
            delete(drop_comment),
        )
}

// ── the PR list ──────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct PrsParams {
    /// The checkout to ask about. Required: a PR list with no folder is a question
    /// about no repository.
    pub cwd: Option<String>,
    /// PR numbers already being tracked, comma-separated, which lead the list.
    pub tracked: Option<String>,
    /// `submitted` for strict newest-first; anything else keeps tracked-first.
    pub sort: Option<String>,
    /// The viewer's team slugs, comma-separated, so a team review request counts as an
    /// ask. The caller knows these and `gh` does not report them cheaply.
    pub teams: Option<String>,
}

/// One folder's open PRs, with the triage answer and the order already applied.
///
/// Attention and order are computed here rather than in the client for the reason the
/// whole port exists: the phone and the desktop must not disagree about which PRs are
/// waiting on you, and "waiting on you" is four rules with a priority between them, not
/// a rendering preference.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PrsBody {
    pub available: bool,
    pub prs: Vec<gh::PullRequest>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub viewer: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// The PRs that need the viewer, most urgent first, each with its reason.
    pub needs_you: Vec<gh::NeedsYou>,
}

async fn prs(Query(params): Query<PrsParams>, State(_): State<CoreHandles>) -> Response {
    let Some(cwd) = non_empty(params.cwd) else {
        return bad_request("cwd (absolute project path) required");
    };
    let mut list = gh::open_prs(&cwd).await;
    let viewer = list.viewer.clone().unwrap_or_default();
    let teams = csv_set(params.teams.as_deref());

    let needs_you = gh::prs_needing_you(
        &[gh::FolderPrs {
            cwd: cwd.clone(),
            prs: list.prs.clone(),
            viewer: viewer.clone(),
        }],
        &teams,
    );

    list.prs = if params.sort.as_deref() == Some("submitted") {
        gh::sort_prs_by_submit_date(list.prs)
    } else {
        let tracked: BTreeSet<i64> = params
            .tracked
            .as_deref()
            .map(|raw| {
                raw.split(',')
                    .filter_map(|n| n.trim().parse().ok())
                    .collect()
            })
            .unwrap_or_default();
        gh::sort_prs_tracked_first(list.prs, &tracked)
    };

    Json(PrsBody {
        available: list.available,
        prs: list.prs,
        viewer: list.viewer,
        error: list.error,
        needs_you,
    })
    .into_response()
}

// ── one PR ───────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct PrParams {
    pub cwd: Option<String>,
    pub number: Option<i64>,
    /// The PR's own url. The owner/name is lifted out of it, which is what saves a
    /// `gh repo view` round-trip per read.
    pub url: Option<String>,
}

impl PrParams {
    fn parts(&self) -> Result<(String, i64), Response> {
        let cwd = non_empty(self.cwd.clone())
            .ok_or_else(|| bad_request("cwd (absolute project path) required"))?;
        let number = self
            .number
            .filter(|n| *n > 0)
            .ok_or_else(|| bad_request("a positive PR number required"))?;
        Ok((cwd, number))
    }
}

async fn conversation(Query(params): Query<PrParams>, State(_): State<CoreHandles>) -> Response {
    let (cwd, number) = match params.parts() {
        Ok(parts) => parts,
        Err(response) => return response,
    };
    let Some(url) = non_empty(params.url.clone()) else {
        return bad_request("url (the PR's github.com url) required");
    };
    match gh_convo::pr_conversation(&cwd, number, &url).await {
        Some(conversation) => Json(conversation).into_response(),
        None => unreachable_pr(number),
    }
}

/// The conversation already merged into the order it is read in, with each review
/// carrying the threads it started and the empty cards dropped.
///
/// A route rather than a client-side pass over `/conversation` for the same reason the
/// triage answer is: the merge has three tie-break rules in it, and two clients that
/// implemented them separately would eventually draw two different chronologies of one
/// conversation.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelineBody {
    pub state: String,
    pub body: String,
    pub items: Vec<PrTimelineItem>,
    pub threads: Vec<gh_convo::PrReviewThread>,
}

async fn timeline(Query(params): Query<PrParams>, State(_): State<CoreHandles>) -> Response {
    let (cwd, number) = match params.parts() {
        Ok(parts) => parts,
        Err(response) => return response,
    };
    let Some(url) = non_empty(params.url.clone()) else {
        return bad_request("url (the PR's github.com url) required");
    };
    let Some(conversation) = gh_convo::pr_conversation(&cwd, number, &url).await else {
        return unreachable_pr(number);
    };
    Json(timeline_of(&conversation)).into_response()
}

fn timeline_of(conversation: &PrConversation) -> TimelineBody {
    TimelineBody {
        state: conversation.state.clone(),
        body: conversation.body.clone(),
        items: pr_timeline::pr_visible_timeline(conversation),
        threads: conversation.threads.clone(),
    }
}

/// One CI check, with the coarse outcome its row draws already decided.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckRow {
    #[serde(flatten)]
    pub run: gh::PrCheckRun,
    pub outcome: pr_timeline::PrCheckOutcome,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChecksBody {
    pub checks: Vec<CheckRow>,
}

async fn checks(Query(params): Query<PrParams>, State(_): State<CoreHandles>) -> Response {
    let (cwd, number) = match params.parts() {
        Ok(parts) => parts,
        Err(response) => return response,
    };
    let checks = gh::pr_check_runs(&cwd, number)
        .await
        .into_iter()
        .map(|run| CheckRow {
            outcome: pr_timeline::check_outcome(&run),
            run,
        })
        .collect();
    Json(ChecksBody { checks }).into_response()
}

/// The failing steps of a red build, parsed into folds and lines.
///
/// Always a 200, even when there is nothing: a green PR has no failing log, and that is
/// an answer rather than a failure. `sections: []` is what a client draws "CI is not
/// red" from.
async fn actions_log(Query(params): Query<PrParams>, State(_): State<CoreHandles>) -> Response {
    let (cwd, number) = match params.parts() {
        Ok(parts) => parts,
        Err(response) => return response,
    };
    let raw = gh::failed_check_logs(&cwd, number, 5).await;
    Json(parse_actions_log(&raw)).into_response()
}

// ── the reads the desktop used to make in its own process ────────────────────
//
// juancode-h0l6. Everything below was a `gh` call inside the SwiftUI app: the search
// that reaches past the page cap, the single-branch lookup, a folder's repo identity,
// a PR's diff, and the cross-repo queue behind the toolbar badge. They are here for
// the reason the rest of the module is — a phone cannot shell out — and each is scoped
// to one `cwd` the caller names, never a fan-out over folders.

#[derive(Debug, Deserialize)]
pub struct SearchParams {
    pub cwd: Option<String>,
    /// The `gh pr list --search` qualifiers, already assembled by the caller.
    pub q: Option<String>,
}

/// A repo-scoped PR search. The list route caps at a page of the newest PRs; this is
/// how a client reaches the ones beyond it — your own older PRs, or an old PR matched
/// by a query — and the caller unions the two.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchBody {
    pub prs: Vec<gh::PullRequest>,
}

async fn search_prs(Query(params): Query<SearchParams>, State(_): State<CoreHandles>) -> Response {
    let Some(cwd) = non_empty(params.cwd) else {
        return bad_request("cwd (absolute project path) required");
    };
    let Some(q) = non_empty(params.q) else {
        return bad_request("q (the search qualifiers) required");
    };
    Json(SearchBody {
        prs: gh::search_open_prs(&cwd, &q).await,
    })
    .into_response()
}

#[derive(Debug, Deserialize)]
pub struct BranchParams {
    pub cwd: Option<String>,
    pub branch: Option<String>,
}

/// The open PR for one branch, or `null`. A 200 with no PR rather than a 404: "this
/// branch has no PR" is an answer the header draws, and both a hit and a miss are
/// cached by the caller.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BranchPrBody {
    pub pr: Option<gh::PullRequest>,
}

async fn pr_for_branch(
    Query(params): Query<BranchParams>,
    State(_): State<CoreHandles>,
) -> Response {
    let Some(cwd) = non_empty(params.cwd) else {
        return bad_request("cwd (absolute project path) required");
    };
    let Some(branch) = non_empty(params.branch) else {
        return bad_request("branch required");
    };
    Json(BranchPrBody {
        pr: gh::pr_for_branch(&cwd, &branch).await,
    })
    .into_response()
}

#[derive(Debug, Deserialize)]
pub struct CwdParams {
    pub cwd: Option<String>,
}

/// A checkout's repo identity (`owner/name`), or `null` when it has no GitHub remote.
/// This is what maps a cross-repo queue row — which knows a repo, not a path — back
/// onto a local checkout.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RepoBody {
    pub nwo: Option<String>,
}

async fn repo(Query(params): Query<CwdParams>, State(_): State<CoreHandles>) -> Response {
    let Some(cwd) = non_empty(params.cwd) else {
        return bad_request("cwd (absolute project path) required");
    };
    Json(RepoBody {
        nwo: gh::repo_nwo(&cwd).await,
    })
    .into_response()
}

/// An open PR's net diff, in the same per-file shape `/api/git/diff` answers with.
async fn pr_diff(Query(params): Query<PrParams>, State(_): State<CoreHandles>) -> Response {
    let (cwd, number) = match params.parts() {
        Ok(parts) => parts,
        Err(response) => return response,
    };
    match gh::pr_diff(&cwd, number).await {
        Ok(diff) => Json(diff).into_response(),
        Err(e) => gh_write_failed(e),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ViewerPrsParams {
    /// Any directory that exists. The search is not repo-scoped — that is the point of
    /// it next to `/api/prs` — so this only decides where `gh` is run, and the daemon's
    /// own cwd is used when the caller names none.
    pub cwd: Option<String>,
    /// The viewer's team slugs, comma-separated, so a team review request counts as an
    /// ask. Same parameter, same meaning, as on `/api/prs`.
    pub teams: Option<String>,
}

async fn viewer_prs(
    Query(params): Query<ViewerPrsParams>,
    State(_): State<CoreHandles>,
) -> Response {
    let cwd = non_empty(params.cwd).unwrap_or_else(|| {
        std::env::current_dir()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| "/".into())
    });
    let teams = csv_set(params.teams.as_deref());
    Json(gh::viewer_prs(&cwd, &teams).await).into_response()
}

// ── the writes ───────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreatePrBody {
    pub cwd: Option<String>,
    pub title: Option<String>,
    pub body: Option<String>,
    #[serde(default)]
    pub draft: bool,
}

/// Open a PR for the checkout's current branch. The caller pushes first — this core
/// will not push a branch on somebody's behalf as a side effect of a different verb.
async fn create_pr(State(_): State<CoreHandles>, Json(body): Json<CreatePrBody>) -> Response {
    let Some(cwd) = non_empty(body.cwd) else {
        return bad_request("cwd (absolute project path) required");
    };
    let Some(title) = non_empty(body.title) else {
        return bad_request("title required");
    };
    match gh::create_pr(&cwd, &title, &body.body.unwrap_or_default(), body.draft).await {
        Ok(result) => Json(result).into_response(),
        Err(e) => gh_write_failed(e),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrCommentBody {
    pub cwd: Option<String>,
    pub number: Option<i64>,
    pub body: Option<String>,
    /// The REST id of the review comment being replied to. Absent posts a top-level
    /// comment instead. One route and not two, because the composer is one box whose
    /// target is whether a thread is open under it.
    pub reply_to: Option<i64>,
}

async fn comment(State(_): State<CoreHandles>, Json(body): Json<PrCommentBody>) -> Response {
    let Some(cwd) = non_empty(body.cwd) else {
        return bad_request("cwd (absolute project path) required");
    };
    let Some(number) = body.number.filter(|n| *n > 0) else {
        return bad_request("a positive PR number required");
    };
    let Some(text) = non_empty(body.body) else {
        return bad_request("body required");
    };
    let result = match body.reply_to {
        Some(id) => gh::reply_to_review_comment(&cwd, number, id, &text).await,
        None => gh::comment_on_pr(&cwd, number, &text).await,
    };
    match result {
        Ok(()) => Json(serde_json::json!({ "ok": true })).into_response(),
        Err(e) => gh_write_failed(e),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RerunBody {
    pub cwd: Option<String>,
    pub number: Option<i64>,
    /// GitHub's "re-run failed jobs". Everything otherwise.
    #[serde(default)]
    pub failed_only: bool,
}

async fn rerun(State(_): State<CoreHandles>, Json(body): Json<RerunBody>) -> Response {
    let Some(cwd) = non_empty(body.cwd) else {
        return bad_request("cwd (absolute project path) required");
    };
    let Some(number) = body.number.filter(|n| *n > 0) else {
        return bad_request("a positive PR number required");
    };
    match gh::rerun_checks(&cwd, number, body.failed_only).await {
        Ok(()) => Json(serde_json::json!({ "ok": true })).into_response(),
        Err(e) => gh_write_failed(e),
    }
}

/// A `gh` write or read that failed, carrying the sentence `gh` gave for it. A 502 for
/// the same reason `unreachable_pr` is one: the route exists and the request was
/// well-formed; what failed is the hop to GitHub.
fn gh_write_failed(e: gh::GhError) -> Response {
    (
        StatusCode::BAD_GATEWAY,
        Json(serde_json::json!({ "error": e.0 })),
    )
        .into_response()
}

// ── the review surface ───────────────────────────────────────────────────────

async fn get_review(Path(id): Path<String>, State(handles): State<CoreHandles>) -> Response {
    let Some(reviews) = handles.reviews.as_ref() else {
        return no_review_store();
    };
    if handles.sessions.meta(&id).is_none() {
        return not_found(&id);
    }
    match reviews.get_review(&id) {
        Ok(Some(result)) => Json(result).into_response(),
        // `null`, not a 404: the session is real and simply has not been reviewed,
        // which is a different thing from a session this core does not hold.
        Ok(None) => Json(Option::<ReviewResult>::None).into_response(),
        Err(e) => store_error(e),
    }
}

/// Run a review pass over the session's working tree and cache it.
///
/// Synchronous on purpose, and slow — it is a whole model turn. A client that does not
/// want to hold a request open for four minutes reads the cached one instead; this is
/// the route that makes a new one exist.
async fn post_review(Path(id): Path<String>, State(handles): State<CoreHandles>) -> Response {
    let Some(reviews) = handles.reviews.as_ref() else {
        return no_review_store();
    };
    let Some(meta) = handles.sessions.meta(&id) else {
        return not_found(&id);
    };
    let comments = match reviews.list_comments(&id) {
        Ok(comments) => comments,
        Err(e) => return store_error(e),
    };
    let cwd = meta.cwd.clone();
    // The git reads are blocking and there are a few per changed file, so they go to a
    // blocking thread rather than parking a runtime worker for the length of a diff.
    let files = match tokio::task::spawn_blocking(move || review::working_tree_files(&cwd)).await {
        Ok(files) => files,
        Err(_) => return store_error(anyhow::anyhow!("reading the working tree was cancelled")),
    };
    let result = review::run_review(&meta.cwd, &files, &comments, now_ms()).await;
    // Cached even when it failed: "the last pass errored, and this is why" is what the
    // panel shows, and losing it would make a failed review look like no review.
    if let Err(e) = reviews.save_review(&id, &result) {
        return store_error(e);
    }
    // Always a 200, whatever the pass concluded. A review that errored is a result the
    // panel renders — "the last pass failed, and this is why" — not a failed request.
    Json(result).into_response()
}

async fn list_comments(Path(id): Path<String>, State(handles): State<CoreHandles>) -> Response {
    let Some(reviews) = handles.reviews.as_ref() else {
        return no_review_store();
    };
    if handles.sessions.meta(&id).is_none() {
        return not_found(&id);
    }
    match reviews.list_comments(&id) {
        Ok(comments) => Json(comments).into_response(),
        Err(e) => store_error(e),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommentBody {
    pub file: String,
    /// `old` or `new`. Refused rather than defaulted: a comment on the wrong side of a
    /// hunk lands on a line the author never wrote.
    pub side: String,
    pub line: i64,
    pub end_line: Option<i64>,
    pub body: String,
    pub quote: Option<String>,
    pub commit_sha: Option<String>,
    pub commit_subject: Option<String>,
}

async fn add_comment(
    Path(id): Path<String>,
    State(handles): State<CoreHandles>,
    Json(body): Json<CommentBody>,
) -> Response {
    let Some(reviews) = handles.reviews.as_ref() else {
        return no_review_store();
    };
    if handles.sessions.meta(&id).is_none() {
        return not_found(&id);
    }
    let side = match body.side.as_str() {
        "old" => CommentSide::Old,
        "new" => CommentSide::New,
        _ => return bad_request("file, side ('old'|'new'), integer line, and body required"),
    };
    let text = body.body.trim();
    if text.is_empty() {
        return bad_request("file, side ('old'|'new'), integer line, and body required");
    }
    let end = body.end_line.unwrap_or(body.line);
    let comment = DiffComment {
        id: uuid::Uuid::new_v4().to_string(),
        session_id: id,
        file: body.file,
        side,
        // Normalised rather than trusted: a client that dragged a selection upwards
        // sends the range backwards, and a backwards range highlights nothing.
        line: body.line.min(end),
        end_line: body.line.max(end),
        body: text.to_string(),
        created_at: now_ms(),
        quote: body.quote,
        commit_sha: body.commit_sha,
        commit_subject: body.commit_subject,
    };
    match reviews.add_comment(&comment) {
        Ok(()) => (StatusCode::CREATED, Json(comment)).into_response(),
        Err(e) => store_error(e),
    }
}

async fn clear_comments(Path(id): Path<String>, State(handles): State<CoreHandles>) -> Response {
    let Some(reviews) = handles.reviews.as_ref() else {
        return no_review_store();
    };
    if handles.sessions.meta(&id).is_none() {
        return not_found(&id);
    }
    match reviews.clear_comments(&id) {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => store_error(e),
    }
}

async fn drop_comment(
    Path((id, comment_id)): Path<(String, String)>,
    State(handles): State<CoreHandles>,
) -> Response {
    let Some(reviews) = handles.reviews.as_ref() else {
        return no_review_store();
    };
    match reviews.remove_comment(&id, &comment_id) {
        Ok(true) => StatusCode::NO_CONTENT.into_response(),
        Ok(false) => (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({ "error": format!("no comment `{comment_id}` on `{id}`") })),
        )
            .into_response(),
        Err(e) => store_error(e),
    }
}

// ── shared answers ───────────────────────────────────────────────────────────

fn non_empty(value: Option<String>) -> Option<String> {
    value
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

fn csv_set(raw: Option<&str>) -> BTreeSet<String> {
    raw.map(|raw| {
        raw.split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .collect()
    })
    .unwrap_or_default()
}

fn bad_request(message: &str) -> Response {
    (
        StatusCode::BAD_REQUEST,
        Json(serde_json::json!({ "error": message })),
    )
        .into_response()
}

fn not_found(id: &str) -> Response {
    (
        StatusCode::NOT_FOUND,
        Json(serde_json::json!({ "error": format!("no session `{id}`") })),
    )
        .into_response()
}

/// `gh` could not answer for this PR. A 502 and not a 404: the route exists and the PR
/// probably does — what failed is the hop to GitHub, and a client told "not found"
/// would cache a PR out of existence.
fn unreachable_pr(number: i64) -> Response {
    (
        StatusCode::BAD_GATEWAY,
        Json(serde_json::json!({
            "error": format!(
                "gh could not read PR #{number}: it is missing, unauthenticated, offline, \
                 or this is not a GitHub checkout"
            )
        })),
    )
        .into_response()
}

/// A tree that mounted no review store. A 501 rather than an empty list, because an
/// empty list is a promise that nothing was staged and this core cannot make it.
fn no_review_store() -> Response {
    (
        StatusCode::NOT_IMPLEMENTED,
        Json(serde_json::json!({
            "error": "this core mounted no review store, so diff comments and reviews \
                      have nowhere to live"
        })),
    )
        .into_response()
}

fn store_error(e: anyhow::Error) -> Response {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(serde_json::json!({ "error": e.to_string() })),
    )
        .into_response()
}
