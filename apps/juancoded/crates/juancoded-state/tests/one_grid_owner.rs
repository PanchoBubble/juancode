//! Regression: one grid, one owner.
//!
//! Two bug families collapse into the same structural claim here.
//!
//! **juancode-9goj** was a crash loop: the same pty stream was parsed twice on
//! different threads — a headless model on the session queue and the GUI terminal
//! view on the main actor — and both mutated SwiftTerm's process-global OSC 8
//! hyperlink atom table with no shared lock. A hyperlink-bearing stream corrupted
//! that dictionary and aborted the app. The fix there was a process-wide parse lock
//! with a documented residual race. Here there is nothing to lock: the grid is fed
//! from the session's pump and nowhere else, and every reader gets a value snapshot.
//!
//! **juancode-d89 / o9h2 / jpvj** were freezes: the daemon wrote pty output into a UI
//! surface whose consumer had been suspended, the write parked in a futex forever, and
//! teardown then waited on it from the main thread. The claim here is that a client
//! cannot be in the way at all — output is published on a broadcast that drops a slow
//! receiver's backlog rather than applying backpressure to the producer.

mod harness;

use std::sync::Arc;
use std::time::Duration;

use harness::{wait_for_screen, Harness};
use juancoded_state::registry::SessionEvent;

/// The exact byte shape that crashed the two-parser build: an OSC 8 hyperlink, whose
/// URL goes into a process-global interning table.
const HYPERLINK: &str = "\x1b]8;;https://example.invalid/one\x1b\\link one\x1b]8;;\x1b\\\r\n";

#[tokio::test]
async fn a_flood_of_hyperlinks_read_from_every_side_at_once_stays_consistent() {
    let harness = Harness::new("hyperlinks");
    let id = harness.create("/tmp", 100, 30, 1).await;

    // Readers on other tasks, hammering the projection while the pump feeds it. In
    // the two-parser world the readers were parsers too, and this is the shape that
    // corrupted the shared atom table.
    let readers: Vec<_> = (0..8)
        .map(|_| {
            let sessions = Arc::clone(&harness.sessions);
            let id = id.clone();
            tokio::spawn(async move {
                let mut seen = 0usize;
                for _ in 0..400 {
                    if let Some(snapshot) = sessions.snapshot(&id) {
                        // A snapshot is a value: its rows cannot be half-written,
                        // whatever the pump is doing to the grid at the time.
                        assert_eq!(snapshot.lines.len(), snapshot.rows);
                        seen += 1;
                    }
                    tokio::task::yield_now().await;
                }
                seen
            })
        })
        .collect();

    for i in 0..60 {
        harness
            .sessions
            .input(&id, HYPERLINK.as_bytes())
            .expect("input");
        harness
            .sessions
            .input(&id, format!("plain {i}\r\n").as_bytes())
            .expect("input");
    }
    wait_for_screen(&harness.sessions, &id, "plain 59", 20).await;

    for reader in readers {
        assert!(reader.await.expect("no reader panicked") > 0);
    }
    let text = harness.sessions.snapshot(&id).expect("grid").text();
    assert!(text.contains("link one"), "{text:?}");
    assert!(text.contains("plain 59"), "{text:?}");
}

#[tokio::test]
async fn a_client_that_never_reads_cannot_stall_the_grid_or_the_pty() {
    let harness = Harness::new("wedged");
    let id = harness.create("/tmp", 80, 24, 1).await;

    // A subscriber standing in for a wedged UI surface: subscribed, never drained.
    // Its backlog is 4096 frames, so this flood is comfortably past it.
    let wedged = harness.sessions.subscribe();

    for i in 0..5_000 {
        harness
            .sessions
            .input(&id, format!("line {i}\r\n").as_bytes())
            .expect("input must not block on a reader");
    }
    // The grid is fed from the pump, so it sees everything the wedged client did not.
    wait_for_screen(&harness.sessions, &id, "line 4999", 30).await;

    // And the session is still fully usable afterwards: input, resize, exit.
    assert!(harness.sessions.resize(&id, 1, 90, 26).applied);
    harness
        .sessions
        .input(&id, b"still alive\r\n")
        .expect("input");
    wait_for_screen(&harness.sessions, &id, "still alive", 20).await;

    // Whatever the idle client did not read is bounded by its own backlog: the
    // producer never grew a queue on its behalf and never waited for it. That is the
    // difference between a wedged surface stalling itself and a wedged surface
    // freezing the daemon.
    assert!(
        wedged.len() <= 4096,
        "an idle client accumulated {} frames, so the producer is buffering for it",
        wedged.len()
    );
}

#[tokio::test]
async fn the_registry_keeps_serving_while_a_reader_holds_a_snapshot() {
    let harness = Harness::new("snapshot-hold");
    let id = harness.create("/tmp", 80, 24, 1).await;
    harness.sessions.input(&id, b"first\r\n").expect("input");
    wait_for_screen(&harness.sessions, &id, "first", 20).await;

    // Holding a projection is holding a value, not the grid: the writer is free.
    let held = harness.sessions.snapshot(&id).expect("grid");
    harness.sessions.input(&id, b"second\r\n").expect("input");
    wait_for_screen(&harness.sessions, &id, "second", 20).await;
    assert!(
        !held.text().contains("second"),
        "a snapshot that changed under its reader is not a value"
    );
    assert!(harness
        .sessions
        .snapshot(&id)
        .expect("grid")
        .text()
        .contains("second"));
}

#[tokio::test]
async fn output_events_and_the_grid_never_diverge() {
    let harness = Harness::new("no-divergence");
    let mut events = harness.sessions.subscribe();
    let id = harness.create("/tmp", 80, 24, 1).await;

    harness
        .sessions
        .input(&id, b"marker-in-both\r\n")
        .expect("input");
    // The bytes a client is sent are the same bytes the grid was fed, from the one
    // task that owns both: there is no second path for either to drift down.
    let mut streamed = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        let event = tokio::time::timeout_at(deadline, events.recv())
            .await
            .expect("timed out")
            .expect("bus closed");
        if let SessionEvent::Output { bytes, .. } = event {
            streamed.extend_from_slice(&bytes);
            if String::from_utf8_lossy(&streamed).contains("marker-in-both") {
                break;
            }
        }
    }
    let scrollback = harness
        .sessions
        .attach(&id, 1, 80, 24)
        .expect("attach")
        .scrollback;
    assert!(scrollback.contains("marker-in-both"));
    assert!(harness
        .sessions
        .snapshot(&id)
        .expect("grid")
        .text()
        .contains("marker-in-both"));
}
