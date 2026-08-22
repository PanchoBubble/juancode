//! The steering queue's rules, at the registry edge.
//!
//! The wire surface above this is a translation: it subscribes, it pushes whatever
//! list the registry hands it, and it does not decide what a queue is. So the rules
//! that matter are here — insertion order is delivery order, whitespace is not a
//! message, and only a change that happened is announced. A snapshot pushed for a
//! queue that never moved is worse than a missing one: it teaches a client to
//! distrust the frames it does get.
//!
//! Nothing here delivers. The Rust core has no paste-then-verified-Enter engine yet,
//! which is why it does not advertise the `queue` capability, and why these tests say
//! nothing about a message reaching the pty.

mod harness;

use std::time::Duration;

use harness::Harness;
use juancoded_state::registry::SessionEvent;
use tokio::sync::broadcast::Receiver;

/// How many queue announcements land for `id` inside `window`. Always waits the full
/// window: the interesting assertion is usually that nothing arrives, and every other
/// event on the bus (output, activity) has to be walked past to know that.
async fn queue_changes(rx: &mut Receiver<SessionEvent>, id: &str, window: Duration) -> usize {
    let deadline = tokio::time::Instant::now() + window;
    let mut seen = 0;
    while let Ok(Ok(event)) = tokio::time::timeout_at(deadline, rx.recv()).await {
        if matches!(&event, SessionEvent::QueueChanged { session_id } if session_id == id) {
            seen += 1;
        }
    }
    seen
}

#[tokio::test]
async fn insertion_order_is_delivery_order_and_every_change_is_announced_once() {
    let harness = Harness::new("queue-order");
    let id = harness.create("/tmp", 80, 24, 1).await;
    let mut rx = harness.sessions.subscribe();

    for text in ["first", "second", "third"] {
        harness
            .sessions
            .queue_message(&id, text)
            .expect("queueing to a live session")
            .expect("a real message is queued");
    }
    let texts: Vec<String> = harness
        .sessions
        .queue(&id)
        .into_iter()
        .map(|q| q.text)
        .collect();
    assert_eq!(texts, ["first", "second", "third"]);
    assert_eq!(
        queue_changes(&mut rx, &id, Duration::from_millis(300)).await,
        3,
        "one announcement per queued message, so a watcher repaints once per change"
    );

    // The queue is addressed by the ids its own snapshot handed out.
    let middle = harness.sessions.queue(&id)[1].id.clone();
    assert!(harness
        .sessions
        .dequeue_message(&id, &middle)
        .expect("dequeue"));
    let texts: Vec<String> = harness
        .sessions
        .queue(&id)
        .into_iter()
        .map(|q| q.text)
        .collect();
    assert_eq!(texts, ["first", "third"], "removal keeps the rest in order");
}

#[tokio::test]
async fn a_whitespace_only_message_is_not_queued_and_announces_nothing() {
    let harness = Harness::new("queue-blank");
    let id = harness.create("/tmp", 80, 24, 1).await;
    let mut rx = harness.sessions.subscribe();

    for blank in ["   ", "\n", "\t \r\n"] {
        assert!(
            harness
                .sessions
                .queue_message(&id, blank)
                .expect("a blank text is not an error")
                .is_none(),
            "{blank:?} is not a message"
        );
    }
    assert!(harness.sessions.queue(&id).is_empty());
    assert_eq!(
        queue_changes(&mut rx, &id, Duration::from_millis(300)).await,
        0,
        "a queue that did not move must not push a snapshot"
    );

    // A message with whitespace around it is a message; what is stored is what would
    // be typed in.
    let item = harness
        .sessions
        .queue_message(&id, "  ship it  ")
        .expect("queueing")
        .expect("a real message");
    assert_eq!(item.text, "ship it");
}

#[tokio::test]
async fn dequeuing_a_message_that_is_not_there_changes_nothing() {
    let harness = Harness::new("queue-missing");
    let id = harness.create("/tmp", 80, 24, 1).await;
    let item = harness
        .sessions
        .queue_message(&id, "keep me")
        .expect("queueing")
        .expect("a real message");
    let mut rx = harness.sessions.subscribe();

    assert!(
        !harness
            .sessions
            .dequeue_message(&id, "not-a-message-id")
            .expect("an unknown id is not an error"),
        "there was nothing to remove"
    );
    // A live message id belonging to another session must miss too, or a stale id
    // would cancel somebody else's pending work.
    let other = harness.create("/tmp", 80, 24, 1).await;
    assert!(!harness
        .sessions
        .dequeue_message(&other, &item.id)
        .expect("cross-session dequeue"));

    assert_eq!(
        harness.sessions.queue(&id).len(),
        1,
        "the message is still pending"
    );
    assert_eq!(
        queue_changes(&mut rx, &id, Duration::from_millis(300)).await,
        0,
        "nothing was removed, so nothing is announced"
    );
}

#[tokio::test]
async fn queueing_to_a_session_nobody_knows_is_refused() {
    let harness = Harness::new("queue-unknown");
    // A queue row hangs off its session, so this is refused up front rather than
    // failing as a foreign-key violation inside the store.
    assert!(harness
        .sessions
        .queue_message("no-such-session", "hello")
        .is_err());
    assert!(harness.sessions.queue("no-such-session").is_empty());
}
