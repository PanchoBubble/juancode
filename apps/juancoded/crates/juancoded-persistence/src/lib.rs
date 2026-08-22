//! The Rust core's own store: SQLite, one file, never the Swift core's.
//!
//! Two constraints shape everything here.
//!
//! 1. **One DB file per core.** A session started under the Swift core is simply not
//!    visible under this one, which is what makes flipping cores a restart rather
//!    than a migration. So the default path is `~/.juancode/rust-core/`, not the
//!    `~/.juancode/data/` the Swift core owns, and the file name says which core
//!    wrote it even if someone points both at one directory.
//! 2. **Scrollback carries the grid it was written at.** A byte ring with no record
//!    of its width can only be replayed by guessing, and a wrong guess lands hard
//!    wraps and absolute cursor moves in the wrong cells — the same garble the live
//!    path was fixed for. `scrollback` stores `cols`/`rows` beside the bytes, and
//!    every reader parses at that width.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use anyhow::{Context, Result};
use rusqlite::{params, Connection, OptionalExtension};

use juancoded_core::model::{ProviderId, SessionKind, SessionMeta, SessionStatus, SessionUsage};

pub mod discovery;
pub mod schema;

/// Scrollback bytes plus the grid they were parsed at. Never one without the other.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Scrollback {
    pub cols: u16,
    pub rows: u16,
    pub bytes: Vec<u8>,
}

/// One queued steering message, in delivery order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueuedMessage {
    pub id: String,
    pub session_id: String,
    pub text: String,
    pub created_at: i64,
}

/// One watched pull request. Stored here so the watch list survives a restart; the
/// poll loop that drives it is a later ticket.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrackedPr {
    pub id: String,
    pub number: i64,
    pub title: String,
    pub url: String,
    pub branch: String,
    pub cwd: String,
    pub session_id: Option<String>,
    pub state: String,
    pub checks: String,
    pub created_at: i64,
}

/// Where this core's DB lives.
///
/// `JUANCODED_DATA_DIR` first (the daemon's own knob), then `JUANCODE_DATA_DIR` so a
/// harness that only knows the Swift core's variable still isolates us, then the
/// default. The file name is fixed either way: sharing a directory with the Swift
/// core is survivable, sharing a file is not.
pub fn db_path() -> PathBuf {
    let dir = std::env::var("JUANCODED_DATA_DIR")
        .or_else(|_| std::env::var("JUANCODE_DATA_DIR"))
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
            PathBuf::from(home).join(".juancode").join("rust-core")
        });
    dir.join("juancoded-rust.db")
}

