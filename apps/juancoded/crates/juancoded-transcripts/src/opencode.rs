//! The opencode-sqlite source: opencode's own database, opened read-only.
//!
//! opencode stores a conversation as `message` rows (role, model, tokens) and `part`
//! rows (text, reasoning, tool, step-start, step-finish), and the parts are where
//! everything the seam wants lives. Correlation is the id the registry already
//! discovers: opencode has no flag to pin one, so `juancoded-persistence::discovery`
//! reads the newest top-level `session` row for the cwd and writes it to
//! `cli_session_id`. That id is this source's locator.
//!
//! Two properties of the store shape the cursor.
//!
//! Parts are inserted in time order and never renumbered, so `(time_created, id)` is
//! a stable resume point and a poll reads one indexed range.
//!
//! A tool part, though, is inserted when the call starts and updated when it finishes,
//! so reading strictly forward would show every call and no result. The cursor
//! therefore carries the calls still in flight: they are re-read by id each pass until
//! their status settles, at which point the result is emitted and the id is dropped.
//! The alternative, holding the cursor behind the oldest unfinished tool, would stall
//! a whole session behind one long `cargo test`.
//!
//! Not read, for the same reason as the claude source: `patch`, `file`, `compaction`
//! and `snapshot` parts, cost, and the todo/permission tables. None of them is one of
//! the eight events.

use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::Result;
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{
    clamp, BindRequest, Binding, Cursor, Emitted, Source, TokenUsage, TranscriptEvent,
    TranscriptSource,
};

/// How many part rows one pass will take. A session resumed after a long gap catches
/// up over several polls instead of allocating its whole history at once.
const BATCH: usize = 2_000;

/// The durable resume point for one opencode conversation.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpencodeCursor {
    /// `time_created` of the last part consumed.
    #[serde(default)]
    pub after_time: i64,
    /// Its id, which breaks the tie when several parts share a millisecond.
    #[serde(default)]
    pub after_id: String,
    /// The message id of the open turn.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn: Option<String>,
    /// Tool parts seen but not yet finished, by part id.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub pending: Vec<String>,
}

/// Reads opencode's own SQLite. Never opens it for writing and never creates it.
#[derive(Debug, Clone, Default)]
pub struct OpencodeSqlite {
    db: Option<PathBuf>,
}

impl OpencodeSqlite {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_db(db: impl Into<PathBuf>) -> Self {
        Self {
            db: Some(db.into()),
        }
    }

    fn db_path(&self) -> PathBuf {
        self.db.clone().unwrap_or_else(default_db_path)
    }
}

/// opencode's database, resolved the way opencode resolves it.
///
/// Deliberately the same rules as `juancoded_persistence::discovery::opencode_db_path`
/// rather than a call into it: this crate reads other people's stores and does not
/// depend on our own.
pub fn default_db_path() -> PathBuf {
    if let Ok(ours) = std::env::var("JUANCODE_OPENCODE_DB") {
        if !ours.is_empty() {
            return PathBuf::from(ours);
        }
    }
    let dir = match std::env::var("XDG_DATA_HOME") {
        Ok(xdg) if !xdg.is_empty() => PathBuf::from(xdg).join("opencode"),
        _ => PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".local/share/opencode"),
    };
    if let Ok(theirs) = std::env::var("OPENCODE_DB") {
        if !theirs.is_empty() {
            return if theirs.starts_with('/') {
                PathBuf::from(theirs)
            } else {
                dir.join(theirs)
            };
        }
    }
    dir.join("opencode.db")
}

