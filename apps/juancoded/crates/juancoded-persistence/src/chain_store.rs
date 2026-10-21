//! Chains and their members, in `chains` / `chain_members` (migration 12).
//!
//! The store keeps the rules the schema can keep: one chain per item is
//! `UNIQUE(kind, ref)`, and deleting a chain untags its members by cascade. Everything
//! that needs a decision — a valid slug, whether a session exists, who to tell — is the
//! engine's (`juancoded-server::chains`).

use anyhow::Result;
use rusqlite::{params, OptionalExtension};

use juancoded_core::chain::{Chain, ChainMember, ChainMemberKind, ChainState};

use crate::SqliteStore;

pub trait ChainStore: Send + Sync {
    /// Every chain with its members, chains oldest first and members in the order they
    /// joined.
    fn chains(&self) -> Result<Vec<Chain>>;
    /// Create an empty active chain. `false` when the slug is taken, active or not: a
    /// slug is an identity, and a closed chain still owns its own.
    fn create_chain(&self, slug: &str, created_at: i64) -> Result<bool>;
    /// Mark a chain active or inactive. `closed_at` is what to record beside it (`None`
    /// on a reopen). `false` when there is no such chain.
    fn set_chain_state(
        &self,
        slug: &str,
        state: ChainState,
        closed_at: Option<i64>,
    ) -> Result<bool>;
    /// Delete a chain, untagging its members. `false` when there was none.
    fn delete_chain(&self, slug: &str) -> Result<bool>;
    /// Put an item in `slug`, moving it out of whatever chain held it. Returns that
    /// previous chain, which is `Some(slug)` itself for a re-tag into the same one.
    fn set_member(&self, slug: &str, member: &ChainMember) -> Result<Option<String>>;
    /// Take an item out of its chain. Returns the chain it left, `None` if it was in none.
    fn clear_member(&self, kind: ChainMemberKind, ref_id: &str) -> Result<Option<String>>;
}

fn previous_chain(
    conn: &rusqlite::Connection,
    kind: ChainMemberKind,
    ref_id: &str,
) -> rusqlite::Result<Option<String>> {
    conn.query_row(
        "SELECT chain_slug FROM chain_members WHERE kind = ?1 AND ref = ?2",
        params![kind.as_str(), ref_id],
        |r| r.get(0),
    )
    .optional()
}

