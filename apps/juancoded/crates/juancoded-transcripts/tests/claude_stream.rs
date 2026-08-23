//! The claude source end to end: a file that grows, moves and misbehaves the way a
//! real one does, read through the public `TranscriptSource` API with nothing mocked.
//!
//! The unit tests in `tail` prove each file-movement case in isolation. This proves
//! the same cases survive the layer above them, which is where the parser's own
//! carried state (the open turn, the announced step) can go wrong even when the offset
//! does not.

use std::io::Write;
use std::path::{Path, PathBuf};

use juancoded_transcripts::claude::ClaudeJsonl;
use juancoded_transcripts::{BindRequest, Binding, Cursor, TranscriptEvent, TranscriptSource};

struct Scratch {
    dir: PathBuf,
}

impl Scratch {
    fn new(label: &str) -> Self {
        let dir = std::env::temp_dir().join(format!(
            "juancoded-claude-stream-{label}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).expect("scratch dir");
        Self { dir }
    }

    /// A projects tree shaped exactly like claude's own.
    fn project(&self, cwd: &str) -> PathBuf {
        let slug: String = cwd
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
            .collect();
        let dir = self.dir.join(slug);
        std::fs::create_dir_all(&dir).expect("project dir");
        dir
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

fn kinds(events: &[juancoded_transcripts::Emitted]) -> Vec<&'static str> {
    events.iter().map(|e| e.event.kind()).collect()
}

const PROMPT: &str = r#"{"type":"user","promptId":"p1","timestamp":"2026-08-23T10:00:00.000Z","message":{"role":"user","content":"land the ticket"}}"#;
const CALL: &str = r#"{"type":"assistant","requestId":"req_1","timestamp":"2026-08-23T10:00:01.000Z","message":{"model":"claude-opus-5","usage":{"input_tokens":4,"output_tokens":9},"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"cargo test"}}],"stop_reason":"tool_use"}}"#;
const RESULT: &str = r#"{"type":"user","timestamp":"2026-08-23T10:00:30.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"34 passed"}]}}"#;
const DONE: &str = r#"{"type":"assistant","requestId":"req_2","timestamp":"2026-08-23T10:00:31.000Z","message":{"model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":2},"content":[{"type":"text","text":"green"}],"stop_reason":"end_turn"}}"#;

#[test]
fn a_session_is_bound_by_the_id_the_spawn_pinned_and_read_as_it_grows() {
    let scratch = Scratch::new("grow");
    let cwd = "/Users/me/workdir/juancode";
    let path = scratch
        .project(cwd)
        .join("11111111-2222-3333-4444-555555555555.jsonl");
    append(&path, &[PROMPT]);

    let source = ClaudeJsonl::with_root(&scratch.dir);
    // `--session-id <juancode id>` means the juancode session id IS the file name.
    let binding = source
        .bind(&BindRequest {
            session: "11111111-2222-3333-4444-555555555555".into(),
            provider: "claude".into(),
            cwd: cwd.into(),
            cli_session_id: Some("11111111-2222-3333-4444-555555555555".into()),
        })
        .expect("the pinned id names the file");
    assert_eq!(binding, Binding::ClaudeJsonl { path: path.clone() });

    let (first, cursor) = source.read(&binding, &String::new()).unwrap();
    assert_eq!(kinds(&first), ["turnStart"]);
    assert_eq!(first[0].at_ms, Some(1_787_479_200_000));

    append(&path, &[CALL, RESULT]);
    let (second, cursor) = source.read(&binding, &cursor).unwrap();
    assert_eq!(kinds(&second), ["step", "usage", "toolCall", "toolResult"]);
    assert!(
        second.iter().all(|e| e.turn.as_deref() == Some("p1")),
        "the turn opened before this poll must still be the one in force"
    );

    append(&path, &[DONE]);
    let (third, cursor) = source.read(&binding, &cursor).unwrap();
    assert_eq!(kinds(&third), ["step", "usage", "assistant", "turnEnd"]);

    let (idle, _) = source.read(&binding, &cursor).unwrap();
    assert!(idle.is_empty(), "an unchanged file must cost no records");
}

#[test]
fn a_record_written_in_two_writes_is_read_once_it_is_whole() {
    let scratch = Scratch::new("partial");
    let cwd = "/tmp/partial";
    let path = scratch.project(cwd).join("s.jsonl");
    append(&path, &[PROMPT]);
    let source = ClaudeJsonl::with_root(&scratch.dir);
    let binding = Binding::ClaudeJsonl { path: path.clone() };
    let (_, cursor) = source.read(&binding, &String::new()).unwrap();

    // Half a record on disk, which is the ordinary state of a file being written.
    let half = &CALL[..CALL.len() / 2];
    let mut file = std::fs::OpenOptions::new()
        .append(true)
        .open(&path)
        .unwrap();
    file.write_all(half.as_bytes()).unwrap();
    let (nothing, cursor) = source.read(&binding, &cursor).unwrap();
    assert!(nothing.is_empty(), "half a record is not a record");

    file.write_all(&CALL.as_bytes()[CALL.len() / 2..]).unwrap();
    file.write_all(b"\n").unwrap();
    let (whole, _) = source.read(&binding, &cursor).unwrap();
    assert_eq!(kinds(&whole), ["step", "usage", "toolCall"]);
}

#[test]
fn a_transcript_replaced_at_the_same_path_is_read_from_the_top_with_fresh_state() {
    let scratch = Scratch::new("replaced");
    let cwd = "/tmp/replaced";
    let path = scratch.project(cwd).join("s.jsonl");
    append(&path, &[PROMPT, CALL]);
    let source = ClaudeJsonl::with_root(&scratch.dir);
    let binding = Binding::ClaudeJsonl { path: path.clone() };
    let (_, cursor) = source.read(&binding, &String::new()).unwrap();

    // A different file at the same name, longer than the one before it.
    std::fs::remove_file(&path).unwrap();
    append(&path, &[PROMPT, CALL, RESULT, DONE]);
    let (after, _) = source.read(&binding, &cursor).unwrap();
    assert_eq!(
        kinds(&after),
        [
            "turnStart",
            "step",
            "usage",
            "toolCall",
            "toolResult",
            "step",
            "usage",
            "assistant",
            "turnEnd"
        ],
        "a replacement is a new file, so nothing carries over"
    );
    // And the turn the old file left open did not leak into the new one: the first
    // event is the new file's own turn opening, not a turnEnd for the old.
    assert!(matches!(after[0].event, TranscriptEvent::TurnStart { .. }));
}

#[test]
fn a_cursor_from_before_a_compaction_rereads_rather_than_skipping() {
    let scratch = Scratch::new("compacted");
    let cwd = "/tmp/compacted";
    let path = scratch.project(cwd).join("s.jsonl");
    append(&path, &[PROMPT, CALL, RESULT, DONE]);
    let source = ClaudeJsonl::with_root(&scratch.dir);
    let binding = Binding::ClaudeJsonl { path: path.clone() };
    let (long, cursor) = source.read(&binding, &String::new()).unwrap();
    assert_eq!(long.len(), 9);

    // Compaction: the same inode, rewritten short. The stored offset is now past EOF.
    std::fs::write(&path, format!("{PROMPT}\n")).unwrap();
    let (after, _) = source.read(&binding, &cursor).unwrap();
    assert_eq!(kinds(&after), ["turnStart"]);
}

#[test]
fn a_transcript_full_of_shapes_we_do_not_model_still_yields_the_ones_we_do() {
    let scratch = Scratch::new("noise");
    let cwd = "/tmp/noise";
    let path = scratch.project(cwd).join("s.jsonl");
    append(
        &path,
        &[
            r#"{"type":"mode","mode":"normal"}"#,
            r#"{"type":"permission-mode","permissionMode":"bypassPermissions"}"#,
            PROMPT,
            r#"{"type":"attachment","attachment":{"type":"file","path":"/x"}}"#,
            "}{ not json",
            r#"{"type":"file-history-snapshot","messageId":"m","snapshot":{"big":true}}"#,
            CALL,
            r#"{"type":"system","subtype":"stop_hook_summary","hookCount":1}"#,
            r#"{"type":"ai-title","aiTitle":"a title"}"#,
            RESULT,
            r#"{"type":"a-shape-from-a-later-claude","payload":{"whatever":1}}"#,
            DONE,
        ],
    );
    let source = ClaudeJsonl::with_root(&scratch.dir);
    let (events, cursor) = source
        .read(&Binding::ClaudeJsonl { path: path.clone() }, &String::new())
        .unwrap();
    assert_eq!(
        kinds(&events),
        [
            "turnStart",
            "step",
            "usage",
            "toolCall",
            "toolResult",
            "step",
            "usage",
            "assistant",
            "turnEnd"
        ]
    );
    // The offset got past every unrecognised line, which is the part that matters: a
    // reader that stopped on one would never see anything after it again.
    let position: serde_json::Value = serde_json::from_str(&cursor).unwrap();
    let size = std::fs::metadata(&path).unwrap().len();
    assert_eq!(position["offset"].as_u64(), Some(size));
}

#[test]
fn a_session_whose_cwd_no_longer_matches_is_found_by_its_id() {
    let scratch = Scratch::new("moved");
    // The conversation was recorded under one project; the session now claims another,
    // which is what an adopted external session with no reliable cwd looks like.
    let path = scratch
        .project("/Users/me/workdir/elsewhere")
        .join("abc-123.jsonl");
    append(&path, &[PROMPT]);
    scratch.project("/Users/me/workdir/here");

    let source = ClaudeJsonl::with_root(&scratch.dir);
    let binding = source.bind(&BindRequest {
        session: "juancode-local-id".into(),
        provider: "claude".into(),
        cwd: "/Users/me/workdir/here".into(),
        cli_session_id: Some("abc-123".into()),
    });
    assert_eq!(binding, Some(Binding::ClaudeJsonl { path }));
}

#[test]
fn a_session_with_no_transcript_yet_binds_to_nothing_and_is_asked_again() {
    let scratch = Scratch::new("absent");
    scratch.project("/tmp/absent");
    let source = ClaudeJsonl::with_root(&scratch.dir);
    let mut req = BindRequest {
        session: "s1".into(),
        provider: "claude".into(),
        cwd: "/tmp/absent".into(),
        cli_session_id: None,
    };
    assert_eq!(source.bind(&req), None, "no id yet");
    req.cli_session_id = Some("not-written-yet".into());
    assert_eq!(source.bind(&req), None, "no file yet");

    let path = scratch.project("/tmp/absent").join("not-written-yet.jsonl");
    append(&path, &[PROMPT]);
    assert_eq!(source.bind(&req), Some(Binding::ClaudeJsonl { path }));
}

#[test]
fn a_source_handed_the_wrong_kind_of_binding_says_so() {
    let source = ClaudeJsonl::new();
    let wrong = Binding::OpencodeSqlite {
        db: "/tmp/x.db".into(),
        conversation: "ses_1".into(),
    };
    let err = source.read(&wrong, &Cursor::new()).unwrap_err();
    assert!(err.to_string().contains("opencode-sqlite"), "{err}");
}
