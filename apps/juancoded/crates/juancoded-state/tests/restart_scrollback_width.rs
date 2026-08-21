//! Regression: persisted scrollback re-parsed at the wrong width (juancode-grnu),
//! and the ticket's own "sessions survive a daemon restart" bar.
//!
//! The bug was that the byte ring was stored with no record of the grid it was
//! written at, so anything that re-parsed it later had to guess a width. A guess that
//! misses lays hard wraps and absolute cursor moves in the wrong cells, which is the
//! same garble the live path was fixed for.
//!
//! These tests assert the property, not the implementation: the picture a restarted
//! daemon shows is the picture the running one showed, and it is only that when the
//! width travels with the bytes.

mod harness;

use harness::{wait_for_exit, wait_for_screen, Harness};

/// Long enough to hard-wrap at 40 columns and not at 100, so a wrong width is
/// visible as a different picture rather than a subtle one.
const WRAPPING_LINE: &str = "0123456789abcdefghij0123456789ABCDEFGHIJ0123456789klmnopqrst\r\n";

#[tokio::test]
async fn a_session_survives_a_restart_with_its_scrollback_at_its_own_width() {
    let harness = Harness::new("restart");
    let mut events = harness.sessions.subscribe();
    let id = harness.create("/tmp", 40, 10, 1);

    harness
        .sessions
        .input(&id, WRAPPING_LINE.as_bytes())
        .expect("input");
    wait_for_screen(&harness.sessions, &id, "klmnopqrst", 20).await;

    let before = harness
        .sessions
        .snapshot(&id)
        .expect("a live session has a grid")
        .text();
    assert_eq!(harness.sessions.grid(&id), Some((40, 10)));
    // Two rows means it really wrapped: a test that passes at any width proves
    // nothing about the width.
    assert!(
        before.lines().count() >= 2,
        "the fixture must wrap at 40 columns: {before:?}"
    );

    harness.sessions.kill(&id).expect("kill");
    wait_for_exit(&mut events, &id).await;

    let harness = harness.restart();

    let meta = harness
        .sessions
        .meta(&id)
        .expect("the session survived the restart");
    assert_eq!(meta.id, id);
    assert!(
        !harness.sessions.is_running(&id),
        "a restored session's pty died with the previous daemon"
    );
    assert_eq!(
        harness.sessions.grid(&id),
        Some((40, 10)),
        "the grid came back from the store, not from a default"
    );
    let after = harness
        .sessions
        .snapshot(&id)
        .expect("the replay grid is rebuilt on demand")
        .text();
    assert_eq!(
        after, before,
        "the restored screen must be the screen that was there"
    );
    assert!(harness
        .sessions
        .attach(&id, 1, 40, 10)
        .expect("attach")
        .scrollback
        .contains("klmnopqrst"));
}

#[tokio::test]
async fn the_width_is_what_makes_the_replay_right_and_it_is_not_guessed() {
    let harness = Harness::new("width");
    let mut events = harness.sessions.subscribe();
    let id = harness.create("/tmp", 40, 10, 1);

    harness
        .sessions
        .input(&id, WRAPPING_LINE.as_bytes())
        .expect("input");
    wait_for_screen(&harness.sessions, &id, "klmnopqrst", 20).await;
    let at_40 = harness.sessions.snapshot(&id).expect("grid").text();

    harness.sessions.kill(&id).expect("kill");
    wait_for_exit(&mut events, &id).await;

    // The control: laying the same bytes out at a different width really does produce
    // a different picture, so the equality assertions above are load bearing.
    let outcome = harness.sessions.resize(&id, 1, 100, 10);
    assert!(
        !outcome.denied,
        "the owner may re-lay a dead session's replay"
    );
    let at_100 = harness.sessions.snapshot(&id).expect("grid").text();
    assert_ne!(
        at_40, at_100,
        "if width did not matter, nothing here would be a regression test"
    );

    // And back: the replay is rebuilt from the bytes each time rather than reflowed
    // from whatever the last reader left behind.
    harness.sessions.resize(&id, 1, 40, 10);
    assert_eq!(harness.sessions.snapshot(&id).expect("grid").text(), at_40);

    // A restart takes the *last* width the reader asked for, because that is the
    // width the bytes were stored with.
    harness.sessions.resize(&id, 1, 100, 10);
    harness.sessions.attach(&id, 1, 100, 10).expect("attach");
    let harness = harness.restart();
    assert_eq!(harness.sessions.grid(&id), Some((100, 10)));
    assert_eq!(
        harness.sessions.snapshot(&id).expect("grid").text(),
        at_100,
        "the reader never has to guess: the width came out of the store"
    );
}

#[tokio::test]
async fn a_restarted_session_is_exited_rather_than_claiming_to_be_running() {
    let harness = Harness::new("restart-status");
    let id = harness.create("/tmp", 60, 12, 1);
    assert!(harness.sessions.is_running(&id));
    // Deliberately no kill: this is the hard-restart case, where the pty died with
    // the daemon and nobody got to write an exit.
    harness.sessions.attach(&id, 1, 60, 12).expect("attach");

    let harness = harness.restart();
    let meta = harness.sessions.meta(&id).expect("session row survived");
    assert_eq!(
        meta.status,
        juancoded_core::model::SessionStatus::Exited,
        "a row that claimed to be running would be a session no client could ever \
         get bytes out of"
    );
    // And an attach tells the client so, instead of leaving it waiting for output.
    let attached = harness.sessions.attach(&id, 1, 60, 12).expect("attach");
    assert!(attached.replay_exit.is_some());
}
