//! What the per-project session cap actually removes, and who is told.
//!
//! The cap used to be a thing the desktop app did to its own mirror: it deleted rows
//! there, sent no frame, and the daemon's next `sessions` snapshot put every one of
//! them back (juancode-0rbi). The daemon is the only side that can make a prune
//! stick, so these are the three promises it has to keep — the row is gone from the
//! store, every client hears about it without having to list again, and a session
//! somebody archived is not a candidate at all.

mod harness;

use harness::{wait_for, wait_for_exit, Harness};
use juancoded_state::registry::SessionEvent;

/// Create a session in `cwd`, kill it, and come back once its row says exited — the
/// only state the cap considers.
///
/// The prune rides on the settle of an exit, and runs after the `Exit` event goes
/// out, so a test that asserts on what the cap did waits for the `Deleted` that
/// follows rather than for this to return.
async fn finished(harness: &Harness, cwd: &str) -> String {
    let mut events = harness.sessions.subscribe();
    let id = harness.create(cwd, 80, 24, 1).await;
    harness.sessions.kill(&id).expect("kill");
    wait_for_exit(&mut events, &id).await;
    id
}

/// Wait until the cap has announced that it dropped `id`.
async fn wait_for_prune(
    events: &mut tokio::sync::broadcast::Receiver<SessionEvent>,
    id: &str,
) -> SessionEvent {
    wait_for(
        events,
        20,
        |e| matches!(e, SessionEvent::Deleted { session_id, .. } if session_id == id),
    )
    .await
}

#[tokio::test]
async fn a_pruned_session_is_announced_rather_than_left_for_the_next_reconnect() {
    let harness = Harness::keeping("retention-announced", 1);
    let cwd = harness.dir.to_str().expect("utf8 dir").to_string();

    let first = finished(&harness, &cwd).await;
    // Subscribed before the second exit, because the prune rides on its settle.
    let mut events = harness.sessions.subscribe();
    let second = finished(&harness, &cwd).await;

    match wait_for_prune(&mut events, &first).await {
        SessionEvent::Deleted {
            worktree_path,
            worktree_removed,
            ..
        } => {
            // A tree outlives its session on purpose and nothing on a timer may reap
            // one, so the cap must never claim it removed a directory.
            assert_eq!(worktree_path, None);
            assert_eq!(worktree_removed, None);
        }
        other => panic!("{other:?}"),
    }

    let ids: Vec<String> = harness.sessions.ids();
    assert!(!ids.contains(&first), "{ids:?}");
    assert!(ids.contains(&second), "{ids:?}");
    // And it stays gone: the row is out of the store, so the tree that comes up next
    // has nothing to hydrate it from.
    let harness = harness.restart();
    let rows: Vec<String> = harness
        .sessions
        .sessions()
        .into_iter()
        .map(|m| m.id)
        .collect();
    assert_eq!(
        rows,
        vec![second],
        "a pruned session came back on a restart"
    );
}

#[tokio::test]
async fn an_archived_session_is_kept_past_the_cap() {
    let harness = Harness::keeping("retention-archived", 1);
    let cwd = harness.dir.to_str().expect("utf8 dir").to_string();

    let kept = finished(&harness, &cwd).await;
    harness
        .sessions
        .set_meta(&kept, None, Some(true))
        .expect("archive");
    let doomed = finished(&harness, &cwd).await;
    let mut events = harness.sessions.subscribe();
    let newest = finished(&harness, &cwd).await;
    wait_for_prune(&mut events, &doomed).await;

    // Archiving is the one way to keep a session past the cap, and an archived row
    // does not take up one of the slots either — a project whose archive alone
    // exceeded the cap would otherwise sweep away everything it had.
    let ids = harness.sessions.ids();
    assert!(
        ids.contains(&kept),
        "an archived session was pruned: {ids:?}"
    );
    assert!(ids.contains(&newest), "{ids:?}");
    assert!(!ids.contains(&doomed), "{ids:?}");
}

