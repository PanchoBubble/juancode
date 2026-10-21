//! Chains: the daemon's one book of named groups, and who it tells when one moves.
//!
//! One engine per daemon, never per connection, for the reason the paused set and the
//! tracked-PR list are one each: a chain the phone tags a session into is the chain the
//! desktop's badge draws, so every connection reads and writes this object.
//!
//! ## The change stream
//!
//! A subscriber gets the whole book once (`chains`) and then one frame per chain that
//! moved: `chain` carrying that chain whole, members and all, or `chainRemoved` when it
//! was deleted. A change is never a patch on a member list. Moving an item from `a` to
//! `b` is therefore two `chain` frames, each the complete chain, and applying a frame a
//! client has already seen is harmless — which is what lets the snapshot and the stream
//! overlap without a sequence number: whatever order they arrive in, the last frame for
//! a slug is the truth about it.
//!
//! ## Where the rules live
//!
//! The schema keeps one-chain-per-item (`UNIQUE(kind, ref)`) and the untag-on-delete
//! cascade. This module keeps the rest: a valid slug, a session member that exists, and
//! the order a mutation and its broadcast happen in — the store is written before
//! anybody is told, so a client is never shown a chain the next restart would not have.

use std::sync::{Arc, Mutex};

use tokio::sync::broadcast;
use tokio::sync::broadcast::error::RecvError;
use tracing::{debug, warn};

use juancoded_core::chain::{validate_slug, Chain, ChainMember, ChainMemberKind, ChainState};
use juancoded_core::model::now_ms;
use juancoded_persistence::chain_store::ChainStore;
use juancoded_state::registry::SessionEvent;
use juancoded_state::SessionsApi;

/// How far a slow subscriber may fall behind before it loses changes. A loss is
/// recoverable — the next `subscribeChains` on a reconnect is the whole book — but a
/// connection that lagged is not resynced on its own, so this is generous.
const CHANGE_BUFFER: usize = 256;

/// One chain moved.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChainChange {
    /// The chain as it now is, whole. Created, closed, reopened, or a member joined or left.
    Upsert(Chain),
    /// The chain is gone and its members are untagged.
    Removed(String),
}

/// Why a mutation was refused. The string is the code that goes on the wire.
pub type ChainRefusal = &'static str;

pub struct Chains {
    sessions: Arc<dyn SessionsApi>,
    store: Arc<dyn ChainStore>,
    changes: broadcast::Sender<ChainChange>,
    /// The book as the store last returned it. Held across a mutation AND its re-read,
    /// so two mutations cannot interleave and publish in an order the store did not
    /// apply them in.
    book: Mutex<Vec<Chain>>,
}

impl Chains {
    pub fn new(sessions: Arc<dyn SessionsApi>, store: Arc<dyn ChainStore>) -> Arc<Self> {
        let book = store.chains().unwrap_or_else(|e| {
            // Not a reason to refuse to serve: the frames still answer, from an empty
            // book, and every write still goes to the file.
            warn!("could not load the chains: {e:#}");
            Vec::new()
        });
        Arc::new(Self {
            sessions,
            store,
            changes: broadcast::channel(CHANGE_BUFFER).0,
            book: Mutex::new(book),
        })
    }

    pub fn subscribe(&self) -> broadcast::Receiver<ChainChange> {
        self.changes.subscribe()
    }

    /// Every chain, oldest first, members in the order they joined.
    pub fn list(&self) -> Vec<Chain> {
        self.lock().clone()
    }

    /// The chain an item is in, if any.
    pub fn chain_of(&self, kind: ChainMemberKind, ref_id: &str) -> Option<String> {
        self.lock()
            .iter()
            .find(|c| {
                c.members
                    .iter()
                    .any(|m| m.kind == kind && m.ref_id == ref_id)
            })
            .map(|c| c.slug.clone())
    }

    pub fn create(&self, slug: &str) -> Result<(), ChainRefusal> {
        validate_slug(slug).map_err(|e| e.0)?;
        self.mutate(|store| match store.create_chain(slug, now_ms()) {
            Ok(true) => Ok(vec![slug.to_string()]),
            Ok(false) => Err("chain-exists"),
            Err(e) => Err(store_failed(e)),
        })
    }

