//! The schema, applied on every open.
//!
//! Migrations are numbered and idempotent: `user_version` records how far this file
//! has come, so opening an older database upgrades it in place and opening a current
//! one does nothing. A daemon that refused to start against last week's file would
//! make the restart guarantee worthless.

use anyhow::Result;
use rusqlite::Connection;

/// Ordered migrations. Append only — an existing entry is already in someone's file.
const MIGRATIONS: &[&str] = &[
    // 1: sessions, scrollback (with its grid), queue, tracked PRs, dispatch ledger.
    r#"
    CREATE TABLE sessions (
        id                TEXT PRIMARY KEY,
        provider          TEXT NOT NULL,
        cwd               TEXT NOT NULL,
        title             TEXT NOT NULL,
        status            TEXT NOT NULL,
        exit_code         INTEGER,
        created_at        INTEGER NOT NULL,
        updated_at        INTEGER NOT NULL,
        cli_session_id    TEXT,
        skip_permissions  INTEGER NOT NULL DEFAULT 0,
        worktree_path     TEXT,
        usage             TEXT,
        archived          INTEGER NOT NULL DEFAULT 0,
        dormant           INTEGER NOT NULL DEFAULT 0,
        kind              TEXT NOT NULL DEFAULT 'agent',
        parent_session_id TEXT,
        dispatch_id       TEXT
    );
    CREATE INDEX sessions_by_project ON sessions (cwd, created_at DESC);

    -- cols/rows are not metadata: without them the bytes can only be replayed by
    -- guessing a width, and a wrong guess garbles every hard wrap in the history.
    CREATE TABLE scrollback (
        session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
        cols       INTEGER NOT NULL,
        rows       INTEGER NOT NULL,
        bytes      BLOB NOT NULL
    );

    CREATE TABLE queue (
        id         TEXT PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        text       TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        position   INTEGER NOT NULL
    );
    CREATE INDEX queue_by_session ON queue (session_id, position);

    CREATE TABLE tracked_prs (
        id         TEXT PRIMARY KEY,
        number     INTEGER NOT NULL,
        title      TEXT NOT NULL,
        url        TEXT NOT NULL,
        branch     TEXT NOT NULL,
        cwd        TEXT NOT NULL,
        session_id TEXT,
        state      TEXT NOT NULL,
        checks     TEXT NOT NULL,
        created_at INTEGER NOT NULL
    );

    CREATE TABLE dispatches (
        dispatch_id TEXT PRIMARY KEY,
        session_id  TEXT,
        created_at  INTEGER NOT NULL
    );
    "#,
    // 2: per-session goals. No `armed` column, and there is not meant to be one:
    // permission to start another round lives in daemon memory, so a restart always
    // comes back needing a fresh human authorization.
    //
    // No foreign key to `sessions` either. The goal plugin owns its own connection
    // and may mount before a session row is written, and a rail that refuses to
    // record a round cap because the session table is not ready yet is a rail that
    // fails open.
    r#"
    CREATE TABLE goals (
        session_id    TEXT PRIMARY KEY,
        objective     TEXT NOT NULL,
        phase         TEXT NOT NULL,
        revision      INTEGER NOT NULL,
        round_cap     INTEGER NOT NULL,
        rounds_used   INTEGER NOT NULL,
        block_code    TEXT,
        block_message TEXT,
        created_at    INTEGER NOT NULL,
        updated_at    INTEGER NOT NULL
    );
    CREATE INDEX goals_by_phase ON goals (phase);
    "#,
    // 3: where each session's transcript reader stopped.
    //
    // `cursor` is opaque on purpose: a claude cursor is a byte offset plus the file
    // identity it belongs to, an opencode one is a row key plus the tool calls still
    // in flight, and neither is this layer's business. `locator` is, though: a cursor
    // whose file the session no longer maps to is somebody else's offset, and
    // resuming from it would skip a whole transcript.
    //
    // `next_seq` is durable for the same reason the offset is. Records are promised
    // append-only per session, and a counter that restarted at zero would hand a
    // consumer two different records with the same sequence number.
    r#"
    CREATE TABLE transcript_cursors (
        session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
        source     TEXT NOT NULL,
        locator    TEXT NOT NULL,
        cursor     TEXT NOT NULL,
        next_seq   INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
    );
    "#,
];

pub fn migrate(conn: &Connection) -> Result<()> {
    // Foreign keys are off by default in SQLite, and the cascade from `sessions` to
    // `scrollback`/`queue` is the only thing stopping a pruned session from leaving
    // its byte ring behind forever.
    conn.execute_batch("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;")?;
    let current: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    for (index, sql) in MIGRATIONS.iter().enumerate() {
        let version = index as i64 + 1;
        if version <= current {
            continue;
        }
        conn.execute_batch(&format!(
            "BEGIN; {sql} PRAGMA user_version = {version}; COMMIT;"
        ))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrating_twice_is_a_no_op_and_leaves_the_version_at_the_head() {
        let conn = Connection::open_in_memory().unwrap();
        migrate(&conn).unwrap();
        migrate(&conn).unwrap();
        let version: i64 = conn
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(version, MIGRATIONS.len() as i64);
    }

    #[test]
    fn the_cascade_from_sessions_is_actually_enabled() {
        let conn = Connection::open_in_memory().unwrap();
        migrate(&conn).unwrap();
        let on: i64 = conn
            .query_row("PRAGMA foreign_keys", [], |r| r.get(0))
            .unwrap();
        assert_eq!(on, 1, "the scrollback cascade depends on this");
    }
}
