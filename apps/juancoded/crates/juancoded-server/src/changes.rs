//! The git working tree, over HTTP.
//!
//! Two route families, because there are two askers and they address the tree
//! differently.
//!
//! * `/api/sessions/{id}/…` — what a REMOTE client asks. It knows a session id and
//!   nothing about the filesystem, and these are the same URLs the Swift core served,
//!   so the relay forwards them and a client's code does not move. `?cwd=` may name a
//!   different worktree, and it is validated against that session's own repo listing:
//!   a path this core has not just seen in `git worktree list` is ignored and the
//!   session's own cwd answers instead.
//! * `/api/git/…?cwd=` — what the DESKTOP asks, over loopback, about paths that are
//!   not any session's cwd: an orphaned worktree whose session was deleted is exactly
//!   the folder the at-risk badge exists for, and there is no session id to reach it
//!   by. This family is not in the relay's allowlist and does not leave this machine.
//!
//! Every handler runs on `spawn_blocking`. These are `git` invocations, and a fork
//! costs 257ms on this machine before the child runs an instruction — holding the
//! async runtime's worker for that would stall the pty bytes sharing it.

use axum::extract::{Path as AxPath, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use juancoded_core::{at_risk, git, worktree};

use crate::serve::CoreHandles;

/// How many commits the picker asks for when a caller names no bound.
const DEFAULT_COMMIT_LIMIT: usize = 50;

/// How many paths the Quick Open index answers with. A pathological checkout cannot
/// be allowed to turn one keystroke into a megabyte of JSON.
const DEFAULT_FILE_LIMIT: usize = 20_000;

pub fn routes() -> Router<CoreHandles> {
    Router::new()
        .route("/api/sessions/{id}/diff", get(session_diff))
        .route("/api/sessions/{id}/git", get(session_state))
        .route("/api/sessions/{id}/worktrees", get(session_worktrees))
        .route("/api/sessions/{id}/file", get(session_file))
        .route("/api/git/state", get(path_state))
        .route("/api/git/diff", get(path_diff))
        .route("/api/git/worktrees", get(path_worktrees))
        .route("/api/git/commits", get(path_commits))
        .route("/api/git/status", get(path_status))
        .route("/api/git/files", get(path_files))
        .route("/api/git/changes", get(path_changes))
        .route("/api/git/at-risk", get(path_at_risk))
        .route("/api/git/agent-worktree", get(path_agent_worktree))
        .route("/api/git/file", get(path_file))
}

/// `?cwd=`, `?base=`, `?commit=`, `?path=`, `?limit=`, `?pid=` — the whole query
/// vocabulary of this family, in one struct so no route invents a second spelling.
#[derive(Debug, Default, Deserialize)]
pub struct GitParams {
    pub cwd: Option<String>,
    /// Diff this branch against `base` instead of against HEAD. Present with an empty
    /// value means "the branch's own inferred base", which is what the panel's default
    /// comparison is.
    pub base: Option<String>,
    /// Diff exactly this commit instead of the working tree.
    pub commit: Option<String>,
    pub path: Option<String>,
    pub limit: Option<usize>,
    pub pid: Option<i32>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileBody {
    pub path: String,
    pub content: String,
}

/// The at-risk probe, flattened onto the wire. `Probe` itself is three fields and a
/// `GitState`; this is that, with the two counts the classifier distrusts kept
/// separate so the reading side cannot confuse them (see [`at_risk::Probe`]).
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AtRiskBody {
    pub state: git::GitState,
    pub dirty_files: usize,
    pub ahead_of_base: Option<i64>,
    pub head_on_remote: bool,
}

// ── session-addressed ────────────────────────────────────────────────────────

/// The session's own cwd, or the worktree `?cwd=` names when that path is really one
/// of this repo's worktrees.
///
/// The validation is the point. Without it `?cwd=` is "run git wherever I say" on a
/// route a remote client reaches; with it, the set of answerable paths is the set git
/// itself just listed for the session's repo.
fn target_cwd(session_cwd: &str, requested: Option<&str>) -> String {
    let Some(req) = requested.map(str::trim).filter(|r| !r.is_empty()) else {
        return session_cwd.to_string();
    };
    if same_path(req, session_cwd) {
        return session_cwd.to_string();
    }
    worktree::list(session_cwd)
        .into_iter()
        .find(|t| same_path(&t.path, req))
        .map(|t| t.path)
        .unwrap_or_else(|| session_cwd.to_string())
}

fn same_path(a: &str, b: &str) -> bool {
    a.trim_end_matches('/') == b.trim_end_matches('/')
}

/// The cwd a session-addressed route acts on, or a 404 when there is no such session.
fn session_cwd(handles: &CoreHandles, id: &str, requested: Option<&str>) -> Option<String> {
    let meta = handles.sessions.meta(id)?;
    Some(target_cwd(&meta.cwd, requested))
}

async fn session_diff(
    AxPath(id): AxPath<String>,
    Query(p): Query<GitParams>,
    State(handles): State<CoreHandles>,
) -> Response {
    let Some(cwd) = session_cwd(&handles, &id, p.cwd.as_deref()) else {
        return not_found(&id);
    };
    diff_for(cwd, p).await
}

async fn session_state(
    AxPath(id): AxPath<String>,
    Query(p): Query<GitParams>,
    State(handles): State<CoreHandles>,
) -> Response {
    let Some(cwd) = session_cwd(&handles, &id, p.cwd.as_deref()) else {
        return not_found(&id);
    };
    blocking(move || Json(git::state(&cwd)).into_response()).await
}

async fn session_worktrees(
    AxPath(id): AxPath<String>,
    Query(p): Query<GitParams>,
    State(handles): State<CoreHandles>,
) -> Response {
    let Some(cwd) = session_cwd(&handles, &id, p.cwd.as_deref()) else {
        return not_found(&id);
    };
    blocking(move || Json(worktree::list(&cwd)).into_response()).await
}

async fn session_file(
    AxPath(id): AxPath<String>,
    Query(p): Query<GitParams>,
    State(handles): State<CoreHandles>,
) -> Response {
    let Some(cwd) = session_cwd(&handles, &id, p.cwd.as_deref()) else {
        return not_found(&id);
    };
    file_for(cwd, p).await
}

// ── path-addressed (loopback only) ───────────────────────────────────────────

async fn path_state(Query(p): Query<GitParams>) -> Response {
    let Some(cwd) = required_cwd(&p) else {
        return missing_cwd();
    };
    blocking(move || Json(git::state(&cwd)).into_response()).await
}

async fn path_diff(Query(p): Query<GitParams>) -> Response {
    let Some(cwd) = required_cwd(&p) else {
        return missing_cwd();
    };
    diff_for(cwd, p).await
}

async fn path_worktrees(Query(p): Query<GitParams>) -> Response {
    let Some(cwd) = required_cwd(&p) else {
        return missing_cwd();
    };
    blocking(move || Json(worktree::list(&cwd)).into_response()).await
}

async fn path_commits(Query(p): Query<GitParams>) -> Response {
    let Some(cwd) = required_cwd(&p) else {
        return missing_cwd();
    };
    let limit = p.limit.unwrap_or(DEFAULT_COMMIT_LIMIT);
    blocking(move || Json(git::recent_commits(&cwd, limit)).into_response()).await
}

async fn path_status(Query(p): Query<GitParams>) -> Response {
    let Some(cwd) = required_cwd(&p) else {
        return missing_cwd();
    };
    blocking(move || Json(git::work_tree_status(&cwd)).into_response()).await
}

async fn path_files(Query(p): Query<GitParams>) -> Response {
    let Some(cwd) = required_cwd(&p) else {
        return missing_cwd();
    };
    let limit = p.limit.unwrap_or(DEFAULT_FILE_LIMIT);
    blocking(move || Json(git::tracked_files(&cwd, limit)).into_response()).await
}

async fn path_changes(Query(p): Query<GitParams>) -> Response {
    let Some(cwd) = required_cwd(&p) else {
        return missing_cwd();
    };
    blocking(move || {
        let stat = git::change_stat(&cwd);
        Json(serde_json::json!({
            "files": stat.files,
            "additions": stat.additions,
            "deletions": stat.deletions,
            "signature": stat.signature,
        }))
        .into_response()
    })
    .await
}

/// The at-risk probe for one folder. `null` for a folder that is missing or is not a
/// work tree — distinct from a probe that found nothing wrong, which is an object with
/// zeroes in it.
async fn path_at_risk(Query(p): Query<GitParams>) -> Response {
    let Some(cwd) = required_cwd(&p) else {
        return missing_cwd();
    };
    blocking(move || {
        Json(at_risk::probe(&cwd).map(|probe| AtRiskBody {
            state: probe.state,
            dirty_files: probe.dirty_files,
            ahead_of_base: probe.ahead_of_base,
            head_on_remote: probe.head_on_remote,
        }))
        .into_response()
    })
    .await
}

/// The worktree an agent cut for itself from inside its own pty, matched by the pid
/// it locked the tree with. `{ "path": null }` when it never left `cwd`.
async fn path_agent_worktree(Query(p): Query<GitParams>) -> Response {
    let Some(cwd) = required_cwd(&p) else {
        return missing_cwd();
    };
    let Some(pid) = p.pid.filter(|n| *n > 0) else {
        return bad_request("pid required");
    };
    blocking(move || {
        Json(serde_json::json!({
            "path": worktree::detect_agent_worktree(&cwd, pid),
        }))
        .into_response()
    })
    .await
}

async fn path_file(Query(p): Query<GitParams>) -> Response {
    let Some(cwd) = required_cwd(&p) else {
        return missing_cwd();
    };
    file_for(cwd, p).await
}

// ── the shared bodies ────────────────────────────────────────────────────────

/// One of three diffs, picked by which parameter is present: a commit's own diff,
/// the branch against its base, or the working tree against HEAD.
async fn diff_for(cwd: String, p: GitParams) -> Response {
    blocking(move || {
        if let Some(sha) = p.commit.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            return match git::commit_diff(&cwd, sha) {
                Ok(d) => Json(d).into_response(),
                Err(e) => git_error(e),
            };
        }
        if let Some(base) = p.base.as_deref() {
            let requested = Some(base).filter(|b| !b.trim().is_empty());
            return match git::base_diff(&cwd, requested) {
                Ok(d) => Json(d).into_response(),
                Err(e) => git_error(e),
            };
        }
        Json(git::diff(&cwd)).into_response()
    })
    .await
}

async fn file_for(cwd: String, p: GitParams) -> Response {
    let Some(rel) = p.path.filter(|r| !r.trim().is_empty()) else {
        return bad_request("path required");
    };
    blocking(move || match git::read_file(&cwd, &rel) {
        Ok((path, content)) => Json(FileBody { path, content }).into_response(),
        // A path that escapes the tree and a file that is not there are both the
        // caller's problem and neither is this core's: 404 for both, so a probe cannot
        // use the status code to learn what exists outside the worktree.
        Err(e) => (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({ "error": e.0 })),
        )
            .into_response(),
    })
    .await
}

