//! The `queue` service: a session's not-yet-typed steering messages, addressable one
//! occurrence at a time.
//!
//! Three rules make this different from a list of strings.
//!
//! 1. **An occurrence is the unit, not the text.** Every accepted message gets its own
//!    opaque id, so the same words queued twice are two rows a client can tell apart.
//!    Addressing by content, or by whatever id the sender's chat app used, is ambiguous
//!    the moment someone repeats themselves.
//! 2. **Mutation ends at the claim.** The delivery engine claims the head occurrence
//!    before it types a single byte, and from that instant edit and remove answer
//!    `queue-item-not-found` rather than rewriting input that is already in the
//!    agent's box. A missing session answers with the same code on purpose: a client
//!    holding a stale row cannot tell the two apart and must not try.
//! 3. **The host is the only authority.** Every mutation produces a complete
//!    [`QueueSnapshot`], never a delta, so a client's whole job is to replace what it
//!    is holding. See [`crate::plugins::queue::mirror`] for the client half.
//!
//! Ids are process-local by construction: they carry the epoch the queue was created
//! at, so an id minted before a restart names nothing afterwards. That is deliberate.
//! Work that must survive a restart is not addressable steering.

use std::collections::BTreeMap;
use std::fmt;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use juancoded_core::model::now_ms;

use crate::service::Service;

/// What a queued occurrence holds.
///
/// Only [`Content::Text`] is editable. An occurrence that is a keypress or an escape
/// sequence has no plain-text form to replace, and inventing one would let an edit
/// turn a control byte into a sentence.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Content {
    Text {
        text: String,
    },
    /// Bytes with no textual reading, carried with a label a client can render.
    Keys {
        label: String,
        bytes: Vec<u8>,
    },
}

impl Content {
    pub fn text(text: impl Into<String>) -> Self {
        Self::Text { text: text.into() }
    }

    pub fn keys(label: impl Into<String>, bytes: impl Into<Vec<u8>>) -> Self {
        Self::Keys {
            label: label.into(),
            bytes: bytes.into(),
        }
    }

    /// The bytes the delivery engine types. Text is handed over verbatim; adding the
    /// submit key is the engine's business, not the queue's.
    pub fn payload(&self) -> Vec<u8> {
        match self {
            Self::Text { text } => text.as_bytes().to_vec(),
            Self::Keys { bytes, .. } => bytes.clone(),
        }
    }

    pub fn as_text(&self) -> Option<&str> {
        match self {
            Self::Text { text } => Some(text),
            Self::Keys { .. } => None,
        }
    }
}

/// Whether an occurrence is still the client's to change.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ItemState {
    /// Not yet typed. Editable, removable.
    Pending,
    /// Claimed by the delivery engine. Still on screen, no longer addressable.
    InFlight,
}

/// One addressable occurrence.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Occurrence {
    pub id: String,
    pub content: Content,
    /// Where it came from: `telegram`, `native`, `dispatch`. Preserved across an edit,
    /// because an edited message is still the message that arrived from that surface.
    pub source: String,
    pub created_at: i64,
    pub state: ItemState,
}

impl Occurrence {
    pub fn is_pending(&self) -> bool {
        matches!(self.state, ItemState::Pending)
    }
}

/// The whole of a session's queue, which is the only thing this service ever hands out.
///
/// `revision` is per session and strictly increasing, so a client that receives two
/// snapshots out of order can drop the older one. It is not a cursor: there is nothing
/// to fetch between revisions, because there are no deltas.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QueueSnapshot {
    pub session: String,
    pub revision: u64,
    pub items: Vec<Occurrence>,
}

impl QueueSnapshot {
    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    pub fn get(&self, id: &str) -> Option<&Occurrence> {
        self.items.iter().find(|item| item.id == id)
    }

    /// Where an occurrence sits in delivery order.
    pub fn position(&self, id: &str) -> Option<usize> {
        self.items.iter().position(|item| item.id == id)
    }
}

/// Why a mutation did not happen.
///
/// There is deliberately no separate code for "that session is gone", "no such id" and
/// "the engine already claimed it". All three mean the same thing to the caller: the
/// row you are holding is not yours to change, replace your view from the next
/// snapshot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QueueError {
    NotFound,
    /// The occurrence exists and is pending, but holds bytes rather than text.
    NotText,
}

