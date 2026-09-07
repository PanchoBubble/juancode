//! Forgetting a session: the row, the conversation, and the worktree.
//!
//! `kill` and `delete` are two operations and the difference is the whole point of
//! this file. A killed session is still a row in the store to attach to and replay; a
//! deleted one is gone, its conversation is not adoptable again, and the worktree it
//! owned has been reaped. juancoded had only the first (juancode-lxe3, juancode-oe30).

mod harness;

use std::path::Path;
use std::process::Command;

use harness::{wait_for, Harness};
use juancoded_core::model::ProviderId;
use juancoded_state::registry::{AdoptRequest, CreateRequest, SessionEvent, StateError};

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

fn git(cwd: &Path, args: &[&str]) {
    let status = Command::new("git")
        .args(args)
        .current_dir(cwd)
        .env("GIT_AUTHOR_NAME", "test")
        .env("GIT_AUTHOR_EMAIL", "test@localhost")
        .env("GIT_COMMITTER_NAME", "test")
        .env("GIT_COMMITTER_EMAIL", "test@localhost")
        .status()
        .expect("git");
    assert!(status.success(), "git {args:?}");
}

/// A repo with one commit inside the harness's own scratch directory, so the
/// `<repo>-worktrees` sibling this makes cannot collide with another test's.
fn repo(dir: &Path) -> String {
    let root = dir.join("repo");
    std::fs::create_dir_all(&root).unwrap();
    git(&root, &["init", "--quiet", "--initial-branch=main"]);
    std::fs::write(root.join("committed.txt"), "base\n").unwrap();
    git(&root, &["add", "committed.txt"]);
    git(&root, &["commit", "--quiet", "-m", "base"]);
    root.to_string_lossy().to_string()
}

#[tokio::test]
async fn deleting_a_session_takes_the_row_the_pty_and_the_handle() {
    let harness = Harness::new("forget-row");
    let mut events = harness.sessions.subscribe();
    let meta = harness.sessions.create(request("/tmp")).expect("create");
    let id = meta.id.clone();
    assert!(harness.sessions.is_running(&id));

    let deleted = harness.sessions.delete(&id).expect("delete");
    assert_eq!(deleted.session_id, id);
    assert_eq!(deleted.worktree_path, None);
    assert_eq!(deleted.worktree_removed, None, "there was no tree to reap");

    // Every consumer hears it, which is what stops another client's sidebar showing
    // a row this daemon no longer has.
    let event = wait_for(
        &mut events,
        10,
        |e| matches!(e, SessionEvent::Deleted { session_id, .. } if session_id == &id),
    )
    .await;
    assert!(
        matches!(
            &event,
            SessionEvent::Deleted {
                worktree_path: None,
                ..
            }
        ),
        "{event:?}"
    );

    assert!(harness.sessions.meta(&id).is_none());
    assert!(!harness.sessions.ids().contains(&id));
    assert_eq!(
        harness.sessions.attach(&id, 1, 80, 24).unwrap_err(),
        StateError::NotFound,
        "nothing left to attach to"
    );
}

/// The difference from `kill`, stated as a test: a restart is exactly where the two
/// diverge, because a killed session's row is what the next daemon hydrates.
#[tokio::test]
async fn a_deleted_session_does_not_come_back_on_the_next_boot() {
    let harness = Harness::new("forget-restart");
    let kept = harness.sessions.create(request("/tmp")).expect("create");
    let gone = harness.sessions.create(request("/tmp")).expect("create");
    harness.sessions.kill(&kept.id).expect("kill");
    harness.sessions.delete(&gone.id).expect("delete");

    let harness = harness.restart();
    let ids = harness.sessions.ids();
    assert!(ids.contains(&kept.id), "a killed session is still history");
    assert!(!ids.contains(&gone.id), "a deleted one is not");
}

/// The resurrection path the tombstone closes. Dropping the row makes the
/// conversation id unused again, and unused is exactly what `adopt_external` picks up.
#[tokio::test]
async fn a_forgotten_conversation_is_not_adopted_back() {
    let harness = Harness::new("forget-adopt");
    let adopt = AdoptRequest {
        provider: ProviderId::Claude,
        cli_session_id: "conv-forget-me".into(),
        cwd: "/tmp".into(),
        start_ms: 1,
        cols: 80,
        rows: 24,
        owner: 1,
    };
    let adopted = harness
        .sessions
        .adopt_external(adopt.clone())
        .expect("adopt")
        .expect("a fresh conversation is adoptable");
    assert_eq!(adopted.cli_session_id.as_deref(), Some("conv-forget-me"));

    harness.sessions.delete(&adopted.id).expect("delete");

    assert!(
        harness
            .sessions
            .adopt_external(adopt)
            .expect("the refusal is not an error")
            .is_none(),
        "a conversation somebody deleted is not one waiting to be picked up"
    );
    assert!(harness.sessions.ids().is_empty());
}

/// juancode-oe30: the tree an isolated create made, reaped by the delete and by
/// nothing else. An exit must not take it — the work in a worktree routinely outlives
/// the agent that did it.
#[tokio::test]
async fn deleting_an_isolated_session_reaps_its_worktree() {
    let harness = Harness::new("forget-worktree");
    let root = repo(&harness.dir);
    let mut req = request(&root);
    req.isolate_worktree = true;
    let meta = harness.sessions.create(req).expect("an isolated create");
    let tree = meta.worktree_path.clone().expect("a worktree path");
    assert!(Path::new(&tree).is_dir(), "{tree}");

    // The exit on its own leaves it: this is the assertion that says the reap is on
    // the delete path and not on the pty's death.
    harness.sessions.kill(&meta.id).expect("kill");
    let mut events = harness.sessions.subscribe();
    harness.sessions.delete(&meta.id).expect("delete");
    let event = wait_for(
        &mut events,
        10,
        |e| matches!(e, SessionEvent::Deleted { session_id, .. } if session_id == &meta.id),
    )
    .await;
    assert!(
        matches!(
            &event,
            SessionEvent::Deleted { worktree_path: Some(p), worktree_removed: Some(true), .. }
                if p == &tree
        ),
        "{event:?}"
    );
    assert!(
        !Path::new(&tree).exists(),
        "the tree is what `pnpm loose` finds: {tree}"
    );
}

/// The other half of the same rule, so the reap cannot quietly migrate onto the exit
/// edge without a test noticing.
#[tokio::test]
async fn an_exit_leaves_the_worktree_alone() {
    let harness = Harness::new("keep-worktree");
    let root = repo(&harness.dir);
    let mut req = request(&root);
    req.isolate_worktree = true;
    let meta = harness.sessions.create(req).expect("an isolated create");
    let tree = meta.worktree_path.clone().expect("a worktree path");

    let mut events = harness.sessions.subscribe();
    harness.sessions.kill(&meta.id).expect("kill");
    harness::wait_for_exit(&mut events, &meta.id).await;
    assert!(
        Path::new(&tree).is_dir(),
        "a session ending is not a reason to throw its work away: {tree}"
    );
}

#[tokio::test]
async fn deleting_a_session_this_core_never_had_is_not_found() {
    let harness = Harness::new("forget-missing");
    assert_eq!(
        harness.sessions.delete("no-such-session").unwrap_err(),
        StateError::NotFound
    );
}
