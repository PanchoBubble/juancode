//! kimi's working state, end to end: a spinner frame painted by the pty reaches the
//! grid, the grid reaches the detector, and the transition is the broadcast clients
//! turn into the yellow dot.
//!
//! kimi never paints `esc to interrupt`, so before its own frames were read a kimi
//! session sat at idle for the whole of every turn.

mod harness;

use std::time::Duration;

use harness::{wait_for, wait_for_screen, Harness};
use juancoded_core::model::{ProviderId, SessionActivity};
use juancoded_state::registry::SessionEvent;

async fn next_activity(
    events: &mut tokio::sync::broadcast::Receiver<SessionEvent>,
    id: &str,
) -> (SessionActivity, bool) {
    let event = wait_for(
        events,
        20,
        |e| matches!(e, SessionEvent::Activity { session_id, .. } if session_id == id),
    )
    .await;
    match event {
        SessionEvent::Activity { state, notify, .. } => (state, notify),
        other => panic!("expected activity, got {other:?}"),
    }
}

#[tokio::test]
async fn a_kimi_session_reads_busy_while_its_spinner_is_painted_and_idle_once_it_is_gone() {
    let harness = Harness::new("kimi-activity");
    let mut events = harness.sessions.subscribe();
    let id = harness.create_as(ProviderId::Kimi, "/tmp", 80, 24, 1).await;

    // The frame lands on the bottom row, just above where kimi's input box would be.
    harness
        .sessions
        .input(
            &id,
            "\x1b[20;1H  ⠙ Working… · Tip: /init: generate AGENTS.md\r\n".as_bytes(),
        )
        .expect("input");
    assert_eq!(
        next_activity(&mut events, &id).await,
        (SessionActivity::Busy, false),
        "entering a turn is never a ping"
    );
    assert_eq!(harness.sessions.activity(&id), Some(SessionActivity::Busy));

    // The spinner is erased and the turn is over, which is a ping.
    harness
        .sessions
        .input(&id, b"\x1b[2J\x1b[H\r\n")
        .expect("input");
    assert_eq!(
        next_activity(&mut events, &id).await,
        (SessionActivity::Idle, true)
    );
}

#[tokio::test]
async fn the_same_frame_on_a_claude_session_is_not_work() {
    let harness = Harness::new("kimi-frame-on-claude");
    let id = harness.create("/tmp", 80, 24, 1).await;

    harness
        .sessions
        .input(&id, "\x1b[20;1H  ⠙ Working… · Tip: /init\r\n".as_bytes())
        .expect("input");
    wait_for_screen(&harness.sessions, &id, "Working…", 20).await;
    // Past the settle, so a transition that was going to happen has happened.
    tokio::time::sleep(Duration::from_millis(600)).await;
    assert_eq!(harness.sessions.activity(&id), Some(SessionActivity::Idle));
}
