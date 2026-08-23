//! Typing a queued steering message into a live session, and settling the claim that
//! says what became of it.
//!
//! This is the other side of [`crate::seed`]. The engine is the same one, and
//! deliberately so: a queued message and a create's `initialInput` both have to survive
//! a CLI that collapses a paste into a chip, a CLI that echoes nothing at all, and a CR
//! that arrives inside a still-open bracketed paste. What is different is not the typing
//! but the two things around it.
//!
//! **The precondition.** A seed goes into a session that is booting; a queued message
//! goes into one that has been up for a while and is between turns. So a busy session
//! means opposite things in the two cases, and the engine is told which case it is in
//! rather than guessing. Read the wrong way it fails silently: a busy live session read
//! as "already seeded" reports a delivery that typed nothing.
//!
//! **The claim.** Before a byte is written the occurrence is claimed, which is what
//! makes `editQueued` and `dequeueMessage` answer `queue-item-not-found` for text that
//! is already in the agent's box. The claim is settled exactly once, and which of the
//! three outcomes it gets is decided by evidence and not by how the failure felt:
//!
//! - `Delivered` when the bytes reached the agent and the turn started.
//! - `Abandoned` only for [`SeedOutcome::Refused`], which the engine returns exactly
//!   when no write ever succeeded. The occurrence goes back to pending at its own
//!   position with its own id, editable again.
//! - `Discarded` for [`SeedOutcome::Failed`], where bytes went out and the delivery
//!   still did not finish. Re-queueing that is how this area has previously shipped a
//!   duplicate paste, so it retires unsent with the reason instead.
//!
//! A claim outstanding is also the anti-duplicate-paste guard across retries:
//! `claim_next` refuses a second claim while one is held, so a payload that landed in
//! the box but has not been submitted keeps its row rather than being pasted again.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use juancoded_cordis::services::queue::{ClaimRefused, Content, Delivery, QueueApi};
use juancoded_core::model::SessionActivity;
use juancoded_state::SessionsApi;
use tracing::{debug, warn};

use crate::seed::{deliver_text, Precondition, SeedOutcome, SeedTiming};

/// How often the pump looks for a session that can take a delivery.
///
/// A tick rather than an event edge, because the two events that would drive it are
/// exactly the two this loop causes: settling a claim publishes a snapshot, and a
/// delivered message makes the session busy. Waking on those is how a refusal that
/// recurs becomes a spin. One cheap read per session with a queue, four times a second,
/// is the whole cost, and it touches registry state rather than a pty so it cannot wake
/// a sleeping session.
pub const PUMP_TICK: Duration = Duration::from_millis(250);

/// First wait after a refusal, doubling to [`MAX_BACKOFF`].
const BASE_BACKOFF: Duration = Duration::from_secs(2);
/// Ceiling on the wait, so a session that cannot be written to is retried forever but
/// cheaply rather than either abandoned or hammered.
const MAX_BACKOFF: Duration = Duration::from_secs(30);

/// Whether `session` could take a delivery right now.
///
/// Checked before the claim, not after: claiming takes the head row out of the client's
/// hands, and doing that for the length of someone else's turn would make an editable
/// message un-editable for no delivery at all.
pub fn deliverable(
    sessions: &Arc<dyn SessionsApi>,
    queue: &Arc<dyn QueueApi>,
    session: &str,
) -> bool {
    if queue.claimed(session).is_some() {
        return false;
    }
    if !queue.snapshot(session).items.iter().any(|i| i.is_pending()) {
        return false;
    }
    sessions.is_running(session) && sessions.activity(session) != Some(SessionActivity::Busy)
}

/// Claim the head of `session`'s queue, type it, and settle.
///
/// `None` means no claim was taken at all, so nothing was settled and nothing moved.
pub async fn deliver_next(
    sessions: &Arc<dyn SessionsApi>,
    queue: &Arc<dyn QueueApi>,
    session: &str,
    timing: SeedTiming,
) -> Option<Delivery> {
    let claim = match queue.claim_next(session) {
        Ok(claim) => claim,
        // Neither is an error. Empty is the ordinary answer, and a claim already
        // outstanding is the guard doing its job: some other pass owns that row and may
        // already have put its bytes on screen.
        Err(ClaimRefused::Empty) => return None,
        Err(ClaimRefused::AlreadyClaimed { id }) => {
            debug!(session, item = %id, "queue: a claim is already outstanding");
            return None;
        }
    };

    let outcome = match &claim.content {
        Content::Text { text } => {
            deliver_text(
                Arc::clone(sessions),
                session,
                text,
                timing,
                Precondition::LiveIdle,
            )
            .await
        }
        // A keypress is its own submission: the bytes are the action, there is no text
        // to find on screen and no Enter to add. So it is one write, and the write
        // succeeding is the whole of the evidence there is to have.
        Content::Keys { label, bytes } => match sessions.input(session, bytes) {
            Ok(()) => {
                debug!(session, keys = %label, "queue: keys written");
                SeedOutcome::Submitted {
                    verified_land: false,
                }
            }
            Err(e) => SeedOutcome::Refused {
                reason: format!("the pty refused the keys: {e}"),
            },
        },
    };

    let delivery = match outcome {
        SeedOutcome::Submitted { .. } => Delivery::Delivered,
        SeedOutcome::Refused { reason } => {
            debug!(session, item = %claim.id, reason = %reason, "queue: nothing typed, back to pending");
            Delivery::Abandoned
        }
        SeedOutcome::Failed { reason } => {
            warn!(session, item = %claim.id, reason = %reason, "queue: typed and not submitted, discarding");
            Delivery::Discarded { reason }
        }
    };
    claim.settle(delivery.clone());
    Some(delivery)
}