impl ChainStore for SqliteStore {
    fn chains(&self) -> Result<Vec<Chain>> {
        let conn = self.conn_for_chains();
        let mut stmt = conn.prepare(
            "SELECT slug, state, created_at, closed_at FROM chains ORDER BY created_at ASC, slug ASC",
        )?;
        let mut chains = stmt
            .query_map([], |row| {
                let state: String = row.get(1)?;
                Ok(Chain {
                    slug: row.get(0)?,
                    // A state this build does not know reads as active: a chain that
                    // vanished from the list would be worse than one shown as open.
                    state: ChainState::parse(&state).unwrap_or(ChainState::Active),
                    created_at: row.get(2)?,
                    closed_at: row.get(3)?,
                    members: Vec::new(),
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;

        let mut stmt = conn.prepare(
            "SELECT chain_slug, kind, ref, title, url, added_at FROM chain_members \
             ORDER BY added_at ASC, rowid ASC",
        )?;
        let rows = stmt.query_map([], |row| {
            let kind: String = row.get(1)?;
            Ok((
                row.get::<_, String>(0)?,
                kind,
                row.get::<_, String>(2)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, i64>(5)?,
            ))
        })?;
        for row in rows {
            let (slug, kind, ref_id, title, url, added_at) = row?;
            // A kind a newer build wrote is skipped rather than guessed at.
            let Some(kind) = ChainMemberKind::parse(&kind) else {
                continue;
            };
            if let Some(chain) = chains.iter_mut().find(|c| c.slug == slug) {
                chain.members.push(ChainMember {
                    kind,
                    ref_id,
                    title,
                    url,
                    added_at,
                });
            }
        }
        Ok(chains)
    }

    fn create_chain(&self, slug: &str, created_at: i64) -> Result<bool> {
        let inserted = self.conn_for_chains().execute(
            "INSERT INTO chains (slug, state, created_at, closed_at) VALUES (?1, ?2, ?3, NULL) \
             ON CONFLICT(slug) DO NOTHING",
            params![slug, ChainState::Active.as_str(), created_at],
        )?;
        Ok(inserted > 0)
    }

    fn set_chain_state(
        &self,
        slug: &str,
        state: ChainState,
        closed_at: Option<i64>,
    ) -> Result<bool> {
        let updated = self.conn_for_chains().execute(
            "UPDATE chains SET state = ?2, closed_at = ?3 WHERE slug = ?1",
            params![slug, state.as_str(), closed_at],
        )?;
        Ok(updated > 0)
    }

    fn delete_chain(&self, slug: &str) -> Result<bool> {
        let deleted = self
            .conn_for_chains()
            .execute("DELETE FROM chains WHERE slug = ?1", params![slug])?;
        Ok(deleted > 0)
    }

    fn set_member(&self, slug: &str, member: &ChainMember) -> Result<Option<String>> {
        let mut conn = self.conn_for_chains();
        // One transaction, so the chain this answers "it came from" is the one the
        // upsert actually took it out of.
        let tx = conn.transaction()?;
        let previous = previous_chain(&tx, member.kind, &member.ref_id)?;
        tx.execute(
            "INSERT INTO chain_members (kind, ref, chain_slug, title, url, added_at) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6) \
             ON CONFLICT(kind, ref) DO UPDATE SET chain_slug = excluded.chain_slug, \
             title = excluded.title, url = excluded.url, added_at = excluded.added_at",
            params![
                member.kind.as_str(),
                member.ref_id,
                slug,
                member.title,
                member.url,
                member.added_at
            ],
        )?;
        tx.commit()?;
        Ok(previous)
    }

    fn clear_member(&self, kind: ChainMemberKind, ref_id: &str) -> Result<Option<String>> {
        let mut conn = self.conn_for_chains();
        let tx = conn.transaction()?;
        let previous = previous_chain(&tx, kind, ref_id)?;
        tx.execute(
            "DELETE FROM chain_members WHERE kind = ?1 AND ref = ?2",
            params![kind.as_str(), ref_id],
        )?;
        tx.commit()?;
        Ok(previous)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn member(kind: ChainMemberKind, ref_id: &str, at: i64) -> ChainMember {
        ChainMember {
            kind,
            ref_id: ref_id.into(),
            title: None,
            url: None,
            added_at: at,
        }
    }

    #[test]
    fn chains_and_members_survive_reopening_the_file() {
        let dir = std::env::temp_dir().join(format!("juancoded-chains-{}", uuid_like()));
        let path = dir.join("juancoded-rust.db");
        {
            let store = SqliteStore::open(&path).unwrap();
            assert!(store.create_chain("auth-rewrite", 1).unwrap());
            assert!(store.create_chain("billing", 2).unwrap());
            let mut ticket = member(ChainMemberKind::Linear, "ENG-1", 3);
            ticket.title = Some("Rotate keys".into());
            ticket.url = Some("https://linear.app/x/issue/ENG-1".into());
            store.set_member("auth-rewrite", &ticket).unwrap();
            store
                .set_member("auth-rewrite", &member(ChainMemberKind::Session, "s1", 4))
                .unwrap();
            assert!(store
                .set_chain_state("billing", ChainState::Inactive, Some(9))
                .unwrap());
        }
        let store = SqliteStore::open(&path).unwrap();
        let chains = store.chains().unwrap();
        assert_eq!(
            chains.iter().map(|c| c.slug.as_str()).collect::<Vec<_>>(),
            ["auth-rewrite", "billing"]
        );
        assert_eq!(chains[0].members.len(), 2);
        assert_eq!(chains[0].members[0].ref_id, "ENG-1");
        assert_eq!(chains[0].members[0].title.as_deref(), Some("Rotate keys"));
        assert_eq!(chains[0].members[1].kind, ChainMemberKind::Session);
        assert_eq!(chains[1].state, ChainState::Inactive);
        assert_eq!(chains[1].closed_at, Some(9));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn an_item_is_in_one_chain_and_tagging_it_again_moves_it() {
        let store = SqliteStore::in_memory().unwrap();
        store.create_chain("a", 1).unwrap();
        store.create_chain("b", 2).unwrap();
        let pr = member(ChainMemberKind::TrackedPr, "/repo#7", 3);
        assert_eq!(store.set_member("a", &pr).unwrap(), None);
        assert_eq!(store.set_member("b", &pr).unwrap(), Some("a".into()));
        let chains = store.chains().unwrap();
        assert!(chains[0].members.is_empty());
        assert_eq!(chains[1].members, vec![pr.clone()]);
        // The same ref under a different kind is a different item.
        store
            .set_member("a", &member(ChainMemberKind::Beads, "/repo#7", 4))
            .unwrap();
        assert_eq!(store.chains().unwrap()[0].members.len(), 1);

        assert_eq!(
            store
                .clear_member(ChainMemberKind::TrackedPr, "/repo#7")
                .unwrap(),
            Some("b".into())
        );
        assert_eq!(
            store
                .clear_member(ChainMemberKind::TrackedPr, "/repo#7")
                .unwrap(),
            None
        );
    }

    #[test]
    fn the_schema_itself_refuses_a_second_chain_for_one_item() {
        let store = SqliteStore::in_memory().unwrap();
        store.create_chain("a", 1).unwrap();
        store.create_chain("b", 1).unwrap();
        let conn = store.conn_for_chains();
        conn.execute(
            "INSERT INTO chain_members (kind, ref, chain_slug, added_at) VALUES ('beads','x','a',1)",
            [],
        )
        .unwrap();
        let second = conn.execute(
            "INSERT INTO chain_members (kind, ref, chain_slug, added_at) VALUES ('beads','x','b',1)",
            [],
        );
        assert!(second.is_err(), "UNIQUE(kind, ref) is the one-chain rule");
    }

    #[test]
    fn deleting_a_chain_untags_its_members_and_a_slug_is_never_taken_twice() {
        let store = SqliteStore::in_memory().unwrap();
        assert!(store.create_chain("a", 1).unwrap());
        assert!(!store.create_chain("a", 2).unwrap());
        store
            .set_member("a", &member(ChainMemberKind::Session, "s1", 3))
            .unwrap();
        assert!(store.delete_chain("a").unwrap());
        assert!(!store.delete_chain("a").unwrap());
        assert!(store.chains().unwrap().is_empty());
        assert_eq!(
            store.clear_member(ChainMemberKind::Session, "s1").unwrap(),
            None,
            "the cascade took the member with the chain"
        );
        assert!(!store
            .set_chain_state("a", ChainState::Inactive, Some(1))
            .unwrap());
    }

    fn uuid_like() -> String {
        format!(
            "{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        )
    }
}
