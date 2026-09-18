//! The four per-session reads a remote client makes once, over HTTP.
//!
//! Everything else about a session is a subscription: a pane attaches and follows the
//! byte stream, a transcript panel subscribes and follows the records. That shape is
//! right for a desktop pane and wrong for everything that asks a question and leaves —
//! a phone opening a session, a Telegram command printing the last few turns, a script
//! checking what an agent said. Those had no answer at all on this core: the Swift
//! app's relay serves `/api/sessions`, and every per-session read under it fell through
//! to a 501 (juancode-ag1e).
//!
//! Four routes, all read-only, all keyed by session id:
//!
//! * `GET /api/sessions/{id}/scrollback` — the retained pty bytes **and the grid they
//!   were parsed at**. Never one without the other: a byte ring replayed at the wrong
//!   width lands every hard wrap and every absolute cursor move in the wrong cell, and
//!   the width is not recoverable from the bytes. This is the same pairing
//!   `juancoded_persistence::Scrollback` exists to enforce in the store, carried onto
//!   the wire so the last hop cannot undo it.
//! * `GET /api/sessions/{id}/transcript` — the structured records the daemon kept,
//!   oldest first: exactly what `subscribeTranscript` replays, from the same store,
//!   without the subscription.
//! * `GET /api/sessions/{id}/messages` — those same records projected into chat shape.
//!   A derived view, never a second source: a reader with no VT emulator (Telegram, a
//!   notification, a script) needs prose and who said it, not a grid.
//! * `GET /api/sessions/{id}/screen` — the **rendered** screen: the parsed grid, not
//!   the bytes. This is what the scrollback read is a fallback for. A byte ring has to
//!   be replayed to be looked at, and a replay at the wrong width lands every hard wrap
//!   in the wrong cell; these rows were laid out by the parser that wrote them, at the
//!   width it wrote them at, so there is nothing left to get wrong (juancode-tyd9).
//!   `text/plain` by default, `?scrollback=N` to flow history in above the screen,
//!   `?json=1` for the `screen` frame's own row encoding with history at NEGATIVE row
//!   indices.
//!
//! None of the four touches the session. A read must not resize the desktop's
//! terminal to see it, which is why the scrollback route reads the ring and the grid
//! directly instead of going through `attach`.

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use juancoded_transcripts::{TranscriptEvent, TranscriptRecord};
use juancoded_vt::wire::PeekRow;

use crate::serve::CoreHandles;

/// How many records a read answers with when the caller names no bound. The same
/// number a `subscribeTranscript` replays, for the same reason: it is the recent end a
/// reader draws before it has scrolled anywhere.
pub const DEFAULT_LIMIT: usize = crate::transcript_pump::DEFAULT_REPLAY_LIMIT;

pub fn routes() -> Router<CoreHandles> {
    Router::new()
        .route("/api/sessions/{id}/scrollback", get(scrollback))
        .route("/api/sessions/{id}/transcript", get(transcript))
        .route("/api/sessions/{id}/messages", get(messages))
        .route("/api/sessions/{id}/screen", get(screen))
}

/// How much history a bare `?scrollback` asks for — the same number the Swift model
/// seeds a reattaching pane with (`SessionTerminalModel.defaultSeedScrollbackRows`).
pub const DEFAULT_SCREEN_SCROLLBACK_ROWS: usize = 500;

/// The most history any one read will answer with, however large a number is asked
/// for. A peek is a look, not an export; `/scrollback` is the route for the whole ring.
pub const SCREEN_SCROLLBACK_CAP: usize = 5_000;

/// `?limit=` on the two transcript reads: how much of the tail to answer with. `0`
/// means the whole history the daemon kept, which is what the store already means by
/// zero.
#[derive(Debug, Default, Deserialize)]
pub struct ReadParams {
    pub limit: Option<usize>,
}

impl ReadParams {
    fn limit(&self) -> usize {
        self.limit.unwrap_or(DEFAULT_LIMIT)
    }
}

