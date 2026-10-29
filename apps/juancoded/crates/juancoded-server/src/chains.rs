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
//!
//! ## Auto-close
//!
//! A chain closes itself when its last unfinished member finishes: a session exits
//! (not one the reaper put to sleep, which is waiting to be woken) or is archived or
//! deleted, a tracked PR leaves the watch list (which is what a merge or a close does
//! to it), or a client reports a beads or Linear ticket done. The daemon can see the
//! first two for itself. It cannot see tickets — a beads id names no repo, and Linear
//! needs credentials the daemon does not hold — so their state is the client's report
//! on `setChainMember.done`, stored with the member, and a ticket nobody reported reads
//! as live.
//!
//! It is edge-triggered on purpose. Only a member FINISHING asks the question, never a
//! join, an untag, a reopen or a restart, so a chain that was just created (empty), a
//! chain somebody tags already-finished work into, and a chain somebody reopened by
//! hand all stay open until something in them actually finishes. Nothing reopens a
//! chain on its own either: a ticket reopened or a session revived is a person's cue to
//! reopen the chain, not the daemon's.

use std::collections::BTreeSet;
use std::sync::{Arc, Mutex};

use tokio::sync::broadcast;
use tokio::sync::broadcast::error::RecvError;
use tracing::{debug, info, warn};

use juancoded_core::chain::{
    validate_slug, Chain, ChainMember, ChainMemberKind, ChainState, Handoff, HandoffDelivery,
    HandoffOwner, HandoffState, MemberStatus,
};
use juancoded_core::model::{now_ms, SessionMeta, SessionStatus};
use juancoded_persistence::chain_store::ChainStore;
use juancoded_state::registry::SessionEvent;
use juancoded_state::SessionsApi;

