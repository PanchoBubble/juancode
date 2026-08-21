//! The session registry's own surface: create and its guards, adopt-external,
//! reactivate, the permission-mode restart, exit handling, the per-project retention
//! cap, and the activity state machine's notify edges.

mod harness;

use std::time::Duration;

use harness::{wait_for, wait_for_exit, wait_for_screen, Harness};
use juancoded_core::model::{ProviderId, SessionActivity, SessionStatus};
use juancoded_state::registry::{AdoptRequest, CreateRequest, SessionEvent, StateError};

fn request(cwd: &str) -> CreateRequest {
    CreateRequest {
        provider: ProviderId::Claude,
        cwd: cwd.into(),
        cols: 80,
        rows: 24,
        skip_permissions: false,
        model: None,
        dispatch_id: None,
        owner: 1,
    }
}

#[tokio::test]
async fn a_create_into_a_missing_directory_is_a_clear_error_not_a_doomed_spawn() {
    let harness = Harness::new("cwd-guard");
    let err = harness
        .sessions
        .create(request("/definitely/not/here"))
        .expect_err("a missing cwd must not spawn");
    assert_eq!(
        err.to_string(),
        "\"/definitely/not/here\" is not an existing directory"
    );
    assert!(harness.sessions.ids().is_empty());
}

#[tokio::test]
async fn a_dispatch_id_starts_one_session_and_the_second_delivery_is_told_why_not() {
    let harness = Harness::new("dispatch");
    let mut first = request("/tmp");
    first.dispatch_id = Some("dispatch-abc".into());
    let meta = harness.sessions.create(first.clone()).expect("create");
    assert_eq!(meta.dispatch_id.as_deref(), Some("dispatch-abc"));

    let err = harness
        .sessions
        .create(first)
        .expect_err("a repeat dispatch must not start a second session");
    assert_eq!(
        err,
        StateError::DispatchAlreadyProcessed("dispatch-abc".into())
    );
    assert_eq!(
        err.to_string(),
        "Dispatch dispatch-abc was already processed"
    );
    assert_eq!(harness.sessions.ids().len(), 1);
}

#[tokio::test]
async fn every_activity_broadcast_carries_the_dispatch_id_for_the_sessions_whole_life() {
    let harness = Harness::new("dispatch-stamp");
    let mut events = harness.sessions.subscribe();
    let mut req = request("/tmp");
    req.dispatch_id = Some("dispatch-xyz".into());
    let id = harness.sessions.create(req).expect("create").id;

    // Any activity edge will do; a turn is the one a caller most wants routed back.
    harness
        .sessions
        .input(&id, b"working... esc to interrupt\r\n")
        .expect("input");
    let event = wait_for(
        &mut events,
        20,
        |e| matches!(e, SessionEvent::Activity { session_id, .. } if session_id == &id),
    )
    .await;
    match event {
        SessionEvent::Activity { dispatch_id, .. } => {
            assert_eq!(dispatch_id.as_deref(), Some("dispatch-xyz"))
        }
        other => panic!("expected an activity event, got {other:?}"),
    }
}

#[tokio::test]
async fn an_external_conversation_is_adopted_once_at_the_age_it_really_started() {
    let harness = Harness::new("adopt");
    let req = AdoptRequest {
        provider: ProviderId::Claude,
        cli_session_id: "external-0001".into(),
        cwd: "/tmp".into(),
        start_ms: 1_700_000_000_000,
        cols: 80,
        rows: 24,
        owner: 1,
    };
    let meta = harness
        .sessions
        .adopt_external(req.clone())
        .expect("adopt")
        .expect("a conversation we did not already own");
    assert_eq!(meta.cli_session_id.as_deref(), Some("external-0001"));
    assert_eq!(
        meta.created_at, 1_700_000_000_000,
        "the age that matters is the conversation's, not the adoption's"
    );
    assert_eq!(meta.status, SessionStatus::Running);

    // Adopting it again is a no-op, not a second session on the same conversation.
    assert!(harness
        .sessions
        .adopt_external(req)
        .expect("adopt")
        .is_none());
    assert_eq!(harness.sessions.ids().len(), 1);
}