impl QueueError {
    /// The string the wire carries. The server's error frame uses it verbatim.
    pub fn code(&self) -> &'static str {
        match self {
            Self::NotFound => "queue-item-not-found",
            Self::NotText => "queue-item-not-text",
        }
    }
}

impl fmt::Display for QueueError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotFound => write!(f, "no pending queue occurrence with that id"),
            Self::NotText => write!(f, "only a plain-text occurrence can be edited"),
        }
    }
}

impl std::error::Error for QueueError {}

/// Why a claim was not granted. Not an error: an empty queue is the normal answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClaimRefused {
    /// Nothing pending.
    Empty,
    /// A claim on this session is already outstanding. One at a time, per session, is
    /// what keeps a retry from pasting a second copy of a message that is already in
    /// the box.
    AlreadyClaimed { id: String },
}

/// How a claim ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Delivery {
    /// The bytes reached the agent and the turn started. The row retires.
    Delivered,
    /// Nothing was typed, so nothing is in flight: the occurrence goes back to
    /// pending at the position it held, keeping its id, and becomes editable again.
    Abandoned,
    /// The occurrence will never be delivered. It retires with a reason, unsent.
    Discarded { reason: String },
}

/// What consumers of the `queue` key may do.
///
/// The mutating half is addressed by occurrence id; the delivery half is addressed by
/// session and hands back a [`Claim`]. Nothing here reorders a queue and there is no
/// send-now: the head is the head, and the only way an occurrence leaves early is a
/// remove.
pub trait QueueApi: Send + Sync {
    /// Append an occurrence and return it. Insertion order is delivery order.
    fn enqueue(&self, session: &str, content: Content, source: &str) -> Occurrence;

    /// Replace a pending occurrence's text, keeping its id, its position and its
    /// source. Not a remove followed by an append: a requeue would mint a new id and
    /// send the message to the back of a queue the user never asked to reorder.
    fn edit(&self, session: &str, id: &str, text: &str) -> Result<Occurrence, QueueError>;

    /// Drop a pending occurrence. Returns what was removed, so the caller can report
    /// what it discarded rather than guessing from its own stale copy.
    fn remove(&self, session: &str, id: &str) -> Result<Occurrence, QueueError>;

    /// The complete current queue. A session nobody has queued to has an empty one at
    /// revision 0 rather than no snapshot at all, which is what a client subscribing
    /// before the first message needs to render an empty dock.
    fn snapshot(&self, session: &str) -> QueueSnapshot;

    /// The claim boundary. Takes the head pending occurrence and marks it in flight;
    /// from here it is the delivery engine's, and edit and remove answer not-found.
    ///
    /// The engine keeps the returned [`Claim`] across its own retries, so a paste that
    /// landed but has not yet been submitted still owns the row.
    fn claim_next(&self, session: &str) -> Result<Claim, ClaimRefused>;

    /// The occurrence currently in flight for this session, if any.
    fn claimed(&self, session: &str) -> Option<String>;

    /// Forget a session's queue entirely: it exited, or was pruned.
    fn clear(&self, session: &str);

    /// Every session holding at least one occurrence.
    fn sessions(&self) -> Vec<String>;
}

/// The contract marker: `ctx.resolve::<QueueService>()` yields `Arc<dyn QueueApi>`.
pub struct QueueService;

impl Service for QueueService {
    const KEY: &'static str = "queue";
    type Api = dyn QueueApi;
}

/// Where a settled claim reports back to. Implemented by the queue itself; it exists
/// so a [`Claim`] can be minted by any implementation of [`QueueApi`], not just this
/// crate's.
pub trait ClaimSink: Send + Sync {
    fn settle_claim(&self, session: &str, id: &str, outcome: Delivery);
}

/// One occurrence, held by the delivery engine while it types.
///
/// Dropping a claim without settling it discards the occurrence rather than returning
/// it to the queue. That direction is chosen on purpose: a claim whose fate nobody
/// recorded may have already put bytes in the agent's box, and re-queueing it is how
/// this area has previously shipped duplicate pastes. An engine that knows it typed
/// nothing says so with [`Delivery::Abandoned`].
pub struct Claim {
    pub session: String,
    pub id: String,
    /// The content as it stood at the moment of the claim. Frozen here so the engine
    /// types what it claimed even if the rest of the world moves on.
    pub content: Content,
    settled: AtomicBool,
    sink: Weak<dyn ClaimSink>,
}

