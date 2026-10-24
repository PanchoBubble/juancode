mod harness;
use harness::{wait_for, Harness};
use juancoded_core::model::SessionActivity;
use juancoded_state::registry::SessionEvent;
use juancoded_transcripts::{Source, TranscriptEvent, TranscriptRecord};

#[tokio::test]
async fn status_is_metadata_not_readiness_and_completed_records_survive_exit_but_not_restart() {
    let h = Harness::new("program-status");
    let id = h.create(&h.dir.to_string_lossy(), 80, 24, 1).await;
    let mut rx = h.sessions.subscribe();
    h.sessions
        .input(
            &id,
            b"\x1b]7501;state=blocked:kind=permission:app=claude\x07\n",
        )
        .unwrap();
    wait_for(&mut rx, 10, |e| matches!(e, SessionEvent::ProgramStatusChanged { records, .. } if records.first().is_some_and(|r| r.state == "blocked"))).await;
    assert_eq!(
        h.sessions.activity(&id),
        Some(SessionActivity::Idle),
        "a program cannot grant itself agent authority"
    );
    h.sessions.on_transcript(
        &id,
        &[TranscriptRecord {
            session: id.clone(),
            source: Source::ClaudeJsonl,
            seq: 0,
            at_ms: None,
            turn: None,
            event: TranscriptEvent::ToolCall {
                call: "call".into(),
                name: "Task".into(),
                input: "{}".into(),
            },
        }],
    );
    h.sessions
        .input(&id, b"\x1b]7501;state=done\x07\n")
        .unwrap();
    wait_for(&mut rx, 10, |e| matches!(e, SessionEvent::ProgramStatusChanged { records, .. } if records.first().is_some_and(|r| r.state == "done"))).await;
    assert_eq!(
        h.sessions.activity(&id),
        Some(SessionActivity::Busy),
        "completion must not release transcript-held work"
    );
    h.sessions.kill(&id).unwrap();
    wait_for(
        &mut rx,
        10,
        |e| matches!(e, SessionEvent::Exit { session_id, .. } if session_id == &id),
    )
    .await;
    assert_eq!(h.sessions.program_status(&id)[0].state, "done");
    // Reconstructing the terminal from persisted bytes is not fresh program evidence.
    let h = h.restart();
    let _ = h.sessions.snapshot(&id);
    assert!(h.sessions.program_status(&id).is_empty());
}

#[tokio::test]
async fn input_acknowledges_completion_and_clear_publishes_empty_snapshot() {
    let h = Harness::new("program-status-input");
    let id = h.create(&h.dir.to_string_lossy(), 80, 24, 1).await;
    let mut rx = h.sessions.subscribe();
    h.sessions
        .input(&id, b"\x1b]7501;state=done\x07\n")
        .unwrap();
    wait_for(
        &mut rx,
        10,
        |e| matches!(e, SessionEvent::ProgramStatusChanged { records, .. } if !records.is_empty()),
    )
    .await;
    h.sessions.input(&id, b"next\n").unwrap();
    wait_for(
        &mut rx,
        10,
        |e| matches!(e, SessionEvent::ProgramStatusChanged { records, .. } if records.is_empty()),
    )
    .await;
    h.sessions
        .input(&id, b"\x1b]7501;state=working\x07\n")
        .unwrap();
    wait_for(
        &mut rx,
        10,
        |e| matches!(e, SessionEvent::ProgramStatusChanged { records, .. } if !records.is_empty()),
    )
    .await;
    h.sessions
        .input(&id, b"\x1b]7501;state=clear\x07\n")
        .unwrap();
    wait_for(
        &mut rx,
        10,
        |e| matches!(e, SessionEvent::ProgramStatusChanged { records, .. } if records.is_empty()),
    )
    .await;
}
