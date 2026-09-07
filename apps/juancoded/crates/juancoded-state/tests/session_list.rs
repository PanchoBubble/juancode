//! What `listSessions` answers with.
//!
//! The whole point of the frame is the case this file measures: a client that was not
//! running when the sessions were created is still told about them. Without it the
//! desktop's mirror only ever holds what happened to arrive over the wire while it was
//! connected, which on this machine was 28 rows against the daemon's 379
//! (juancode-75c5).

mod harness;

use harness::Harness;
use juancoded_core::model::{ProviderId, SessionStatus};
use juancoded_state::registry::CreateRequest;

fn request(cwd: &str) -> CreateRequest {
    CreateRequest {
        provider: ProviderId::Claude,
        cwd: cwd.into(),
        cols: 80,
        rows: 24,
        skip_permissions: false,
        model: None,
        preset: None,
        isolate_worktree: false,
        dispatch_id: None,
        owner: 1,
    }
}

#[tokio::test]
async fn the_list_is_every_session_the_store_remembers_not_just_the_live_ones() {
    let harness = Harness::new("list-history");
    let first = harness.sessions.create(request("/tmp")).expect("create");
    let second = harness.sessions.create(request("/tmp")).expect("create");
    harness.sessions.kill(&first.id).expect("kill");

    // The restart is the client's arrival, stood in for: a tree that was not there
    // when these were made, reading them back.
    let harness = harness.restart();
    let rows = harness.sessions.sessions();
    assert_eq!(rows.len(), 2, "{rows:?}");
    let ids: Vec<&str> = rows.iter().map(|m| m.id.as_str()).collect();
    assert!(ids.contains(&first.id.as_str()));
    assert!(ids.contains(&second.id.as_str()));
    // Hydration comes back exited, and the list has to say so rather than repeat the
    // status the row was written with: a client that drew a running pane for a pty
    // that died with the last daemon would wait forever for bytes.
    for row in &rows {
        assert_eq!(row.status, SessionStatus::Exited, "{row:?}");
    }
}

#[tokio::test]
async fn the_list_is_oldest_first_and_carries_the_whole_row() {
    let harness = Harness::new("list-order");
    let first = harness.sessions.create(request("/tmp")).expect("create");
    let second = harness.sessions.create(request("/tmp")).expect("create");

    let rows = harness.sessions.sessions();
    assert_eq!(rows.len(), 2);
    assert!(
        rows[0].created_at <= rows[1].created_at,
        "{:?}",
        rows.iter().map(|m| m.created_at).collect::<Vec<_>>()
    );
    // Two creates inside the same millisecond are ordered by id, so the list is a
    // stable answer rather than whatever the hash map iterated to this time.
    if rows[0].created_at == rows[1].created_at {
        assert!(rows[0].id < rows[1].id);
    }
    let ids: Vec<&str> = rows.iter().map(|m| m.id.as_str()).collect();
    assert!(ids.contains(&first.id.as_str()) && ids.contains(&second.id.as_str()));
    // The sidebar needs the fields it draws with, so the frame carries rows and not
    // ids: cwd and title are what a project row IS.
    assert_eq!(rows[0].cwd, "/tmp");
    assert!(!rows[0].title.is_empty());
}

#[tokio::test]
async fn a_core_with_nothing_answers_an_empty_list_rather_than_silence() {
    let harness = Harness::new("list-empty");
    assert!(harness.sessions.sessions().is_empty());
}