#[tokio::test]
async fn a_dead_session_with_no_conversation_id_is_unresumable_and_says_so() {
    let harness = Harness::new("unresumable");
    let mut events = harness.sessions.subscribe();
    // Codex has no flag to pin a session id, so it stays unknown until discovered
    // from the CLI's own files — which is the case that cannot be revived.
    let mut req = request("/tmp");
    req.provider = ProviderId::Codex;
    let meta = harness.sessions.create(req).expect("create");
    assert!(meta.cli_session_id.is_none());

    harness.sessions.kill(&meta.id).expect("kill");
    wait_for_exit(&mut events, &meta.id).await;

    match harness.sessions.reactivate(&meta.id, 1, 80, 24) {
        Err(StateError::Unresumable(reason)) => {
            assert_eq!(reason, juancoded_state::UNRESUMABLE_REASON);
            assert!(reason.contains("No prior CLI conversation"));
        }
        other => panic!("expected unresumable, got {other:?}"),
    }
    // Distinct from "there is no such session at all", which is a different answer.
    assert!(matches!(
        harness.sessions.reactivate("nope", 1, 80, 24),
        Err(StateError::NotFound)
    ));
}

#[tokio::test]
async fn reactivating_a_live_session_is_a_no_op_rather_than_a_restart() {
    let harness = Harness::new("already-live");
    let id = harness.create("/tmp", 80, 24, 1);
    harness.sessions.input(&id, b"before\r\n").expect("input");
    wait_for_screen(&harness.sessions, &id, "before", 20).await;

    assert!(harness
        .sessions
        .reactivate(&id, 1, 80, 24)
        .expect("a live session is not an error")
        .is_none());
    // Still the same session, still showing what it showed.
    assert!(harness.sessions.is_running(&id));
    assert!(harness
        .sessions
        .snapshot(&id)
        .expect("grid")
        .text()
        .contains("before"));
}

#[tokio::test]
async fn flipping_the_permission_mode_restarts_the_cli_under_the_same_session_id() {
    let harness = Harness::new("skip-perms");
    let id = harness.create("/tmp", 80, 24, 1);
    assert!(!harness.sessions.meta(&id).unwrap().skip_permissions);

    let attached = harness
        .sessions
        .set_skip_permissions(&id, true, 1, 80, 24)
        .expect("flip");
    assert_eq!(
        attached.meta.id, id,
        "the client must not have to re-find it"
    );
    assert!(attached.meta.skip_permissions);
    assert_eq!(attached.meta.status, SessionStatus::Running);
    assert!(
        attached.replay_exit.is_none(),
        "the transient exit of the old pty is not the session's exit"
    );
    assert!(harness.sessions.is_running(&id));

    // And the flip is refused on a session with no pty behind it.
    let mut events = harness.sessions.subscribe();
    harness.sessions.kill(&id).expect("kill");
    wait_for_exit(&mut events, &id).await;
    assert!(matches!(
        harness.sessions.set_skip_permissions(&id, false, 1, 80, 24),
        Err(StateError::NotRunning)
    ));
}