impl TranscriptSource for OpencodeSqlite {
    fn name(&self) -> &'static str {
        "opencode-sqlite"
    }

    fn source(&self) -> Source {
        Source::OpencodeSqlite
    }

    fn bind(&self, req: &BindRequest) -> Option<Binding> {
        if req.provider != "opencode" {
            return None;
        }
        // opencode writes its `session` row on the first message, so an id that is
        // not there yet is an ordinary state and the caller asks again.
        let conversation = req.cli_session_id.as_deref()?.to_string();
        let db = self.db_path();
        db.is_file()
            .then_some(Binding::OpencodeSqlite { db, conversation })
    }

    fn read(&self, binding: &Binding, cursor: &Cursor) -> Result<(Vec<Emitted>, Cursor)> {
        let Binding::OpencodeSqlite { db, conversation } = binding else {
            anyhow::bail!(
                "opencode-sqlite was handed a {} binding",
                binding.source().as_str()
            );
        };
        let mut state: OpencodeCursor = if cursor.is_empty() {
            OpencodeCursor::default()
        } else {
            serde_json::from_str(cursor).unwrap_or_default()
        };
        if !db.exists() {
            return Ok((Vec::new(), serde_json::to_string(&state)?));
        }

        let conn = open_read_only(db)?;
        let mut out = Vec::new();
        settle_pending(&conn, &mut state, &mut out)?;
        read_forward(&conn, conversation, &mut state, &mut out)?;
        Ok((out, serde_json::to_string(&state)?))
    }
}

/// Read-only, with a short busy timeout: a live opencode holding the WAL is somebody
/// else's write and we wait a moment rather than getting in its way.
fn open_read_only(db: &Path) -> Result<Connection> {
    let conn = Connection::open_with_flags(db, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    conn.busy_handler(None).ok();
    conn.busy_timeout(Duration::from_millis(250))?;
    Ok(conn)
}

/// Tool calls we have already announced: emit a result for each one that has finished.
fn settle_pending(
    conn: &Connection,
    state: &mut OpencodeCursor,
    out: &mut Vec<Emitted>,
) -> Result<()> {
    if state.pending.is_empty() {
        return Ok(());
    }
    let mut still = Vec::new();
    let mut stmt = conn.prepare("SELECT time_created, data FROM part WHERE id = ?1")?;
    for id in std::mem::take(&mut state.pending) {
        let row = stmt
            .query_row([&id], |row| {
                Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
            })
            .ok();
        let Some((at, data)) = row else {
            // The part is gone, so nothing will ever finish it.
            continue;
        };
        let Ok(part) = serde_json::from_str::<Value>(&data) else {
            continue;
        };
        match tool_result(&part) {
            Some(event) => out.push(Emitted::new(Some(at), state.turn.clone(), event)),
            None => still.push(id),
        }
    }
    state.pending = still;
    Ok(())
}

fn read_forward(
    conn: &Connection,
    conversation: &str,
    state: &mut OpencodeCursor,
    out: &mut Vec<Emitted>,
) -> Result<()> {
    let mut stmt = conn.prepare(
        "SELECT p.id, p.message_id, p.time_created, p.data, m.data \
         FROM part p JOIN message m ON m.id = p.message_id \
         WHERE p.session_id = ?1 \
           AND (p.time_created > ?2 OR (p.time_created = ?2 AND p.id > ?3)) \
         ORDER BY p.time_created, p.id LIMIT ?4",
    )?;
    let rows = stmt.query_map(
        rusqlite::params![conversation, state.after_time, state.after_id, BATCH as i64],
        |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
            ))
        },
    )?;

    for row in rows {
        let (id, message_id, at, part_data, message_data) = row?;
        state.after_time = at;
        state.after_id = id.clone();
        let (Ok(part), Ok(message)) = (
            serde_json::from_str::<Value>(&part_data),
            serde_json::from_str::<Value>(&message_data),
        ) else {
            continue;
        };
        emit_part(&id, &message_id, at, &part, &message, state, out);
    }
    Ok(())
}

