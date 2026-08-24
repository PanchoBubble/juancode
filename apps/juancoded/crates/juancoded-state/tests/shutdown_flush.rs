//! What a shutdown owes a live session: the bytes it printed since the last
//! throttled write.
//!
//! Scrollback is persisted on a 2-second throttle while a session runs
//! (`FLUSH_EVERY`), and nothing used to force it on the way out — no plugin unmount
//! writes it, because unmounting is effects going away and there is no unmount hook.
//! That was survivable while the daemon outlived the app: the next client just read
//! the live ring. It stopped being survivable when quitting the app started ending the
//! daemon, because then every quit truncates every live transcript by up to two
//! seconds, silently.
//!
//! So the daemon's one shutdown path calls `flush_all`, and these tests are the
//! property: what was on screen when the daemon stopped is what comes back.

mod harness;

use std::time::{Duration, Instant};

use harness::{wait_for_screen, Harness};

/// Written first, so the ring's very first store write is not the line under test.
const FIRST: &str = "an-earlier-line\r\n";
/// The line the throttle has NOT written yet when the daemon is asked to stop.
const LAST: &str = "the-newest-line-nobody-flushed\r\n";

/// The throttle the whole thing turns on. Mirrors `registry::FLUSH_EVERY`.
const THROTTLE: Duration = Duration::from_secs(2);

#[tokio::test]
async fn a_shutdown_flush_persists_what_the_throttle_had_not_written() {
    let harness = Harness::new("shutdown-flush");
    let id = harness.create("/tmp", 80, 24, 1).await;

    harness
        .sessions
        .input(&id, FIRST.as_bytes())
        .expect("input");
    wait_for_screen(&harness.sessions, &id, "an-earlier-line", 20).await;
    harness.sessions.input(&id, LAST.as_bytes()).expect("input");
    wait_for_screen(&harness.sessions, &id, "the-newest-line", 20).await;

    // The count is part of the contract: the shutdown log says how many sessions it
    // persisted, and a flush that silently wrote nothing would read the same as one
    // that had nothing to write.
    assert_eq!(
        harness.sessions.flush_all(),
        1,
        "one live session, one row written"
    );

    let harness = harness.restart();
    let replayed = harness
        .sessions
        .attach(&id, 1, 80, 24)
        .expect("attach")
        .scrollback;
    assert!(
        replayed.contains("the-newest-line-nobody-flushed"),
        "the last thing on screen before the daemon stopped came back: {replayed:?}"
    );
}

/// The control. Without the flush the newest line is exactly what is lost, which is
/// what makes the assertion above load bearing rather than a restatement of the
/// throttle happening to have fired.
#[tokio::test]
async fn without_the_flush_the_newest_bytes_are_the_ones_that_do_not_survive() {
    let harness = Harness::new("no-flush");
    // Timed from before the session exists, because the stand-in's own banner is the
    // output that triggers the ring's first store write. Everything after it is inside
    // the throttle window unless this measured span outruns it.
    let started = Instant::now();
    let id = harness.create("/tmp", 80, 24, 1).await;
    harness
        .sessions
        .input(&id, FIRST.as_bytes())
        .expect("input");
    wait_for_screen(&harness.sessions, &id, "an-earlier-line", 20).await;
    harness.sessions.input(&id, LAST.as_bytes()).expect("input");
    wait_for_screen(&harness.sessions, &id, "the-newest-line", 20).await;
    let within_throttle = started.elapsed() < THROTTLE;

    // Deliberately no flush, no kill and no attach — attaching forces a write, and a
    // control that flushed by accident would assert nothing.
    let harness = harness.restart();
    let replayed = harness
        .sessions
        .attach(&id, 1, 80, 24)
        .expect("attach")
        .scrollback;

    // Only meaningful while the throttle provably had not expired. On a machine loaded
    // enough to spend two seconds between two writes it fires on its own, and failing
    // here would be reporting the load rather than the behaviour.
    if within_throttle {
        assert!(
            !replayed.contains("the-newest-line-nobody-flushed"),
            "the throttle cannot have written this yet, so `flush_all` is what saves \
             it: {replayed:?}"
        );
    } else {
        eprintln!(
            "control skipped: {:?} elapsed, past the {THROTTLE:?} throttle",
            started.elapsed()
        );
    }
}