// Multi-threaded on purpose: the daemon's runtime is, and on a current-thread
// runtime the retired pump cannot run while the restart is in progress, so the race
// this test exists for is not expressible.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_permission_flip_never_reports_the_retired_ptys_exit_as_the_sessions() {
    let harness = Harness::new("skip-perms-retire");
    let id = harness.create("/tmp", 80, 24, 1);
    let mut events = harness.sessions.subscribe();

    // The dying child's exit and its replacement's spawn are two tasks, so one flip
    // can win the race by luck. Flipping repeatedly, and settling after each one so
    // the retired pump has time to reach its exit and be turned away, is what makes
    // losing it once visible.
    for round in 0..24 {
        let attached = harness
            .sessions
            .set_skip_permissions(&id, round % 2 == 0, 1, 80, 24)
            .unwrap_or_else(|e| panic!("round {round}: the session was already gone: {e}"));
        assert_eq!(
            attached.meta.status,
            SessionStatus::Running,
            "round {round}"
        );
        assert!(attached.replay_exit.is_none(), "round {round}");
        tokio::time::sleep(Duration::from_millis(40)).await;
        assert!(
            harness.sessions.is_running(&id),
            "round {round}: the replacement pty was reaped along with the retired one"
        );
        assert_eq!(
            harness.sessions.meta(&id).expect("meta").status,
            SessionStatus::Running,
            "round {round}"
        );
    }

    // And not one of those restarts may reach a client as this session ending.
    while let Ok(event) = events.try_recv() {
        assert!(
            !matches!(&event, SessionEvent::Exit { session_id, .. } if session_id == &id),
            "a retired pty's exit was published as the session's: {event:?}"
        );
    }
}

#[tokio::test]
async fn an_exit_code_survives_to_a_client_that_attaches_afterwards() {
    let harness = Harness::new("exit-replay");
    let mut events = harness.sessions.subscribe();
    // `sh -c "exit 7"` is the smallest child with an exit status of its own.
    let id = harness.create("/tmp", 80, 24, 1);
    harness
        .sessions
        .input(&id, b"before the end\r\n")
        .expect("input");
    wait_for_screen(&harness.sessions, &id, "before the end", 20).await;
    harness.sessions.kill(&id).expect("kill");

    let code = wait_for_exit(&mut events, &id).await;
    assert_eq!(
        code,
        Some(-1),
        "a child taken by a signal reports -1, not a status it never had"
    );
    let meta = harness
        .sessions
        .meta(&id)
        .expect("the row outlives the pty");
    assert_eq!(meta.status, SessionStatus::Exited);
    assert_eq!(meta.exit_code, Some(-1));

    let attached = harness.sessions.attach(&id, 2, 80, 24).expect("attach");
    assert!(attached.scrollback.contains("before the end"));
    assert_eq!(
        attached.replay_exit,
        Some(Some(-1)),
        "a late client is re-told the exit instead of waiting for one"
    );
}

#[tokio::test]
async fn the_retention_cap_is_per_project_and_only_takes_finished_sessions() {
    let harness = Harness::new("retention");
    let project_a = harness.dir.join("a");
    let project_b = harness.dir.join("b");
    std::fs::create_dir_all(&project_a).unwrap();
    std::fs::create_dir_all(&project_b).unwrap();
    let (a, b) = (
        project_a.to_str().unwrap().to_string(),
        project_b.to_str().unwrap().to_string(),
    );

    // The cap lives on the store, so drive it directly: the registry's job is to
    // apply it on the settle of an exit and forget what it dropped.
    let store = juancoded_persistence::SqliteStore::open(&harness.store).expect("store");
    use juancoded_persistence::SessionStore;

    let mut ids = Vec::new();
    for _ in 0..4 {
        let mut events = harness.sessions.subscribe();
        let id = harness.create(&a, 80, 24, 1);
        harness.sessions.kill(&id).expect("kill");
        wait_for_exit(&mut events, &id).await;
        ids.push(id);
    }
    let live_in_b = harness.create(&b, 80, 24, 1);

    assert_eq!(store.prune_project(&a, 2).expect("prune").len(), 2);
    assert!(store.get(&ids[0]).expect("get").is_none());
    assert!(store.get(&ids[3]).expect("get").is_some());
    // The other project is untouched, and a running session is never a candidate.
    assert!(store.get(&live_in_b).expect("get").is_some());
    assert!(harness.sessions.is_running(&live_in_b));
}