fn emit_part(
    id: &str,
    message_id: &str,
    at: i64,
    part: &Value,
    message: &Value,
    state: &mut OpencodeCursor,
    out: &mut Vec<Emitted>,
) {
    let at = Some(at);
    let user = message.get("role").and_then(Value::as_str) == Some("user");
    let kind = part.get("type").and_then(Value::as_str);

    match kind {
        Some("text") if user => {
            let text = part.get("text").and_then(Value::as_str).unwrap_or_default();
            if text.trim().is_empty() {
                return;
            }
            if let Some(open) = state.turn.take() {
                out.push(Emitted::new(
                    at,
                    Some(open),
                    TranscriptEvent::TurnEnd { reason: None },
                ));
            }
            // opencode has no prompt id: the user message this part belongs to is the
            // only thing that names the turn, and its row id is stable.
            let turn = message_id.to_string();
            state.turn = Some(turn.clone());
            out.push(Emitted::new(
                at,
                Some(turn),
                TranscriptEvent::TurnStart {
                    prompt: clamp(text),
                },
            ));
        }
        Some("text") => {
            let text = part.get("text").and_then(Value::as_str).unwrap_or_default();
            if !text.trim().is_empty() {
                out.push(Emitted::new(
                    at,
                    state.turn.clone(),
                    TranscriptEvent::Assistant {
                        step: None,
                        text: clamp(text),
                    },
                ));
            }
        }
        Some("reasoning") => {
            let text = part.get("text").and_then(Value::as_str).unwrap_or_default();
            if !text.trim().is_empty() {
                out.push(Emitted::new(
                    at,
                    state.turn.clone(),
                    TranscriptEvent::Thinking {
                        step: None,
                        text: clamp(text),
                    },
                ));
            }
        }
        Some("step-start") => out.push(Emitted::new(
            at,
            state.turn.clone(),
            TranscriptEvent::Step {
                step: id.to_string(),
                model: message
                    .get("modelID")
                    .and_then(Value::as_str)
                    .map(str::to_string),
            },
        )),
        Some("step-finish") => {
            let usage = tokens_of(part.get("tokens"));
            if !usage.is_zero() {
                out.push(Emitted::new(
                    at,
                    state.turn.clone(),
                    TranscriptEvent::Usage { step: None, usage },
                ));
            }
            if part.get("reason").and_then(Value::as_str) == Some("stop") {
                if let Some(open) = state.turn.take() {
                    out.push(Emitted::new(
                        at,
                        Some(open),
                        TranscriptEvent::TurnEnd {
                            reason: Some("stop".into()),
                        },
                    ));
                }
            }
        }
        Some("tool") => {
            let Some(call) = part.get("callID").and_then(Value::as_str) else {
                return;
            };
            out.push(Emitted::new(
                at,
                state.turn.clone(),
                TranscriptEvent::ToolCall {
                    call: call.to_string(),
                    name: part
                        .get("tool")
                        .and_then(Value::as_str)
                        .unwrap_or("tool")
                        .to_string(),
                    input: clamp(
                        &part
                            .pointer("/state/input")
                            .map(Value::to_string)
                            .unwrap_or_else(|| "{}".into()),
                    ),
                },
            ));
            match tool_result(part) {
                Some(event) => out.push(Emitted::new(at, state.turn.clone(), event)),
                // Still running. The row is updated in place when it finishes, so the
                // id is kept and re-read rather than the cursor being held back.
                None => state.pending.push(id.to_string()),
            }
        }
        _ => {}
    }
}

/// A finished tool part as a result event, or `None` while it is still running.
fn tool_result(part: &Value) -> Option<TranscriptEvent> {
    let call = part.get("callID").and_then(Value::as_str)?;
    let status = part.pointer("/state/status").and_then(Value::as_str)?;
    let ok = match status {
        "completed" => true,
        "error" => false,
        _ => return None,
    };
    let output = part
        .pointer("/state/output")
        .or_else(|| part.pointer("/state/error"))
        .map(|v| match v {
            Value::String(text) => text.clone(),
            other => other.to_string(),
        })
        .unwrap_or_default();
    Some(TranscriptEvent::ToolResult {
        call: call.to_string(),
        ok,
        output: clamp(&output),
    })
}

