//! The two facts a client cannot poll for: whose grid it is, and what a session's
//! row says now.
//!
//! Both already lived in the state layer and neither left it. A resize outcome only
//! ever reaches the client that asked, so a second viewer could see that its own
//! request was refused but never that the grid had been let go; and a row a client
//! attached with was frozen at that moment, so a title the CLI chose for itself or a
//! conversation id discovered after the spawn arrived only on the next attach.
//!
//! These assert the fan-out, not the arbitration — `resize_authority` owns that.

mod harness;

use harness::{wait_for, wait_for_screen, Harness};
use juancoded_core::model::SessionMeta;
use juancoded_state::registry::SessionEvent;
use tokio::sync::broadcast::Receiver;

const DESKTOP: u64 = 1;
const PHONE: u64 = 2;

/// The next grid change for `id`, as `(owner, cols, rows)`.
async fn next_grid(rx: &mut Receiver<SessionEvent>, id: &str) -> (Option<u64>, u16, u16) {
    match wait_for(
        rx,
        20,
        |e| matches!(e, SessionEvent::GridChange { session_id, .. } if session_id == id),
    )
    .await
    {
        SessionEvent::GridChange {
            owner, cols, rows, ..
        } => (owner, cols, rows),
        _ => unreachable!("the predicate only matches a grid change"),
    }
}

/// The next meta change for `id`.
async fn next_meta(rx: &mut Receiver<SessionEvent>, id: &str) -> SessionMeta {
    match wait_for(
        rx,
        20,
        |e| matches!(e, SessionEvent::Meta { session_id, .. } if session_id == id),
    )
    .await
    {
        SessionEvent::Meta { meta, .. } => meta,
        _ => unreachable!("the predicate only matches a meta change"),
    }
}

#[tokio::test]
async fn the_grid_is_claimed_publicly_granted_publicly_and_released_publicly() {
    let harness = Harness::new("grid-fanout");
    let mut events = harness.sessions.subscribe();
    let id = harness.create("/tmp", 80, 24, DESKTOP).await;

    // Claimed by the client that spawned the session, at the size it spawned it.
    assert_eq!(next_grid(&mut events, &id).await, (Some(DESKTOP), 80, 24));

    assert!(harness.sessions.resize(&id, DESKTOP, 100, 30).applied);
    assert_eq!(next_grid(&mut events, &id).await, (Some(DESKTOP), 100, 30));

    // A refused request did not change the arbitrated state, so there is nothing to
    // announce. The owner's release is the next thing anyone hears about this grid.
    assert!(harness.sessions.resize(&id, PHONE, 70, 20).denied);
    harness.sessions.release_client(DESKTOP);
    assert_eq!(
        next_grid(&mut events, &id).await,
        (None, 100, 30),
        "a release is a null owner, carrying the grid it let go of"
    );

    // And the release was real: the viewer that was refused a moment ago now holds it.
    assert!(harness.sessions.resize(&id, PHONE, 90, 28).applied);
    assert_eq!(next_grid(&mut events, &id).await, (Some(PHONE), 90, 28));
}

#[tokio::test]
async fn a_denied_resize_names_the_owner_the_client_has_to_wait_for() {
    let harness = Harness::new("grid-owner-on-deny");
    let id = harness.create("/tmp", 80, 24, DESKTOP).await;

    let owned = harness.sessions.resize(&id, DESKTOP, 100, 30);
    assert_eq!(owned.owner, Some(DESKTOP), "an owner is told it is itself");

    let denied = harness.sessions.resize(&id, PHONE, 70, 20);
    assert!(denied.denied);
    assert_eq!(
        denied.owner,
        Some(DESKTOP),
        "a denied client learns who to wait for, not only that it lost"
    );

    // Nothing to resize is not a denial, and it has no owner to report.
    let nothing = harness.sessions.resize("no-such-session", PHONE, 70, 20);
    assert_eq!(
        (nothing.applied, nothing.denied, nothing.owner),
        (false, false, None)
    );
}

#[tokio::test]
async fn a_window_title_the_cli_sets_for_itself_becomes_the_session_title() {
    let harness = Harness::new("osc-title");
    let mut events = harness.sessions.subscribe();
    let id = harness.create("/tmp", 80, 24, DESKTOP).await;

    let before = harness.sessions.meta(&id).expect("a row").title;
    assert_eq!(before, "tmp", "the row starts at the directory basename");

    // The stand-in echoes the line back, so this is the CLI naming its own window —
    // nobody asked the core to rename anything.
    harness
        .sessions
        .input(&id, b"\x1b]2;named by the cli\x07\n")
        .expect("input");

    let meta = next_meta(&mut events, &id).await;
    assert_eq!(meta.title, "named by the cli");
    assert_eq!(
        harness.sessions.meta(&id).expect("a row").title,
        "named by the cli",
        "the broadcast and the row it describes are the same fact"
    );

    // A repaint of the same title is the CLI's business, not a new fact.
    harness
        .sessions
        .input(&id, b"\x1b]2;named by the cli\x07\n")
        .expect("input");
    harness
        .sessions
        .input(&id, b"\x1b]2;renamed\x07\n")
        .expect("input");
    let meta = next_meta(&mut events, &id).await;
    assert_eq!(
        meta.title, "renamed",
        "the unchanged repaint should not have been announced"
    );
}

#[tokio::test]
async fn a_meta_change_reaches_a_client_that_never_attached() {
    let harness = Harness::new("meta-broadcast");
    let mut events = harness.sessions.subscribe();
    let id = harness.create("/tmp", 80, 24, DESKTOP).await;

    // A second subscriber that never attached to anything: the row is a fact about
    // the session, not a reply to a request.
    let mut observer = harness.sessions.subscribe();
    harness
        .sessions
        .input(&id, b"\x1b]2;visible to everyone\x07\n")
        .expect("input");

    assert_eq!(
        next_meta(&mut events, &id).await.title,
        "visible to everyone"
    );
    assert_eq!(
        next_meta(&mut observer, &id).await.title,
        "visible to everyone"
    );
}

#[tokio::test]
async fn an_empty_or_unchanged_title_is_not_a_meta_change() {
    let harness = Harness::new("title-noise");
    let mut events = harness.sessions.subscribe();
    let id = harness.create("/tmp", 80, 24, DESKTOP).await;

    // An OSC that resets the title, and one that sets it to whitespace: neither is a
    // name, so neither may move the row.
    harness
        .sessions
        .input(&id, b"\x1b]2;\x07\n")
        .expect("input");
    harness
        .sessions
        .input(&id, b"\x1b]2;   \x07\n")
        .expect("input");
    harness
        .sessions
        .input(&id, b"\x1b]2;real\x07\n")
        .expect("input");

    let meta = next_meta(&mut events, &id).await;
    assert_eq!(
        meta.title, "real",
        "the blank titles should not have been announced"
    );
    // And nothing follows it: the same title arriving again is not news. The marker
    // is how we know the repaint has been parsed rather than how long we waited for
    // it: anything the repaint was going to say is on the bus by the time it paints.
    harness
        .sessions
        .input(&id, b"\x1b]2;real\x07\nparsed the repaint\n")
        .expect("input");
    wait_for_screen(&harness.sessions, &id, "parsed the repaint", 20).await;
    while let Ok(event) = events.try_recv() {
        assert!(
            !matches!(event, SessionEvent::Meta { .. }),
            "an unchanged title was announced: {event:?}"
        );
    }
}