impl Claim {
    pub fn new(session: &str, id: &str, content: Content, sink: Weak<dyn ClaimSink>) -> Self {
        Self {
            session: session.to_string(),
            id: id.to_string(),
            content,
            settled: AtomicBool::new(false),
            sink,
        }
    }

    /// Report the claim's fate. Consumes the claim, so an engine cannot settle twice.
    pub fn settle(self, outcome: Delivery) {
        self.settled.store(true, Ordering::Relaxed);
        if let Some(sink) = self.sink.upgrade() {
            sink.settle_claim(&self.session, &self.id, outcome);
        }
    }
}

impl fmt::Debug for Claim {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Claim")
            .field("session", &self.session)
            .field("id", &self.id)
            .field("content", &self.content)
            .finish()
    }
}

impl Drop for Claim {
    fn drop(&mut self) {
        if self.settled.load(Ordering::Relaxed) {
            return;
        }
        tracing::warn!(
            session = %self.session,
            item = %self.id,
            "queue claim dropped before it was settled"
        );
        if let Some(sink) = self.sink.upgrade() {
            sink.settle_claim(
                &self.session,
                &self.id,
                Delivery::Discarded {
                    reason: "claim dropped before settle".into(),
                },
            );
        }
    }
}

/// Called with every snapshot the queue produces, which is one per mutation.
pub type Broadcast = Arc<dyn Fn(&QueueSnapshot) + Send + Sync>;

#[derive(Default)]
struct Lane {
    revision: u64,
    items: Vec<Occurrence>,
    claimed: Option<String>,
}

#[derive(Default)]
struct Inner {
    sessions: BTreeMap<String, Lane>,
    next: u64,
}

/// The real implementation: in memory, for the life of the process.
///
/// It does not write through to the store, and that follows from the id rule rather
/// than from laziness. An id that cannot name work after a restart has no business
/// being written to a file that outlives one.
pub struct SessionQueues {
    epoch: String,
    inner: Mutex<Inner>,
    broadcast: Mutex<Option<Broadcast>>,
    /// Handed to every claim, so a settle finds its way back here.
    sink: Mutex<Weak<dyn ClaimSink>>,
}

impl SessionQueues {
    /// A queue whose ids carry this process's start time.
    pub fn new() -> Arc<Self> {
        Self::with_epoch(&process_epoch())
    }

    /// Same, with the epoch pinned. Tests use it to prove two epochs do not collide.
    pub fn with_epoch(epoch: &str) -> Arc<Self> {
        // Typed here rather than inline: an unsized coercion needs a coercion site,
        // and `Mutex::new` is not one.
        let unset: Weak<dyn ClaimSink> = Weak::<Self>::new();
        let queue = Arc::new(Self {
            epoch: epoch.to_string(),
            inner: Mutex::new(Inner::default()),
            broadcast: Mutex::new(None),
            sink: Mutex::new(unset),
        });
        // Coercing the clone keeps the same allocation, so the weak handle a claim
        // holds stays upgradeable for exactly as long as the caller holds the queue.
        let sink: Arc<dyn ClaimSink> = queue.clone();
        *queue.sink.lock().unwrap_or_else(|e| e.into_inner()) = Arc::downgrade(&sink);
        queue
    }

