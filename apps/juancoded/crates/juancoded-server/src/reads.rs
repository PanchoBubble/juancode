//! The three per-session reads a remote client makes once, over HTTP.
//!
//! Everything else about a session is a subscription: a pane attaches and follows the
//! byte stream, a transcript panel subscribes and follows the records. That shape is
//! right for a desktop pane and wrong for everything that asks a question and leaves —
//! a phone opening a session, a Telegram command printing the last few turns, a script
//! checking what an agent said. Those had no answer at all on this core: the Swift
//! app's relay serves `/api/sessions`, and every per-session read under it fell through
//! to a 501 (juancode-ag1e).
//!
//! Three routes, all read-only, all keyed by session id:
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
//!
//! None of the three touches the session. A read must not resize the desktop's
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
}

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
        let bytes = axum::body::to_bytes(response.into_body(), 1 << 20)
            .await
            .expect("body");
        let json = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        (status, json)
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

        for leaf in ["scrollback", "transcript", "messages"] {
            let (status, _) = get(&handles, &format!("/api/sessions/{session}/{leaf}")).await;
            assert_eq!(status, StatusCode::OK, "{leaf}");
        }
        assert_eq!(handles.sessions.grid(&session), Some((100, 30)));
    }

    #[tokio::test]
    async fn an_unknown_session_is_a_404_on_all_three_reads() {
        let scratch = Scratch::new("missing");
        let (_loader, handles) = scratch.boot();

        for leaf in ["scrollback", "transcript", "messages"] {
            let (status, body) = get(&handles, &format!("/api/sessions/nope/{leaf}")).await;
            assert_eq!(status, StatusCode::NOT_FOUND, "{leaf}");
            assert!(
                body["error"].as_str().unwrap_or_default().contains("nope"),
                "{leaf}: {body}"
            );
        }
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