/// How many sessions a project keeps. 0 means unlimited, matching the Swift core's
/// `JUANCODE_SESSIONS_PER_PROJECT=0` escape hatch (the conformance suite sets it so a
/// scenario's session is still there when the next step addresses it).
pub fn sessions_per_project() -> usize {
    std::env::var("JUANCODE_SESSIONS_PER_PROJECT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(40)
}

/// The store contract. A trait rather than the concrete type so a test can stand in
/// an in-memory double, and so the cordis mount site is the only place that knows
/// this is SQLite at all.
pub trait SessionStore: Send + Sync {
    fn upsert(&self, meta: &SessionMeta) -> Result<()>;
    fn get(&self, id: &str) -> Result<Option<SessionMeta>>;
    fn all(&self) -> Result<Vec<SessionMeta>>;
    fn delete(&self, id: &str) -> Result<()>;
    /// Every CLI conversation id we already own, so an adopt cannot duplicate one.
    fn used_cli_session_ids(&self) -> Result<Vec<String>>;

    fn save_scrollback(&self, id: &str, cols: u16, rows: u16, bytes: &[u8]) -> Result<()>;
    fn scrollback(&self, id: &str) -> Result<Option<Scrollback>>;

    fn enqueue(&self, item: &QueuedMessage) -> Result<()>;
    /// Drop one queued message from one session's queue. `false` means there was
    /// nothing to drop, which is what a caller gets for a message already delivered
    /// or already cancelled — and the reason a watcher is not told about a change
    /// that did not happen.
    fn dequeue(&self, session_id: &str, message_id: &str) -> Result<bool>;
    fn queue(&self, session_id: &str) -> Result<Vec<QueuedMessage>>;

    fn upsert_tracked_pr(&self, pr: &TrackedPr) -> Result<()>;
    fn untrack_pr(&self, tracked_id: &str) -> Result<()>;
    fn tracked_prs(&self) -> Result<Vec<TrackedPr>>;

    /// Claim a dispatch id. `false` means someone already claimed it, which is how a
    /// dispatch delivered twice starts one session instead of two.
    fn claim_dispatch(&self, dispatch_id: &str, session_id: Option<&str>) -> Result<bool>;

    /// Trim a project's history to `keep` sessions, oldest exited first, and return
    /// what was removed. `keep == 0` keeps everything.
    fn prune_project(&self, cwd: &str, keep: usize) -> Result<Vec<String>>;
}

/// The real store. One connection behind one mutex: every write here is small and
/// the daemon's session count is in the tens, so a pool would be complexity for no
/// measured gain.
pub struct SqliteStore {
    conn: Mutex<Connection>,
    path: PathBuf,
}

impl SqliteStore {
    /// Open (creating the parent directory) and migrate.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref().to_path_buf();
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).with_context(|| format!("mkdir {}", dir.display()))?;
        }
        let conn = Connection::open(&path).with_context(|| format!("open {}", path.display()))?;
        schema::migrate(&conn)?;
        Ok(Self {
            conn: Mutex::new(conn),
            path,
        })
    }

    /// An unnamed in-memory database. Tests only, and the one place a store is not a file.
    pub fn in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        schema::migrate(&conn)?;
        Ok(Self {
            conn: Mutex::new(conn),
            path: PathBuf::from(":memory:"),
        })
    }

    /// Open the path this core's environment names.
    pub fn open_default() -> Result<Self> {
        Self::open(db_path())
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn conn(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|e| e.into_inner())
    }
}

fn row_to_meta(row: &rusqlite::Row<'_>) -> rusqlite::Result<SessionMeta> {
    let provider: String = row.get("provider")?;
    let status: String = row.get("status")?;
    let kind: String = row.get("kind")?;
    let usage: Option<String> = row.get("usage")?;
    Ok(SessionMeta {
        id: row.get("id")?,
        provider: ProviderId::parse(&provider).unwrap_or(ProviderId::Claude),
        cwd: row.get("cwd")?,
        title: row.get("title")?,
        status: if status == "running" {
            SessionStatus::Running
        } else {
            SessionStatus::Exited
        },
        exit_code: row.get("exit_code")?,
        created_at: row.get("created_at")?,
        updated_at: row.get("updated_at")?,
        cli_session_id: row.get("cli_session_id")?,
        skip_permissions: row.get::<_, i64>("skip_permissions")? != 0,
        worktree_path: row.get("worktree_path")?,
        usage: usage.and_then(|u| serde_json::from_str::<SessionUsage>(&u).ok()),
        archived: row.get::<_, i64>("archived")? != 0,
        dormant: row.get::<_, i64>("dormant")? != 0,
        kind: if kind == "editor" {
            SessionKind::Editor
        } else {
            SessionKind::Agent
        },
        parent_session_id: row.get("parent_session_id")?,
        dispatch_id: row.get("dispatch_id")?,
    })
}

const SESSION_COLUMNS: &str = "id, provider, cwd, title, status, exit_code, created_at, \
     updated_at, cli_session_id, skip_permissions, worktree_path, usage, archived, dormant, \
     kind, parent_session_id, dispatch_id";