    /// Send every snapshot to `broadcast` from now on. The plugin wires this to the
    /// bus; a test can leave it unset and read snapshots directly.
    pub fn on_change(&self, broadcast: Broadcast) {
        *self.broadcast.lock().unwrap_or_else(|e| e.into_inner()) = Some(broadcast);
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn mint(&self, inner: &mut Inner) -> String {
        inner.next += 1;
        format!("q{}-{}", self.epoch, inner.next)
    }

    /// Build the snapshot under the lock, publish it outside: a listener is free to
    /// call back into the queue.
    fn publish(&self, snapshot: QueueSnapshot) {
        let broadcast = self
            .broadcast
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        if let Some(broadcast) = broadcast {
            broadcast(&snapshot);
        }
    }

    fn snapshot_of(session: &str, lane: Option<&Lane>) -> QueueSnapshot {
        QueueSnapshot {
            session: session.to_string(),
            revision: lane.map(|lane| lane.revision).unwrap_or(0),
            items: lane.map(|lane| lane.items.clone()).unwrap_or_default(),
        }
    }

    /// Bump the revision and read the session's whole queue back out.
    fn bump(inner: &mut Inner, session: &str) -> QueueSnapshot {
        let queue = inner.sessions.entry(session.to_string()).or_default();
        queue.revision += 1;
        Self::snapshot_of(session, Some(queue))
    }
}

impl ClaimSink for SessionQueues {
    fn settle_claim(&self, session: &str, id: &str, outcome: Delivery) {
        let snapshot = {
            let mut inner = self.lock();
            let Some(queue) = inner.sessions.get_mut(session) else {
                return;
            };
            if queue.claimed.as_deref() != Some(id) {
                // A claim that outlived its session's queue. Nothing to retire.
                return;
            }
            queue.claimed = None;
            match outcome {
                Delivery::Delivered | Delivery::Discarded { .. } => {
                    queue.items.retain(|item| item.id != id);
                }
                Delivery::Abandoned => {
                    if let Some(item) = queue.items.iter_mut().find(|item| item.id == id) {
                        item.state = ItemState::Pending;
                    }
                }
            }
            Self::bump(&mut inner, session)
        };
        self.publish(snapshot);
    }
}

impl QueueApi for SessionQueues {
    fn enqueue(&self, session: &str, content: Content, source: &str) -> Occurrence {
        let (occurrence, snapshot) = {
            let mut inner = self.lock();
            let id = self.mint(&mut inner);
            let occurrence = Occurrence {
                id,
                content,
                source: source.to_string(),
                created_at: now_ms(),
                state: ItemState::Pending,
            };
            inner
                .sessions
                .entry(session.to_string())
                .or_default()
                .items
                .push(occurrence.clone());
            (occurrence, Self::bump(&mut inner, session))
        };
        self.publish(snapshot);
        occurrence
    }

    fn edit(&self, session: &str, id: &str, text: &str) -> Result<Occurrence, QueueError> {
        let (occurrence, snapshot) = {
            let mut inner = self.lock();
            let queue = inner
                .sessions
                .get_mut(session)
                .ok_or(QueueError::NotFound)?;
            let item = queue
                .items
                .iter_mut()
                .find(|item| item.id == id && item.is_pending())
                .ok_or(QueueError::NotFound)?;
            if item.content.as_text().is_none() {
                return Err(QueueError::NotText);
            }
            // In place: the row keeps its id, its slot in the vector and its source.
            item.content = Content::text(text);
            let occurrence = item.clone();
            (occurrence, Self::bump(&mut inner, session))
        };
        self.publish(snapshot);
        Ok(occurrence)
    }

    fn remove(&self, session: &str, id: &str) -> Result<Occurrence, QueueError> {
        let (occurrence, snapshot) = {
            let mut inner = self.lock();
            let queue = inner
                .sessions
                .get_mut(session)
                .ok_or(QueueError::NotFound)?;
            let at = queue
                .items
                .iter()
                .position(|item| item.id == id && item.is_pending())
                .ok_or(QueueError::NotFound)?;
            let occurrence = queue.items.remove(at);
            (occurrence, Self::bump(&mut inner, session))
        };
        self.publish(snapshot);
        Ok(occurrence)
    }

    fn snapshot(&self, session: &str) -> QueueSnapshot {
        let inner = self.lock();
        Self::snapshot_of(session, inner.sessions.get(session))
    }

    fn claim_next(&self, session: &str) -> Result<Claim, ClaimRefused> {
        let (claim, snapshot) = {
            let mut inner = self.lock();
            let sink = self.sink.lock().unwrap_or_else(|e| e.into_inner()).clone();
            let queue = inner.sessions.get_mut(session).ok_or(ClaimRefused::Empty)?;
            if let Some(id) = &queue.claimed {
                return Err(ClaimRefused::AlreadyClaimed { id: id.clone() });
            }
            let item = queue
                .items
                .iter_mut()
                .find(|item| item.is_pending())
                .ok_or(ClaimRefused::Empty)?;
            item.state = ItemState::InFlight;
            let claim = Claim::new(session, &item.id, item.content.clone(), sink);
            queue.claimed = Some(claim.id.clone());
            (claim, Self::bump(&mut inner, session))
        };
        self.publish(snapshot);
        Ok(claim)
    }

    fn claimed(&self, session: &str) -> Option<String> {
        self.lock()
            .sessions
            .get(session)
            .and_then(|queue| queue.claimed.clone())
    }

    fn clear(&self, session: &str) {
        let snapshot = {
            let mut inner = self.lock();
            let Some(lane) = inner.sessions.get_mut(session) else {
                return;
            };
            if lane.items.is_empty() && lane.claimed.is_none() {
                return;
            }
            lane.items.clear();
            lane.claimed = None;
            // Emptied rather than forgotten: the revision has to keep climbing or a
            // client still watching would read the empty queue as stale news and go
            // on rendering rows that no longer exist.
            Self::bump(&mut inner, session)
        };
        self.publish(snapshot);
    }