#[tokio::test]
async fn the_activity_machine_notifies_on_a_turn_boundary_and_on_a_prompt_only() {
    let harness = Harness::new("activity");
    let mut events = harness.sessions.subscribe();
    let id = harness.create("/tmp", 80, 24, 1);

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

    // Entering a turn is never a ping.
    harness
        .sessions
        .input(&id, b"working... esc to interrupt\r\n")
        .expect("input");
    assert_eq!(
        next_activity(&mut events, &id).await,
        (SessionActivity::Busy, false)
    );

    // Erasing the footer ends the turn, and a turn boundary is a ping.
    harness
        .sessions
        .input(&id, b"\x1b[2J\x1b[H\r\n")
        .expect("input");
    assert_eq!(
        next_activity(&mut events, &id).await,
        (SessionActivity::Idle, true)
    );

    // A prompt in the footer band is a ping, whether or not a turn preceded it.
    harness
        .sessions
        .input(&id, b"\x1b[999;1HDo you want to proceed? (y/n)\r\n")
        .expect("input");
    assert_eq!(
        next_activity(&mut events, &id).await,
        (SessionActivity::WaitingInput, true)
    );
    assert_eq!(
        harness.sessions.activity(&id),
        Some(SessionActivity::WaitingInput)
    );

    // A prompt answered away is not a new ping.
    harness
        .sessions
        .input(&id, b"\x1b[2J\x1b[H\r\n")
        .expect("input");
    assert_eq!(
        next_activity(&mut events, &id).await,
        (SessionActivity::Idle, false)
    );
}

#[tokio::test]
async fn a_settled_turn_over_a_dirty_worktree_carries_the_change_rollup() {
    let harness = Harness::new("changes");
    let repo = harness.dir.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    let git = |args: &[&str]| {
        let ok = std::process::Command::new("git")
            .args(args)
            .current_dir(&repo)
            .env("GIT_AUTHOR_NAME", "test")
            .env("GIT_AUTHOR_EMAIL", "test@localhost")
            .env("GIT_COMMITTER_NAME", "test")
            .env("GIT_COMMITTER_EMAIL", "test@localhost")
            .status()
            .expect("git")
            .success();
        assert!(ok, "git {args:?}");
    };
    git(&["init", "--quiet", "--initial-branch=main"]);
    std::fs::write(repo.join("a.txt"), "one\n").unwrap();
    git(&["add", "a.txt"]);
    git(&["commit", "--quiet", "-m", "base"]);
    std::fs::write(repo.join("a.txt"), "one\ntwo\n").unwrap();

    let mut events = harness.sessions.subscribe();
    let id = harness.create(repo.to_str().unwrap(), 80, 24, 1);
    harness
        .sessions
        .input(&id, b"working... esc to interrupt\r\n")
        .expect("input");
    harness
        .sessions
        .input(&id, b"\x1b[2J\x1b[H\r\n")
        .expect("input");

    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    let rollup = loop {
        let event = tokio::time::timeout_at(deadline, events.recv())
            .await
            .expect("timed out waiting for the settle edge")
            .expect("bus closed");
        if let SessionEvent::Activity {
            state: SessionActivity::Idle,
            notify: true,
            changes,
            ..
        } = event
        {
            break changes;
        }
    };
    let rollup = rollup.expect("a dirty worktree must produce a rollup");
    assert_eq!(rollup.files, 1);
    assert_eq!(rollup.additions, 1);
    assert_eq!(rollup.deletions, 0);
}

#[tokio::test]
async fn a_turn_that_ends_outside_a_worktree_carries_no_rollup() {
    let harness = Harness::new("no-changes");
    let plain = harness.dir.join("plain");
    std::fs::create_dir_all(&plain).unwrap();
    let mut events = harness.sessions.subscribe();
    let id = harness.create(plain.to_str().unwrap(), 80, 24, 1);
    harness
        .sessions
        .input(&id, b"working... esc to interrupt\r\n")
        .expect("input");
    harness
        .sessions
        .input(&id, b"\x1b[2J\x1b[H\r\n")
        .expect("input");

    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        let event = tokio::time::timeout_at(deadline, events.recv())
            .await
            .expect("timed out")
            .expect("bus closed");
        if let SessionEvent::Activity {
            state: SessionActivity::Idle,
            notify: true,
            changes,
            ..
        } = event
        {
            assert!(changes.is_none(), "{changes:?}");
            break;
        }
    }
}
