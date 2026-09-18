//! Inline diff comments and the last review of a session.
//!
//! Two tables with opposite lifetimes, which is why they are two tables. A diff comment
//! is a person's note, staged deliberately and kept until they clear it; a review is a
//! cache of a model turn, replaced wholesale every time a new pass runs. Nothing here
//! is derivable from anything else in the store, and both survive a restart, because
//! the panel that reads them is a client that comes and goes.
//!
//! They are keyed by session and cascade with it. A comment on a session that has been
//! pruned is a comment on nothing — the file it names may not even be in the tree any
//! more — and a review of it is a verdict on a diff that no longer exists.

use anyhow::Result;
use rusqlite::{params, OptionalExtension};

use juancoded_core::review::{CommentSide, DiffComment, ReviewResult};

use crate::SqliteStore;

/// The store's review surface: the staged comments of a session, and its last pass.
pub trait ReviewStore: Send + Sync {
    /// A session's staged comments, oldest first — the order they were made in, which
    /// is the order the composer quotes them in.
    fn list_comments(&self, session_id: &str) -> Result<Vec<DiffComment>>;
    /// Stage one. Re-adding an id replaces it rather than raising: the client owns the
    /// id, and a retry of a request that already landed must not be an error.
    fn add_comment(&self, comment: &DiffComment) -> Result<()>;
    /// Drop one. `false` when this session had no such comment, which is what lets the
    /// route answer 404 rather than pretend.
    fn remove_comment(&self, session_id: &str, comment_id: &str) -> Result<bool>;
    /// Drop all of a session's.
    fn clear_comments(&self, session_id: &str) -> Result<()>;
    /// The last review of a session, or `None` when none has run (or the cached row
    /// will not decode, which an older shape would be).
    fn get_review(&self, session_id: &str) -> Result<Option<ReviewResult>>;
    /// Cache a pass, replacing whatever was there. One row per session: a review is
    /// about the tree as it is now, so keeping the previous one would be keeping a
    /// verdict on a diff nobody can see any more.
    fn save_review(&self, session_id: &str, result: &ReviewResult) -> Result<()>;
}