impl SessionStore for SqliteStore {
    fn upsert(&self, meta: &SessionMeta) -> Result<()> {
        let status = match meta.status {
            SessionStatus::Running => "running",
            SessionStatus::Exited => "exited",
        };
        let kind = match meta.kind {
            SessionKind::Agent => "agent",
            SessionKind::Editor => "editor",
        };
        let usage = meta
            .usage
            .as_ref()
            .and_then(|u| serde_json::to_string(u).ok());
        self.conn().execute(
            "INSERT INTO sessions (id, provider, cwd, title, status, exit_code, created_at, \
             updated_at, cli_session_id, skip_permissions, worktree_path, usage, archived, \
             dormant, kind, parent_session_id, dispatch_id) \
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17) \
             ON CONFLICT(id) DO UPDATE SET provider=excluded.provider, cwd=excluded.cwd, \
             title=excluded.title, status=excluded.status, exit_code=excluded.exit_code, \
             updated_at=excluded.updated_at, cli_session_id=excluded.cli_session_id, \
             skip_permissions=excluded.skip_permissions, worktree_path=excluded.worktree_path, \
             usage=excluded.usage, archived=excluded.archived, dormant=excluded.dormant, \
             kind=excluded.kind, parent_session_id=excluded.parent_session_id, \
             dispatch_id=excluded.dispatch_id",
            params![
                meta.id,
                meta.provider.as_str(),
                meta.cwd,
                meta.title,
                status,
                meta.exit_code,
                meta.created_at,
                meta.updated_at,
                meta.cli_session_id,
                i64::from(meta.skip_permissions),
                meta.worktree_path,
                usage,
                i64::from(meta.archived),
                i64::from(meta.dormant),
                kind,
                meta.parent_session_id,
                meta.dispatch_id,
            ],
        )?;
        Ok(())
    }

    fn get(&self, id: &str) -> Result<Option<SessionMeta>> {
        let conn = self.conn();
        let sql = format!("SELECT {SESSION_COLUMNS} FROM sessions WHERE id = ?1");
        let meta = conn.query_row(&sql, params![id], row_to_meta).optional()?;
        Ok(meta)
    }

