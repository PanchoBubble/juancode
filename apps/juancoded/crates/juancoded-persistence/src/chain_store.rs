//! Chains and their members, in `chains` / `chain_members` (migration 12).
//!
//! The store keeps the rules the schema can keep: one chain per item is
//! `UNIQUE(kind, ref)`, and deleting a chain untags its members by cascade. Everything
//! that needs a decision — a valid slug, whether a session exists, who to tell — is the
//! engine's (`juancoded-server::chains`).

use anyhow::Result;
use rusqlite::{params, OptionalExtension};

use juancoded_core::chain::{Chain, ChainMember, ChainMemberKind, ChainState};
use juancoded_core::chain::{Handoff, HandoffDelivery, HandoffOwner, HandoffState};

use crate::SqliteStore;

pub trait ChainStore: Send + Sync {
    fn handoffs(&self) -> Result<Vec<Handoff>>;
    fn create_handoff(&self, handoff: &Handoff) -> Result<bool>;
    /// Atomically close `predecessor` as handed off and insert its successor.
    /// Repeating the same successor id is idempotent; a different successor conflicts.
    fn advance_handoff(&self, predecessor: &str, successor: &Handoff, at: i64) -> Result<bool>;
    fn update_handoff(
        &self,
        id: &str,
        state: Option<HandoffState>,
        closure_reason: Option<&str>,
        delivery: Option<HandoffDelivery>,
        at: i64,
    ) -> Result<bool>;
    /// Every chain with its members, chains oldest first and members in the order they
    /// joined.
    fn chains(&self) -> Result<Vec<Chain>>;
    /// Create an empty active chain. `false` when the slug is taken, active or not: a
    /// slug is an identity, and a closed chain still owns its own.
    fn create_chain(&self, slug: &str, created_at: i64) -> Result<bool> {
        self.create_named_chain(slug, slug, created_at)
    }
    fn create_named_chain(&self, slug: &str, name: &str, created_at: i64) -> Result<bool>;
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
    fn handoffs(&self) -> Result<Vec<Handoff>> {
        let conn = self.conn_for_chains();
        let mut stmt = conn.prepare("SELECT id, chain_slug, source_kind, source_ref, target_kind, target_ref, beads_issue, summary, created_at, updated_at, state, closure_reason, predecessor_id, successor_id, evidence_ref, delivery FROM handoffs ORDER BY created_at, id")?;
        let rows = stmt.query_map([], |r| {
            let owner =
                |kind: String, reference: Option<String>| -> rusqlite::Result<HandoffOwner> {
                    match kind.as_str() {
                        "human" => Ok(HandoffOwner::Human),
                        "session" => reference
                            .map(HandoffOwner::Session)
                            .ok_or(rusqlite::Error::InvalidQuery),
                        _ => Err(rusqlite::Error::InvalidQuery),
                    }
                };
            let state: String = r.get(10)?;
            let delivery: String = r.get(15)?;
            Ok(Handoff {
                id: r.get(0)?,
                chain_slug: r.get(1)?,
                source: owner(r.get(2)?, r.get(3)?)?,
                target: owner(r.get(4)?, r.get(5)?)?,
                beads_issue: r.get(6)?,
                summary: r.get(7)?,
                created_at: r.get(8)?,
                updated_at: r.get(9)?,
                state: match state.as_str() {
                    "pending" => HandoffState::Pending,
                    "acknowledged" => HandoffState::Acknowledged,
                    "closed" => HandoffState::Closed,
                    _ => return Err(rusqlite::Error::InvalidQuery),
                },
                closure_reason: r.get(11)?,
                predecessor_id: r.get(12)?,
                successor_id: r.get(13)?,
                evidence_ref: r.get(14)?,
                delivery: match delivery.as_str() {
                    "not_sent" => HandoffDelivery::NotSent,
                    "sent" => HandoffDelivery::Sent,
                    _ => return Err(rusqlite::Error::InvalidQuery),
                },
            })
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(Into::into)
    }

    fn create_handoff(&self, h: &Handoff) -> Result<bool> {
        let conn = self.conn_for_chains();
        let inserted = conn.execute("INSERT INTO handoffs(id,chain_slug,source_kind,source_ref,target_kind,target_ref,beads_issue,summary,created_at,updated_at,state,closure_reason,predecessor_id,successor_id,evidence_ref,delivery) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,NULL,NULL,?13,?14) ON CONFLICT(id) DO NOTHING", params![h.id,h.chain_slug,owner_parts(&h.source).0,owner_parts(&h.source).1,owner_parts(&h.target).0,owner_parts(&h.target).1,h.beads_issue,h.summary,h.created_at,h.updated_at,state_str(h.state),h.closure_reason,h.evidence_ref,delivery_str(h.delivery)])?;
        Ok(inserted > 0)
    }

    fn advance_handoff(&self, predecessor: &str, h: &Handoff, at: i64) -> Result<bool> {
        let mut conn = self.conn_for_chains();
        let tx = conn.transaction()?;
        let current: Option<(String, String, Option<String>)> = tx
            .query_row(
                "SELECT state, chain_slug, successor_id FROM handoffs WHERE id=?1",
                [predecessor],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        let Some((state, chain_slug, successor)) = current else {
            anyhow::bail!("handoff-not-found")
        };
        if chain_slug != h.chain_slug {
            anyhow::bail!("handoff-chain-mismatch")
        }
        if successor.as_deref() == Some(&h.id) {
            if !handoff_matches(&tx, &h.id, h)? {
                anyhow::bail!("handoff-id-conflict")
            }
            tx.commit()?;
            return Ok(false);
        }
        if successor.is_some() || state == "closed" {
            anyhow::bail!("handoff-conflict")
        }
        let inserted = insert_handoff(&tx, h)?;
        if !inserted {
            anyhow::bail!("handoff-id-conflict")
        }
        let changed = tx.execute("UPDATE handoffs SET state='closed', closure_reason='handed_off_to', successor_id=?2, updated_at=?3 WHERE id=?1 AND successor_id IS NULL AND state!='closed'", params![predecessor,h.id,at])?;
        if changed != 1 {
            anyhow::bail!("handoff-conflict")
        }
        tx.commit()?;
        Ok(true)
    }

    fn update_handoff(
        &self,
        id: &str,
        state: Option<HandoffState>,
        reason: Option<&str>,
        delivery: Option<HandoffDelivery>,
        at: i64,
    ) -> Result<bool> {
        let conn = self.conn_for_chains();
        let changed = conn.execute("UPDATE handoffs SET state=COALESCE(?2,state), closure_reason=COALESCE(?3,closure_reason), delivery=COALESCE(?4,delivery), updated_at=?5 WHERE id=?1", params![id,state.map(state_str),reason,delivery.map(delivery_str),at])?;
        Ok(changed > 0)
    }

    fn chains(&self) -> Result<Vec<Chain>> {
        let conn = self.conn_for_chains();
        let mut stmt = conn.prepare(
            "SELECT slug, state, created_at, closed_at, id, name FROM chains ORDER BY created_at ASC, slug ASC",
        )?;
        let mut chains = stmt
            .query_map([], |row| {
                let state: String = row.get(1)?;
                Ok(Chain {
                    id: row.get(4)?,
                    name: row.get(5)?,
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
            "SELECT chain_slug, kind, ref, title, url, added_at, done FROM chain_members \
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
                row.get::<_, bool>(6)?,
            ))
        })?;
        for row in rows {
            let (slug, kind, ref_id, title, url, added_at, done) = row?;
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
                    done,
                });
            }
        }
        Ok(chains)
    }

