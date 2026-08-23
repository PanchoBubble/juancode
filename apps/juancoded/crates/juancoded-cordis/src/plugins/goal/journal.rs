//! The goal journal on SQLite, over the core's own database file.
//!
//! It opens its own connection rather than borrowing the `store` service's, because
//! the goal plugin is mountable on its own and a rail that only works when the whole
//! state tree is up is a rail with a hole in it. WAL is already on from the shared
//! migration, so a second connection to one file is the supported case.
//!
//! Every read is strict. A row this code did not write is not guessed at: an
//! unreadable phase or a `blocked` row with no code fails the load, and the plugin
//! fails to mount, which stops automatic work rather than resuming it against a
//! record nobody can vouch for.

use std::path::Path;
use std::sync::Mutex;

use rusqlite::{params, Connection};

use crate::services::goal::{BlockCode, Blocked, Goal, GoalJournal, GoalPhase};

pub struct SqliteGoalJournal {
    conn: Mutex<Connection>,
}

impl SqliteGoalJournal {
    /// Open (creating the parent directory) and migrate. `:memory:` is accepted so a
    /// test can exercise the real SQL without a file.
    pub fn open(path: &str) -> anyhow::Result<Self> {
        let conn = if path == ":memory:" {
            Connection::open_in_memory()?
        } else {
            if let Some(dir) = Path::new(path).parent() {
                std::fs::create_dir_all(dir)?;
            }
            Connection::open(path)?
        };
        juancoded_persistence::schema::migrate(&conn)?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// The one place the durable columns become a [`Goal`] again.
fn row_to_goal(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<(Goal, Option<String>, Option<String>)> {
    let phase: String = row.get("phase")?;
    Ok((
        Goal {
            session_id: row.get("session_id")?,
            objective: row.get("objective")?,
            // Filled in by the caller, which is also where an unreadable one is
            // reported: a `FromSql` error here would lose the session id with it.
            phase: GoalPhase::Active,
            revision: row.get::<_, i64>("revision")? as u64,
            round_cap: row.get::<_, i64>("round_cap")? as u32,
            rounds_used: row.get::<_, i64>("rounds_used")? as u32,
            block: None,
            created_at: row.get("created_at")?,
            updated_at: row.get("updated_at")?,
        },
        Some(phase),
        row.get("block_code")?,
    ))
}

impl GoalJournal for SqliteGoalJournal {
    fn load_all(&self) -> Result<Vec<Goal>, String> {
        let conn = self.lock();
        let mut stmt = conn
            .prepare(
                "SELECT session_id, objective, phase, revision, round_cap, rounds_used, \
                 block_code, block_message, created_at, updated_at FROM goals \
                 ORDER BY session_id ASC",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |row| {
                let (goal, phase, code) = row_to_goal(row)?;
                let message: Option<String> = row.get("block_message")?;
                Ok((goal, phase, code, message))
            })
            .map_err(|e| e.to_string())?;

        let mut goals = Vec::new();
        for row in rows {
            let (mut goal, phase, code, message) = row.map_err(|e| e.to_string())?;
            let phase = phase.unwrap_or_default();
            goal.phase = GoalPhase::parse(&phase).ok_or_else(|| {
                format!(
                    "goal `{}` has an unreadable phase `{phase}`",
                    goal.session_id
                )
            })?;
            if goal.phase == GoalPhase::Blocked {
                let code = code
                    .ok_or_else(|| format!("goal `{}` is blocked with no code", goal.session_id))?;
                let code = BlockCode::parse(&code).map_err(|e| e.to_string())?;
                goal.block = Some(Blocked {
                    code,
                    message: message.unwrap_or_default(),
                });
            }
            goals.push(goal);
        }
        Ok(goals)
    }

    fn put(&self, goal: &Goal) -> Result<(), String> {
        let (code, message) = match &goal.block {
            Some(block) => (
                Some(block.code.as_str().to_string()),
                Some(block.message.clone()),
            ),
            None => (None, None),
        };
        self.lock()
            .execute(
                "INSERT INTO goals (session_id, objective, phase, revision, round_cap, \
                 rounds_used, block_code, block_message, created_at, updated_at) \
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10) \
                 ON CONFLICT(session_id) DO UPDATE SET objective=excluded.objective, \
                 phase=excluded.phase, revision=excluded.revision, \
                 round_cap=excluded.round_cap, rounds_used=excluded.rounds_used, \
                 block_code=excluded.block_code, block_message=excluded.block_message, \
                 updated_at=excluded.updated_at",
                params![
                    goal.session_id,
                    goal.objective,
                    goal.phase.as_str(),
                    goal.revision as i64,
                    i64::from(goal.round_cap),
                    i64::from(goal.rounds_used),
                    code,
                    message,
                    goal.created_at,
                    goal.updated_at,
                ],
            )
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    fn remove(&self, session: &str) -> Result<(), String> {
        self.lock()
            .execute("DELETE FROM goals WHERE session_id = ?1", params![session])
            .map_err(|e| e.to_string())?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn goal(session: &str) -> Goal {
        Goal {
            session_id: session.into(),
            objective: "land the ticket".into(),
            phase: GoalPhase::Active,
            revision: 3,
            round_cap: 8,
            rounds_used: 2,
            block: None,
            created_at: 10,
            updated_at: 20,
        }
    }

    #[test]
    fn a_goal_round_trips_every_column_including_the_block() {
        let journal = SqliteGoalJournal::open(":memory:").unwrap();
        let plain = goal("s1");
        journal.put(&plain).unwrap();
        assert_eq!(journal.load_all().unwrap(), vec![plain.clone()]);

        let mut blocked = plain.clone();
        blocked.revision = 4;
        blocked.phase = GoalPhase::Blocked;
        blocked.block = Some(Blocked {
            code: BlockCode::parse("ci-red").unwrap(),
            message: "3 checks failing".into(),
        });
        journal.put(&blocked).unwrap();
        assert_eq!(journal.load_all().unwrap(), vec![blocked.clone()]);

        // Unblocking clears both columns rather than leaving a code behind that
        // something would keep routing.
        let mut clear = blocked;
        clear.revision = 5;
        clear.phase = GoalPhase::Active;
        clear.block = None;
        journal.put(&clear).unwrap();
        assert_eq!(journal.load_all().unwrap(), vec![clear]);

        journal.remove("s1").unwrap();
        assert!(journal.load_all().unwrap().is_empty());
    }

    #[test]
    fn there_is_no_column_an_authorization_could_have_been_written_to() {
        let journal = SqliteGoalJournal::open(":memory:").unwrap();
        journal.put(&goal("s1")).unwrap();
        let conn = journal.lock();
        let mut stmt = conn.prepare("PRAGMA table_info(goals)").unwrap();
        let columns: Vec<String> = stmt
            .query_map([], |r| r.get::<_, String>(1))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert!(
            !columns.iter().any(|c| c.contains("arm")),
            "the rail is that this is unstorable: {columns:?}"
        );
    }

    #[test]
    fn a_row_this_code_did_not_write_fails_the_load_instead_of_being_guessed_at() {
        let journal = SqliteGoalJournal::open(":memory:").unwrap();
        journal.put(&goal("s1")).unwrap();
        journal
            .lock()
            .execute(
                "UPDATE goals SET phase = 'running' WHERE session_id = 's1'",
                [],
            )
            .unwrap();
        let err = journal.load_all().unwrap_err();
        assert!(err.contains("unreadable phase"), "{err}");

        journal
            .lock()
            .execute(
                "UPDATE goals SET phase = 'blocked', block_code = NULL WHERE session_id = 's1'",
                [],
            )
            .unwrap();
        let err = journal.load_all().unwrap_err();
        assert!(err.contains("blocked with no code"), "{err}");
    }
}