/// Run deliveries for every session that can take one, until the task is dropped.
///
/// Deliveries run as their own tasks so one CLI's boot window cannot hold up another
/// session's queue, and an in-flight set keeps a tick from starting a second delivery
/// for a session that is already mid-paste.
pub fn spawn_pump(
    sessions: Arc<dyn SessionsApi>,
    queue: Arc<dyn QueueApi>,
    timing: SeedTiming,
    tick: Duration,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let in_flight: Arc<Mutex<HashSet<String>>> = Arc::new(Mutex::new(HashSet::new()));
        // A refusal is about the session rather than the message, so retrying it at the
        // tick rate would be a spin over a condition that is not changing. Backoff is
        // per session and cleared the moment a delivery gets through.
        let backoff: Arc<Mutex<HashMap<String, (u32, Instant)>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let mut ticker = tokio::time::interval(tick);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            ticker.tick().await;
            for session in queue.sessions() {
                if !deliverable(&sessions, &queue, &session) {
                    continue;
                }
                if let Some((_, until)) = lock(&backoff).get(&session) {
                    if Instant::now() < *until {
                        continue;
                    }
                }
                if !lock(&in_flight).insert(session.clone()) {
                    continue;
                }
                let sessions = Arc::clone(&sessions);
                let queue = Arc::clone(&queue);
                let live = Arc::clone(&in_flight);
                let waits = Arc::clone(&backoff);
                tokio::spawn(async move {
                    let outcome = deliver_next(&sessions, &queue, &session, timing).await;
                    match outcome {
                        Some(Delivery::Abandoned) => {
                            let mut waits = lock(&waits);
                            let entry = waits.entry(session.clone()).or_insert((0, Instant::now()));
                            entry.0 = entry.0.saturating_add(1);
                            entry.1 = Instant::now() + wait_for(entry.0);
                        }
                        // Delivered, discarded, or never claimed: whatever was wrong
                        // with this session is not still wrong.
                        _ => {
                            lock(&waits).remove(&session);
                        }
                    }
                    lock(&live).remove(&session);
                });
            }
        }
    })
}

