//! Sleeping a session on purpose, and why it is not a kill.
//!
//! `kill` and `sleep` both end the pty, and for a month that made them the same
//! operation to this daemon: the desktop's global pause had no frame to ask with, so
//! it sent `kill` and wrote `dormant` onto its OWN mirror row (juancode-nizo). The
//! daemon's row then said "ended", which is the row its rehydrate reads at the next
//! boot and the row a play would have to find its paused set in. Pausing five agents
//! and coming back to five dead ones is the shape of that bug.
//!
//! So the difference is asserted here, from the daemon's own state: the same two
//! sessions, one slept and one killed, and every place the answer is kept has to keep
//! telling them apart — the live row, the store behind it, and the rehydrate after a
//! restart.

mod harness;

use std::sync::Arc;

use harness::{wait_for_exit, Harness};
use juancoded_core::model::SessionStatus;
use juancoded_state::registry::StateError;
use juancoded_state::SessionsApi;

fn dormant(sessions: &Arc<dyn SessionsApi>, id: &str) -> bool {
    sessions.meta(id).expect("the row is still there").dormant
}

fn status(sessions: &Arc<dyn SessionsApi>, id: &str) -> SessionStatus {
    sessions.meta(id).expect("the row is still there").status
}

#[tokio::test]
async fn a_slept_session_and_a_killed_one_leave_different_rows_behind() {
    let harness = Harness::new("sleep-vs-kill");
    let mut events = harness.sessions.subscribe();
    let paused = harness.create("/tmp", 80, 24, 1).await;
    let ended = harness.create("/tmp", 80, 24, 1).await;

    harness.sessions.sleep(&paused).expect("sleep");
    harness.sessions.kill(&ended).expect("kill");
    wait_for_exit(&mut events, &paused).await;
    wait_for_exit(&mut events, &ended).await;

    // Both ptys are gone: sleeping is what frees the ~300MB, so a dormant row that
    // still held a live CLI would be a pause that paused nothing.
    assert_eq!(status(&harness.sessions, &paused), SessionStatus::Exited);
    assert_eq!(status(&harness.sessions, &ended), SessionStatus::Exited);
    // And this is the whole difference the frame exists for.
    assert!(
        dormant(&harness.sessions, &paused),
        "a session the client asked to sleep must read dormant, not dead"
    );
    assert!(
        !dormant(&harness.sessions, &ended),
        "a kill is a kill; nothing may relabel it as asleep"
    );
}

#[tokio::test]
async fn the_flag_is_set_before_the_pty_dies_so_the_exited_row_carries_it() {
    // The ordering half. `kill` finalises the row the pty's death leaves; a flag
    // written after it would land on a row that had already been broadcast as an
    // ordinary exit, which is exactly what a client renders as a crash.
    let harness = Harness::new("sleep-order");
    let mut events = harness.sessions.subscribe();
    let id = harness.create("/tmp", 80, 24, 1).await;

    harness.sessions.sleep(&id).expect("sleep");
    // Read before the exit is even observed: the flag is on the row already.
    assert!(dormant(&harness.sessions, &id));
    wait_for_exit(&mut events, &id).await;
    assert!(dormant(&harness.sessions, &id));
}

#[tokio::test]
async fn a_session_whose_pty_is_already_gone_is_refused_rather_than_flagged() {
    // Dormancy promises there is a conversation to come back to. Stamping it onto a
    // row that crashed, or one the user ended by hand, would put that row in the set
    // a global play revives — which is how "resume exactly what I paused" stops
    // being exactly.
    let harness = Harness::new("sleep-dead");
    let mut events = harness.sessions.subscribe();
    let id = harness.create("/tmp", 80, 24, 1).await;
    harness.sessions.kill(&id).expect("kill");
    wait_for_exit(&mut events, &id).await;

    assert_eq!(harness.sessions.sleep(&id), Err(StateError::NotRunning));
    assert!(!dormant(&harness.sessions, &id));
    assert_eq!(
        harness.sessions.sleep("no-such-session"),
        Err(StateError::NotRunning)
    );
}

#[tokio::test]
async fn the_restore_plan_reads_a_paused_session_as_dormant_after_a_restart() {
    // The daemon's rehydrate is the other consumer of that row, and the one the
    // desktop's mirror could never have reached: every row comes back exited because
    // its pty died with the previous process, so `dormant` is the only thing left
    // that says which of them somebody paused.
    let harness = Harness::new("sleep-restart");
    let mut events = harness.sessions.subscribe();
    let paused = harness.create("/tmp", 80, 24, 1).await;
    let ended = harness.create("/tmp", 80, 24, 1).await;
    harness.sessions.sleep(&paused).expect("sleep");
    harness.sessions.kill(&ended).expect("kill");
    wait_for_exit(&mut events, &paused).await;
    wait_for_exit(&mut events, &ended).await;

    let harness = harness.restart();
    assert_eq!(status(&harness.sessions, &paused), SessionStatus::Exited);
    assert!(
        dormant(&harness.sessions, &paused),
        "the pause did not survive the restart, so nothing knows what to wake"
    );
    assert!(!dormant(&harness.sessions, &ended));
}

#[tokio::test]
async fn waking_a_paused_session_clears_the_flag() {
    let harness = Harness::new("sleep-wake");
    let mut events = harness.sessions.subscribe();
    let id = harness.create("/tmp", 80, 24, 1).await;
    harness.sessions.sleep(&id).expect("sleep");
    wait_for_exit(&mut events, &id).await;

    harness
        .sessions
        .reactivate(&id, 1, 80, 24)
        .expect("reactivate");
    assert_eq!(status(&harness.sessions, &id), SessionStatus::Running);
    assert!(
        !dormant(&harness.sessions, &id),
        "the moon has to go away the moment the CLI is back"
    );
}