fn required_cwd(p: &GitParams) -> Option<String> {
    p.cwd
        .as_deref()
        .map(str::trim)
        .filter(|c| !c.is_empty())
        .map(str::to_string)
}

/// Run a `git` invocation off the async runtime. A panic in one is reported rather
/// than taken as an empty answer — an empty diff and a crashed handler must not look
/// the same to a panel.
async fn blocking<F>(f: F) -> Response
where
    F: FnOnce() -> Response + Send + 'static,
{
    match tokio::task::spawn_blocking(f).await {
        Ok(r) => r,
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({ "error": format!("git read failed: {e}") })),
        )
            .into_response(),
    }
}

fn git_error(e: git::GitError) -> Response {
    (
        StatusCode::UNPROCESSABLE_ENTITY,
        Json(serde_json::json!({ "error": e.0 })),
    )
        .into_response()
}

fn bad_request(why: &str) -> Response {
    (
        StatusCode::BAD_REQUEST,
        Json(serde_json::json!({ "error": why })),
    )
        .into_response()
}

fn missing_cwd() -> Response {
    bad_request("cwd required")
}

fn not_found(id: &str) -> Response {
    (
        StatusCode::NOT_FOUND,
        Json(serde_json::json!({ "error": format!("no session {id}") })),
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::path::{Path, PathBuf};
    use std::process::Command;

    use axum::body::Body;
    use axum::http::Request;
    use juancoded_core::model::ProviderId;
    use juancoded_state::registry::CreateRequest;
    use serde_json::Value;
    use tower::ServiceExt;

    struct Scratch {
        dir: PathBuf,
    }

    impl Scratch {
        fn new(label: &str) -> Self {
            let dir = std::env::temp_dir().join(format!(
                "juancoded-changes-{label}-{}-{:?}",
                std::process::id(),
                std::thread::current().id()
            ));
            std::fs::remove_dir_all(&dir).ok();
            std::fs::create_dir_all(dir.join("repo")).expect("scratch");
            let repo = dir.join("repo");
            git(&repo, &["init", "--quiet", "--initial-branch=main"]);
            std::fs::write(repo.join("a.txt"), "one\ntwo\n").unwrap();
            git(&repo, &["add", "a.txt"]);
            git(&repo, &["commit", "--quiet", "-m", "base"]);
            std::fs::write(repo.join("a.txt"), "one\ntwo\nthree\n").unwrap();
            Self { dir }
        }

        fn cwd(&self) -> String {
            self.dir.join("repo").to_string_lossy().into_owned()
        }

        fn boot(&self) -> (juancoded_cordis::Loader, CoreHandles) {
            let db = self.dir.join("store.db").to_string_lossy().into_owned();
            let entries = juancoded_state::test_entries_at(&db, "/bin/cat", &[]);
            let (loader, _, sessions) = juancoded_state::boot_with(&entries).expect("tree mounts");
            let handles = CoreHandles::from_loader(&loader, sessions);
            (loader, handles)
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            std::fs::remove_dir_all(&self.dir).ok();
        }
    }

    fn git(cwd: &Path, args: &[&str]) {
        let out = Command::new("git")
            .args(args)
            .current_dir(cwd)
            .env("GIT_AUTHOR_NAME", "test")
            .env("GIT_AUTHOR_EMAIL", "test@localhost")
            .env("GIT_COMMITTER_NAME", "test")
            .env("GIT_COMMITTER_EMAIL", "test@localhost")
            .output()
            .expect("git");
        assert!(out.status.success(), "git {args:?}");
    }

    fn create(handles: &CoreHandles, cwd: &str) -> String {
        handles
            .sessions
            .create(CreateRequest {
                provider: ProviderId::Claude,
                cwd: cwd.to_string(),
                cols: 80,
                rows: 24,
                skip_permissions: false,
                model: None,
                preset: None,
                isolate_worktree: false,
                worktree_name: None,
                dispatch_id: None,
                owner: 1,
            })
            .expect("create")
            .id
    }

    /// Through `serve::router`, so what is measured is what a client reaches.
    async fn get(handles: &CoreHandles, path: &str) -> (StatusCode, Value) {
        let response = crate::serve::router(handles.clone())
            .oneshot(Request::builder().uri(path).body(Body::empty()).unwrap())
            .await
            .expect("routed");
        let status = response.status();
        let bytes = axum::body::to_bytes(response.into_body(), 1 << 22)
            .await
            .expect("body");
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    #[tokio::test]
    async fn a_session_read_answers_the_tree_that_session_works_in() {
        let scratch = Scratch::new("session");
        let (_loader, handles) = scratch.boot();
        let id = create(&handles, &scratch.cwd());

        let (status, body) = get(&handles, &format!("/api/sessions/{id}/diff")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["git"], true);
        assert_eq!(body["files"][0]["path"], "a.txt");
        assert_eq!(body["files"][0]["additions"], 1);

        let (status, body) = get(&handles, &format!("/api/sessions/{id}/git")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["branch"], "main");
        assert_eq!(body["dirty"], true);

        let (status, body) = get(&handles, &format!("/api/sessions/{id}/worktrees")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body[0]["main"], true);

        let (status, body) = get(&handles, &format!("/api/sessions/{id}/file?path=a.txt")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["content"], "one\ntwo\nthree\n");
    }

    #[tokio::test]
    async fn a_read_for_a_session_this_core_never_had_is_a_404() {
        let scratch = Scratch::new("missing");
        let (_loader, handles) = scratch.boot();
        for leaf in ["diff", "git", "worktrees", "file?path=a.txt"] {
            let (status, _) = get(&handles, &format!("/api/sessions/nope/{leaf}")).await;
            assert_eq!(status, StatusCode::NOT_FOUND, "{leaf}");
        }
    }

    #[tokio::test]
    async fn a_file_read_that_leaves_the_tree_is_refused() {
        let scratch = Scratch::new("escape");
        let (_loader, handles) = scratch.boot();
        let id = create(&handles, &scratch.cwd());
        std::fs::write(scratch.dir.join("secret.txt"), "do not touch\n").unwrap();

        for bad in ["../secret.txt", "/etc/passwd", "a/../../secret.txt"] {
            let (status, _) = get(
                &handles,
                &format!("/api/sessions/{id}/file?path={}", urlencode(bad)),
            )
            .await;
            assert_eq!(status, StatusCode::NOT_FOUND, "{bad}");
        }
        assert!(scratch.dir.join("secret.txt").exists());
    }

    #[tokio::test]
    async fn the_path_addressed_family_needs_a_cwd_and_answers_about_it() {
        let scratch = Scratch::new("bypath");
        let (_loader, handles) = scratch.boot();
        let cwd = urlencode(&scratch.cwd());

        for leaf in [
            "state",
            "diff",
            "worktrees",
            "commits",
            "status",
            "files",
            "changes",
            "at-risk",
        ] {
            let (status, _) = get(&handles, &format!("/api/git/{leaf}")).await;
            assert_eq!(status, StatusCode::BAD_REQUEST, "{leaf} with no cwd");
        }

        let (status, body) = get(&handles, &format!("/api/git/state?cwd={cwd}")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["branch"], "main");

        let (_, body) = get(&handles, &format!("/api/git/status?cwd={cwd}")).await;
        assert_eq!(body[0]["path"], "a.txt");

        let (_, body) = get(&handles, &format!("/api/git/changes?cwd={cwd}")).await;
        assert_eq!(body["files"], 1);
        assert_eq!(body["additions"], 1);

        let (_, body) = get(&handles, &format!("/api/git/commits?cwd={cwd}")).await;
        assert_eq!(body[0]["subject"], "base");

        let (_, body) = get(&handles, &format!("/api/git/at-risk?cwd={cwd}")).await;
        assert_eq!(body["dirtyFiles"], 1);

        // A folder that is not a repo probes to null rather than to a shape with
        // zeroes in it: "not a work tree" and "nothing at risk here" are different
        // answers and the badge draws neither the same way.
        let plain = urlencode(&scratch.dir.to_string_lossy());
        let (status, body) = get(&handles, &format!("/api/git/at-risk?cwd={plain}")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body, Value::Null);

        // The agent-worktree probe needs a pid, and answers null when no tree is
        // locked to one.
        let (status, _) = get(&handles, &format!("/api/git/agent-worktree?cwd={cwd}")).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        let (_, body) = get(
            &handles,
            &format!("/api/git/agent-worktree?cwd={cwd}&pid=999999"),
        )
        .await;
        assert_eq!(body["path"], Value::Null);
    }

    #[tokio::test]
    async fn a_base_diff_with_no_base_to_find_says_so_rather_than_answering_nothing() {
        let scratch = Scratch::new("basediff");
        let (_loader, handles) = scratch.boot();
        let cwd = urlencode(&scratch.cwd());
        // `main` exists locally, so it IS the inferred base and the diff is empty.
        let (status, body) = get(&handles, &format!("/api/git/diff?cwd={cwd}&base=")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["base"], "main");

        // A base that does not resolve is a 422 with git's own reason, not an empty
        // diff that reads as "this branch changed nothing".
        let (status, body) = get(
            &handles,
            &format!("/api/git/diff?cwd={cwd}&base=origin/nope"),
        )
        .await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
        assert!(body["error"].as_str().unwrap().contains("base branch"));
    }

    fn urlencode(s: &str) -> String {
        s.bytes()
            .map(|b| match b {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                    (b as char).to_string()
                }
                other => format!("%{other:02X}"),
            })
            .collect()
    }

    #[test]
    fn an_unknown_cwd_falls_back_to_the_sessions_own() {
        // Not a repo, so the worktree listing is empty and nothing validates.
        let tmp = std::env::temp_dir();
        let session = tmp.to_str().unwrap();
        assert_eq!(target_cwd(session, None), session);
        assert_eq!(target_cwd(session, Some("   ")), session);
        assert_eq!(
            target_cwd(session, Some("/somewhere/else")),
            session,
            "a path git never listed is not answerable"
        );
        assert_eq!(
            target_cwd(session, Some(&format!("{session}/"))),
            session,
            "a trailing slash is the same path"
        );
    }
}
