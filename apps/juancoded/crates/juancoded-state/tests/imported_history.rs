//! The Swift-store import, from the daemon's side (juancode-xzwd).
//!
//! The persistence crate proves the translation. This proves the thing a user would
//! actually check: a session that only ever existed under the Swift core comes back
//! from the daemon with its transcript in it, and the daemon does not quietly stamp a
//! width over bytes that never recorded one.
//!
//! That second half is not a detail. The Swift store has no column saying how wide the
//! terminal was, so imported bytes arrive with `Scrollback::UNKNOWN_GRID`, and the
//! shutdown flush sweeps EVERY session — including ones nobody opened. A sweep that
//! rewrote the pair would replace "no width recorded" with whatever this process
//! happened to boot at, and the next replay would lay every hard wrap in the wrong
//! cell believing it had the real number.

mod harness;

use std::path::{Path, PathBuf};

use harness::Harness;
use juancoded_persistence::{Scrollback, SessionStore, SqliteStore};

/// Long enough to wrap at 40 columns and not at 100 — the fixture only means anything
/// if a wrong width would be visible.
const TRANSCRIPT: &str = "0123456789abcdefghij0123456789ABCDEFGHIJ0123456789klmnopqrst";

/// A Swift `juancode.db` holding one exited session, at the schema the real one has.
fn swift_db(dir: &Path, id: &str) -> PathBuf {
    let path = dir.join("juancode.db");
    let conn = rusqlite::Connection::open(&path).expect("swift db");
    conn.execute_batch(
        "CREATE TABLE sessions (
            id               TEXT PRIMARY KEY,
            provider         TEXT NOT NULL,
            cwd              TEXT NOT NULL,
            title            TEXT NOT NULL,
            status           TEXT NOT NULL,
            exit_code        INTEGER,
            cli_session_id   TEXT,
            scrollback       TEXT NOT NULL DEFAULT '',
            skip_permissions INTEGER NOT NULL DEFAULT 0,
            worktree_path    TEXT,
            usage            TEXT,
            created_at       INTEGER NOT NULL,
            updated_at       INTEGER NOT NULL,
            archived         INTEGER NOT NULL DEFAULT 0,
            dormant          INTEGER NOT NULL DEFAULT 0,
            dispatch_id      TEXT,
            mid_turn         INTEGER NOT NULL DEFAULT 0
        );",
    )
    .expect("swift schema");
    conn.execute(
        "INSERT INTO sessions (id, provider, cwd, title, status, exit_code, scrollback, \
         created_at, updated_at) VALUES (?1,'claude','/tmp/old-project','a session from \
         before the split','exited',0,?2,1000,2000)",
        rusqlite::params![id, TRANSCRIPT],
    )
    .expect("swift row");
    path
}

#[tokio::test]
async fn a_session_that_only_existed_under_the_swift_core_comes_back_whole() {
    let dir = std::env::temp_dir().join(format!(
        "juancoded-imported-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    std::fs::remove_dir_all(&dir).ok();
    std::fs::create_dir_all(&dir).expect("scratch dir");
    let id = "11111111-2222-3333-4444-555555555555";
    let source = swift_db(&dir, id);
    let store_path = dir.join("state.db");

    {
        let store = SqliteStore::open(&store_path).expect("destination store");
        let report = juancoded_persistence::import_swift::import_from_swift(&source, &store, false)
            .expect("import");
        assert_eq!(report.sessions_imported, 1);
        assert_eq!(report.scrollback_imported, 1);
    }

    let harness = Harness::reopen(dir.clone(), store_path.clone());

    let meta = harness
        .sessions
        .meta(id)
        .expect("the imported session is one the daemon holds");
    assert_eq!(meta.title, "a session from before the split");
    assert_eq!(meta.cwd, "/tmp/old-project");
    assert!(
        !harness.sessions.is_running(id),
        "its pty died with the Swift core"
    );

    // A shutdown sweep, before anything opens the session. This is the moment the
    // invented width used to appear.
    harness.sessions.flush_all();
    {
        let store = SqliteStore::open(&store_path).expect("re-open");
        let stored = store.scrollback(id).expect("read").expect("a row");
        assert_eq!(
            (stored.cols, stored.rows),
            Scrollback::UNKNOWN_GRID,
            "the Swift store recorded no width, so a flush may not invent one"
        );
        assert_eq!(stored.grid(), None);
        assert_eq!(stored.bytes, TRANSCRIPT.as_bytes());
    }

    // And the history is really there to read.
    let attached = harness.sessions.attach(id, 1, 100, 30).expect("attach");
    assert!(
        attached.scrollback.contains("klmnopqrst"),
        "the transcript came across: {:?}",
        attached.scrollback
    );

    // Now that the bytes have actually been parsed at a grid, the row may say so —
    // "unknown" is a fact about the source, not a permanent property of the session.
    let store = SqliteStore::open(&store_path).expect("re-open");
    let stored = store.scrollback(id).expect("read").expect("a row");
    assert_eq!(
        stored.grid(),
        Some((100, 30)),
        "a real replay is the one thing that establishes a width"
    );

    drop(harness);
    std::fs::remove_dir_all(&dir).ok();
}