    fn create_named_chain(&self, slug: &str, name: &str, created_at: i64) -> Result<bool> {
        let id = uuid::Uuid::parse_str(slug)
            .unwrap_or_else(|_| uuid::Uuid::new_v4())
            .to_string();
        let inserted = self.conn_for_chains().execute(
            "INSERT INTO chains (slug, state, created_at, closed_at, id, name) VALUES (?1, ?2, ?3, NULL, ?4, ?5) \
             ON CONFLICT(slug) DO NOTHING",
            params![slug, ChainState::Active.as_str(), created_at, id, name],
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
            "INSERT INTO chain_members (kind, ref, chain_slug, title, url, added_at, done) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) \
             ON CONFLICT(kind, ref) DO UPDATE SET chain_slug = excluded.chain_slug, \
             title = excluded.title, url = excluded.url, added_at = excluded.added_at, \
             done = excluded.done",
            params![
                member.kind.as_str(),
                member.ref_id,
                slug,
                member.title,
                member.url,
                member.added_at,
                member.done
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

fn owner_parts(owner: &HandoffOwner) -> (&'static str, Option<&str>) {
    match owner {
        HandoffOwner::Human => ("human", None),
        HandoffOwner::Session(id) => ("session", Some(id)),
    }
}
fn state_str(state: HandoffState) -> &'static str {
    match state {
        HandoffState::Pending => "pending",
        HandoffState::Acknowledged => "acknowledged",
        HandoffState::Closed => "closed",
    }
}
fn delivery_str(delivery: HandoffDelivery) -> &'static str {
    match delivery {
        HandoffDelivery::NotSent => "not_sent",
        HandoffDelivery::Sent => "sent",
    }
}
fn insert_handoff(tx: &rusqlite::Transaction<'_>, h: &Handoff) -> Result<bool> {
    let src = owner_parts(&h.source);
    let dst = owner_parts(&h.target);
    Ok(tx.execute("INSERT INTO handoffs(id,chain_slug,source_kind,source_ref,target_kind,target_ref,beads_issue,summary,created_at,updated_at,state,closure_reason,predecessor_id,successor_id,evidence_ref,delivery) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,NULL,?14,?15) ON CONFLICT(id) DO NOTHING", params![h.id,h.chain_slug,src.0,src.1,dst.0,dst.1,h.beads_issue,h.summary,h.created_at,h.updated_at,state_str(h.state),h.closure_reason,h.predecessor_id,h.evidence_ref,delivery_str(h.delivery)])? > 0)
}

fn handoff_matches(conn: &rusqlite::Connection, id: &str, h: &Handoff) -> Result<bool> {
    let src = owner_parts(&h.source);
    let dst = owner_parts(&h.target);
    let row: Option<(String, String, Option<String>, String, Option<String>, Option<String>, String, Option<String>, Option<String>)> = conn.query_row(
        "SELECT chain_slug, source_kind, source_ref, target_kind, target_ref, beads_issue, summary, predecessor_id, evidence_ref FROM handoffs WHERE id=?1", [id],
        |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?,r.get(6)?,r.get(7)?,r.get(8)?)),
    ).optional()?;
    Ok(row.is_some_and(|r| {
        r == (
            h.chain_slug.clone(),
            src.0.into(),
            src.1.map(str::to_string),
            dst.0.into(),
            dst.1.map(str::to_string),
            h.beads_issue.clone(),
            h.summary.clone(),
            h.predecessor_id.clone(),
            h.evidence_ref.clone(),
        )
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn handoff(id: &str, predecessor_id: Option<&str>) -> Handoff {
        Handoff {
            id: id.into(),
            chain_slug: "a".into(),
            source: HandoffOwner::Human,
            target: HandoffOwner::Session("s1".into()),
            beads_issue: Some("juancode-043.1".into()),
            summary: format!("work {id}"),
            created_at: 1,
            updated_at: 1,
            state: HandoffState::Pending,
            closure_reason: None,
            predecessor_id: predecessor_id.map(str::to_string),
            successor_id: None,
            evidence_ref: Some("commit:abc".into()),
            delivery: HandoffDelivery::NotSent,
        }
    }

    #[test]
    fn handoffs_survive_restart_and_advancement_is_atomic_idempotent_and_single_successor() {
        let dir = std::env::temp_dir().join(format!("juancoded-handoffs-{}", uuid_like()));
        let path = dir.join("juancoded-rust.db");
        {
            let store = SqliteStore::open(&path).unwrap();
            store.create_chain("a", 1).unwrap();
            assert!(store.create_handoff(&handoff("h1", None)).unwrap());
            assert!(!store.create_handoff(&handoff("h1", None)).unwrap());
            assert!(store
                .advance_handoff("h1", &handoff("h2", Some("h1")), 2)
                .unwrap());
            assert!(!store
                .advance_handoff("h1", &handoff("h2", Some("h1")), 3)
                .unwrap());
            let mut changed_retry = handoff("h2", Some("h1"));
            changed_retry.summary = "different payload".into();
            assert!(store.advance_handoff("h1", &changed_retry, 3).is_err());
            assert!(store
                .advance_handoff("h1", &handoff("h3", Some("h1")), 4)
                .is_err());
        }
        let store = SqliteStore::open(&path).unwrap();
        let history = store.handoffs().unwrap();
        assert_eq!(history.len(), 2);
        assert_eq!(history[0].successor_id.as_deref(), Some("h2"));
        assert_eq!(history[0].state, HandoffState::Closed);
        assert_eq!(history[0].closure_reason.as_deref(), Some("handed_off_to"));
        assert_eq!(history[1].predecessor_id.as_deref(), Some("h1"));
        assert_eq!(history[1].delivery, HandoffDelivery::NotSent);
    }

    fn member(kind: ChainMemberKind, ref_id: &str, at: i64) -> ChainMember {
        ChainMember {
            kind,
            ref_id: ref_id.into(),
            title: None,
            url: None,
            added_at: at,
            done: false,
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
            ticket.done = true;
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
        assert!(
            chains[0].members[0].done,
            "a reported done outlives a restart"
        );
        assert_eq!(chains[0].members[1].kind, ChainMemberKind::Session);
        assert!(!chains[0].members[1].done);
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