/// Retained pty bytes with the grid they were parsed at.
///
/// `cols`/`rows` are not decoration and not a hint: a client parses at them or it
/// draws garbage. They are the session's current authority grid, which is also the
/// width the ring's bytes were written at — the registry rebuilds the replay grid and
/// re-flushes whenever the two could diverge.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScrollbackBody {
    pub session_id: String,
    pub cols: u16,
    pub rows: u16,
    /// The bytes, lossily decoded — the same decoding the `attached` frame does, so a
    /// client gets one representation of this plane rather than two.
    pub scrollback: String,
}

/// `?scrollback` / `?json` on the screen read. Both are strings rather than typed
/// values because both are FLAGS first: `?json` with no value has to read as true, and
/// `?scrollback` with no value has to mean the default depth. A `bool`/`usize` field
/// would reject the bare form outright.
#[derive(Debug, Default, Deserialize)]
pub struct ScreenParams {
    pub scrollback: Option<String>,
    pub json: Option<String>,
}

/// `?scrollback` / `=1` / `=true` → [`DEFAULT_SCREEN_SCROLLBACK_ROWS`]; `?scrollback=N`
/// (N > 1) → that many rows, capped; absent, `=0` or `=false` → none. A boolean flag
/// with a row count as the refinement, matching `ScreenPeek.scrollbackRows` in Swift.
pub fn scrollback_rows(raw: Option<&str>) -> usize {
    let Some(raw) = raw else { return 0 };
    let v = raw.trim().to_ascii_lowercase();
    if v == "0" || v == "false" || v == "no" {
        return 0;
    }
    match v.parse::<usize>() {
        Ok(n) if n > 1 => n.min(SCREEN_SCROLLBACK_CAP),
        _ => DEFAULT_SCREEN_SCROLLBACK_ROWS,
    }
}

/// Present-means-true, the way `?json` reads, with an explicit `0`/`false` honoured.
pub fn flag(raw: Option<&str>) -> bool {
    match raw {
        None => false,
        Some(raw) => {
            let v = raw.trim().to_ascii_lowercase();
            !(v == "0" || v == "false" || v == "no")
        }
    }
}

/// `?json=1` body, field for field the Swift core's `ScreenSnapshotWire`.
///
/// `rows` is the GRID HEIGHT, as in a `screen` frame, rather than doubling as the
/// length of `lines` — `lines` is longer than `rows` whenever history was asked for,
/// and `scrollback` says by how many.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenBody {
    pub session_id: String,
    pub cols: usize,
    pub rows: usize,
    pub cursor: ScreenCursor,
    pub alt: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// How many of `lines` are history rows — all of them at negative indices.
    pub scrollback: usize,
    pub lines: Vec<PeekRow>,
}