    /// Mark a chain inactive. Closing a closed chain is a no-op and publishes nothing.
    pub fn close(&self, slug: &str) -> Result<(), ChainRefusal> {
        self.set_state(slug, ChainState::Inactive)
    }

    /// Mark a chain active again. Reopening an active chain is a no-op.
    pub fn reopen(&self, slug: &str) -> Result<(), ChainRefusal> {
        self.set_state(slug, ChainState::Active)
    }

    /// Delete a chain. Its members are untagged, not deleted: a chain is a label on
    /// work, and removing the label must not reach the work.
    pub fn delete(&self, slug: &str) -> Result<(), ChainRefusal> {
        let mut book = self.lock();
        match self.store.delete_chain(slug) {
            Ok(true) => {}
            Ok(false) => return Err("chain-not-found"),
            Err(e) => return Err(store_failed(e)),
        }
        book.retain(|c| c.slug != slug);
        let _ = self.changes.send(ChainChange::Removed(slug.to_string()));
        Ok(())
    }

    /// Put an item in `slug`, or take it out of whatever chain holds it when `slug` is
    /// `None`. An item already in another chain is moved, which publishes both chains.
    ///
    /// A session member must be a session this daemon holds: a tab for a session that
    /// does not exist is a tab nothing can draw. The other kinds are not checked — two
    /// of them live outside this daemon entirely, and a tracked PR is a watch that may
    /// legitimately have ended while its place in the chain is still history worth
    /// keeping. `title` and `url` are the caller's snapshot for those kinds.
    pub fn set_member(
        &self,
        kind: ChainMemberKind,
        ref_id: &str,
        slug: Option<&str>,
        title: Option<String>,
        url: Option<String>,
    ) -> Result<(), ChainRefusal> {
        if ref_id.trim().is_empty() {
            return Err("chain-member-invalid");
        }
        let Some(slug) = slug else {
            return self.mutate(|store| match store.clear_member(kind, ref_id) {
                Ok(left) => Ok(left.into_iter().collect()),
                Err(e) => Err(store_failed(e)),
            });
        };
        if kind == ChainMemberKind::Session && self.sessions.meta(ref_id).is_none() {
            return Err("chain-member-not-found");
        }
        let member = ChainMember {
            kind,
            ref_id: ref_id.to_string(),
            title,
            url,
            added_at: now_ms(),
        };
        self.mutate(|store| {
            // Checked against the book rather than left to the foreign key, so the
            // refusal says which thing was missing.
            if !store_has(store, slug)? {
                return Err("chain-not-found");
            }
            match store.set_member(slug, &member) {
                Ok(previous) => {
                    let mut moved = vec![slug.to_string()];
                    moved.extend(previous.filter(|p| p != slug));
                    Ok(moved)
                }
                Err(e) => Err(store_failed(e)),
            }
        })
    }

    /// Untag a session that no longer exists. A deleted or pruned session would
    /// otherwise stay a member forever, as a tab nothing can draw.
    pub fn forget_session(&self, session_id: &str) {
        if self
            .chain_of(ChainMemberKind::Session, session_id)
            .is_none()
        {
            return;
        }
        if let Err(code) = self.set_member(ChainMemberKind::Session, session_id, None, None, None) {
            warn!(session = %session_id, code, "could not untag a deleted session");
        }
    }

    /// Watch the session bus and untag each session it reports deleted. One task per
    /// daemon, ended with the handle.
    pub fn spawn_session_sweep(self: &Arc<Self>) -> tokio::task::JoinHandle<()> {
        let mut events = self.sessions.subscribe();
        let chains = Arc::clone(self);
        tokio::spawn(async move {
            loop {
                match events.recv().await {
                    Ok(SessionEvent::Deleted { session_id, .. }) => {
                        chains.forget_session(&session_id)
                    }
                    Ok(_) => {}
                    Err(RecvError::Lagged(n)) => {
                        // A delete this missed is caught by nothing until that id is
                        // re-tagged or the chain is; say so rather than pretend.
                        debug!(dropped = n, "chain sweep lagged behind the session bus");
                    }
                    Err(RecvError::Closed) => return,
                }
            }
        })
    }

