//! Where a session's resume point survives a restart.
//!
//! Two things have to be durable, not one. The read offset is obvious: without it the
//! daemon re-parses every transcript it has ever seen on the first poll after a
//! restart. The sequence number is the other: `seq` is the promise that a session's
//! records are append-only, and a counter that started again at zero after a restart
//! would break exactly the consumers that promise exists for.
//!
//! The cursor itself is an opaque string the source owns. This layer stores bytes.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use anyhow::Result;
use rusqlite::{params, Connection, OptionalExtension};

use crate::{Cursor, Source};

/// One session's place in its transcript.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredCursor {
    pub source: Source,
    /// The binding this cursor belongs to. A cursor whose locator no longer matches
    /// the binding is somebody else's offset and is thrown away rather than resumed.
    pub locator: String,
    pub cursor: Cursor,
    pub next_seq: u64,
}

impl StoredCursor {
    pub fn fresh(source: Source, locator: impl Into<String>) -> Self {
        Self {
            source,
            locator: locator.into(),
            cursor: String::new(),
            next_seq: 0,
        }
    }
}

pub trait CursorStore: Send + Sync {
    fn load(&self, session: &str) -> Option<StoredCursor>;
    fn save(&self, session: &str, cursor: &StoredCursor) -> Result<()>;
    fn clear(&self, session: &str) -> Result<()>;
}

/// For tests, and for a daemon told to keep nothing.
#[derive(Debug, Default)]
pub struct MemoryCursors {
    rows: Mutex<BTreeMap<String, StoredCursor>>,
}

impl MemoryCursors {
    pub fn new() -> Self {
        Self::default()
    }

    fn rows(&self) -> std::sync::MutexGuard<'_, BTreeMap<String, StoredCursor>> {
        self.rows.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl CursorStore for MemoryCursors {
    fn load(&self, session: &str) -> Option<StoredCursor> {
        self.rows().get(session).cloned()
    }

    fn save(&self, session: &str, cursor: &StoredCursor) -> Result<()> {
        self.rows().insert(session.to_string(), cursor.clone());
        Ok(())
    }

    fn clear(&self, session: &str) -> Result<()> {
        self.rows().remove(session);
        Ok(())
    }
}

/// The real one: the core's own SQLite, table `transcript_cursors`.
///
/// The table is created by `juancoded_persistence`'s migration list and not here, so
/// there is one authority on the schema. A store pointed at a database that has not
/// been migrated reports the missing table rather than quietly creating a second
/// version of it.
pub struct SqliteCursors {
    conn: Mutex<Connection>,
    path: PathBuf,
}

impl SqliteCursors {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref().to_path_buf();
        let conn = Connection::open(&path)?;
        conn.busy_timeout(std::time::Duration::from_millis(500))?;
        Ok(Self {
            conn: Mutex::new(conn),
            path,
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn conn(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl CursorStore for SqliteCursors {
    fn load(&self, session: &str) -> Option<StoredCursor> {
        let conn = self.conn();
        let row = conn
            .query_row(
                "SELECT source, locator, cursor, next_seq FROM transcript_cursors WHERE session_id = ?1",
                [session],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, i64>(3)?,
                    ))
                },
            )
            .optional()
            .unwrap_or_else(|e| {
                tracing::warn!(error = %e, "transcript cursor unreadable");
                None
            })?;
        let source = match row.0.as_str() {
            "claude-jsonl" => Source::ClaudeJsonl,
            "opencode-sqlite" => Source::OpencodeSqlite,
            // A row written by a newer build naming a source this one does not have.
            other => {
                tracing::debug!(source = other, "unknown transcript source in cursor store");
                return None;
            }
        };
        Some(StoredCursor {
            source,
            locator: row.1,
            cursor: row.2,
            next_seq: row.3.max(0) as u64,
        })
    }

    fn save(&self, session: &str, cursor: &StoredCursor) -> Result<()> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        self.conn().execute(
            "INSERT INTO transcript_cursors (session_id, source, locator, cursor, next_seq, updated_at) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6) \
             ON CONFLICT(session_id) DO UPDATE SET \
               source = excluded.source, locator = excluded.locator, \
               cursor = excluded.cursor, next_seq = excluded.next_seq, \
               updated_at = excluded.updated_at",
            params![
                session,
                cursor.source.as_str(),
                cursor.locator,
                cursor.cursor,
                cursor.next_seq as i64,
                now
            ],
        )?;
        Ok(())
    }

    fn clear(&self, session: &str) -> Result<()> {
        self.conn().execute(
            "DELETE FROM transcript_cursors WHERE session_id = ?1",
            [session],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_in_memory_store_round_trips_and_forgets_on_clear() {
        let store = MemoryCursors::new();
        assert_eq!(store.load("s1"), None);
        let mut cursor = StoredCursor::fresh(Source::ClaudeJsonl, "/tmp/s1.jsonl");
        cursor.cursor = r#"{"offset":42}"#.into();
        cursor.next_seq = 7;
        store.save("s1", &cursor).unwrap();
        assert_eq!(store.load("s1"), Some(cursor));
        store.clear("s1").unwrap();
        assert_eq!(store.load("s1"), None);
    }
}
