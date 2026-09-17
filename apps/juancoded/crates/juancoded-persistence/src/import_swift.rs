//! One-shot import of the Swift core's store into this one.
//!
//! The two cores keep one DB file each, deliberately (see this crate's constraint 1),
//! and the daemon only ever learns a session by running or adopting it. That leaves
//! every session recorded before the split reachable from exactly one core, and makes
//! deleting the Swift one a data loss rather than a cleanup. This module is the bridge
//! that has to exist before that deletion can.
//!
//! Three rules shape it, and all three are about not destroying what is already here.
//!
//! 1. **Additive only.** A session the destination already holds is left exactly as it
//!    is — the daemon's row is the live one and the Swift row is an older copy of the
//!    same session, so overwriting would move `updated_at` backwards and undo renames,
//!    archives and usage the daemon has since recorded. The one exception is scrollback
//!    the destination does not actually have: an absent row, or a row with zero bytes,
//!    is not history, and filling it takes nothing away. Byte-for-byte this is the
//!    whole point — 723 of the sessions this was measured against had metadata in the
//!    daemon and their transcript only in the Swift file.
//! 2. **Idempotent.** Run it twice and the second run writes nothing. Everything it
//!    decides is a function of what the destination holds right now, so there is no
//!    ledger to keep and no half-finished state a crash could leave.
//! 3. **No tombstones.** `forgotten_cli_sessions` is a promise that a conversation stays
//!    gone, made only by a client's explicit delete. An import is the opposite promise
//!    and must never write there.
//!
//! What does NOT come across, and why: the Swift store's `diff_comments`,
//! `diff_reviews` and `message_queue`. The first two are an app-side review cache with
//! no table on this side, and a queue belongs to a session somebody is still steering —
//! every row being imported here exited months ago.

use std::path::Path;

use anyhow::{Context, Result};
use rusqlite::{Connection, OpenFlags};

use juancoded_core::model::{ProviderId, SessionKind, SessionMeta, SessionStatus, SessionUsage};

use crate::{Scrollback, SessionStore};

/// What one import did, in the terms the person running it asked the question in.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ImportReport {
    /// Rows read out of the Swift store.
    pub sessions_seen: usize,
    /// Sessions the destination did not hold, now written.
    pub sessions_imported: usize,
    /// Sessions the destination already held, left untouched.
    pub sessions_already_present: usize,
    /// Sessions whose scrollback the destination did not hold, now written.
    pub scrollback_imported: usize,
    /// How many bytes of history that moved.
    pub scrollback_bytes: usize,
    /// Sessions whose scrollback the destination already held, left untouched.
    pub scrollback_already_present: usize,
    /// Sessions the Swift store has no scrollback for, so there was nothing to move.
    pub scrollback_empty_at_source: usize,
    /// Rows the Swift store holds that could not be translated, with the reason.
    pub skipped: Vec<(String, String)>,
}

impl ImportReport {
    /// True when a second run would be the no-op the first one promised.
    pub fn wrote_nothing(&self) -> bool {
        self.sessions_imported == 0 && self.scrollback_imported == 0
    }
}

/// One session as the Swift store spells it, before any translation.
struct SwiftRow {
    id: String,
    provider: String,
    cwd: String,
    title: String,
    exit_code: Option<i32>,
    cli_session_id: Option<String>,
    scrollback: String,
    skip_permissions: bool,
    worktree_path: Option<String>,
    usage: Option<String>,
    created_at: i64,
    updated_at: i64,
    archived: bool,
    dormant: bool,
    dispatch_id: Option<String>,
}