#[derive(Debug, Serialize)]
pub struct ScreenCursor {
    pub x: usize,
    pub y: usize,
    pub visible: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptBody {
    pub session_id: String,
    /// Oldest first, each record exactly as `subscribeTranscript` sends it.
    pub records: Vec<Value>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesBody {
    pub session_id: String,
    pub messages: Vec<ChatMessage>,
}

/// One prose-bearing transcript record in chat shape.
///
/// `seq` is carried through unchanged: it is what a client orders and de-duplicates
/// by, and dropping it here would make this view impossible to page or to reconcile
/// against the records it came from.
#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatMessage {
    pub seq: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub at_ms: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn: Option<String>,
    /// `user`, `assistant`, `thinking`, `toolCall` or `toolResult`.
    pub role: &'static str,
    /// The tool's name, on the two tool roles only.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool: Option<String>,
    /// Whether the call succeeded, on `toolResult` only.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ok: Option<bool>,
    pub text: String,
}

async fn scrollback(Path(id): Path<String>, State(handles): State<CoreHandles>) -> Response {
    let Some((cols, rows)) = handles.sessions.grid(&id) else {
        return not_found(&id);
    };
    Json(ScrollbackBody {
        scrollback: handles.sessions.scrollback(&id).unwrap_or_default(),
        session_id: id,
        cols,
        rows,
    })
    .into_response()
}

async fn transcript(
    Path(id): Path<String>,
    Query(params): Query<ReadParams>,
    State(handles): State<CoreHandles>,
) -> Response {
    let Some(records) = history(&handles, &id, params.limit()) else {
        return not_found(&id);
    };
    Json(TranscriptBody {
        session_id: id,
        records,
    })
    .into_response()
}

async fn messages(
    Path(id): Path<String>,
    Query(params): Query<ReadParams>,
    State(handles): State<CoreHandles>,
) -> Response {
    let Some(records) = history(&handles, &id, params.limit()) else {
        return not_found(&id);
    };
    Json(MessagesBody {
        session_id: id,
        messages: chat(&records),
    })
    .into_response()
}

/// The rendered screen, as text or as styled rows.
///
/// Two failure modes, deliberately distinct. An id this core has never heard of is a
/// 404. A session it holds whose pty is gone is a **409**: the screen is live state,
/// and a caller told "conflict" knows to fall back to the stored scrollback on purpose
/// rather than reading an empty grid as an empty session.
///
/// This core could in fact answer for a dead session — `screen_peek` rebuilds a replay
/// grid from the persisted bytes at the width they were written at. It deliberately
/// does not, because the Swift core cannot (its model dies with the pty) and one URL
/// may not mean two things while both cores serve it. See juancode-s96g's follow-up.
async fn screen(
    Path(id): Path<String>,
    Query(params): Query<ScreenParams>,
    State(handles): State<CoreHandles>,
) -> Response {
    if handles.sessions.meta(&id).is_none() {
        return not_found(&id);
    }
    if !handles.sessions.is_running(&id) {
        return (
            StatusCode::CONFLICT,
            Json(serde_json::json!({
                "error": "session is not running — its screen died with the pty"
            })),
        )
            .into_response();
    }
    let rows = scrollback_rows(params.scrollback.as_deref());
    let Some(peek) = handles.sessions.screen_peek(&id, rows) else {
        // Known, running, and no grid: nothing to draw and nothing to fall back to.
        return (
            StatusCode::CONFLICT,
            Json(serde_json::json!({ "error": format!("session {id} has no rendered screen") })),
        )
            .into_response();
    };
    if !flag(params.json.as_deref()) {
        return (
            StatusCode::OK,
            [(
                axum::http::header::CONTENT_TYPE,
                "text/plain; charset=utf-8",
            )],
            peek.text(),
        )
            .into_response();
    }
    Json(ScreenBody {
        session_id: id,
        cols: peek.snapshot.cols,
        rows: peek.snapshot.rows,
        cursor: ScreenCursor {
            x: peek.snapshot.cursor_x,
            y: peek.snapshot.cursor_y,
            visible: peek.snapshot.cursor_visible,
        },
        alt: peek.snapshot.alt,
        title: peek.title.clone(),
        scrollback: peek.history.len(),
        lines: peek.lines(),
    })
    .into_response()
}

/// A session's stored records, or `None` when there is no such session.
///
/// A session that exists but has no transcript answers with an empty list rather than
/// a 404, and so does a core with no transcript plane mounted — the same contract
/// `subscribeTranscript` has, and for the same reason: a reader needs to draw an empty
/// panel, not wait for a frame that is not coming.
fn history(handles: &CoreHandles, id: &str, limit: usize) -> Option<Vec<Value>> {
    handles.sessions.meta(id)?;
    Some(
        handles
            .transcripts
            .as_ref()
            .map(|plane| plane.history_of(id, limit))
            .unwrap_or_default(),
    )
}

fn not_found(id: &str) -> Response {
    (
        StatusCode::NOT_FOUND,
        Json(serde_json::json!({ "error": format!("no session {id}") })),
    )
        .into_response()
}

/// Project records into chat shape, dropping the five that carry no prose.
///
/// `step`, `turnEnd` and `usage` are structure and accounting — real records, and the
/// reason `/transcript` exists beside this — but there is nothing for a chat reader to
/// render in them, and a message list padded with empty rows is harder to read than a
/// shorter one. A record this build cannot decode is skipped rather than allowed to
/// fail the projection, for the reason a batch drops one on the wire: a hole costs the
/// reader one message, a refusal costs it all of them.
pub fn chat(records: &[Value]) -> Vec<ChatMessage> {
    records
        .iter()
        .filter_map(|value| serde_json::from_value::<TranscriptRecord>(value.clone()).ok())
        .filter_map(message)
        .collect()
}

fn message(record: TranscriptRecord) -> Option<ChatMessage> {
    let (role, tool, ok, text) = match record.event {
        TranscriptEvent::TurnStart { prompt } => ("user", None, None, prompt),
        TranscriptEvent::Assistant { text, .. } => ("assistant", None, None, text),
        TranscriptEvent::Thinking { text, .. } => ("thinking", None, None, text),
        TranscriptEvent::ToolCall { name, input, .. } => ("toolCall", Some(name), None, input),
        TranscriptEvent::ToolResult { ok, output, .. } => ("toolResult", None, Some(ok), output),
        TranscriptEvent::Step { .. }
        | TranscriptEvent::TurnEnd { .. }
        | TranscriptEvent::Usage { .. } => return None,
    };
    Some(ChatMessage {
        seq: record.seq,
        at_ms: record.at_ms,
        turn: record.turn,
        role,
        tool,
        ok,
        text,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::io::Write;
    use std::path::{Path, PathBuf};
    use std::time::Instant;

    use axum::body::Body;
    use axum::http::Request;
    use juancoded_core::model::ProviderId;
    use juancoded_state::registry::CreateRequest;
    use tower::ServiceExt;

    /// The same four lines the transcript pump's own tests use, so what these routes
    /// are measured against is the parser that runs in production.
    const PROMPT: &str = r#"{"type":"user","promptId":"p1","timestamp":"2026-08-23T10:00:00.000Z","message":{"role":"user","content":"land the ticket"}}"#;
    const CALL: &str = r#"{"type":"assistant","requestId":"req_1","timestamp":"2026-08-23T10:00:01.000Z","message":{"model":"claude-opus-5","usage":{"input_tokens":4,"output_tokens":9},"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"cargo test"}}],"stop_reason":"tool_use"}}"#;
    const RESULT: &str = r#"{"type":"user","timestamp":"2026-08-23T10:00:30.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"34 passed"}]}}"#;
    const DONE: &str = r#"{"type":"assistant","requestId":"req_2","timestamp":"2026-08-23T10:00:31.000Z","message":{"model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":2},"content":[{"type":"text","text":"green"}],"stop_reason":"end_turn"}}"#;

    struct Scratch {
        dir: PathBuf,
    }

    impl Scratch {
        fn new(label: &str) -> Self {
            let dir = std::env::temp_dir().join(format!(
                "juancoded-reads-{label}-{}-{:?}",
                std::process::id(),
                std::thread::current().id()
            ));
            std::fs::remove_dir_all(&dir).ok();
            std::fs::create_dir_all(dir.join("projects")).expect("scratch");
            std::fs::create_dir_all(dir.join("cwd")).expect("scratch cwd");
            Self { dir }
        }

        fn cwd(&self) -> String {
            self.dir.join("cwd").to_string_lossy().into_owned()
        }

        fn projects(&self) -> PathBuf {
            self.dir.join("projects")
        }

        fn transcript_for(&self, session: &str) -> PathBuf {
            let dir = self
                .projects()
                .join(juancoded_transcripts::claude::project_slug(&self.cwd()));
            std::fs::create_dir_all(&dir).expect("project dir");
            dir.join(format!("{session}.jsonl"))
        }

        fn boot(&self) -> (juancoded_cordis::Loader, CoreHandles) {
            let db = self.dir.join("store.db").to_string_lossy().into_owned();
            let mut entries = juancoded_state::test_entries_at(&db, "/bin/cat", &[]);
            entries.set_config(
                "transcript-claude",
                serde_json::json!({ "root": self.projects().to_string_lossy() }),
            );
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

    fn append(path: &Path, lines: &[&str]) {
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .expect("append");
        for line in lines {
            writeln!(file, "{line}").expect("write");
        }
    }

    fn create(handles: &CoreHandles, cwd: &str, cols: u16, rows: u16) -> String {
        handles
            .sessions
            .create(CreateRequest {
                provider: ProviderId::Claude,
                cwd: cwd.to_string(),
                cols,
                rows,
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

    /// Through `serve::router`, not through `routes()` alone: the merge is part of
    /// what a client reaches, and a route that only exists in its own `Router` is a
    /// 404 in production.
    async fn get(handles: &CoreHandles, path: &str) -> (StatusCode, Value) {
        let (status, _, body) = get_text(handles, path).await;
        (status, serde_json::from_str(&body).unwrap_or(Value::Null))
    }

    /// The same request, kept as bytes: `/screen` answers `text/plain` by default, and
    /// the content type is part of what that default promises.
    async fn get_text(handles: &CoreHandles, path: &str) -> (StatusCode, Option<String>, String) {
        let response = crate::serve::router(handles.clone())
            .oneshot(
                Request::builder()
                    .uri(path)
                    .body(Body::empty())
                    .expect("request"),
            )
            .await
            .expect("routed");
        let status = response.status();
        let content_type = response
            .headers()
            .get(axum::http::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .map(str::to_string);
        let bytes = axum::body::to_bytes(response.into_body(), 1 << 20)
            .await
            .expect("body");
        (
            status,
            content_type,
            String::from_utf8_lossy(&bytes).into_owned(),
        )
    }

    /// Put bytes on a session's grid the way its pty would.
    ///
    /// Straight at the `terminal` service rather than through `input`, because what is
    /// being measured is the RENDERED read and not the pty round trip: a test that
    /// waits on `/bin/cat` to echo measures scheduling. The read is asked for once
    /// first so the grid exists to be fed — the registry opens one on demand.
    fn paint(
        loader: &juancoded_cordis::Loader,
        handles: &CoreHandles,
        session: &str,
        bytes: &[u8],
    ) {
        handles.sessions.screen_peek(session, 0);
        loader
            .services()
            .resolve::<juancoded_cordis::services::terminal::TerminalService>()
            .expect("the terminal service mounts")
            .feed(session, bytes);
    }

    #[tokio::test]
    async fn scrollback_answers_with_the_grid_its_bytes_were_parsed_at() {
        // The whole point of the route: bytes with no width can only be replayed by
        // guessing, and a guess lands every hard wrap in the wrong cell.
        let scratch = Scratch::new("grid");
        let (_loader, handles) = scratch.boot();
        let session = create(&handles, &scratch.cwd(), 132, 43);

        let (status, body) = get(&handles, &format!("/api/sessions/{session}/scrollback")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["sessionId"], session.as_str());
        assert_eq!(body["cols"], 132);
        assert_eq!(body["rows"], 43);
        assert!(body["scrollback"].is_string(), "{body}");
        assert_eq!(handles.sessions.grid(&session), Some((132, 43)));
    }

    #[tokio::test]
    async fn reading_a_session_never_moves_its_grid() {
        // `attach` resizes to the caller's grid; a phone that only wants to LOOK must
        // not be able to resize the desktop's terminal out from under it.
        let scratch = Scratch::new("readonly");
        let (_loader, handles) = scratch.boot();
        let session = create(&handles, &scratch.cwd(), 100, 30);

        for leaf in ["scrollback", "transcript", "messages", "screen"] {
            let (status, _) = get(&handles, &format!("/api/sessions/{session}/{leaf}")).await;
            assert_eq!(status, StatusCode::OK, "{leaf}");
        }
        assert_eq!(handles.sessions.grid(&session), Some((100, 30)));
    }

    #[tokio::test]
    async fn an_unknown_session_is_a_404_on_every_read() {
        let scratch = Scratch::new("missing");
        let (_loader, handles) = scratch.boot();

        for leaf in ["scrollback", "transcript", "messages", "screen"] {
            let (status, body) = get(&handles, &format!("/api/sessions/nope/{leaf}")).await;
            assert_eq!(status, StatusCode::NOT_FOUND, "{leaf}");
            assert!(
                body["error"].as_str().unwrap_or_default().contains("nope"),
                "{leaf}: {body}"
            );
        }
    }

    #[tokio::test]
    async fn the_screen_read_answers_at_the_grid_it_was_rendered_at() {
        // The point of the route. A byte log has no width and has to be replayed to be
        // looked at; these rows were laid out by the parser, and the grid they were
        // laid out at travels with them so nothing downstream has to guess.
        let scratch = Scratch::new("screen-grid");
        let (loader, handles) = scratch.boot();
        let session = create(&handles, &scratch.cwd(), 90, 20);
        paint(&loader, &handles, &session, b"rendered here");

        let (status, body) = get(&handles, &format!("/api/sessions/{session}/screen?json=1")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["sessionId"], session.as_str());
        assert_eq!(body["cols"], 90);
        assert_eq!(body["rows"], 20);
        assert_eq!(body["alt"], false);
        assert_eq!(body["scrollback"], 0);
        assert_eq!(body["cursor"]["visible"], true);
        // `rows` is the GRID HEIGHT and `lines` is every one of them, at 0 … rows-1.
        let lines = body["lines"].as_array().expect("lines");
        assert_eq!(lines.len(), 20);
        assert_eq!(lines[0]["row"], 0);
        assert_eq!(lines[0]["segs"][0]["text"], "rendered here");
        assert_eq!(lines[19]["row"], 19);
    }

    #[tokio::test]
    async fn the_default_screen_body_is_the_plain_text_of_the_grid() {
        let scratch = Scratch::new("screen-text");
        let (loader, handles) = scratch.boot();
        let session = create(&handles, &scratch.cwd(), 40, 6);
        paint(
            &loader,
            &handles,
            &session,
            b"first line\r\nsecond line\r\n",
        );

        let (status, content_type, body) =
            get_text(&handles, &format!("/api/sessions/{session}/screen")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(content_type.as_deref(), Some("text/plain; charset=utf-8"));
        // Trailing blank rows are dropped, so a 6-row grid with two lines on it reads
        // as two lines rather than as four empty ones.
        assert_eq!(body, "first line\nsecond line");
    }

    #[tokio::test]
    async fn history_arrives_above_the_screen_at_negative_row_indices() {
        // The whole reason a peek can carry history at all: the visible rows have to
        // stay at exactly the indices a `screen` frame uses, so one client decoder
        // reads both. Negative indices leave no ambiguity about where history ends.
        let scratch = Scratch::new("screen-history");
        let (loader, handles) = scratch.boot();
        let session = create(&handles, &scratch.cwd(), 40, 3);
        let painted: String = (0..9).map(|i| format!("row {i}\r\n")).collect();
        paint(&loader, &handles, &session, painted.as_bytes());

        let (status, body) = get(
            &handles,
            &format!("/api/sessions/{session}/screen?scrollback=2&json=1"),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["rows"], 3, "`rows` stays the grid height");
        assert_eq!(body["scrollback"], 2);
        let rows: Vec<i64> = body["lines"]
            .as_array()
            .expect("lines")
            .iter()
            .map(|l| l["row"].as_i64().expect("row"))
            .collect();
        assert_eq!(rows, vec![-2, -1, 0, 1, 2]);

        // And the text body flows the same history in above the same screen.
        let (_, _, text) = get_text(
            &handles,
            &format!("/api/sessions/{session}/screen?scrollback=2"),
        )
        .await;
        assert_eq!(text, "row 5\nrow 6\nrow 7\nrow 8");

        // No `?scrollback` at all is the screen and nothing above it.
        let (_, body) = get(&handles, &format!("/api/sessions/{session}/screen?json=1")).await;
        assert_eq!(body["scrollback"], 0);
        assert_eq!(body["lines"].as_array().map(Vec::len), Some(3));
    }

    #[tokio::test]
    async fn a_session_whose_pty_is_gone_is_a_409_rather_than_an_empty_screen() {
        // A caller has to be able to tell "nothing on screen" from "nothing left to
        // look at": the second one means fall back to the stored scrollback on
        // purpose, and an empty 200 would hide that decision.
        let scratch = Scratch::new("screen-dead");
        let (_loader, handles) = scratch.boot();
        let session = create(&handles, &scratch.cwd(), 80, 24);
        handles.sessions.kill(&session).expect("killed");
        // The kill signals; the pty slot clears when the child is reaped. Waiting for
        // the fact rather than for a duration, so a loaded machine does not turn this
        // into a race (`exec` alone costs a quarter-second here).
        let deadline = Instant::now() + std::time::Duration::from_secs(10);
        while handles.sessions.is_running(&session) {
            assert!(Instant::now() < deadline, "the pty never went away");
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let (status, body) = get(&handles, &format!("/api/sessions/{session}/screen")).await;
        assert_eq!(status, StatusCode::CONFLICT);
        assert!(
            body["error"]
                .as_str()
                .unwrap_or_default()
                .contains("not running"),
            "{body}"
        );

        // The byte-log read is exactly what a 409 tells a caller to fall back to, so
        // it must still answer for the same session.
        let (status, _) = get(&handles, &format!("/api/sessions/{session}/scrollback")).await;
        assert_eq!(status, StatusCode::OK);
    }

    #[test]
    fn scrollback_is_a_flag_first_and_a_row_count_second() {
        assert_eq!(scrollback_rows(None), 0);
        assert_eq!(scrollback_rows(Some("0")), 0);
        assert_eq!(scrollback_rows(Some("false")), 0);
        assert_eq!(scrollback_rows(Some("no")), 0);
        // A bare `?scrollback` arrives as an empty value and means "the usual depth".
        assert_eq!(scrollback_rows(Some("")), DEFAULT_SCREEN_SCROLLBACK_ROWS);
        assert_eq!(
            scrollback_rows(Some("true")),
            DEFAULT_SCREEN_SCROLLBACK_ROWS
        );
        assert_eq!(scrollback_rows(Some("1")), DEFAULT_SCREEN_SCROLLBACK_ROWS);
        assert_eq!(scrollback_rows(Some("200")), 200);
        assert_eq!(scrollback_rows(Some(" 200 ")), 200);
        assert_eq!(scrollback_rows(Some("999999")), SCREEN_SCROLLBACK_CAP);

        assert!(!flag(None));
        assert!(!flag(Some("0")));
        assert!(!flag(Some("false")));
        assert!(flag(Some("")));
        assert!(flag(Some("1")));
    }

    #[tokio::test]
    async fn a_session_with_no_transcript_reads_as_empty_rather_than_missing() {
        let scratch = Scratch::new("empty");
        let (_loader, handles) = scratch.boot();
        let session = create(&handles, &scratch.cwd(), 80, 24);

        let (status, body) = get(&handles, &format!("/api/sessions/{session}/transcript")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["records"].as_array().map(Vec::len), Some(0));

        let (status, body) = get(&handles, &format!("/api/sessions/{session}/messages")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["messages"].as_array().map(Vec::len), Some(0));
    }

    #[tokio::test]
    async fn the_two_transcript_reads_answer_from_what_the_pump_stored() {
        let scratch = Scratch::new("records");
        let (_loader, handles) = scratch.boot();
        let plane = handles.transcripts.clone().expect("the plane mounted");
        let session = create(&handles, &scratch.cwd(), 80, 24);
        append(
            &scratch.transcript_for(&session),
            &[PROMPT, CALL, RESULT, DONE],
        );
        crate::transcript_pump::Pump::new().poll_session(
            &handles.sessions,
            &plane,
            &session,
            Instant::now(),
        );

        let (status, body) = get(&handles, &format!("/api/sessions/{session}/transcript")).await;
        assert_eq!(status, StatusCode::OK);
        let kinds: Vec<&str> = body["records"]
            .as_array()
            .expect("records")
            .iter()
            .map(|r| r["kind"].as_str().unwrap_or("?"))
            .collect();
        assert!(kinds.contains(&"turnStart"), "{kinds:?}");
        assert!(kinds.contains(&"toolCall"), "{kinds:?}");
        assert!(kinds.contains(&"usage"), "{kinds:?}");

        // The chat view is the same records minus the ones with no prose in them.
        let (status, body) = get(&handles, &format!("/api/sessions/{session}/messages")).await;
        assert_eq!(status, StatusCode::OK);
        let roles: Vec<&str> = body["messages"]
            .as_array()
            .expect("messages")
            .iter()
            .map(|m| m["role"].as_str().unwrap_or("?"))
            .collect();
        assert_eq!(roles, vec!["user", "toolCall", "toolResult", "assistant"]);
        assert_eq!(body["messages"][0]["text"], "land the ticket");
        assert_eq!(body["messages"][1]["tool"], "Bash");
        assert_eq!(body["messages"][2]["ok"], true);
        assert_eq!(body["messages"][3]["text"], "green");
    }

    #[tokio::test]
    async fn limit_takes_the_tail_and_zero_takes_everything() {
        let scratch = Scratch::new("limit");
        let (_loader, handles) = scratch.boot();
        let plane = handles.transcripts.clone().expect("the plane mounted");
        let session = create(&handles, &scratch.cwd(), 80, 24);
        append(
            &scratch.transcript_for(&session),
            &[PROMPT, CALL, RESULT, DONE],
        );
        crate::transcript_pump::Pump::new().poll_session(
            &handles.sessions,
            &plane,
            &session,
            Instant::now(),
        );

        let (_, all) = get(
            &handles,
            &format!("/api/sessions/{session}/transcript?limit=0"),
        )
        .await;
        let total = all["records"].as_array().expect("records").len();
        assert!(total > 2, "the fixture produces more than two records");

        let (_, tail) = get(
            &handles,
            &format!("/api/sessions/{session}/transcript?limit=2"),
        )
        .await;
        let tail = tail["records"].as_array().expect("records").clone();
        assert_eq!(tail.len(), 2);
        assert_eq!(
            tail,
            all["records"].as_array().expect("records")[total - 2..].to_vec(),
            "a limit takes the recent end, not the old one"
        );
    }

    #[test]
    fn the_chat_view_drops_the_records_with_no_prose_in_them() {
        let record = |seq: u64, event: serde_json::Value| {
            let mut value =
                serde_json::json!({ "session": "s1", "source": "claude-jsonl", "seq": seq });
            for (k, v) in event.as_object().expect("event").iter() {
                value[k] = v.clone();
            }
            value
        };
        let records = vec![
            record(
                0,
                serde_json::json!({ "kind": "turnStart", "prompt": "do it" }),
            ),
            record(1, serde_json::json!({ "kind": "step", "step": "req_1" })),
            record(2, serde_json::json!({ "kind": "thinking", "text": "hm" })),
            record(
                3,
                serde_json::json!({ "kind": "toolCall", "call": "c1", "name": "Bash", "input": "{}" }),
            ),
            record(
                4,
                serde_json::json!({ "kind": "toolResult", "call": "c1", "ok": false, "output": "boom" }),
            ),
            record(
                5,
                serde_json::json!({ "kind": "assistant", "text": "done" }),
            ),
            record(6, serde_json::json!({ "kind": "turnEnd" })),
            record(
                7,
                serde_json::json!({ "kind": "usage", "usage": { "inputTokens": 1 } }),
            ),
            serde_json::json!({ "kind": "notARecord" }),
        ];

        let chat = chat(&records);
        assert_eq!(
            chat.iter().map(|m| m.role).collect::<Vec<_>>(),
            vec!["user", "thinking", "toolCall", "toolResult", "assistant"]
        );
        // `seq` survives the projection: it is what a reader pages and de-duplicates by.
        assert_eq!(
            chat.iter().map(|m| m.seq).collect::<Vec<_>>(),
            vec![0, 2, 3, 4, 5]
        );
        assert_eq!(chat[2].tool.as_deref(), Some("Bash"));
        assert_eq!(chat[3].ok, Some(false));
        assert_eq!(chat[3].text, "boom");
    }
}