    fn sessions(&self) -> Vec<String> {
        self.lock()
            .sessions
            .iter()
            .filter(|(_, queue)| !queue.items.is_empty())
            .map(|(session, _)| session.clone())
            .collect()
    }
}

/// A per-process constant, so an id minted before a restart names nothing after one.
fn process_epoch() -> String {
    static EPOCH: AtomicU64 = AtomicU64::new(0);
    let seen = EPOCH.load(Ordering::Relaxed);
    if seen != 0 {
        return format!("{seen:x}");
    }
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(1);
    EPOCH.store(stamp, Ordering::Relaxed);
    format!("{stamp:x}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn queue() -> Arc<SessionQueues> {
        SessionQueues::with_epoch("test")
    }

    #[test]
    fn the_same_text_queued_twice_is_two_addressable_rows() {
        let q = queue();
        let first = q.enqueue("s1", Content::text("ping"), "telegram");
        let second = q.enqueue("s1", Content::text("ping"), "telegram");
        assert_ne!(first.id, second.id);

        q.remove("s1", &first.id).expect("the first row");
        let snapshot = q.snapshot("s1");
        assert_eq!(snapshot.items.len(), 1);
        assert_eq!(snapshot.items[0].id, second.id);
    }

    #[test]
    fn an_edit_keeps_the_id_the_position_and_the_source() {
        let q = queue();
        q.enqueue("s1", Content::text("first"), "native");
        let target = q.enqueue("s1", Content::text("typo"), "telegram");
        q.enqueue("s1", Content::text("third"), "native");

        let edited = q.edit("s1", &target.id, "fixed").expect("edit");
        assert_eq!(edited.id, target.id);
        assert_eq!(edited.source, "telegram");
        assert_eq!(edited.created_at, target.created_at);
        assert_eq!(edited.content.as_text(), Some("fixed"));

        let snapshot = q.snapshot("s1");
        assert_eq!(snapshot.position(&target.id), Some(1), "still second");
        assert_eq!(
            snapshot
                .items
                .iter()
                .map(|i| i.content.as_text().unwrap())
                .collect::<Vec<_>>(),
            ["first", "fixed", "third"]
        );
    }

    #[test]
    fn editing_bytes_is_refused_and_editing_a_ghost_is_not_found() {
        let q = queue();
        let keys = q.enqueue("s1", Content::keys("escape", vec![0x1b]), "native");
        assert_eq!(q.edit("s1", &keys.id, "hello"), Err(QueueError::NotText));
        assert_eq!(q.edit("s1", "nope", "hello"), Err(QueueError::NotFound));
        assert_eq!(
            q.edit("ghost", &keys.id, "hello"),
            Err(QueueError::NotFound),
            "a missing session answers like a claim race"
        );
        assert_eq!(QueueError::NotFound.code(), "queue-item-not-found");
    }

    #[test]
    fn a_claimed_occurrence_is_no_longer_addressable() {
        let q = queue();
        let item = q.enqueue("s1", Content::text("go"), "telegram");
        let claim = q.claim_next("s1").expect("a claim");
        assert_eq!(claim.id, item.id);
        assert_eq!(q.claimed("s1").as_deref(), Some(item.id.as_str()));

        assert_eq!(q.edit("s1", &item.id, "stop"), Err(QueueError::NotFound));
        assert_eq!(q.remove("s1", &item.id), Err(QueueError::NotFound));

        // It is still on screen while it is in flight, so a client renders it rather
        // than dropping it and re-rendering it if the delivery is abandoned.
        let snapshot = q.snapshot("s1");
        assert_eq!(snapshot.items[0].state, ItemState::InFlight);
        assert_eq!(snapshot.items[0].content.as_text(), Some("go"));

        claim.settle(Delivery::Delivered);
        assert!(q.snapshot("s1").is_empty());
        assert_eq!(q.claimed("s1"), None);
    }

    #[test]
    fn an_abandoned_claim_returns_the_occurrence_to_its_own_position() {
        let q = queue();
        let first = q.enqueue("s1", Content::text("one"), "native");
        let second = q.enqueue("s1", Content::text("two"), "native");

        let claim = q.claim_next("s1").expect("a claim");
        assert_eq!(claim.id, first.id);
        claim.settle(Delivery::Abandoned);

        let snapshot = q.snapshot("s1");
        assert_eq!(snapshot.position(&first.id), Some(0));
        assert_eq!(snapshot.position(&second.id), Some(1));
        assert!(snapshot.items[0].is_pending());
        // Editable again: nothing was typed, so nothing is in flight to rewrite.
        assert!(q.edit("s1", &first.id, "one and a half").is_ok());
    }

    #[test]
    fn a_dropped_claim_discards_rather_than_re_queueing() {
        let q = queue();
        let item = q.enqueue("s1", Content::text("once"), "native");
        drop(q.claim_next("s1").expect("a claim"));
        assert!(
            q.snapshot("s1").is_empty(),
            "a claim of unknown fate may already have typed; re-queueing it duplicates"
        );
        assert_eq!(q.claimed("s1"), None);
        assert_eq!(q.remove("s1", &item.id), Err(QueueError::NotFound));
    }

    #[test]
    fn one_claim_per_session_and_nothing_to_claim_is_not_an_error() {
        let q = queue();
        assert_eq!(q.claim_next("s1").unwrap_err(), ClaimRefused::Empty);
        let item = q.enqueue("s1", Content::text("one"), "native");
        q.enqueue("s1", Content::text("two"), "native");
        let claim = q.claim_next("s1").expect("a claim");
        assert_eq!(
            q.claim_next("s1").unwrap_err(),
            ClaimRefused::AlreadyClaimed {
                id: item.id.clone()
            },
            "a retry keeps its own claim rather than taking a second one"
        );
        claim.settle(Delivery::Delivered);
        assert_eq!(
            q.claim_next("s1").expect("the next").content.as_text(),
            Some("two")
        );
    }

    #[test]
    fn every_mutation_publishes_the_whole_queue_and_a_higher_revision() {
        let q = queue();
        let seen: Arc<Mutex<Vec<QueueSnapshot>>> = Arc::new(Mutex::new(Vec::new()));
        let sink = seen.clone();
        q.on_change(Arc::new(move |snapshot: &QueueSnapshot| {
            sink.lock().unwrap().push(snapshot.clone());
        }));

        let a = q.enqueue("s1", Content::text("one"), "native");
        q.enqueue("s1", Content::text("two"), "native");
        q.edit("s1", &a.id, "uno").unwrap();
        q.remove("s1", &a.id).unwrap();

        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 4);
        assert_eq!(
            seen.iter().map(|s| s.revision).collect::<Vec<_>>(),
            [1, 2, 3, 4]
        );
        // Complete, every time: the third snapshot carries the untouched row too.
        assert_eq!(seen[2].items.len(), 2);
        assert_eq!(seen[2].items[0].content.as_text(), Some("uno"));
        assert_eq!(seen[3].items.len(), 1);
    }

