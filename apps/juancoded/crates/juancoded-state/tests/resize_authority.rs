//! Regression: one resize authority (juancode-1th, juancode-8llo), and the live
//! matrix juancode-po1 asked for, run against the Rust core instead of by hand.
//!
//! The old shape was last-write-wins: every attach resized the shared pty and every
//! client re-asserted its own size, so two differently-sized viewers made the CLI's
//! TUI flap and layout transitions left stale rows behind. The invariant these tests
//! hold is narrow and total: after any resize path, the pty's grid and the rendered
//! grid are the same numbers, and only one client can move them.

mod harness;

use harness::{wait_for_exit, wait_for_screen, Harness};
use juancoded_state::SessionsApi;

const DESKTOP: u64 = 1;
const PHONE: u64 = 2;

/// The property the whole ticket turns on: the grid a client renders and the grid the
/// pty believes it has are one number, read from one place.
fn assert_one_grid(sessions: &std::sync::Arc<dyn SessionsApi>, id: &str, at: &str) {
    let grid = sessions.grid(id).expect("a session has a grid");
    let snapshot = sessions
        .snapshot(id)
        .expect("a session has a rendered grid");
    assert_eq!(
        (grid.0 as usize, grid.1 as usize),
        (snapshot.cols, snapshot.rows),
        "after {at}: the authority and the rendered grid disagree"
    );
}

#[tokio::test]
async fn a_second_viewer_is_denied_rather_than_flapping_the_grid() {
    let harness = Harness::new("arbitrate");
    let id = harness.create("/tmp", 80, 24, DESKTOP).await;

    // The creating client owns the grid it spawned the session at.
    let owned = harness.sessions.resize(&id, DESKTOP, 100, 30);
    assert!(owned.applied && !owned.denied);
    assert_eq!(harness.sessions.grid(&id), Some((100, 30)));

    let denied = harness.sessions.resize(&id, PHONE, 70, 20);
    assert_eq!(
        (denied.applied, denied.denied),
        (false, true),
        "a non-owner must be told retrying is futile"
    );
    assert_eq!(
        harness.sessions.grid(&id),
        Some((100, 30)),
        "the denied resize must not have moved anything"
    );
    assert_one_grid(&harness.sessions, &id, "a denied resize");

    // A bare attach from the secondary viewer is arbitrated the same way: it reads,
    // it does not write.
    harness
        .sessions
        .attach(&id, PHONE, 70, 20)
        .expect("a secondary viewer may still attach");
    assert_eq!(harness.sessions.grid(&id), Some((100, 30)));
    assert_one_grid(&harness.sessions, &id, "a secondary attach");
}

#[tokio::test]
async fn the_grid_passes_to_the_next_client_when_its_owner_disconnects() {
    let harness = Harness::new("handover");
    let id = harness.create("/tmp", 80, 24, DESKTOP).await;
    assert!(harness.sessions.resize(&id, DESKTOP, 90, 26).applied);
    assert!(harness.sessions.resize(&id, PHONE, 70, 20).denied);

    harness.sessions.release_client(DESKTOP);

    let taken = harness.sessions.resize(&id, PHONE, 70, 20);
    assert!(taken.applied && !taken.denied, "{taken:?}");
    assert_eq!(harness.sessions.grid(&id), Some((70, 20)));
    assert_one_grid(&harness.sessions, &id, "a handover");
}

#[tokio::test]
async fn resizing_a_session_that_does_not_exist_is_not_a_denial() {
    let harness = Harness::new("missing");
    let outcome = harness.sessions.resize("no-such-session", DESKTOP, 80, 24);
    assert_eq!(
        (outcome.applied, outcome.denied),
        (false, false),
        "denied would tell the client to give up; it should re-assert instead"
    );
}