fn tokens_of(tokens: Option<&Value>) -> TokenUsage {
    let Some(tokens) = tokens else {
        return TokenUsage::default();
    };
    let n = |key: &str| tokens.get(key).and_then(Value::as_u64).unwrap_or(0);
    TokenUsage {
        input: n("input"),
        output: n("output"),
        cache_read: tokens
            .pointer("/cache/read")
            .and_then(Value::as_u64)
            .unwrap_or(0),
        cache_write: tokens
            .pointer("/cache/write")
            .and_then(Value::as_u64)
            .unwrap_or(0),
        reasoning: n("reasoning"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture {
        dir: PathBuf,
        db: PathBuf,
    }

    impl Fixture {
        fn new(label: &str) -> Self {
            let dir = std::env::temp_dir().join(format!(
                "juancoded-opencode-{label}-{}-{:?}",
                std::process::id(),
                std::thread::current().id()
            ));
            std::fs::remove_dir_all(&dir).ok();
            std::fs::create_dir_all(&dir).expect("scratch dir");
            let db = dir.join("opencode.db");
            let conn = Connection::open(&db).expect("fixture db");
            conn.execute_batch(
                "CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT, parent_id TEXT, time_created INTEGER);
                 CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
                 CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, data TEXT);",
            )
            .expect("fixture schema");
            Self { dir, db }
        }

        fn conn(&self) -> Connection {
            Connection::open(&self.db).expect("open fixture")
        }

        fn message(&self, id: &str, data: &str) {
            self.conn()
                .execute(
                    "INSERT INTO message (id, session_id, time_created, data) VALUES (?1, 'ses_1', 0, ?2)",
                    rusqlite::params![id, data],
                )
                .expect("insert message");
        }

        fn part(&self, id: &str, message: &str, at: i64, data: &str) {
            self.conn()
                .execute(
                    "INSERT INTO part (id, message_id, session_id, time_created, data) VALUES (?1, ?2, 'ses_1', ?3, ?4)",
                    rusqlite::params![id, message, at, data],
                )
                .expect("insert part");
        }

        fn update_part(&self, id: &str, data: &str) {
            self.conn()
                .execute(
                    "UPDATE part SET data = ?2 WHERE id = ?1",
                    rusqlite::params![id, data],
                )
                .expect("update part");
        }

        fn binding(&self) -> Binding {
            Binding::OpencodeSqlite {
                db: self.db.clone(),
                conversation: "ses_1".into(),
            }
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            std::fs::remove_dir_all(&self.dir).ok();
        }
    }

    fn kinds(events: &[Emitted]) -> Vec<&'static str> {
        events.iter().map(|e| e.event.kind()).collect()
    }

    #[test]
    fn a_conversation_reads_as_a_turn_a_step_and_its_cost() {
        let fx = Fixture::new("turn");
        fx.message("msg_u", r#"{"role":"user"}"#);
        fx.message("msg_a", r#"{"role":"assistant","modelID":"qwen3:8b"}"#);
        fx.part("prt_1", "msg_u", 10, r#"{"type":"text","text":"test"}"#);
        fx.part(
            "prt_2",
            "msg_a",
            20,
            r#"{"type":"step-start","snapshot":"abc"}"#,
        );
        fx.part(
            "prt_3",
            "msg_a",
            30,
            r#"{"type":"reasoning","text":"deciding"}"#,
        );
        fx.part(
            "prt_4",
            "msg_a",
            40,
            r#"{"type":"text","text":"here you go"}"#,
        );
        fx.part(
            "prt_5",
            "msg_a",
            50,
            r#"{"type":"step-finish","reason":"stop","tokens":{"input":2050,"output":201,"reasoning":0,"cache":{"read":0,"write":24472}}}"#,
        );

        let source = OpencodeSqlite::new();
        let (events, cursor) = source.read(&fx.binding(), &String::new()).unwrap();
        assert_eq!(
            kinds(&events),
            [
                "turnStart",
                "step",
                "thinking",
                "assistant",
                "usage",
                "turnEnd"
            ]
        );
        assert_eq!(
            events[4].event,
            TranscriptEvent::Usage {
                step: None,
                usage: TokenUsage {
                    input: 2050,
                    output: 201,
                    cache_read: 0,
                    cache_write: 24472,
                    reasoning: 0,
                }
            }
        );
        assert!(events[1..5]
            .iter()
            .all(|e| e.turn.as_deref() == Some("msg_u")));

        // A second pass over an unchanged conversation reads nothing.
        let (again, _) = source.read(&fx.binding(), &cursor).unwrap();
        assert!(again.is_empty());
    }

    #[test]
    fn a_tool_still_running_is_announced_now_and_answered_when_it_finishes() {
        let fx = Fixture::new("pending");
        fx.message("msg_a", r#"{"role":"assistant"}"#);
        fx.part(
            "prt_t",
            "msg_a",
            10,
            r#"{"type":"tool","callID":"call_1","tool":"bash","state":{"status":"running","input":{"command":"cargo test"}}}"#,
        );

        let source = OpencodeSqlite::new();
        let (first, cursor) = source.read(&fx.binding(), &String::new()).unwrap();
        assert_eq!(kinds(&first), ["toolCall"]);
        assert!(
            cursor.contains("prt_t"),
            "the call must be remembered: {cursor}"
        );

        // Nothing new, and the call has not settled: still no result.
        let (idle, cursor) = source.read(&fx.binding(), &cursor).unwrap();
        assert!(idle.is_empty());

        fx.update_part(
            "prt_t",
            r#"{"type":"tool","callID":"call_1","tool":"bash","state":{"status":"completed","input":{"command":"cargo test"},"output":"ok"}}"#,
        );
        let (settled, cursor) = source.read(&fx.binding(), &cursor).unwrap();
        assert_eq!(
            settled.iter().map(|e| e.event.clone()).collect::<Vec<_>>(),
            [TranscriptEvent::ToolResult {
                call: "call_1".into(),
                ok: true,
                output: "ok".into()
            }]
        );
        // And it is not answered twice.
        let (after, _) = source.read(&fx.binding(), &cursor).unwrap();
        assert!(after.is_empty());
    }

    #[test]
    fn a_finished_tool_is_a_call_and_a_result_in_one_pass() {
        let fx = Fixture::new("settled");
        fx.message("msg_a", r#"{"role":"assistant"}"#);
        fx.part(
            "prt_ok",
            "msg_a",
            10,
            r#"{"type":"tool","callID":"c1","tool":"glob","state":{"status":"completed","input":{"pattern":"**/*"},"output":"one/two"}}"#,
        );
        fx.part(
            "prt_bad",
            "msg_a",
            20,
            r#"{"type":"tool","callID":"c2","tool":"read","state":{"status":"error","input":{},"error":"no such file"}}"#,
        );
        let (events, _) = OpencodeSqlite::new()
            .read(&fx.binding(), &String::new())
            .unwrap();
        assert_eq!(
            kinds(&events),
            ["toolCall", "toolResult", "toolCall", "toolResult"]
        );
        assert_eq!(
            events[1].event,
            TranscriptEvent::ToolResult {
                call: "c1".into(),
                ok: true,
                output: "one/two".into()
            }
        );
        assert_eq!(
            events[3].event,
            TranscriptEvent::ToolResult {
                call: "c2".into(),
                ok: false,
                output: "no such file".into()
            }
        );
    }

    #[test]
    fn parts_arriving_between_polls_are_read_once_and_in_order() {
        let fx = Fixture::new("incremental");
        fx.message("msg_u", r#"{"role":"user"}"#);
        fx.message("msg_a", r#"{"role":"assistant"}"#);
        fx.part("prt_1", "msg_u", 10, r#"{"type":"text","text":"first"}"#);
        let source = OpencodeSqlite::new();
        let (_, cursor) = source.read(&fx.binding(), &String::new()).unwrap();

        // Two parts in the same millisecond: the id breaks the tie, and neither is lost.
        fx.part("prt_2", "msg_a", 20, r#"{"type":"text","text":"a"}"#);
        fx.part("prt_3", "msg_a", 20, r#"{"type":"text","text":"b"}"#);
        let (events, cursor) = source.read(&fx.binding(), &cursor).unwrap();
        assert_eq!(kinds(&events), ["assistant", "assistant"]);
        let (again, _) = source.read(&fx.binding(), &cursor).unwrap();
        assert!(again.is_empty(), "a repeated read would duplicate a part");
    }

    #[test]
    fn a_part_shape_we_do_not_know_is_skipped_rather_than_failing_the_read() {
        let fx = Fixture::new("unknown");
        fx.message("msg_a", r#"{"role":"assistant"}"#);
        fx.part(
            "prt_1",
            "msg_a",
            10,
            r#"{"type":"patch","hash":"deadbeef","files":[]}"#,
        );
        fx.part("prt_2", "msg_a", 20, "this is not json");
        fx.part("prt_3", "msg_a", 30, r#"{"type":"somethingNew"}"#);
        fx.part(
            "prt_4",
            "msg_a",
            40,
            r#"{"type":"text","text":"still here"}"#,
        );
        let (events, _) = OpencodeSqlite::new()
            .read(&fx.binding(), &String::new())
            .unwrap();
        assert_eq!(kinds(&events), ["assistant"]);
    }

    #[test]
    fn another_conversation_in_the_same_database_is_not_ours() {
        let fx = Fixture::new("scoped");
        fx.message("msg_a", r#"{"role":"assistant"}"#);
        fx.part("prt_1", "msg_a", 10, r#"{"type":"text","text":"ours"}"#);
        fx.conn()
            .execute_batch(
                "INSERT INTO message VALUES ('msg_o','ses_other',0,'{\"role\":\"assistant\"}');
                 INSERT INTO part VALUES ('prt_o','msg_o','ses_other',20,'{\"type\":\"text\",\"text\":\"theirs\"}');",
            )
            .expect("other conversation");
        let (events, _) = OpencodeSqlite::new()
            .read(&fx.binding(), &String::new())
            .unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(
            events[0].event,
            TranscriptEvent::Assistant {
                step: None,
                text: "ours".into()
            }
        );
    }

    #[test]
    fn a_missing_database_is_no_binding_and_never_a_created_file() {
        let path = std::env::temp_dir().join("juancoded-transcripts-absent.db");
        std::fs::remove_file(&path).ok();
        let source = OpencodeSqlite::with_db(&path);
        assert_eq!(
            source.bind(&BindRequest {
                session: "s1".into(),
                provider: "opencode".into(),
                cwd: "/tmp".into(),
                cli_session_id: Some("ses_1".into()),
            }),
            None
        );
        // And reading a binding whose file has since gone is empty, not an error.
        let binding = Binding::OpencodeSqlite {
            db: path.clone(),
            conversation: "ses_1".into(),
        };
        assert!(source.read(&binding, &String::new()).unwrap().0.is_empty());
        assert!(!path.exists(), "reading a store must never create it");
    }

    #[test]
    fn a_session_with_no_discovered_id_yet_does_not_bind() {
        let fx = Fixture::new("noid");
        let source = OpencodeSqlite::with_db(&fx.db);
        let mut req = BindRequest {
            session: "s1".into(),
            provider: "opencode".into(),
            cwd: "/tmp".into(),
            cli_session_id: None,
        };
        assert_eq!(source.bind(&req), None);
        req.cli_session_id = Some("ses_1".into());
        assert_eq!(source.bind(&req), Some(fx.binding()));
        // And a claude session is not this source's business.
        req.provider = "claude".into();
        assert_eq!(source.bind(&req), None);
    }
}
