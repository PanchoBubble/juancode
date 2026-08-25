//! The transcript signal, through the real tree: no pty output at all, and a session
//! that reads busy anyway.
//!
//! The unit tests in `juancoded-core` drive the state machine directly. What these
//! measure is the wiring around it — that a record reaches the detector, that the turn
//! it opens is broadcast on the session bus, and that the settle it arms is the same
//! one the byte path arms — because a signal the registry never hands over is a signal
//! nobody has.

mod harness;

use std::time::Duration;

use harness::{wait_for, wait_for_exit, Harness};
use juancoded_core::model::SessionActivity;
use juancoded_state::registry::SessionEvent;
use juancoded_transcripts::{Source, TranscriptEvent, TranscriptRecord};

fn record(session: &str, seq: u64, event: TranscriptEvent) -> TranscriptRecord {
    TranscriptRecord {
        session: session.to_string(),
        source: Source::ClaudeJsonl,
        seq,
        at_ms: None,
        turn: Some("t1".into()),
        event,
    }
}

fn assistant(session: &str, seq: u64) -> TranscriptRecord {
    record(
        session,
        seq,
        TranscriptEvent::Assistant {
            step: Some("req_1".into()),
            text: "on it".into(),
        },
    )
}

fn tool_call(session: &str, seq: u64) -> TranscriptRecord {
    record(
        session,
        seq,
        TranscriptEvent::ToolCall {
            call: "toolu_1".into(),
            name: "Task".into(),
            input: "{}".into(),
        },
    )
}

/// Which activity state each broadcast carried, for a predicate to read.
fn activity_of(event: &SessionEvent, id: &str) -> Option<(SessionActivity, bool)> {
    match event {
        SessionEvent::Activity {
            session_id,
            state,
            notify,
            ..
        } if session_id == id => Some((*state, *notify)),
        _ => None,
    }
}

#[tokio::test]
async fn a_record_opens_a_turn_and_the_settle_closes_it_with_no_pty_output_at_all() {
    let h = Harness::new("transcript-activity");
    let cwd = h.dir.to_string_lossy().into_owned();
    let id = h.create(&cwd, 80, 24, 1).await;
    let mut rx = h.sessions.subscribe();

    // The stand-in CLI has printed nothing since it went quiet, and nothing it printed
    // looks like a working footer. The only evidence of work is the record.
    h.sessions.on_transcript(&id, &[assistant(&id, 0)]);
    let opened = wait_for(&mut rx, 10, |e| {
        activity_of(e, &id).is_some_and(|(state, _)| state == SessionActivity::Busy)
    })
    .await;
    assert_eq!(
        activity_of(&opened, &id),
        Some((SessionActivity::Busy, false)),
        "a transcript-opened turn is still a turn, and opening one never pings"
    );
    assert_eq!(h.sessions.activity(&id), Some(SessionActivity::Busy));

    // The settle the record armed is the byte path's settle: a quiet screen ends the
    // turn, and ending one is the edge a phone rings on.
    let closed = wait_for(&mut rx, 10, |e| {
        activity_of(e, &id).is_some_and(|(state, _)| state == SessionActivity::Idle)
    })
    .await;
    assert_eq!(
        activity_of(&closed, &id),
        Some((SessionActivity::Idle, true))
    );
}

#[tokio::test]
async fn a_session_whose_tool_call_is_still_open_does_not_settle_to_idle() {
    let h = Harness::new("transcript-hold");
    let cwd = h.dir.to_string_lossy().into_owned();
    let id = h.create(&cwd, 80, 24, 1).await;
    let mut rx = h.sessions.subscribe();

    h.sessions.on_transcript(&id, &[tool_call(&id, 0)]);
    wait_for(&mut rx, 10, |e| {
        activity_of(e, &id).is_some_and(|(state, _)| state == SessionActivity::Busy)
    })
    .await;

    // Screen-quiet and transcript-quiet, which is what a delegated subagent looks like
    // for minutes at a time. The ordinary settle would have ended the turn six times
    // over by now; the open call is what stops it, and the whole point of the signal is
    // that a session doing real work never reads dormant.
    tokio::time::sleep(Duration::from_millis(1_500)).await;
    assert_eq!(
        h.sessions.activity(&id),
        Some(SessionActivity::Busy),
        "an unresolved tool call holds the turn"
    );
}

#[tokio::test]
async fn an_exited_session_is_not_revived_busy_by_the_last_records_of_its_final_turn() {
    let h = Harness::new("transcript-exited");
    let cwd = h.dir.to_string_lossy().into_owned();
    let id = h.create(&cwd, 80, 24, 1).await;
    let mut rx = h.sessions.subscribe();

    h.sessions.kill(&id).expect("kill");
    wait_for_exit(&mut rx, &id).await;

    // The pump polls once more on exit, precisely so the final turn's records are not
    // lost. Those records are history by the time anyone reads them.
    h.sessions.on_transcript(&id, &[assistant(&id, 0)]);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(h.sessions.activity(&id), Some(SessionActivity::Idle));
}