use crate::tracked_prs::{TrackedPrChange, TrackedPrs};

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
    Handoff(Handoff),
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
    /// The keys of the PRs under watch, as the watch list last published them. `None`
    /// until a watch list is attached — and for good on a daemon without one — and a
    /// tracked-PR member then reads as live, because "not watched" would be a guess.
    watched_prs: Mutex<Option<BTreeSet<String>>>,
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
            watched_prs: Mutex::new(None),
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

    pub fn handoffs(&self) -> Result<Vec<Handoff>, ChainRefusal> {
        self.store.handoffs().map_err(store_failed)
    }

    pub fn create_handoff(&self, mut handoff: Handoff) -> Result<(), ChainRefusal> {
        self.validate_handoff(&handoff)?;
        handoff.created_at = now_ms();
        handoff.updated_at = handoff.created_at;
        handoff.state = HandoffState::Pending;
        handoff.closure_reason = None;
        handoff.predecessor_id = None;
        handoff.successor_id = None;
        handoff.delivery = HandoffDelivery::NotSent;
        let _book = self.lock();
        match self.store.create_handoff(&handoff) {
            Ok(true) => {
                let _ = self.changes.send(ChainChange::Handoff(handoff));
                Ok(())
            }
            Ok(false) => match self
                .store
                .handoffs()
                .map_err(store_failed)?
                .into_iter()
                .find(|h| h.id == handoff.id)
            {
                Some(existing) if same_handoff_request(&existing, &handoff) => Ok(()),
                _ => Err("handoff-id-conflict"),
            },
            Err(e) => Err(store_failed(e)),
        }
    }

    pub fn advance_handoff(
        &self,
        predecessor: &str,
        mut successor: Handoff,
    ) -> Result<(), ChainRefusal> {
        successor.predecessor_id = Some(predecessor.to_string());
        successor.created_at = now_ms();
        successor.updated_at = successor.created_at;
        successor.state = HandoffState::Pending;
        successor.closure_reason = None;
        successor.successor_id = None;
        successor.delivery = HandoffDelivery::NotSent;
        self.validate_handoff(&successor)?;
        if successor.predecessor_id.as_deref() != Some(predecessor) {
            return Err("handoff-predecessor-invalid");
        }
        let _book = self.lock();
        match self
            .store
            .advance_handoff(predecessor, &successor, now_ms())
        {
            Ok(false) => Ok(()),
            Ok(true) => {
                if let Some(previous) = self
                    .store
                    .handoffs()
                    .map_err(store_failed)?
                    .into_iter()
                    .find(|h| h.id == predecessor)
                {
                    let _ = self.changes.send(ChainChange::Handoff(previous));
                }
                if let Some(next) = self
                    .store
                    .handoffs()
                    .map_err(store_failed)?
                    .into_iter()
                    .find(|h| h.id == successor.id)
                {
                    let _ = self.changes.send(ChainChange::Handoff(next));
                }
                Ok(())
            }
            Err(e) => match e.to_string().as_str() {
                "handoff-not-found" => Err("handoff-not-found"),
                "handoff-conflict" => Err("handoff-conflict"),
                "handoff-id-conflict" => Err("handoff-id-conflict"),
                _ => Err(store_failed(e)),
            },
        }
    }

    pub fn acknowledge_handoff(&self, id: &str) -> Result<(), ChainRefusal> {
        if let Some(h) = self
            .store
            .handoffs()
            .map_err(store_failed)?
            .into_iter()
            .find(|h| h.id == id)
        {
            if h.state == HandoffState::Closed {
                return Err("handoff-closed");
            }
            if h.state == HandoffState::Acknowledged {
                return Ok(());
            }
        } else {
            return Err("handoff-not-found");
        }
        self.update_handoff(id, Some(HandoffState::Acknowledged), None, None)
    }
    pub fn close_handoff(&self, id: &str, reason: &str) -> Result<(), ChainRefusal> {
        if reason.trim().is_empty() {
            return Err("handoff-closure-reason-required");
        }
        self.update_handoff(id, Some(HandoffState::Closed), Some(reason), None)
    }
    pub fn mark_handoff_delivered(&self, id: &str) -> Result<(), ChainRefusal> {
        self.update_handoff(id, None, None, Some(HandoffDelivery::Sent))
    }

    fn update_handoff(
        &self,
        id: &str,
        state: Option<HandoffState>,
        reason: Option<&str>,
        delivery: Option<HandoffDelivery>,
    ) -> Result<(), ChainRefusal> {
        let _book = self.lock();
        let current = self
            .store
            .handoffs()
            .map_err(store_failed)?
            .into_iter()
            .find(|h| h.id == id)
            .ok_or("handoff-not-found")?;
        if state == Some(HandoffState::Closed) && current.state == HandoffState::Closed {
            if reason == current.closure_reason.as_deref() {
                return Ok(());
            }
            return Err("handoff-closed");
        }
        if delivery == Some(HandoffDelivery::Sent) && current.delivery == HandoffDelivery::Sent {
            return Ok(());
        }
        if state.is_some() && current.state == HandoffState::Closed {
            return Err("handoff-closed");
        }
        match self
            .store
            .update_handoff(id, state, reason, delivery, now_ms())
        {
            Ok(true) => {
                let h = self
                    .store
                    .handoffs()
                    .map_err(store_failed)?
                    .into_iter()
                    .find(|h| h.id == id)
                    .ok_or("handoff-not-found")?;
                let _ = self.changes.send(ChainChange::Handoff(h));
                Ok(())
            }
            Ok(false) => Err("handoff-not-found"),
            Err(e) => Err(store_failed(e)),
        }
    }

    fn validate_handoff(&self, h: &Handoff) -> Result<(), ChainRefusal> {
        if h.id.trim().is_empty()
            || h.id.trim() != h.id
            || h.summary.trim().is_empty()
            || h.beads_issue
                .as_ref()
                .is_some_and(|issue| issue.trim().is_empty())
        {
            return Err("handoff-invalid");
        }
        if !self.lock().iter().any(|c| c.slug == h.chain_slug) {
            return Err("chain-not-found");
        }
        for owner in [&h.source, &h.target] {
            if let HandoffOwner::Session(id) = owner {
                if self.sessions.meta(id).is_none() {
                    return Err("handoff-session-not-found");
                }
            }
        }
        Ok(())
    }

    pub fn create(&self, slug: &str) -> Result<(), ChainRefusal> {
        validate_slug(slug).map_err(|e| e.0)?;
        self.mutate(|store| match store.create_chain(slug, now_ms()) {
            Ok(true) => Ok(vec![slug.to_string()]),
            Ok(false) => Err("chain-exists"),
            Err(e) => Err(store_failed(e)),
        })
    }

    pub fn create_named(&self, slug: &str, name: &str) -> Result<(), ChainRefusal> {
        if uuid::Uuid::parse_str(slug).is_err() {
            return Err("chain-id-invalid");
        }
        let name = name.trim();
        if name.is_empty() || name.chars().count() > 200 {
            return Err("chain-name-invalid");
        }
        self.mutate(
            |store| match store.create_named_chain(slug, name, now_ms()) {
                Ok(true) => Ok(vec![slug.to_string()]),
                Ok(false) => Err("chain-exists"),
                Err(e) => Err(store_failed(e)),
            },
        )
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
        if self
            .store
            .handoffs()
            .map_err(store_failed)?
            .iter()
            .any(|h| h.chain_slug == slug)
        {
            return Err("chain-has-handoffs");
        }
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
        self.set_member_reporting(kind, ref_id, slug, title, url, None)
    }

    /// [`Self::set_member`], carrying a ticket's done-state as the client sees it.
    ///
    /// `done` is the report for a beads issue or a Linear ticket, the two kinds this
    /// daemon cannot look up: `None` keeps whatever was reported before (so a re-tag
    /// that only refreshes a title does not reopen the ticket), and it is ignored for a
    /// session or a tracked PR, whose state is read live. A ticket reported done while
    /// it was in this chain unfinished is a member finishing, which may close the chain.
    pub fn set_member_reporting(
        &self,
        kind: ChainMemberKind,
        ref_id: &str,
        slug: Option<&str>,
        title: Option<String>,
        url: Option<String>,
        done: Option<bool>,
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
        let previous = self.member(kind, ref_id);
        let stays = previous
            .as_ref()
            .filter(|(at, _)| at.as_str() == slug)
            .map(|(_, m)| m);
        let was_done = previous.as_ref().is_some_and(|(_, m)| m.done);
        let done = ChainMember::is_reported(kind) && done.unwrap_or(was_done);
        let member = ChainMember {
            kind,
            ref_id: ref_id.to_string(),
            title,
            url,
            // Only a move restamps it: a report or a title refresh is not the item
            // joining again, and must not send it to the end of the chain.
            added_at: stays.map_or_else(now_ms, |m| m.added_at),
            done,
        };
        let finished_here = done && stays.is_some_and(|m| !m.done);
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
        })?;
        if finished_here {
            self.close_if_finished(slug);
        }
        Ok(())
    }

    /// Give a dispatch a chain even when its source is absent or no longer known.
    /// Prefer inheritance, and never move a session that already belongs to a chain.
    pub fn chain_dispatch(&self, session_id: &str, from_session: Option<&str>) {
        if let Some(from) = from_session {
            self.inherit(from, ChainMemberKind::Session, session_id, None, None);
        }
        let Some(session) = self.sessions.meta(session_id) else {
            return;
        };
        let outcome = self.mutate(|store| {
            let book = store.chains().map_err(store_failed)?;
            if book.iter().any(|chain| {
                chain.members.iter().any(|member| {
                    member.kind == ChainMemberKind::Session && member.ref_id == session_id
                })
            }) {
                return Ok(Vec::new());
            }
            let slug = start_chain_for(store, &session)?;
            store
                .set_member(
                    &slug,
                    &ChainMember {
                        kind: ChainMemberKind::Session,
                        ref_id: session_id.to_string(),
                        title: None,
                        url: None,
                        added_at: now_ms(),
                        done: false,
                    },
                )
                .map_err(store_failed)?;
            Ok(vec![slug])
        });
        if let Err(code) = outcome {
            warn!(session = %session_id, code, "could not create a dispatch chain");
        }
    }

    /// Put a just-created item in whatever chain `from_session` is in: the session an
    /// Oracle dispatched joins the Oracle's chain, and a PR tracked from a chained
    /// session joins that session's chain. Returns the slug it joined.
    ///
    /// Once, at creation, and never a move. An item that is already in a chain stays
    /// where it is — a PR that was untracked and tracked again keeps the chain a person
    /// may have moved it to — and after this it is an ordinary member that
    /// `set_member` retags or untags like any other. A `from_session` this daemon does
    /// not know is not a refusal: the item is simply untagged, which is what it would
    /// have been without the hint.
    ///
    /// A session dispatched from a session in no chain starts one: every dispatched
    /// agent belongs to a chain, so the work it was handed off from and the work it is
    /// doing are grouped from the first moment. The chain is named after the source
    /// session's title (`-2`, `-3`… when taken) and holds the source, then the new
    /// session. Only a session does this; a PR tracked from an unchained session stays
    /// untagged, because a lone PR is not a dispatch.
    ///
    /// The chain's state is not consulted. An Oracle in a closed chain that dispatches
    /// more work is doing that chain's work, and the badge saying so is truer than no
    /// badge; whether that reopens the chain is the chain's business, not this one's.
    pub fn inherit(
        &self,
        from_session: &str,
        kind: ChainMemberKind,
        ref_id: &str,
        title: Option<String>,
        url: Option<String>,
    ) -> Option<String> {
        if ref_id.trim().is_empty() || from_session == ref_id {
            return None;
        }
        if kind == ChainMemberKind::Session && self.sessions.meta(ref_id).is_none() {
            return None;
        }
        // Only needed to start a chain; a source this daemon does not know starts none.
        let source = (kind == ChainMemberKind::Session)
            .then(|| self.sessions.meta(from_session))
            .flatten();
        let mut joined = None;
        let mut started = false;
        // One mutation, read off the store inside it, so a retag that lands between
        // looking up the parent's chain and joining it cannot be overwritten.
        let outcome = self.mutate(|store| {
            let book = store.chains().map_err(store_failed)?;
            let holds = |c: &Chain, kind: ChainMemberKind, id: &str| {
                c.members.iter().any(|m| m.kind == kind && m.ref_id == id)
            };
            if book.iter().any(|c| holds(c, kind, ref_id)) {
                return Ok(Vec::new());
            }
            let found = book
                .iter()
                .find(|c| holds(c, ChainMemberKind::Session, from_session))
                .map(|c| c.slug.clone());
            let slug = match (found, &source) {
                (Some(slug), _) => slug,
                (None, Some(source)) if kind == ChainMemberKind::Session => {
                    let slug = start_chain_for(store, source)?;
                    let parent = ChainMember {
                        kind: ChainMemberKind::Session,
                        ref_id: from_session.to_string(),
                        title: None,
                        url: None,
                        added_at: now_ms(),
                        done: false,
                    };
                    store.set_member(&slug, &parent).map_err(store_failed)?;
                    started = true;
                    slug
                }
                _ => return Ok(Vec::new()),
            };
            let member = ChainMember {
                kind,
                ref_id: ref_id.to_string(),
                title,
                url,
                added_at: now_ms(),
                // Only an item in no chain inherits one, so there is no earlier report
                // to keep.
                done: false,
            };
            store.set_member(&slug, &member).map_err(store_failed)?;
            joined = Some(slug.clone());
            Ok(vec![slug])
        });
        if let Err(code) = outcome {
            warn!(from = %from_session, item = %ref_id, code, "could not inherit a chain");
            return None;
        }
        if let Some(slug) = &joined {
            if started {
                info!(from = %from_session, item = %ref_id, chain = %slug, "started a chain for a dispatch");
            } else {
                debug!(from = %from_session, item = %ref_id, chain = %slug, "inherited a chain");
            }
        }
        joined
    }

    /// Untag a session that no longer exists. A deleted or pruned session would
    /// otherwise stay a member forever, as a tab nothing can draw.
    ///
    /// A deleted session is also a finished one, so the chain it left is asked whether
    /// that was the last unfinished member.
    pub fn forget_session(&self, session_id: &str) {
        let Some(slug) = self.chain_of(ChainMemberKind::Session, session_id) else {
            return;
        };
        if let Err(code) = self.set_member(ChainMemberKind::Session, session_id, None, None, None) {
            warn!(session = %session_id, code, "could not untag a deleted session");
            return;
        }
        self.close_if_finished(&slug);
    }

    /// A member finished: close its chain if that was the last unfinished one.
    pub fn member_finished(&self, kind: ChainMemberKind, ref_id: &str) {
        if let Some(slug) = self.chain_of(kind, ref_id) {
            self.close_if_finished(&slug);
        }
    }

    /// Take in the watch list as it now is. A PR that was watched and no longer is
    /// merged, closed or was untracked, which finishes it as a member. The first list
    /// only sets the baseline: a PR missing from it may have left long ago, and that is
    /// not news.
    pub fn prs_changed(&self, watched: BTreeSet<String>) {
        let left: Vec<String> = {
            let mut held = self.watched_prs.lock().unwrap_or_else(|e| e.into_inner());
            let left = held
                .as_ref()
                .map(|before| before.difference(&watched).cloned().collect())
                .unwrap_or_default();
            *held = Some(watched);
            left
        };
        for key in left {
            self.member_finished(ChainMemberKind::TrackedPr, &key);
        }
    }

    /// Follow the watch list for as long as it publishes. One task per daemon.
    pub fn spawn_pr_watch(
        self: &Arc<Self>,
        tracked: Arc<TrackedPrs>,
    ) -> tokio::task::JoinHandle<()> {
        // Subscribed before the baseline is read, so a change in between is not lost:
        // at worst it is applied twice, and a list is whole, so twice is once.
        let mut changes = tracked.subscribe();
        self.prs_changed(watch_keys(&tracked.list()));
        let chains = Arc::clone(self);
        tokio::spawn(async move {
            loop {
                match changes.recv().await {
                    Ok(TrackedPrChange::List(list)) => chains.prs_changed(watch_keys(&list)),
                    Ok(TrackedPrChange::Notification { .. }) => {}
                    // The next list is whole, and the diff is against the last one this
                    // saw, so a lag delays a PR finishing without losing it.
                    Err(RecvError::Lagged(n)) => {
                        debug!(dropped = n, "chain PR watch lagged behind the watch list")
                    }
                    Err(RecvError::Closed) => return,
                }
            }
        })
    }

    /// Whether a member is finished, as far as this daemon can tell.
    fn status(&self, member: &ChainMember) -> MemberStatus {
        let finished = match member.kind {
            ChainMemberKind::Session => match self.sessions.meta(&member.ref_id) {
                None => true,
                // A dormant session exited because the reaper put it to sleep, and it
                // is one click from running again.
                Some(meta) => {
                    meta.archived || (meta.status == SessionStatus::Exited && !meta.dormant)
                }
            },
            ChainMemberKind::TrackedPr => self
                .watched_prs
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .as_ref()
                .is_some_and(|watched| !watched.contains(&member.ref_id)),
            ChainMemberKind::Beads | ChainMemberKind::Linear => member.done,
        };
        if finished {
            MemberStatus::Finished
        } else {
            MemberStatus::Live
        }
    }

    /// Close `slug` if it is active, not empty, and every member in it is finished.
    /// Decided against the store under the book's lock, so a member that joined a
    /// moment ago is part of the answer.
    fn close_if_finished(&self, slug: &str) {
        let mut closed = false;
        let outcome = self.mutate(|store| {
            let Some(chain) = store
                .chains()
                .map_err(store_failed)?
                .into_iter()
                .find(|c| c.slug == slug)
            else {
                return Ok(Vec::new());
            };
            if store
                .handoffs()
                .map_err(store_failed)?
                .iter()
                .any(|h| h.chain_slug == slug && h.state != HandoffState::Closed)
            {
                return Ok(Vec::new());
            }
            if !chain.all_finished(|m| self.status(m)) {
                return Ok(Vec::new());
            }
            match store.set_chain_state(slug, ChainState::Inactive, Some(now_ms())) {
                Ok(true) => {
                    closed = true;
                    Ok(vec![slug.to_string()])
                }
                Ok(false) => Ok(Vec::new()),
                Err(e) => Err(store_failed(e)),
            }
        });
        match outcome {
            Ok(()) if closed => info!(chain = slug, "every member is finished; chain closed"),
            Ok(()) => {}
            Err(code) => warn!(chain = slug, code, "could not auto-close a chain"),
        }
    }

    /// Watch the session bus: untag each session it reports deleted, and ask a
    /// session's chain whether it is done when the session exits or is archived. One
    /// task per daemon, ended with the handle.
    pub fn spawn_session_sweep(self: &Arc<Self>) -> tokio::task::JoinHandle<()> {
        let mut events = self.sessions.subscribe();
        let chains = Arc::clone(self);
        tokio::spawn(async move {
            // Sessions seen archived, so a later rename of an archived session is not
            // the session finishing again — which would re-close a chain somebody
            // reopened by hand.
            let mut archived = BTreeSet::new();
            loop {
                match events.recv().await {
                    Ok(SessionEvent::Deleted { session_id, .. }) => {
                        archived.remove(&session_id);
                        chains.forget_session(&session_id)
                    }
                    Ok(SessionEvent::Exit { session_id, .. }) => {
                        chains.member_finished(ChainMemberKind::Session, &session_id)
                    }
                    Ok(SessionEvent::Meta { session_id, meta }) => {
                        if !meta.archived {
                            archived.remove(&session_id);
                        } else if archived.insert(session_id.clone()) {
                            chains.member_finished(ChainMemberKind::Session, &session_id)
                        }
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

    /// The chain an item is in and the item as that chain holds it.
    fn member(&self, kind: ChainMemberKind, ref_id: &str) -> Option<(String, ChainMember)> {
        self.lock().iter().find_map(|c| {
            c.members
                .iter()
                .find(|m| m.kind == kind && m.ref_id == ref_id)
                .map(|m| (c.slug.clone(), m.clone()))
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<Chain>> {
        self.book.lock().unwrap_or_else(|e| e.into_inner())
    }
}

fn same_handoff_request(existing: &Handoff, requested: &Handoff) -> bool {
    existing.id == requested.id
        && existing.chain_slug == requested.chain_slug
        && existing.source == requested.source
        && existing.target == requested.target
        && existing.beads_issue == requested.beads_issue
        && existing.summary == requested.summary
        && existing.evidence_ref == requested.evidence_ref
        && existing.predecessor_id == requested.predecessor_id
}

fn watch_keys(list: &[juancoded_core::pr::TrackedPr]) -> BTreeSet<String> {
    list.iter().map(|pr| pr.id.clone()).collect()
}

/// Create a chain with a UUID and the source session’s display title.
fn start_chain_for(store: &dyn ChainStore, source: &SessionMeta) -> Result<String, ChainRefusal> {
    let slug = uuid::Uuid::new_v4().to_string();
    let name = if source.title.trim().is_empty() {
        "New chain"
    } else {
        &source.title
    };
    if store
        .create_named_chain(&slug, name, now_ms())
        .map_err(store_failed)?
    {
        Ok(slug)
    } else {
        Err("chain-exists")
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

    fn spawn(h: &crate::serve::CoreHandles) -> String {
        h.sessions
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
            .id
    }

    fn state(chains: &Chains, slug: &str) -> ChainState {
        chains.list().iter().find(|c| c.slug == slug).unwrap().state
    }

    #[tokio::test]
    async fn open_handoffs_block_auto_close_and_deleted_owners_remain_historical() {
        let (handles, chains) = engine();
        let owner = spawn(&handles);
        chains.create("handoff-test").unwrap();
        let unknown_owner = Handoff {
            id: "unknown".into(),
            chain_slug: "handoff-test".into(),
            source: HandoffOwner::Session("missing-session".into()),
            target: HandoffOwner::Human,
            beads_issue: None,
            summary: "Must be refused".into(),
            created_at: 0,
            updated_at: 0,
            state: HandoffState::Pending,
            closure_reason: None,
            predecessor_id: None,
            successor_id: None,
            evidence_ref: None,
            delivery: HandoffDelivery::NotSent,
        };
        assert_eq!(
            chains.create_handoff(unknown_owner),
            Err("handoff-session-not-found")
        );
        chains
            .set_member_reporting(
                ChainMemberKind::Beads,
                "juancode-043.1",
                Some("handoff-test"),
                None,
                None,
                Some(false),
            )
            .unwrap();
        let handoff = Handoff {
            id: "stable-1".into(),
            chain_slug: "handoff-test".into(),
            source: HandoffOwner::Session(owner.clone()),
            target: HandoffOwner::Human,
            beads_issue: Some("juancode-043.1".into()),
            summary: "Continue the slice".into(),
            created_at: 1,
            updated_at: 1,
            state: HandoffState::Pending,
            closure_reason: None,
            predecessor_id: None,
            successor_id: None,
            evidence_ref: None,
            delivery: HandoffDelivery::NotSent,
        };
        chains.create_handoff(handoff.clone()).unwrap();
        chains.create_handoff(handoff.clone()).unwrap();
        let mut conflicting = handoff.clone();
        conflicting.summary = "a different request under the same id".into();
        assert_eq!(
            chains.create_handoff(conflicting),
            Err("handoff-id-conflict")
        );
        assert_eq!(chains.delete("handoff-test"), Err("chain-has-handoffs"));
        chains.mark_handoff_delivered("stable-1").unwrap();
        assert_eq!(
            chains.handoffs().unwrap()[0].state,
            HandoffState::Pending,
            "delivery is not acknowledgement"
        );
        chains
            .set_member_reporting(
                ChainMemberKind::Beads,
                "juancode-043.1",
                Some("handoff-test"),
                None,
                None,
                Some(true),
            )
            .unwrap();
        assert_eq!(state(&chains, "handoff-test"), ChainState::Active);
        handles.sessions.delete(&owner).unwrap();
        let historical = chains.handoffs().unwrap();
        assert_eq!(historical[0].source, HandoffOwner::Session(owner));
        chains.close_handoff("stable-1", "no-follow-on").unwrap();
        chains
            .set_member_reporting(
                ChainMemberKind::Beads,
                "juancode-043.1",
                Some("handoff-test"),
                None,
                None,
                Some(false),
            )
            .unwrap();
        chains
            .set_member_reporting(
                ChainMemberKind::Beads,
                "juancode-043.1",
                Some("handoff-test"),
                None,
                None,
                Some(true),
            )
            .unwrap();
        assert_eq!(state(&chains, "handoff-test"), ChainState::Inactive);
    }

    /// Wait for the sweep task to act on an event, which it does on its own schedule.
    async fn settles_to(chains: &Chains, slug: &str, want: ChainState) {
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
        while state(chains, slug) != want {
            assert!(
                tokio::time::Instant::now() < deadline,
                "{slug} never went {want:?}"
            );
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
    }

    fn report(chains: &Chains, ref_id: &str, slug: &str, done: Option<bool>) {
        chains
            .set_member_reporting(ChainMemberKind::Beads, ref_id, Some(slug), None, None, done)
            .unwrap();
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
                ChainChange::Handoff(handoff) => format!("handoff:{}", handoff.id),
            })
            .collect()
    }

    #[tokio::test]
    async fn named_chains_keep_uuid_identity_and_allow_duplicate_display_names() {
        let (h, _) = engine();
        let store = Arc::new(SqliteStore::in_memory().unwrap());
        let chains = Chains::new(Arc::clone(&h.sessions), store.clone());
        let a = uuid::Uuid::new_v4().to_string();
        let b = uuid::Uuid::new_v4().to_string();
        chains.create_named(&a, "  Fix café login  ").unwrap();
        chains.create_named(&b, "Fix café login").unwrap();
        assert_eq!(chains.create_named(&a, "Other"), Err("chain-exists"));
        assert_eq!(chains.create_named("bad", "Name"), Err("chain-id-invalid"));
        assert_eq!(
            chains.create_named(&uuid::Uuid::new_v4().to_string(), "  "),
            Err("chain-name-invalid")
        );
        let restarted = Chains::new(Arc::clone(&h.sessions), store);
        assert_eq!(restarted.list(), chains.list());
        assert!(chains.list().iter().any(|c| c.id == a));
        assert!(chains.list().iter().all(|c| c.name == "Fix café login"));
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
        let id = spawn(&h);
        chains
            .set_member(ChainMemberKind::Session, &id, Some("a"), None, None)
            .unwrap();
        let mut rx = chains.subscribe();
        chains.forget_session(&id);
        assert_eq!(slugs_of(&drain(&mut rx)), ["a"]);
        assert!(chains.list()[0].members.is_empty());
        let _ = h.sessions.kill(&id);
    }

    fn session(h: &crate::serve::CoreHandles) -> String {
        h.sessions
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
            .id
    }

    #[tokio::test]
    async fn a_new_item_inherits_its_parents_chain_once_and_never_moves() {
        let (h, chains) = engine();
        chains.create("a").unwrap();
        chains.create("b").unwrap();
        let oracle = session(&h);
        let child = session(&h);
        let loner = session(&h);
        chains
            .set_member(ChainMemberKind::Session, &oracle, Some("a"), None, None)
            .unwrap();
        let mut rx = chains.subscribe();

        assert_eq!(
            chains.inherit(&oracle, ChainMemberKind::Session, &child, None, None),
            Some("a".into())
        );
        assert_eq!(slugs_of(&drain(&mut rx)), ["a"]);
        assert_eq!(
            chains.chain_of(ChainMemberKind::Session, &child).as_deref(),
            Some("a")
        );

        // A PR tracked from a chained session joins with the caller's snapshot.
        assert_eq!(
            chains.inherit(
                &child,
                ChainMemberKind::TrackedPr,
                "/r#1",
                Some("Fix it".into()),
                Some("https://example.invalid/1".into()),
            ),
            Some("a".into())
        );
        let pr = chains.list()[0]
            .members
            .iter()
            .find(|m| m.kind == ChainMemberKind::TrackedPr)
            .cloned()
            .expect("the PR is a member");
        assert_eq!(pr.title.as_deref(), Some("Fix it"));
        drain(&mut rx);

        // Overridden afterwards, and a second inherit does not drag it back.
        chains
            .set_member(ChainMemberKind::TrackedPr, "/r#1", Some("b"), None, None)
            .unwrap();
        drain(&mut rx);
        assert_eq!(
            chains.inherit(&oracle, ChainMemberKind::TrackedPr, "/r#1", None, None),
            None
        );
        assert!(drain(&mut rx).is_empty(), "a no-op publishes nothing");
        assert_eq!(
            chains
                .chain_of(ChainMemberKind::TrackedPr, "/r#1")
                .as_deref(),
            Some("b")
        );

        // A parent in no chain, or one this daemon never heard of, tags nothing.
        assert_eq!(
            chains.inherit(&loner, ChainMemberKind::TrackedPr, "/r#2", None, None),
            None
        );
        assert_eq!(
            chains.inherit("nope", ChainMemberKind::TrackedPr, "/r#2", None, None),
            None
        );
        // Nor does a session member that does not exist.
        assert_eq!(
            chains.inherit(&oracle, ChainMemberKind::Session, "ghost", None, None),
            None
        );
        assert!(drain(&mut rx).is_empty());
        for id in [oracle, child, loner] {
            let _ = h.sessions.kill(&id);
        }
    }

    #[tokio::test]
    async fn a_session_dispatched_from_an_unchained_session_starts_a_chain() {
        let (h, chains) = engine();
        let oracle = session(&h);
        let title = h.sessions.meta(&oracle).unwrap().title;
        let base = "existing-chain".to_string();
        // An unrelated existing chain cannot collide with the generated identity.
        chains.create(&base).unwrap();
        let first = session(&h);
        let second = session(&h);
        let mut rx = chains.subscribe();

        let slug = chains
            .inherit(&oracle, ChainMemberKind::Session, &first, None, None)
            .expect("a chain is started");
        assert!(uuid::Uuid::parse_str(&slug).is_ok());
        assert_eq!(slugs_of(&drain(&mut rx)), [slug.clone()]);
        let chain = chains.list().into_iter().find(|c| c.slug == slug).unwrap();
        assert_eq!(chain.state, ChainState::Active);
        assert_eq!(chain.name, title);
        assert_eq!(chain.id, slug);
        let ids: Vec<_> = chain.members.iter().map(|m| m.ref_id.as_str()).collect();
        assert_eq!(
            ids,
            [oracle.as_str(), first.as_str()],
            "the source, then the dispatch"
        );

        // The next dispatch from it joins that chain rather than starting another.
        assert_eq!(
            chains.inherit(&oracle, ChainMemberKind::Session, &second, None, None),
            Some(slug.clone())
        );
        assert_eq!(chains.list().len(), 2);

        // A source this daemon does not know starts nothing, and a PR never does.
        let loner = session(&h);
        let orphan = session(&h);
        assert_eq!(
            chains.inherit("nope", ChainMemberKind::Session, &orphan, None, None),
            None
        );
        assert_eq!(
            chains.inherit(&loner, ChainMemberKind::TrackedPr, "/r#9", None, None),
            None
        );
        assert_eq!(chains.list().len(), 2);
        for id in [oracle, first, second, loner, orphan] {
            let _ = h.sessions.kill(&id);
        }
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

    #[tokio::test]
    async fn a_ticket_reported_done_closes_the_chain_when_it_was_the_last_one_open() {
        let (_h, chains) = engine();
        chains.create("a").unwrap();
        report(&chains, "x-1", "a", None);
        report(&chains, "x-2", "a", None);
        let added = chains.list()[0].members[0].added_at;

        report(&chains, "x-1", "a", Some(true));
        assert_eq!(state(&chains, "a"), ChainState::Active, "x-2 is still open");
        let member = &chains.list()[0].members[0];
        assert!(member.done);
        assert_eq!(
            (member.ref_id.as_str(), member.added_at),
            ("x-1", added),
            "a report is not a re-join"
        );

        // A re-tag that says nothing about done keeps the report it already has.
        report(&chains, "x-1", "a", None);
        assert!(chains.list()[0].members[0].done);

        let mut rx = chains.subscribe();
        report(&chains, "x-2", "a", Some(true));
        let closed = chains.list()[0].clone();
        assert_eq!(closed.state, ChainState::Inactive);
        assert!(closed.closed_at.is_some());
        assert_eq!(closed.members.len(), 2, "closing keeps the members");
        let changes = drain(&mut rx);
        assert_eq!(
            changes.last(),
            Some(&ChainChange::Upsert(closed)),
            "the close is published like a manual one"
        );
    }

    #[tokio::test]
    async fn only_a_member_finishing_closes_a_chain_never_a_join_or_a_reopen() {
        let (_h, chains) = engine();
        chains.create("a").unwrap();
        chains.member_finished(ChainMemberKind::Beads, "nothing");
        assert_eq!(
            state(&chains, "a"),
            ChainState::Active,
            "an empty chain stays open"
        );

        // Tagging work that is already finished is not that work finishing.
        report(&chains, "x-1", "a", Some(true));
        assert_eq!(state(&chains, "a"), ChainState::Active);

        report(&chains, "x-2", "a", None);
        report(&chains, "x-2", "a", Some(true));
        assert_eq!(state(&chains, "a"), ChainState::Inactive);

        // Reopened by hand, it stays open while nothing in it finishes again — even a
        // report that repeats what is already known is not a member finishing.
        chains.reopen("a").unwrap();
        report(&chains, "x-2", "a", Some(true));
        assert_eq!(state(&chains, "a"), ChainState::Active);

        // A member going live again does not reopen a closed chain, either.
        chains.close("a").unwrap();
        report(&chains, "x-2", "a", Some(false));
        assert_eq!(state(&chains, "a"), ChainState::Inactive);
        assert!(!chains.list()[0].members[1].done);
    }

    #[tokio::test]
    async fn done_is_only_kept_for_the_kinds_a_client_reports() {
        let (_h, chains) = engine();
        chains.create("a").unwrap();
        chains
            .set_member_reporting(
                ChainMemberKind::TrackedPr,
                "/r#1",
                Some("a"),
                None,
                None,
                Some(true),
            )
            .unwrap();
        assert!(!chains.list()[0].members[0].done);
        assert_eq!(state(&chains, "a"), ChainState::Active);
    }

    #[tokio::test]
    async fn a_pr_leaving_the_watch_list_finishes_it() {
        let (_h, chains) = engine();
        chains.create("a").unwrap();
        chains
            .set_member(ChainMemberKind::TrackedPr, "/r#1", Some("a"), None, None)
            .unwrap();
        chains
            .set_member(ChainMemberKind::TrackedPr, "/r#2", Some("a"), None, None)
            .unwrap();
        let watched = |keys: &[&str]| keys.iter().map(|k| k.to_string()).collect();

        // Without a watch list, a PR's state is unknown and so not finished.
        chains.member_finished(ChainMemberKind::TrackedPr, "/r#1");
        assert_eq!(state(&chains, "a"), ChainState::Active);

        // The first list is a baseline: /r#2 is missing from it, but that is old news.
        chains.prs_changed(watched(&["/r#1", "/other#9"]));
        assert_eq!(state(&chains, "a"), ChainState::Active);
        chains.prs_changed(watched(&["/other#9"]));
        assert_eq!(state(&chains, "a"), ChainState::Inactive);
    }

    #[tokio::test]
    async fn a_session_exiting_or_being_archived_finishes_it_but_sleeping_does_not() {
        let (h, chains) = engine();
        let _sweep = chains.spawn_session_sweep();
        chains.create("exits").unwrap();
        chains.create("archived").unwrap();
        chains.create("sleeps").unwrap();
        let (exits, archived, sleeps) = (spawn(&h), spawn(&h), spawn(&h));
        for (id, slug) in [
            (&exits, "exits"),
            (&archived, "archived"),
            (&sleeps, "sleeps"),
        ] {
            chains
                .set_member(ChainMemberKind::Session, id, Some(slug), None, None)
                .unwrap();
        }

        h.sessions.kill(&exits).unwrap();
        settles_to(&chains, "exits", ChainState::Inactive).await;

        h.sessions.set_meta(&archived, None, Some(true)).unwrap();
        settles_to(&chains, "archived", ChainState::Inactive).await;

        // Put to sleep by the reaper: exited, but waiting to be woken.
        h.sessions.sleep(&sleeps).unwrap();
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
        while h.sessions.is_running(&sleeps) {
            assert!(tokio::time::Instant::now() < deadline, "never slept");
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        assert_eq!(state(&chains, "sleeps"), ChainState::Active);

        let _ = h.sessions.kill(&archived);
        let _ = h.sessions.kill(&sleeps);
    }

    #[tokio::test]
    async fn a_deleted_session_that_was_the_last_one_open_closes_its_chain() {
        let (h, chains) = engine();
        chains.create("a").unwrap();
        report(&chains, "x-1", "a", None);
        let id = spawn(&h);
        chains
            .set_member(ChainMemberKind::Session, &id, Some("a"), None, None)
            .unwrap();
        report(&chains, "x-1", "a", Some(true));
        assert_eq!(
            state(&chains, "a"),
            ChainState::Active,
            "the session is running"
        );
        chains.forget_session(&id);
        let chain = chains.list()[0].clone();
        assert_eq!(chain.state, ChainState::Inactive);
        assert_eq!(chain.members.len(), 1);
        let _ = h.sessions.kill(&id);
    }
}