    fn set_state(&self, slug: &str, state: ChainState) -> Result<(), ChainRefusal> {
        self.mutate(|store| {
            let current = store
                .chains()
                .map_err(store_failed)?
                .into_iter()
                .find(|c| c.slug == slug)
                .ok_or("chain-not-found")?;
            if current.state == state {
                return Ok(Vec::new());
            }
            let closed_at = (state == ChainState::Inactive).then(now_ms);
            match store.set_chain_state(slug, state, closed_at) {
                Ok(true) => Ok(vec![slug.to_string()]),
                Ok(false) => Err("chain-not-found"),
                Err(e) => Err(store_failed(e)),
            }
        })
    }

    /// Run one write against the store, re-read the book, and publish every chain the
    /// write says it touched. The write returns those slugs; an empty list is a no-op
    /// and publishes nothing.
    fn mutate(
        &self,
        write: impl FnOnce(&dyn ChainStore) -> Result<Vec<String>, ChainRefusal>,
    ) -> Result<(), ChainRefusal> {
        let mut book = self.lock();
        let touched = write(self.store.as_ref())?;
        if touched.is_empty() {
            return Ok(());
        }
        *book = self.store.chains().map_err(store_failed)?;
        for slug in touched {
            if let Some(chain) = book.iter().find(|c| c.slug == slug) {
                let _ = self.changes.send(ChainChange::Upsert(chain.clone()));
            }
        }
        Ok(())
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<Chain>> {
        self.book.lock().unwrap_or_else(|e| e.into_inner())
    }
}

fn store_has(store: &dyn ChainStore, slug: &str) -> Result<bool, ChainRefusal> {
    Ok(store
        .chains()
        .map_err(store_failed)?
        .iter()
        .any(|c| c.slug == slug))
}

fn store_failed(e: anyhow::Error) -> ChainRefusal {
    warn!("chain store write failed: {e:#}");
    "chain-store-failed"
}

#[cfg(test)]
mod tests {
    use super::*;
    use juancoded_core::model::ProviderId;
    use juancoded_persistence::SqliteStore;
    use juancoded_state::registry::CreateRequest;

    fn engine() -> (crate::serve::CoreHandles, Arc<Chains>) {
        let handles = crate::testing::handles();
        let store: Arc<dyn ChainStore> = Arc::new(SqliteStore::in_memory().unwrap());
        let chains = Chains::new(Arc::clone(&handles.sessions), store);
        (handles, chains)
    }

    fn drain(rx: &mut broadcast::Receiver<ChainChange>) -> Vec<ChainChange> {
        std::iter::from_fn(|| rx.try_recv().ok()).collect()
    }

    fn slugs_of(changes: &[ChainChange]) -> Vec<String> {
        changes
            .iter()
            .map(|c| match c {
                ChainChange::Upsert(chain) => chain.slug.clone(),
                ChainChange::Removed(slug) => format!("-{slug}"),
            })
            .collect()
    }

    #[tokio::test]
    async fn a_create_is_validated_unique_and_published_whole() {
        let (_h, chains) = engine();
        let mut rx = chains.subscribe();
        assert_eq!(chains.create("Auth Rewrite"), Err("chain-slug-invalid"));
        assert_eq!(chains.create("auth-rewrite"), Ok(()));
        assert_eq!(chains.create("auth-rewrite"), Err("chain-exists"));
        let changes = drain(&mut rx);
        assert_eq!(changes.len(), 1, "a refusal publishes nothing");
        let ChainChange::Upsert(chain) = &changes[0] else {
            panic!("{changes:?}")
        };
        assert_eq!(chain.state, ChainState::Active);
        assert!(chain.members.is_empty());
    }