/// Read every session out of a Swift `juancode.db`.
///
/// Opened read-only, and read-only is not a formality: the source here is the user's
/// own history and the import must not be able to damage it even by accident. The
/// column set is discovered rather than assumed, because the Swift store grew
/// `archived`, `dormant` and `dispatch_id` by in-place migration and a file written
/// before one of those lands is still a file somebody wants imported.
fn read_swift_sessions(src: &Path) -> Result<Vec<SwiftRow>> {
    let conn = Connection::open_with_flags(src, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .with_context(|| format!("open {} read-only", src.display()))?;

    let mut present = std::collections::HashSet::new();
    {
        let mut stmt = conn
            .prepare("PRAGMA table_info(sessions)")
            .context("this does not look like a juancode store")?;
        let names = stmt.query_map([], |r| r.get::<_, String>("name"))?;
        for name in names {
            present.insert(name?);
        }
    }
    if present.is_empty() {
        anyhow::bail!(
            "{} has no `sessions` table; that is not a Swift juancode.db",
            src.display()
        );
    }
    for required in ["id", "provider", "cwd", "title", "created_at", "updated_at"] {
        if !present.contains(required) {
            anyhow::bail!(
                "{} has a `sessions` table with no `{required}` column",
                src.display()
            );
        }
    }
    // A column this file predates reads as its default rather than failing the import.
    let opt = |name: &str, fallback: &str| {
        if present.contains(name) {
            name.to_string()
        } else {
            format!("{fallback} AS {name}")
        }
    };
    let mut columns = vec![
        "id".to_string(),
        "provider".to_string(),
        "cwd".to_string(),
        "title".to_string(),
        "created_at".to_string(),
        "updated_at".to_string(),
    ];
    columns.extend([
        opt("exit_code", "NULL"),
        opt("cli_session_id", "NULL"),
        opt("scrollback", "''"),
        opt("skip_permissions", "0"),
        opt("worktree_path", "NULL"),
        opt("usage", "NULL"),
        opt("archived", "0"),
        opt("dormant", "0"),
        opt("dispatch_id", "NULL"),
    ]);
    let sql = format!(
        "SELECT {} FROM sessions ORDER BY created_at ASC",
        columns.join(", ")
    );

    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map([], |r| {
        Ok(SwiftRow {
            id: r.get("id")?,
            provider: r.get("provider")?,
            cwd: r.get("cwd")?,
            title: r.get("title")?,
            exit_code: r.get("exit_code")?,
            cli_session_id: r.get("cli_session_id")?,
            scrollback: r.get("scrollback").unwrap_or_default(),
            skip_permissions: r.get::<_, i64>("skip_permissions").unwrap_or(0) != 0,
            worktree_path: r.get("worktree_path")?,
            usage: r.get("usage")?,
            created_at: r.get("created_at")?,
            updated_at: r.get("updated_at")?,
            archived: r.get::<_, i64>("archived").unwrap_or(0) != 0,
            dormant: r.get::<_, i64>("dormant").unwrap_or(0) != 0,
            dispatch_id: r.get("dispatch_id")?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

/// Translate one Swift row into this core's `SessionMeta`.
///
/// **Status is forced to exited**, whatever the source says. The pty that backed it
/// died with the Swift core, so a row claiming to be running would be a session no
/// client could ever get a byte out of, and the daemon would have to correct it on the
/// next hydrate anyway.
///
/// Three fields have no source and are not guessed: `kind` is `Agent` because the Swift
/// store predates editor sessions entirely, `parent_session_id` is `None` because it
/// has no column there, and `title_is_manual` is `false` — the Swift core keeps that
/// flag in memory only, so an import cannot know whose idea a title was, and claiming
/// `true` would pin a derived title against every future rename.
fn translate(row: &SwiftRow) -> SessionMeta {
    SessionMeta {
        id: row.id.clone(),
        provider: ProviderId::parse(&row.provider).unwrap_or(ProviderId::Claude),
        cwd: row.cwd.clone(),
        title: row.title.clone(),
        status: SessionStatus::Exited,
        exit_code: row.exit_code,
        created_at: row.created_at,
        updated_at: row.updated_at,
        cli_session_id: row.cli_session_id.clone(),
        skip_permissions: row.skip_permissions,
        worktree_path: row.worktree_path.clone(),
        // Same camelCase JSON on both sides, so this is a parse to prove it is
        // readable rather than a reshape. A row whose usage this core cannot read
        // still imports — losing a token count is not a reason to lose a transcript.
        usage: row
            .usage
            .as_deref()
            .and_then(|u| serde_json::from_str::<SessionUsage>(u).ok()),
        archived: row.archived,
        dormant: row.dormant,
        title_is_manual: false,
        kind: SessionKind::Agent,
        parent_session_id: None,
        dispatch_id: row.dispatch_id.clone(),
    }
}

/// Import `src` (a Swift `juancode.db`) into `dest`, writing only what `dest` does not
/// already hold. `dry_run` measures without writing, so the numbers can be read before
/// anything is decided.
pub fn import_from_swift(
    src: &Path,
    dest: &dyn SessionStore,
    dry_run: bool,
) -> Result<ImportReport> {
    let rows = read_swift_sessions(src)?;
    let mut report = ImportReport {
        sessions_seen: rows.len(),
        ..Default::default()
    };

    for row in &rows {
        let existing = match dest.get(&row.id) {
            Ok(v) => v,
            Err(e) => {
                report.skipped.push((row.id.clone(), e.to_string()));
                continue;
            }
        };
        if existing.is_some() {
            report.sessions_already_present += 1;
        } else {
            if !dry_run {
                if let Err(e) = dest.upsert(&translate(row)) {
                    report.skipped.push((row.id.clone(), e.to_string()));
                    continue;
                }
            }
            report.sessions_imported += 1;
        }

        let bytes = row.scrollback.as_bytes();
        if bytes.is_empty() {
            report.scrollback_empty_at_source += 1;
            continue;
        }
        // A row of zero bytes is not history. The daemon writes one for every session
        // it rehydrates with nothing to replay, so "the row exists" is the wrong test
        // here and "there is something in it" is the right one.
        let held = dest.scrollback(&row.id).ok().flatten();
        if held.is_some_and(|s| !s.bytes.is_empty()) {
            report.scrollback_already_present += 1;
            continue;
        }
        // A dry run of a session that is not there yet cannot write scrollback either,
        // but it still counts what a real run would move.
        if !dry_run {
            let (cols, rows_) = Scrollback::UNKNOWN_GRID;
            if let Err(e) = dest.save_scrollback(&row.id, cols, rows_, bytes) {
                report.skipped.push((row.id.clone(), e.to_string()));
                continue;
            }
        }
        report.scrollback_imported += 1;
        report.scrollback_bytes += bytes.len();
    }

    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SqliteStore;

    /// A Swift store, at the schema the real one has today. Written by hand rather
    /// than by importing GRDB: the point of the test is that this module reads the
    /// shape that is on the user's disk, so the shape belongs in the test.
    fn swift_db(dir: &Path, rows: &[(&str, &str, &str, &str, &str)]) -> std::path::PathBuf {
        let path = dir.join("juancode.db");
        let conn = Connection::open(&path).unwrap();
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
        .unwrap();
        for (i, (id, provider, cwd, title, scrollback)) in rows.iter().enumerate() {
            conn.execute(
                "INSERT INTO sessions (id, provider, cwd, title, status, exit_code, \
                 cli_session_id, scrollback, skip_permissions, worktree_path, usage, \
                 created_at, updated_at) \
                 VALUES (?1,?2,?3,?4,'exited',-1,?5,?6,1,'/tmp/wt',?7,?8,?9)",
                rusqlite::params![
                    id,
                    provider,
                    cwd,
                    title,
                    format!("cli-{id}"),
                    scrollback,
                    r#"{"inputTokens":1,"outputTokens":2,"cacheReadTokens":3,"cacheWriteTokens":4,"totalTokens":10,"costUsd":0.5}"#,
                    1000 + i as i64,
                    2000 + i as i64,
                ],
            )
            .unwrap();
        }
        path
    }

    fn tmpdir(tag: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("juancoded-import-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_swift_only_session_arrives_whole() {
        let dir = tmpdir("whole");
        let src = swift_db(
            &dir,
            &[("s1", "claude", "/tmp/proj", "a title", "hello\x1b[Hworld")],
        );
        let dest = SqliteStore::in_memory().unwrap();

        let report = import_from_swift(&src, &dest, false).unwrap();
        assert_eq!(report.sessions_imported, 1);
        assert_eq!(report.scrollback_imported, 1);
        assert_eq!(report.scrollback_bytes, "hello\x1b[Hworld".len());

        let meta = dest.get("s1").unwrap().unwrap();
        assert_eq!(meta.title, "a title");
        assert_eq!(meta.cwd, "/tmp/proj");
        assert_eq!(meta.provider, ProviderId::Claude);
        assert_eq!(meta.cli_session_id.as_deref(), Some("cli-s1"));
        assert_eq!(meta.worktree_path.as_deref(), Some("/tmp/wt"));
        assert_eq!(meta.created_at, 1000);
        assert!(meta.skip_permissions);
        assert_eq!(meta.usage.unwrap().total_tokens, 10);
        // The pty that backed it is long gone, whatever the source row said.
        assert_eq!(meta.status, SessionStatus::Exited);
        // Nothing the source could not know is asserted as true.
        assert!(!meta.title_is_manual);
        assert_eq!(meta.kind, SessionKind::Agent);

        let back = dest.scrollback("s1").unwrap().unwrap();
        assert_eq!(back.bytes, b"hello\x1b[Hworld");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn imported_scrollback_says_it_has_no_grid_rather_than_inventing_one() {
        let dir = tmpdir("grid");
        let src = swift_db(&dir, &[("s1", "claude", "/tmp", "t", "bytes")]);
        let dest = SqliteStore::in_memory().unwrap();
        import_from_swift(&src, &dest, false).unwrap();

        let back = dest.scrollback("s1").unwrap().unwrap();
        assert_eq!((back.cols, back.rows), Scrollback::UNKNOWN_GRID);
        assert_eq!(
            back.grid(),
            None,
            "the Swift store records no width, so nothing here may claim one"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn running_it_twice_writes_nothing_the_second_time() {
        let dir = tmpdir("twice");
        let src = swift_db(
            &dir,
            &[
                ("s1", "claude", "/tmp/a", "one", "aaa"),
                ("s2", "codex", "/tmp/b", "two", "bbb"),
            ],
        );
        let dest = SqliteStore::in_memory().unwrap();

        let first = import_from_swift(&src, &dest, false).unwrap();
        assert_eq!((first.sessions_imported, first.scrollback_imported), (2, 2));

        let second = import_from_swift(&src, &dest, false).unwrap();
        assert!(second.wrote_nothing(), "{second:?}");
        assert_eq!(second.sessions_already_present, 2);
        assert_eq!(second.scrollback_already_present, 2);
        assert_eq!(dest.all().unwrap().len(), 2);
        assert_eq!(dest.scrollback("s1").unwrap().unwrap().bytes, b"aaa");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_session_the_daemon_already_owns_keeps_its_own_metadata() {
        let dir = tmpdir("own");
        let src = swift_db(&dir, &[("s1", "claude", "/tmp", "the old title", "aaa")]);
        let dest = SqliteStore::in_memory().unwrap();
        let mut live = SessionMeta::new(
            "s1".into(),
            ProviderId::Claude,
            "/tmp".into(),
            "the name I gave it".into(),
            9_000,
            false,
        );
        live.title_is_manual = true;
        live.status = SessionStatus::Exited;
        dest.upsert(&live).unwrap();

        let report = import_from_swift(&src, &dest, false).unwrap();
        assert_eq!(report.sessions_imported, 0);
        assert_eq!(report.sessions_already_present, 1);

        let back = dest.get("s1").unwrap().unwrap();
        assert_eq!(back.title, "the name I gave it");
        assert!(back.title_is_manual, "an import may not undo a rename");
        assert_eq!(back.updated_at, 9_000, "nor move updated_at backwards");
    }

    /// The case this was actually built for: the daemon holds the row, and a rehydrate
    /// with nothing to replay has already written it an empty scrollback. The history
    /// still only exists in the Swift file, and an "is there a row?" test would call
    /// that done.
    #[test]
    fn an_empty_scrollback_row_is_not_history_and_gets_filled() {
        let dir = tmpdir("empty");
        let src = swift_db(&dir, &[("s1", "claude", "/tmp", "t", "the transcript")]);
        let dest = SqliteStore::in_memory().unwrap();
        let mut live = SessionMeta::new(
            "s1".into(),
            ProviderId::Claude,
            "/tmp".into(),
            "t".into(),
            9_000,
            false,
        );
        live.status = SessionStatus::Exited;
        dest.upsert(&live).unwrap();
        dest.save_scrollback("s1", 120, 40, b"").unwrap();

        let report = import_from_swift(&src, &dest, false).unwrap();
        assert_eq!(report.scrollback_imported, 1);
        let back = dest.scrollback("s1").unwrap().unwrap();
        assert_eq!(back.bytes, b"the transcript");
        assert_eq!(
            back.grid(),
            None,
            "the 120x40 that was on the empty row was this daemon's default, not a \
             width these bytes were ever parsed at"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn scrollback_the_destination_really_has_is_never_overwritten() {
        let dir = tmpdir("keep");
        let src = swift_db(&dir, &[("s1", "claude", "/tmp", "t", "older bytes")]);
        let dest = SqliteStore::in_memory().unwrap();
        let mut live = SessionMeta::new(
            "s1".into(),
            ProviderId::Claude,
            "/tmp".into(),
            "t".into(),
            9_000,
            false,
        );
        live.status = SessionStatus::Exited;
        dest.upsert(&live).unwrap();
        dest.save_scrollback("s1", 100, 30, b"the daemon's own bytes")
            .unwrap();

        let report = import_from_swift(&src, &dest, false).unwrap();
        assert_eq!(report.scrollback_already_present, 1);
        let back = dest.scrollback("s1").unwrap().unwrap();
        assert_eq!(back.bytes, b"the daemon's own bytes");
        assert_eq!(back.grid(), Some((100, 30)));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn an_import_never_tombstones_a_conversation() {
        let dir = tmpdir("tombstone");
        let src = swift_db(&dir, &[("s1", "claude", "/tmp", "t", "aaa")]);
        let dest = SqliteStore::in_memory().unwrap();
        import_from_swift(&src, &dest, false).unwrap();
        assert!(
            dest.forgotten_cli_session_ids().unwrap().is_empty(),
            "a tombstone would make every imported conversation un-adoptable"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_dry_run_counts_the_same_work_and_does_none_of_it() {
        let dir = tmpdir("dry");
        let src = swift_db(
            &dir,
            &[
                ("s1", "claude", "/tmp/a", "one", "aaa"),
                ("s2", "opencode", "/tmp/b", "two", ""),
            ],
        );
        let dest = SqliteStore::in_memory().unwrap();

        let dry = import_from_swift(&src, &dest, true).unwrap();
        assert_eq!(dry.sessions_imported, 2);
        assert_eq!(dry.scrollback_imported, 1);
        assert_eq!(dry.scrollback_empty_at_source, 1);
        assert!(dest.all().unwrap().is_empty(), "a dry run wrote a row");

        let wet = import_from_swift(&src, &dest, false).unwrap();
        assert_eq!(wet.sessions_imported, dry.sessions_imported);
        assert_eq!(wet.scrollback_imported, dry.scrollback_imported);
        assert_eq!(wet.scrollback_bytes, dry.scrollback_bytes);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_store_written_before_the_later_columns_landed_still_imports() {
        let dir = tmpdir("old");
        let path = dir.join("juancode.db");
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE sessions (
                id         TEXT PRIMARY KEY,
                provider   TEXT NOT NULL,
                cwd        TEXT NOT NULL,
                title      TEXT NOT NULL,
                status     TEXT NOT NULL,
                scrollback TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            INSERT INTO sessions VALUES ('s1','claude','/tmp','t','exited','aaa',1,2);",
        )
        .unwrap();
        drop(conn);

        let dest = SqliteStore::in_memory().unwrap();
        let report = import_from_swift(&path, &dest, false).unwrap();
        assert_eq!(report.sessions_imported, 1);
        let meta = dest.get("s1").unwrap().unwrap();
        assert!(!meta.archived);
        assert!(!meta.dormant);
        assert_eq!(meta.dispatch_id, None);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_file_that_is_not_a_juancode_store_is_refused_rather_than_half_read() {
        let dir = tmpdir("bogus");
        let path = dir.join("not-a-store.db");
        Connection::open(&path)
            .unwrap()
            .execute_batch("CREATE TABLE something_else (a TEXT);")
            .unwrap();
        let dest = SqliteStore::in_memory().unwrap();
        assert!(import_from_swift(&path, &dest, false).is_err());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