#[tokio::test]
async fn the_po1_matrix_ends_at_the_right_grid_with_no_step_out_of_step() {
    let harness = Harness::new("matrix");
    let mut events = harness.sessions.subscribe();
    // Spawn small and resize immediately: the spawn-race leg of the matrix, where a
    // CLI that installs its SIGWINCH handler late can miss the first resize.
    let id = harness.create("/tmp", 80, 24, DESKTOP).await;
    assert!(harness.sessions.resize(&id, DESKTOP, 132, 43).applied);
    assert_one_grid(&harness.sessions, &id, "an immediate post-spawn resize");

    // The layout legs, as the sizes they actually produce: a panel opening, a divider
    // dragged through intermediate widths, a fullscreen toggle, and back.
    let legs: &[(&str, u16, u16)] = &[
        ("panel open", 96, 43),
        ("divider drag", 95, 43),
        ("divider drag", 88, 43),
        ("divider drag", 74, 43),
        ("panel close", 132, 43),
        ("fullscreen", 213, 56),
        ("fullscreen off", 132, 43),
    ];
    for (leg, cols, rows) in legs {
        let outcome = harness.sessions.resize(&id, DESKTOP, *cols, *rows);
        assert!(!outcome.denied, "{leg}: the owner was denied its own grid");
        assert_eq!(
            harness.sessions.grid(&id),
            Some((*cols, *rows)),
            "{leg}: the authority did not take"
        );
        assert_one_grid(&harness.sessions, &id, leg);
    }
    // Re-asserting the settled grid is a no-op rather than a fresh SIGWINCH: every
    // forced repaint is a chance for a streaming TUI to garble for nothing.
    let again = harness.sessions.resize(&id, DESKTOP, 132, 43);
    assert!(
        !again.applied && !again.denied,
        "an unchanged grid must not be re-written to the pty: {again:?}"
    );
    assert_one_grid(&harness.sessions, &id, "a redundant re-assert");

    // The reactivate leg: a dead session revived at a new grid comes back at that
    // grid, and the two halves still agree.
    harness.sessions.kill(&id).expect("kill");
    wait_for_exit(&mut events, &id).await;
    let revived = harness
        .sessions
        .reactivate(&id, DESKTOP, 100, 30)
        .expect("claude pins its conversation id, so this is resumable")
        .expect("it was not already live");
    assert_eq!(
        revived.meta.status,
        juancoded_core::model::SessionStatus::Running
    );
    assert_eq!(harness.sessions.grid(&id), Some((100, 30)));
    assert_one_grid(&harness.sessions, &id, "a reactivate at a new grid");

    // The reconnect leg: a client that comes back and re-asserts the grid it left at
    // is applied, not denied, once the old connection is gone.
    harness.sessions.release_client(DESKTOP);
    let reconnected = harness.sessions.resize(&id, 99, 100, 30);
    assert!(!reconnected.denied);
    assert_one_grid(&harness.sessions, &id, "a reconnect replay");
}

#[tokio::test]
async fn a_resize_that_raced_the_spawn_is_re_asserted_once_the_screen_settles() {
    let harness = Harness::new("reapply");
    let id = harness.create("/tmp", 80, 24, DESKTOP).await;
    harness.sessions.kill(&id).expect("kill");
    let mut events = harness.sessions.subscribe();
    let _ = harness::wait_for(&mut events, 20, |e| {
        matches!(e, juancoded_state::SessionEvent::Exit { session_id, .. } if session_id == &id)
    })
    .await;

    // A resize with no pty behind it: not denied, not applied, and remembered — this
    // is the case the client used to paper over with a stack of retry timers.
    let outcome = harness.sessions.resize(&id, DESKTOP, 150, 45);
    assert_eq!((outcome.applied, outcome.denied), (false, false));
    assert_eq!(harness.sessions.grid(&id), Some((150, 45)));

    // Revived at the remembered grid, the pty gets it for real.
    harness
        .sessions
        .reactivate(&id, DESKTOP, 150, 45)
        .expect("resumable")
        .expect("not already live");
    wait_for_screen(&harness.sessions, &id, "", 5).await;
    assert_eq!(harness.sessions.grid(&id), Some((150, 45)));
    assert_one_grid(&harness.sessions, &id, "a revive at the remembered grid");
}