impl ReviewStore for SqliteStore {
    fn list_comments(&self, session_id: &str) -> Result<Vec<DiffComment>> {
        let conn = self.conn_for_reviews();
        let mut stmt = conn.prepare(
            "SELECT id, session_id, file, side, line, end_line, body, created_at, quote, \
             commit_sha, commit_subject FROM diff_comments WHERE session_id = ?1 \
             ORDER BY created_at ASC, rowid ASC",
        )?;
        let rows = stmt.query_map(params![session_id], |row| {
            Ok(DiffComment {
                id: row.get(0)?,
                session_id: row.get(1)?,
                file: row.get(2)?,
                side: if row.get::<_, String>(3)? == "old" {
                    CommentSide::Old
                } else {
                    CommentSide::New
                },
                line: row.get(4)?,
                end_line: row.get(5)?,
                body: row.get(6)?,
                created_at: row.get(7)?,
                quote: row.get(8)?,
                commit_sha: row.get(9)?,
                commit_subject: row.get(10)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    fn add_comment(&self, c: &DiffComment) -> Result<()> {
        self.conn_for_reviews().execute(
            "INSERT INTO diff_comments (id, session_id, file, side, line, end_line, body, \
             created_at, quote, commit_sha, commit_subject) \
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11) \
             ON CONFLICT(id) DO UPDATE SET body = excluded.body, quote = excluded.quote",
            params![
                c.id,
                c.session_id,
                c.file,
                c.side.as_str(),
                c.line,
                c.end_line,
                c.body,
                c.created_at,
                c.quote,
                c.commit_sha,
                c.commit_subject,
            ],
        )?;
        Ok(())
    }

    fn remove_comment(&self, session_id: &str, comment_id: &str) -> Result<bool> {
        // Scoped to the session, not keyed by id alone: an id is a client's to choose,
        // and a delete that ignored the session would let one client's request remove
        // another session's comment.
        let removed = self.conn_for_reviews().execute(
            "DELETE FROM diff_comments WHERE session_id = ?1 AND id = ?2",
            params![session_id, comment_id],
        )?;
        Ok(removed > 0)
    }

    fn clear_comments(&self, session_id: &str) -> Result<()> {
        self.conn_for_reviews().execute(
            "DELETE FROM diff_comments WHERE session_id = ?1",
            params![session_id],
        )?;
        Ok(())
    }

    fn get_review(&self, session_id: &str) -> Result<Option<ReviewResult>> {
        let conn = self.conn_for_reviews();
        let raw: Option<String> = conn
            .query_row(
                "SELECT result FROM diff_reviews WHERE session_id = ?1",
                params![session_id],
                |r| r.get(0),
            )
            .optional()?;
        // A row this core cannot decode is a cache miss, not a failure: the pass can
        // simply be run again, which is cheaper than refusing to open the panel.
        Ok(raw.and_then(|json| serde_json::from_str(&json).ok()))
    }

    fn save_review(&self, session_id: &str, result: &ReviewResult) -> Result<()> {
        self.conn_for_reviews().execute(
            "INSERT INTO diff_reviews (session_id, result, created_at) VALUES (?1,?2,?3) \
             ON CONFLICT(session_id) DO UPDATE SET result = excluded.result, \
             created_at = excluded.created_at",
            params![
                session_id,
                serde_json::to_string(result)?,
                result.created_at
            ],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SessionStore;
    use juancoded_core::model::{now_ms, ProviderId, SessionMeta};
    use juancoded_core::review::{ReviewFinding, ReviewSeverity, ReviewStatus};

    fn store() -> SqliteStore {
        let store = SqliteStore::in_memory().expect("a store");
        // The rows cascade off a session, so there has to be one to hang them on.
        for id in ["s1", "s2"] {
            store
                .upsert(&SessionMeta::new(
                    id.into(),
                    ProviderId::Claude,
                    "/tmp".into(),
                    id.into(),
                    now_ms(),
                    false,
                ))
                .expect("a session");
        }
        store
    }

    fn comment(id: &str, session: &str, line: i64, at: i64) -> DiffComment {
        DiffComment {
            id: id.into(),
            session_id: session.into(),
            file: "src/a.rs".into(),
            side: CommentSide::New,
            line,
            end_line: line,
            body: format!("note {id}"),
            created_at: at,
            quote: Some("+let x = 1;".into()),
            commit_sha: None,
            commit_subject: None,
        }
    }

    fn review(at: i64) -> ReviewResult {
        ReviewResult {
            status: ReviewStatus::Ok,
            findings: vec![ReviewFinding {
                file: "src/a.rs".into(),
                side: CommentSide::Old,
                line: None,
                severity: ReviewSeverity::Critical,
                title: "t".into(),
                note: "n".into(),
            }],
            summary: Some("one issue".into()),
            created_at: at,
            error: None,
        }
    }

    #[test]
    fn comments_come_back_in_the_order_they_were_made_and_only_for_their_session() {
        let store = store();
        store.add_comment(&comment("c2", "s1", 20, 200)).unwrap();
        store.add_comment(&comment("c1", "s1", 10, 100)).unwrap();
        store.add_comment(&comment("c9", "s2", 30, 50)).unwrap();

        let listed = store.list_comments("s1").unwrap();
        assert_eq!(
            listed.iter().map(|c| c.id.as_str()).collect::<Vec<_>>(),
            vec!["c1", "c2"],
            "oldest first, which is the order the composer quotes them in"
        );
        assert_eq!(listed[0].side, CommentSide::New);
        assert_eq!(listed[0].quote.as_deref(), Some("+let x = 1;"));
        assert_eq!(store.list_comments("s2").unwrap().len(), 1);
        assert!(store.list_comments("never-existed").unwrap().is_empty());
    }

    /// The id belongs to the client, so a retried request must land once rather than
    /// raise — and a delete must not be able to reach across sessions.
    #[test]
    fn staging_is_idempotent_and_deleting_is_scoped_to_its_session() {
        let store = store();
        store.add_comment(&comment("c1", "s1", 10, 100)).unwrap();
        let mut edited = comment("c1", "s1", 10, 100);
        edited.body = "rewritten".into();
        store.add_comment(&edited).unwrap();
        let listed = store.list_comments("s1").unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].body, "rewritten");

        store.add_comment(&comment("c9", "s2", 30, 50)).unwrap();
        assert!(
            !store.remove_comment("s1", "c9").unwrap(),
            "s1 must not be able to delete s2's comment by naming its id"
        );
        assert_eq!(store.list_comments("s2").unwrap().len(), 1);
        assert!(store.remove_comment("s1", "c1").unwrap());
        assert!(!store.remove_comment("s1", "c1").unwrap());
        assert!(store.list_comments("s1").unwrap().is_empty());
    }

    #[test]
    fn clearing_takes_one_sessions_comments_and_leaves_the_rest() {
        let store = store();
        store.add_comment(&comment("c1", "s1", 1, 1)).unwrap();
        store.add_comment(&comment("c2", "s1", 2, 2)).unwrap();
        store.add_comment(&comment("c9", "s2", 3, 3)).unwrap();
        store.clear_comments("s1").unwrap();
        assert!(store.list_comments("s1").unwrap().is_empty());
        assert_eq!(store.list_comments("s2").unwrap().len(), 1);
    }

    /// One row per session. A review is about the tree as it is now, so keeping the
    /// previous verdict would be keeping an opinion about a diff nobody can see.
    #[test]
    fn a_new_pass_replaces_the_cached_one_rather_than_joining_it() {
        let store = store();
        assert_eq!(store.get_review("s1").unwrap(), None);
        store.save_review("s1", &review(100)).unwrap();
        store.save_review("s1", &review(200)).unwrap();
        let cached = store.get_review("s1").unwrap().expect("a cached review");
        assert_eq!(cached.created_at, 200);
        assert_eq!(cached.findings[0].severity, ReviewSeverity::Critical);
        assert_eq!(
            cached.findings[0].side,
            CommentSide::Old,
            "the side survives the round trip, so a finding lands on the line it was about"
        );
        assert_eq!(store.get_review("s2").unwrap(), None);
    }

    /// A row written by a shape this core no longer reads is a cache miss. Refusing
    /// instead would make an old row a reason the panel will not open.
    #[test]
    fn a_cached_row_that_will_not_decode_reads_as_no_review() {
        let store = store();
        store
            .conn_for_reviews()
            .execute(
                "INSERT INTO diff_reviews (session_id, result, created_at) VALUES ('s1','{',0)",
                [],
            )
            .unwrap();
        assert_eq!(store.get_review("s1").unwrap(), None);
    }

    /// Both tables hang off the session. A pruned session's comments name files that
    /// may not be in the tree any more, and its review is a verdict on a diff that is
    /// gone.
    #[test]
    fn deleting_a_session_takes_its_comments_and_its_review_with_it() {
        let store = store();
        store.add_comment(&comment("c1", "s1", 1, 1)).unwrap();
        store.save_review("s1", &review(1)).unwrap();
        store.delete("s1").unwrap();
        assert!(store.list_comments("s1").unwrap().is_empty());
        assert_eq!(store.get_review("s1").unwrap(), None);
    }
}