    #[tokio::test]
    async fn retagging_moves_the_item_and_publishes_both_chains() {
        let (_h, chains) = engine();
        chains.create("a").unwrap();
        chains.create("b").unwrap();
        let mut rx = chains.subscribe();
        chains
            .set_member(
                ChainMemberKind::Linear,
                "ENG-1",
                Some("a"),
                Some("Rotate".into()),
                None,
            )
            .unwrap();
        assert_eq!(slugs_of(&drain(&mut rx)), ["a"]);
        chains
            .set_member(ChainMemberKind::Linear, "ENG-1", Some("b"), None, None)
            .unwrap();
        let changes = drain(&mut rx);
        assert_eq!(slugs_of(&changes), ["b", "a"]);
        assert_eq!(
            chains.chain_of(ChainMemberKind::Linear, "ENG-1").as_deref(),
            Some("b")
        );
        let ChainChange::Upsert(left) = &changes[1] else {
            panic!()
        };
        assert!(
            left.members.is_empty(),
            "the old chain is published without it"
        );

        chains
            .set_member(ChainMemberKind::Linear, "ENG-1", None, None, None)
            .unwrap();
        assert_eq!(slugs_of(&drain(&mut rx)), ["b"]);
        assert_eq!(chains.chain_of(ChainMemberKind::Linear, "ENG-1"), None);
        // Clearing an item in no chain is a no-op, not an error.
        chains
            .set_member(ChainMemberKind::Linear, "ENG-1", None, None, None)
            .unwrap();
        assert!(drain(&mut rx).is_empty());
    }

    #[tokio::test]
    async fn a_session_member_must_exist_and_leaves_when_it_is_deleted() {
        let (h, chains) = engine();
        chains.create("a").unwrap();
        assert_eq!(
            chains.set_member(ChainMemberKind::Session, "nope", Some("a"), None, None),
            Err("chain-member-not-found")
        );
        assert_eq!(
            chains.set_member(ChainMemberKind::Beads, "x-1", Some("missing"), None, None),
            Err("chain-not-found")
        );
        let id = h
            .sessions
            .create(CreateRequest {
                provider: ProviderId::Claude,
                cwd: "/tmp".into(),
                cols: 80,
                rows: 24,
                skip_permissions: false,
                model: None,
                preset: None,
                isolate_worktree: false,
                worktree_name: None,
                dispatch_id: None,
                owner: 1,
            })
            .expect("create")
            .id;
        chains
            .set_member(ChainMemberKind::Session, &id, Some("a"), None, None)
            .unwrap();
        let mut rx = chains.subscribe();
        chains.forget_session(&id);
        assert_eq!(slugs_of(&drain(&mut rx)), ["a"]);
        assert!(chains.list()[0].members.is_empty());
        let _ = h.sessions.kill(&id);
    }

    #[tokio::test]
    async fn close_reopen_and_delete_publish_only_what_moved() {
        let (_h, chains) = engine();
        chains.create("a").unwrap();
        chains
            .set_member(ChainMemberKind::Beads, "x-1", Some("a"), None, None)
            .unwrap();
        let mut rx = chains.subscribe();
        chains.close("a").unwrap();
        chains.close("a").unwrap();
        let changes = drain(&mut rx);
        assert_eq!(changes.len(), 1, "closing a closed chain is silent");
        let ChainChange::Upsert(closed) = &changes[0] else {
            panic!()
        };
        assert_eq!(closed.state, ChainState::Inactive);
        assert!(closed.closed_at.is_some());
        assert_eq!(closed.members.len(), 1, "closing keeps the members");

        chains.reopen("a").unwrap();
        let ChainChange::Upsert(open) = &drain(&mut rx)[0] else {
            panic!()
        };
        assert_eq!((open.state, open.closed_at), (ChainState::Active, None));

        assert_eq!(chains.close("missing"), Err("chain-not-found"));
        chains.delete("a").unwrap();
        assert_eq!(slugs_of(&drain(&mut rx)), ["-a"]);
        assert_eq!(chains.delete("a"), Err("chain-not-found"));
        assert_eq!(chains.chain_of(ChainMemberKind::Beads, "x-1"), None);
        // The slug is free again once the chain is gone.
        chains.create("a").unwrap();
    }

    #[tokio::test]
    async fn the_book_is_reloaded_from_the_store_on_restart() {
        let (h, _) = engine();
        let store = Arc::new(SqliteStore::in_memory().unwrap());
        let first = Chains::new(Arc::clone(&h.sessions), store.clone());
        first.create("a").unwrap();
        first
            .set_member(ChainMemberKind::TrackedPr, "/r#1", Some("a"), None, None)
            .unwrap();
        let second = Chains::new(Arc::clone(&h.sessions), store);
        assert_eq!(second.list(), first.list());
    }
}
