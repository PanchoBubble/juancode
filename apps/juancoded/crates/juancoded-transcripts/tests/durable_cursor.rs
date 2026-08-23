//! The cursor survives a restart, and the table it lives in is the one the core's own
//! migration created.
//!
//! Durability is the whole reason the cursor is not just a field on a live object: the
//! first poll after a restart must read what arrived while the daemon was down, and
//! nothing else. A restart is modelled the only honest way, by dropping the store and
//! the reader entirely and building new ones over the same file.

use std::io::Write;
use std::path::{Path, PathBuf};

use juancoded_transcripts::claude::ClaudeJsonl;
use juancoded_transcripts::{
    Binding, CursorStore, Source, SqliteCursors, StoredCursor, TranscriptSource,
};

struct Scratch {
    dir: PathBuf,
}

impl Scratch {
    fn new(label: &str) -> Self {
        let dir = std::env::temp_dir().join(format!(
            "juancoded-cursor-{label}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).expect("scratch dir");
        Self { dir }
    }

    /// A core database at the real schema, so this test breaks if the migration does.
    fn database(&self, sessions: &[&str]) -> PathBuf {
        let path = self.dir.join("juancoded.db");
        let conn = rusqlite::Connection::open(&path).expect("open db");
        juancoded_persistence::schema::migrate(&conn).expect("migrate");
        for session in sessions {
            conn.execute(
                "INSERT INTO sessions (id, provider, cwd, title, status, created_at, updated_at) \
                 VALUES (?1, 'claude', '/tmp', 't', 'running', 0, 0)",
                [session],
            )
            .expect("session row");
        }
        path
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

const ONE: &str = r#"{"type":"user","promptId":"p1","message":{"content":"first"}}"#;
const TWO: &str = r#"{"type":"assistant","requestId":"r1","message":{"content":[{"type":"text","text":"during"}]}}"#;
const THREE: &str = r#"{"type":"assistant","requestId":"r2","message":{"content":[{"type":"text","text":"after the restart"}],"stop_reason":"end_turn"}}"#;

/// One poll: read from the stored cursor and store the new one. What the hub does,
/// written out so this test does not need the hub.
fn poll(
    store: &dyn CursorStore,
    source: &dyn TranscriptSource,
    session: &str,
    binding: &Binding,
) -> Vec<juancoded_transcripts::TranscriptRecord> {
    let locator = binding.locator();
    let mut stored = store
        .load(session)
        .filter(|s| s.locator == locator)
        .unwrap_or_else(|| StoredCursor::fresh(binding.source(), locator));
    let (emitted, next) = source.read(binding, &stored.cursor).expect("read");
    let records: Vec<_> = emitted
        .into_iter()
        .map(|e| {
            let seq = stored.next_seq;
            stored.next_seq += 1;
            juancoded_transcripts::TranscriptRecord {
                session: session.to_string(),
                source: binding.source(),
                seq,
                at_ms: e.at_ms,
                turn: e.turn,
                event: e.event,
            }
        })
        .collect();
    stored.cursor = next;
    store.save(session, &stored).expect("save cursor");
    records
}

#[test]
fn a_restart_resumes_where_it_stopped_and_keeps_counting() {
    let scratch = Scratch::new("restart");
    let db = scratch.database(&["s1"]);
    let path = scratch.dir.join("s1.jsonl");
    append(&path, &[ONE, TWO]);
    let binding = Binding::ClaudeJsonl { path: path.clone() };
    let source = ClaudeJsonl::new();

    {
        let store = SqliteCursors::open(&db).expect("store");
        let records = poll(&store, &source, "s1", &binding);
        assert_eq!(records.len(), 3);
        assert_eq!(records.last().unwrap().seq, 2);
    }

    // The daemon is down; the CLI keeps writing.
    append(&path, &[THREE]);

    let store = SqliteCursors::open(&db).expect("reopen store");
    let records = poll(&store, &source, "s1", &binding);
    assert_eq!(
        records.iter().map(|r| r.event.kind()).collect::<Vec<_>>(),
        ["step", "assistant", "turnEnd"],
        "only what arrived while we were down"
    );
    assert_eq!(
        records.iter().map(|r| r.seq).collect::<Vec<_>>(),
        [3, 4, 5],
        "a sequence that restarted at zero would collide with what is already stored"
    );
    // The turn opened before the restart is still the one these belong to, because the
    // parser's state is carried in the cursor and not in the process.
    assert!(records.iter().all(|r| r.turn.as_deref() == Some("p1")));
}

#[test]
fn a_restart_over_a_transcript_that_was_replaced_reads_it_from_the_top() {
    let scratch = Scratch::new("restart-replaced");
    let db = scratch.database(&["s1"]);
    let path = scratch.dir.join("s1.jsonl");
    append(&path, &[ONE, TWO]);
    let binding = Binding::ClaudeJsonl { path: path.clone() };
    let source = ClaudeJsonl::new();
    {
        let store = SqliteCursors::open(&db).expect("store");
        assert_eq!(poll(&store, &source, "s1", &binding).len(), 3);
    }

    std::fs::remove_file(&path).unwrap();
    append(&path, &[ONE, TWO, THREE]);

    let store = SqliteCursors::open(&db).expect("reopen store");
    let records = poll(&store, &source, "s1", &binding);
    assert_eq!(records.len(), 6, "a new file is read whole");
    // Sequence numbers still only go up, so a consumer that kept the earlier ones can
    // tell the replay apart from the originals.
    assert_eq!(records[0].seq, 3);
}

#[test]
fn the_stored_row_is_what_the_migration_describes() {
    let scratch = Scratch::new("schema");
    let db = scratch.database(&["s1"]);
    let store = SqliteCursors::open(&db).expect("store");
    let mut cursor = StoredCursor::fresh(Source::OpencodeSqlite, "/tmp/opencode.db#ses_1");
    cursor.cursor = r#"{"afterTime":7,"afterId":"prt_1"}"#.into();
    cursor.next_seq = 12;
    store.save("s1", &cursor).unwrap();
    assert_eq!(store.load("s1"), Some(cursor.clone()));

    // Saving again is an update, not a second row.
    let mut moved = cursor.clone();
    moved.next_seq = 20;
    store.save("s1", &moved).unwrap();
    let conn = rusqlite::Connection::open(&db).unwrap();
    let rows: i64 = conn
        .query_row("SELECT count(*) FROM transcript_cursors", [], |r| r.get(0))
        .unwrap();
    assert_eq!(rows, 1);
    assert_eq!(store.load("s1").unwrap().next_seq, 20);

    store.clear("s1").unwrap();
    assert_eq!(store.load("s1"), None);
}

#[test]
fn a_pruned_session_takes_its_cursor_with_it() {
    let scratch = Scratch::new("cascade");
    let db = scratch.database(&["s1"]);
    let store = SqliteCursors::open(&db).expect("store");
    store
        .save(
            "s1",
            &StoredCursor::fresh(Source::ClaudeJsonl, "/tmp/s1.jsonl"),
        )
        .unwrap();

    let conn = rusqlite::Connection::open(&db).unwrap();
    conn.execute_batch("PRAGMA foreign_keys = ON; DELETE FROM sessions WHERE id = 's1';")
        .unwrap();
    assert_eq!(
        store.load("s1"),
        None,
        "the cascade is what stops this leaking"
    );
}