#[tokio::test]
async fn a_cap_raised_after_the_fact_is_applied_to_the_history_already_there() {
    // Nothing is capped while this tree runs, which is the store a daemon that was
    // never given a cap leaves behind.
    let harness = Harness::new("retention-boot-sweep");
    let cwd = harness.dir.to_str().expect("utf8 dir").to_string();
    let mut ids = Vec::new();
    for _ in 0..3 {
        ids.push(finished(&harness, &cwd).await);
    }
    assert_eq!(harness.sessions.ids().len(), 3);

    // The exit path can only ever reach the project a session just finished in, so
    // without a sweep at boot this history would sit there until something ran here
    // again.
    let harness = harness.restart_keeping(1);
    let left: Vec<String> = harness
        .sessions
        .sessions()
        .into_iter()
        .map(|m| m.id)
        .collect();
    assert_eq!(left.len(), 1, "{left:?}");
    assert_eq!(
        left[0], ids[2],
        "the sweep kept the wrong end of the history"
    );

    // Belt and braces: the store, not just the map the tree hydrated.
    let store = juancoded_persistence::SqliteStore::open(&harness.store).expect("store");
    use juancoded_persistence::SessionStore;
    assert!(store.get(&ids[0]).expect("get").is_none());
    assert!(store.get(&ids[2]).expect("get").is_some());
}

#[tokio::test]
async fn the_cap_leaves_other_projects_and_live_sessions_alone() {
    let harness = Harness::keeping("retention-scope", 1);
    let mine = harness.dir.join("mine");
    let theirs = harness.dir.join("theirs");
    std::fs::create_dir_all(&mine).unwrap();
    std::fs::create_dir_all(&theirs).unwrap();
    let (mine, theirs) = (
        mine.to_str().unwrap().to_string(),
        theirs.to_str().unwrap().to_string(),
    );

    let neighbour = finished(&harness, &theirs).await;
    let oldest = finished(&harness, &mine).await;
    let running = harness.create(&mine, 80, 24, 1).await;
    let mut events = harness.sessions.subscribe();
    let newest = finished(&harness, &mine).await;
    wait_for_prune(&mut events, &oldest).await;

    let ids = harness.sessions.ids();
    assert!(!ids.contains(&oldest), "{ids:?}");
    assert!(ids.contains(&newest), "{ids:?}");
    assert!(
        ids.contains(&running) && harness.sessions.is_running(&running),
        "the cap took a session that was still running"
    );
    assert!(
        ids.contains(&neighbour),
        "another project's history was swept: {ids:?}"
    );
}

#[tokio::test]
async fn the_sweep_takes_the_sessions_the_last_daemon_died_holding() {
    let harness = Harness::new("retention-crashed");
    let cwd = harness.dir.to_str().expect("utf8 dir").to_string();
    let survivor = finished(&harness, &cwd).await;

    // A row the previous daemon never got to finalise: killed hard, so the store
    // still says `running`. Only an exited session is a candidate for the cap, and
    // hydration is what corrects this one — which is why the sweep runs after it.
    {
        use juancoded_core::model::{ProviderId, SessionMeta, SessionStatus};
        use juancoded_persistence::SessionStore;
        let store = juancoded_persistence::SqliteStore::open(&harness.store).expect("store");
        let mut crashed = SessionMeta::new(
            "crashed".into(),
            ProviderId::Claude,
            cwd.clone(),
            "crashed".into(),
            1,
            false,
        );
        crashed.created_at = 1;
        crashed.status = SessionStatus::Running;
        store.upsert(&crashed).expect("upsert");
    }

    let harness = harness.restart_keeping(1);
    let left: Vec<String> = harness
        .sessions
        .sessions()
        .into_iter()
        .map(|m| m.id)
        .collect();
    assert_eq!(left, vec![survivor], "{left:?}");
}