    fn all(&self) -> Result<Vec<SessionMeta>> {
        let conn = self.conn();
        let sql = format!("SELECT {SESSION_COLUMNS} FROM sessions ORDER BY created_at ASC");
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map([], row_to_meta)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    fn delete(&self, id: &str) -> Result<()> {
        self.conn()
            .execute("DELETE FROM sessions WHERE id = ?1", params![id])?;
        Ok(())
    }

    fn used_cli_session_ids(&self) -> Result<Vec<String>> {
        let conn = self.conn();
        let mut stmt =
            conn.prepare("SELECT cli_session_id FROM sessions WHERE cli_session_id IS NOT NULL")?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    fn save_scrollback(&self, id: &str, cols: u16, rows: u16, bytes: &[u8]) -> Result<()> {
        self.conn().execute(
            "INSERT INTO scrollback (session_id, cols, rows, bytes) VALUES (?1,?2,?3,?4) \
             ON CONFLICT(session_id) DO UPDATE SET cols=excluded.cols, rows=excluded.rows, \
             bytes=excluded.bytes",
            params![id, i64::from(cols), i64::from(rows), bytes],
        )?;
        Ok(())
    }

    fn scrollback(&self, id: &str) -> Result<Option<Scrollback>> {
        let conn = self.conn();
        let row = conn
            .query_row(
                "SELECT cols, rows, bytes FROM scrollback WHERE session_id = ?1",
                params![id],
                |r| {
                    Ok(Scrollback {
                        cols: r.get::<_, i64>(0)? as u16,
                        rows: r.get::<_, i64>(1)? as u16,
                        bytes: r.get(2)?,
                    })
                },
            )
            .optional()?;
        Ok(row)
    }

    fn enqueue(&self, item: &QueuedMessage) -> Result<()> {
        self.conn().execute(
            "INSERT INTO queue (id, session_id, text, created_at, position) \
             VALUES (?1,?2,?3,?4, COALESCE((SELECT MAX(position) FROM queue WHERE \
             session_id = ?2), 0) + 1)",
            params![item.id, item.session_id, item.text, item.created_at],
        )?;
        Ok(())
    }

    fn dequeue(&self, session_id: &str, message_id: &str) -> Result<bool> {
        // Scoped to the session on purpose: a message id is only ever handed out
        // alongside the session it belongs to, so a stale id from another session
        // must miss rather than delete somebody else's pending message.
        let removed = self.conn().execute(
            "DELETE FROM queue WHERE id = ?1 AND session_id = ?2",
            params![message_id, session_id],
        )?;
        Ok(removed > 0)
    }

    fn queue(&self, session_id: &str) -> Result<Vec<QueuedMessage>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(
            "SELECT id, session_id, text, created_at FROM queue WHERE session_id = ?1 \
             ORDER BY position ASC",
        )?;
        let rows = stmt.query_map(params![session_id], |r| {
            Ok(QueuedMessage {
                id: r.get(0)?,
                session_id: r.get(1)?,
                text: r.get(2)?,
                created_at: r.get(3)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    fn upsert_tracked_pr(&self, pr: &TrackedPr) -> Result<()> {
        self.conn().execute(
            "INSERT INTO tracked_prs (id, number, title, url, branch, cwd, session_id, state, \
             checks, created_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10) \
             ON CONFLICT(id) DO UPDATE SET number=excluded.number, title=excluded.title, \
             url=excluded.url, branch=excluded.branch, cwd=excluded.cwd, \
             session_id=excluded.session_id, state=excluded.state, checks=excluded.checks",
            params![
                pr.id,
                pr.number,
                pr.title,
                pr.url,
                pr.branch,
                pr.cwd,
                pr.session_id,
                pr.state,
                pr.checks,
                pr.created_at,
            ],
        )?;
        Ok(())
    }

    fn untrack_pr(&self, tracked_id: &str) -> Result<()> {
        self.conn()
            .execute("DELETE FROM tracked_prs WHERE id = ?1", params![tracked_id])?;
        Ok(())
    }

    fn tracked_prs(&self) -> Result<Vec<TrackedPr>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(
            "SELECT id, number, title, url, branch, cwd, session_id, state, checks, created_at \
             FROM tracked_prs ORDER BY created_at ASC",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(TrackedPr {
                id: r.get(0)?,
                number: r.get(1)?,
                title: r.get(2)?,
                url: r.get(3)?,
                branch: r.get(4)?,
                cwd: r.get(5)?,
                session_id: r.get(6)?,
                state: r.get(7)?,
                checks: r.get(8)?,
                created_at: r.get(9)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    fn claim_dispatch(&self, dispatch_id: &str, session_id: Option<&str>) -> Result<bool> {
        // The primary key does the arbitration: two concurrent claims cannot both
        // insert, so exactly one caller sees `true`.
        let inserted = self.conn().execute(
            "INSERT OR IGNORE INTO dispatches (dispatch_id, session_id, created_at) \
             VALUES (?1, ?2, ?3)",
            params![dispatch_id, session_id, juancoded_core::model::now_ms()],
        )?;
        Ok(inserted == 1)
    }

    fn prune_project(&self, cwd: &str, keep: usize) -> Result<Vec<String>> {
        if keep == 0 {
            return Ok(Vec::new());
        }
        let conn = self.conn();
        // Newest first, then everything past the cap goes. A running session is
        // never pruned: the cap is about history, not about killing live work.
        let mut stmt = conn.prepare(
            "SELECT id FROM sessions WHERE cwd = ?1 AND status = 'exited' \
             ORDER BY created_at DESC LIMIT -1 OFFSET ?2",
        )?;
        let doomed: Vec<String> = stmt
            .query_map(params![cwd, keep as i64], |r| r.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        drop(stmt);
        for id in &doomed {
            conn.execute("DELETE FROM sessions WHERE id = ?1", params![id])?;
        }
        Ok(doomed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use juancoded_core::model::now_ms;

    fn meta(id: &str, cwd: &str, created_at: i64) -> SessionMeta {
        let mut m = SessionMeta::new(
            id.into(),
            ProviderId::Claude,
            cwd.into(),
            "proj".into(),
            now_ms(),
            false,
        );
        m.created_at = created_at;
        m
    }

    fn exited(id: &str, cwd: &str, created_at: i64) -> SessionMeta {
        let mut m = meta(id, cwd, created_at);
        m.status = SessionStatus::Exited;
        m.exit_code = Some(0);
        m
    }

    #[test]
    fn the_default_path_is_not_the_swift_cores_directory() {
        // Set deliberately: the check is that we never land in `data/juancode.db`,
        // whichever variable a harness happens to know about.
        let path = db_path();
        let shown = path.to_string_lossy();
        assert!(shown.ends_with("juancoded-rust.db"), "{shown}");
        assert!(!shown.contains("/data/juancode.db"), "{shown}");
    }

    #[test]
    fn a_session_round_trips_every_field_that_crosses_the_wire() {
        let store = SqliteStore::in_memory().unwrap();
        let mut m = meta("s1", "/tmp/proj", 10);
        m.cli_session_id = Some("cli-1".into());
        m.worktree_path = Some("/tmp/wt".into());
        m.dispatch_id = Some("d-1".into());
        m.usage = Some(SessionUsage {
            input_tokens: 1,
            output_tokens: 2,
            cache_read_tokens: 3,
            cache_write_tokens: 4,
            total_tokens: 10,
            cost_usd: Some(0.5),
        });
        store.upsert(&m).unwrap();
        assert_eq!(store.get("s1").unwrap().as_ref(), Some(&m));

        m.status = SessionStatus::Exited;
        m.exit_code = Some(7);
        store.upsert(&m).unwrap();
        let back = store.get("s1").unwrap().unwrap();
        assert_eq!(back.status, SessionStatus::Exited);
        assert_eq!(back.exit_code, Some(7));
        assert_eq!(store.all().unwrap().len(), 1);
    }

    #[test]
    fn scrollback_is_stored_with_the_grid_it_was_parsed_at() {
        let store = SqliteStore::in_memory().unwrap();
        store.upsert(&meta("s1", "/tmp", 1)).unwrap();
        store
            .save_scrollback("s1", 43, 11, b"wrapped\x1b[Hbytes")
            .unwrap();
        let back = store.scrollback("s1").unwrap().unwrap();
        assert_eq!((back.cols, back.rows), (43, 11));
        assert_eq!(back.bytes, b"wrapped\x1b[Hbytes");
        // Overwriting at a new grid replaces both halves together; there is no way
        // to end up with bytes from one width and a number from another.
        store.save_scrollback("s1", 100, 30, b"later").unwrap();
        let back = store.scrollback("s1").unwrap().unwrap();
        assert_eq!(
            (back.cols, back.rows, back.bytes),
            (100, 30, b"later".to_vec())
        );
    }

    #[test]
    fn deleting_a_session_takes_its_scrollback_and_queue_with_it() {
        let store = SqliteStore::in_memory().unwrap();
        store.upsert(&meta("s1", "/tmp", 1)).unwrap();
        store.save_scrollback("s1", 80, 24, b"bytes").unwrap();
        store
            .enqueue(&QueuedMessage {
                id: "q1".into(),
                session_id: "s1".into(),
                text: "hello".into(),
                created_at: 1,
            })
            .unwrap();
        store.delete("s1").unwrap();
        assert!(store.scrollback("s1").unwrap().is_none());
        assert!(store.queue("s1").unwrap().is_empty());
    }

    #[test]
    fn the_queue_keeps_insertion_order_across_a_reopen() {
        let dir = std::env::temp_dir().join(format!("juancoded-store-{}", std::process::id()));
        let path = dir.join("q.db");
        std::fs::remove_dir_all(&dir).ok();
        {
            let store = SqliteStore::open(&path).unwrap();
            store.upsert(&meta("s1", "/tmp", 1)).unwrap();
            for (i, text) in ["first", "second", "third"].iter().enumerate() {
                store
                    .enqueue(&QueuedMessage {
                        id: format!("q{i}"),
                        session_id: "s1".into(),
                        text: (*text).into(),
                        created_at: i as i64,
                    })
                    .unwrap();
            }
            assert!(store.dequeue("s1", "q1").unwrap());
            // Neither an id from another session nor one already gone is a deletion.
            assert!(!store.dequeue("s2", "q0").unwrap());
            assert!(!store.dequeue("s1", "q1").unwrap());
        }
        let store = SqliteStore::open(&path).unwrap();
        let texts: Vec<String> = store
            .queue("s1")
            .unwrap()
            .into_iter()
            .map(|q| q.text)
            .collect();
        assert_eq!(texts, ["first", "third"]);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_dispatch_id_can_only_be_claimed_once() {
        let store = SqliteStore::in_memory().unwrap();
        assert!(store.claim_dispatch("d-1", Some("s1")).unwrap());
        assert!(!store.claim_dispatch("d-1", Some("s2")).unwrap());
        assert!(store.claim_dispatch("d-2", None).unwrap());
    }

    #[test]
    fn the_retention_cap_is_per_project_and_spares_the_living() {
        let store = SqliteStore::in_memory().unwrap();
        for i in 0..5 {
            store
                .upsert(&exited(&format!("a{i}"), "/proj/a", i))
                .unwrap();
        }
        for i in 0..3 {
            store
                .upsert(&exited(&format!("b{i}"), "/proj/b", i))
                .unwrap();
        }
        // Still running, and the oldest row in its project.
        store.upsert(&meta("a-live", "/proj/a", -1)).unwrap();

        let pruned = store.prune_project("/proj/a", 2).unwrap();
        assert_eq!(pruned.len(), 3, "{pruned:?}");
        assert!(store.get("a4").unwrap().is_some());
        assert!(store.get("a3").unwrap().is_some());
        assert!(
            store.get("a-live").unwrap().is_some(),
            "a live session was pruned"
        );
        // The other project is untouched, which is what "per project" means.
        assert_eq!(store.prune_project("/proj/b", 5).unwrap().len(), 0);
        assert_eq!(store.all().unwrap().len(), 3 + 3);
    }

    #[test]
    fn a_cap_of_zero_keeps_everything() {
        let store = SqliteStore::in_memory().unwrap();
        for i in 0..10 {
            store.upsert(&exited(&format!("s{i}"), "/proj", i)).unwrap();
        }
        assert!(store.prune_project("/proj", 0).unwrap().is_empty());
        assert_eq!(store.all().unwrap().len(), 10);
    }

    #[test]
    fn adopted_conversation_ids_are_readable_back_so_an_adopt_cannot_duplicate() {
        let store = SqliteStore::in_memory().unwrap();
        let mut m = meta("s1", "/tmp", 1);
        m.cli_session_id = Some("external-0001".into());
        store.upsert(&m).unwrap();
        store.upsert(&meta("s2", "/tmp", 2)).unwrap();
        assert_eq!(store.used_cli_session_ids().unwrap(), ["external-0001"]);
    }

    #[test]
    fn tracked_prs_survive_and_untrack_cleanly() {
        let store = SqliteStore::in_memory().unwrap();
        let pr = TrackedPr {
            id: "t1".into(),
            number: 4242,
            title: "fixture".into(),
            url: "https://example.invalid/pr/4242".into(),
            branch: "main".into(),
            cwd: "/repo".into(),
            session_id: Some("s1".into()),
            state: "watching".into(),
            checks: "none".into(),
            created_at: 5,
        };
        store.upsert_tracked_pr(&pr).unwrap();
        assert_eq!(store.tracked_prs().unwrap(), vec![pr.clone()]);
        store.untrack_pr("t1").unwrap();
        assert!(store.tracked_prs().unwrap().is_empty());
    }
}