fn wait_for(strikes: u32) -> Duration {
    BASE_BACKOFF
        .saturating_mul(1u32 << strikes.min(4))
        .min(MAX_BACKOFF)
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::FakeChild;
    use juancoded_cordis::services::queue::{ItemState, SessionQueues};
    use std::sync::atomic::Ordering;

    fn fast() -> SeedTiming {
        SeedTiming {
            ready_max_ms: 1_000,
            ready_poll_ms: 20,
            land_ms: 300,
            land_deadline_ms: 900,
            submit_settle_ms: 10,
            submit_ms: 600,
            poll_ms: 10,
            live_settle_ms: 300,
            ..SeedTiming::default()
        }
    }

    fn queue() -> Arc<dyn QueueApi> {
        SessionQueues::with_epoch("test")
    }

    #[tokio::test]
    async fn a_delivered_message_retires_and_the_next_one_becomes_the_head() {
        let child = FakeChild::new(true);
        let sessions = child.api();
        let queue = queue();
        queue.enqueue("s", Content::text("first"), "telegram");
        queue.enqueue("s", Content::text("second"), "telegram");

        assert_eq!(
            deliver_next(&sessions, &queue, "s", fast()).await,
            Some(Delivery::Delivered)
        );
        // The row retires rather than lingering as delivered: what is left is what is
        // still steerable, which is the only list a client is asked to render.
        let items = queue.snapshot("s").items;
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].content.as_text(), Some("second"));
        assert_eq!(
            queue.claimed("s"),
            None,
            "a settled claim is not outstanding"
        );

        // One paste and one Enter, and the paste carries no CR of its own.
        let writes = child.written();
        assert_eq!(writes.len(), 2, "{:?}", child.stream());
        assert_eq!(writes[1], b"\r".to_vec());
    }

    /// The distinction the whole boundary turns on. Nothing was typed, so the
    /// occurrence goes back to pending with its own id at its own position, and stays
    /// editable.
    #[tokio::test]
    async fn a_message_the_engine_could_not_type_comes_back_pending_with_its_own_id() {
        let child = FakeChild::new(true);
        child.busy.store(true, Ordering::Relaxed);
        let sessions = child.api();
        let queue = queue();
        let head = queue.enqueue("s", Content::text("first"), "telegram");
        queue.enqueue("s", Content::text("second"), "telegram");

        assert_eq!(
            deliver_next(&sessions, &queue, "s", fast()).await,
            Some(Delivery::Abandoned)
        );
        assert!(child.written().is_empty(), "nothing was typed");

        let items = queue.snapshot("s").items;
        assert_eq!(items.len(), 2, "an abandoned occurrence is not consumed");
        assert_eq!(items[0].id, head.id, "and it keeps its id");
        assert_eq!(
            items[0].state,
            ItemState::Pending,
            "and becomes editable again"
        );
        assert_eq!(
            items[0].content.as_text(),
            Some("first"),
            "and its position: it was the head and it still is"
        );
        // Editable again is the point, so prove it rather than infer it from the state.
        assert!(queue.edit("s", &head.id, "revised").is_ok());
    }

    /// The other direction, and the one that has shipped a duplicate paste before. The
    /// bytes are in the box, so the occurrence retires with a reason instead of going
    /// back to a queue that would type it a second time.
    #[tokio::test]
    async fn a_message_that_was_typed_and_not_submitted_is_discarded_not_requeued() {
        let child = FakeChild::new(true);
        child.swallows_enter.store(true, Ordering::Relaxed);
        let sessions = child.api();
        let queue = queue();
        queue.enqueue("s", Content::text("ship it"), "telegram");

        let outcome = deliver_next(&sessions, &queue, "s", fast()).await;
        match outcome {
            Some(Delivery::Discarded { reason }) => {
                assert!(reason.contains("never submitted"), "{reason}")
            }
            other => panic!("typed bytes may not be re-queued: {other:?}"),
        }
        assert!(
            queue.snapshot("s").items.is_empty(),
            "it retires unsent rather than waiting to be typed again"
        );
    }

    /// The anti-duplicate-paste guard. A payload that landed in the box but has not
    /// been submitted keeps its claim, so a second pass finds nothing to take rather
    /// than pasting a second copy.
    #[tokio::test]
    async fn a_claim_already_outstanding_stops_a_second_pass_from_pasting_again() {
        let child = FakeChild::new(true);
        let sessions = child.api();
        let queue = queue();
        queue.enqueue("s", Content::text("ship it"), "telegram");

        let held = queue.claim_next("s").expect("the head is claimable");
        assert!(
            deliver_next(&sessions, &queue, "s", fast()).await.is_none(),
            "no claim was taken, so nothing was settled and nothing was typed"
        );
        assert!(child.written().is_empty());
        // And the pre-check agrees, so the pump does not spend a tick finding out.
        assert!(!deliverable(&sessions, &queue, "s"));
        drop(held);
    }

    /// A dropped claim discards rather than re-queues, on purpose: a claim whose fate
    /// nobody recorded may already have put bytes on screen.
    #[tokio::test]
    async fn a_claim_dropped_without_settling_discards_the_occurrence() {
        let queue = queue();
        queue.enqueue("s", Content::text("ship it"), "telegram");
        drop(queue.claim_next("s").expect("the head is claimable"));
        assert!(queue.snapshot("s").items.is_empty());
        assert_eq!(queue.claimed("s"), None);
    }

    #[tokio::test]
    async fn an_empty_or_unwritable_session_is_never_claimed() {
        let child = FakeChild::new(true);
        let sessions = child.api();
        let queue = queue();
        // Nothing queued: the ordinary answer, and not an error.
        assert!(deliver_next(&sessions, &queue, "s", fast()).await.is_none());
        assert!(!deliverable(&sessions, &queue, "s"));

        queue.enqueue("s", Content::text("ship it"), "telegram");
        assert!(deliverable(&sessions, &queue, "s"));
        child.running.store(false, Ordering::Relaxed);
        assert!(
            !deliverable(&sessions, &queue, "s"),
            "an exited session keeps its queue but cannot be typed into"
        );
    }

    /// A keypress is its own submission: one write, no land check, no Enter added.
    #[tokio::test]
    async fn a_queued_keypress_is_written_once_and_nothing_is_appended() {
        let child = FakeChild::new(true);
        let sessions = child.api();
        let queue = queue();
        queue.enqueue("s", Content::keys("esc", vec![0x1b]), "native");

        assert_eq!(
            deliver_next(&sessions, &queue, "s", fast()).await,
            Some(Delivery::Delivered)
        );
        assert_eq!(child.written(), vec![vec![0x1b]]);
        assert!(queue.snapshot("s").items.is_empty());
    }
}