    #[test]
    fn a_session_nobody_queued_to_has_an_empty_snapshot_rather_than_none() {
        let q = queue();
        let snapshot = q.snapshot("ghost");
        assert_eq!(snapshot.session, "ghost");
        assert_eq!(snapshot.revision, 0);
        assert!(snapshot.is_empty());
        assert!(q.sessions().is_empty());
    }

    #[test]
    fn clearing_a_session_publishes_one_last_empty_snapshot() {
        let q = queue();
        let seen: Arc<Mutex<Vec<QueueSnapshot>>> = Arc::new(Mutex::new(Vec::new()));
        let sink = seen.clone();
        q.on_change(Arc::new(move |snapshot: &QueueSnapshot| {
            sink.lock().unwrap().push(snapshot.clone());
        }));
        q.enqueue("s1", Content::text("one"), "native");
        q.clear("s1");
        q.clear("s1");

        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 2, "clearing nothing publishes nothing");
        assert!(seen[1].is_empty());
    }

    #[test]
    fn ids_from_two_epochs_do_not_name_each_others_rows() {
        let before = SessionQueues::with_epoch("boot1");
        let stale = before.enqueue("s1", Content::text("one"), "telegram").id;

        let after = SessionQueues::with_epoch("boot2");
        let fresh = after.enqueue("s1", Content::text("something else"), "telegram");
        assert_ne!(stale, fresh.id);
        assert_eq!(
            after.edit("s1", &stale, "rewritten"),
            Err(QueueError::NotFound),
            "an id minted before the restart names nothing after it"
        );
    }
}
