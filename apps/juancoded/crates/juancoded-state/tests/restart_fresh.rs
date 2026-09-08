//! Restarting a session as a fresh conversation, and why it is not a revive.
//!
//! `reactivate` hands the CLI `--resume <id>` and needs one to exist. That leaves a
//! whole class of session with nothing but a dead replay-only pane: codex and opencode
//! only write a conversation id down once they have done some work, so a session that
//! ended before its first turn is one `reactivate` can only answer `unresumable`. A
//! restart starts the CLI instead of resuming it, so it needs no id at all — which is
//! why it is a call of its own rather than a flag on the revive.
//!
//! What has to stay true across it is the identity: the juancode id, its row and the
//! pane a client is bound to survive, and only the conversation behind them changes.

mod harness;

use std::sync::Arc;
use std::time::{Duration, Instant};

use harness::{wait_for_exit, Harness};
use juancoded_cordis::services::pty::PtyHost;
use juancoded_cordis::services::terminal::VtTerminals;
use juancoded_cordis::Bus;
use juancoded_core::model::{ProviderId, SessionStatus};
use juancoded_persistence::{SessionStore, SqliteStore};
use juancoded_state::registry::{CreateRequest, IdScanner, RegistryConfig, StateError};
use juancoded_state::SessionRegistry;

#[tokio::test]
async fn a_restart_pins_a_new_conversation_under_the_id_the_client_already_knows() {
    let harness = Harness::new("restart-fresh-pin");
    let mut events = harness.sessions.subscribe();
    let id = harness.create("/tmp", 80, 24, 1).await;
    let first = harness
        .sessions
        .meta(&id)
        .expect("the row")
        .cli_session_id
        .expect("claude pins its conversation id at spawn");

    // Bytes in the scrollback first, so "the prior conversation is not carried" is
    // something the assertion below can actually miss.
    harness
        .sessions
        .input(&id, b"before-the-restart\r")
        .expect("input");
    let before = wait_until(10, || {
        let attached = harness.sessions.attach(&id, 1, 80, 24).expect("attach");
        attached
            .scrollback
            .contains("before-the-restart")
            .then_some(attached)
    })
    .await;
    assert_eq!(before.meta.cli_session_id.as_deref(), Some(first.as_str()));

    harness.sessions.kill(&id).expect("kill");
    wait_for_exit(&mut events, &id).await;

    let attached = harness
        .sessions
        .restart_fresh(&id, 1, 80, 24)
        .expect("a fresh restart needs nothing to resume");

    // The half that keeps the pane: same juancode id, same row, live again.
    assert_eq!(attached.meta.id, id);
    assert_eq!(attached.meta.status, SessionStatus::Running);
    // And the half that makes it a restart: a different conversation behind it. A
    // fresh pin rather than the old one, because claude refuses `--session-id` for a
    // conversation it has already written — reusing it would fail every restart after
    // the first.
    let second = attached
        .meta
        .cli_session_id
        .clone()
        .expect("a pinned-id provider is resumable again the moment it starts");
    assert_ne!(
        second, first,
        "the restart reused the abandoned conversation"
    );
    assert!(
        !attached.scrollback.contains("before-the-restart"),
        "the pane replayed a transcript the new CLI has never heard of: {:?}",
        attached.scrollback
    );
}

#[tokio::test]
async fn a_live_session_is_refused_rather_than_restarted() {
    // Restarting throws a conversation away. A client that believes the session is
    // dead has to be told it is not, rather than taken at its word.
    let harness = Harness::new("restart-fresh-live");
    let id = harness.create("/tmp", 80, 24, 1).await;
    let before = harness.sessions.meta(&id).expect("the row");

    assert_eq!(
        harness.sessions.restart_fresh(&id, 1, 80, 24).unwrap_err(),
        StateError::StillRunning
    );
    assert!(
        harness.sessions.is_running(&id),
        "the refusal killed the pty"
    );
    assert_eq!(
        harness.sessions.meta(&id).expect("the row").cli_session_id,
        before.cli_session_id,
        "the refusal moved the conversation it declined to touch"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_session_a_revive_gives_up_on_is_the_one_a_restart_serves() {
    // Codex has no flag to pin an id and writes one only once it is working, so a
    // session that ended before then has nothing to resume. This one builds its
    // registry by hand for the same reason `provider_parity` does: the seam is the id
    // scanner, and one that never finds anything makes "still unresumable" a fact
    // rather than a wait.
    let registry = unresumable_rig();
    let meta = registry
        .create(CreateRequest {
            provider: ProviderId::Codex,
            cwd: "/tmp".into(),
            cols: 80,
            rows: 24,
            skip_permissions: false,
            model: None,
            preset: None,
            isolate_worktree: false,
            dispatch_id: None,
            owner: 1,
        })
        .expect("create");
    assert!(meta.cli_session_id.is_none());

    registry.kill(&meta.id).expect("kill");
    wait_until(10, || (!registry.is_running(&meta.id)).then_some(())).await;

    assert!(
        matches!(
            registry.reactivate(&meta.id, 1, 80, 24),
            Err(StateError::Unresumable(_))
        ),
        "the premise of this test is that a revive cannot do it"
    );

    let attached = registry
        .restart_fresh(&meta.id, 1, 80, 24)
        .expect("a restart needs no resumable id");
    assert_eq!(attached.meta.id, meta.id);
    assert_eq!(attached.meta.status, SessionStatus::Running);
    // Still nothing pinned: a discovered-id provider goes back to being discovered,
    // and this rig's scanner never finds anything.
    assert!(attached.meta.cli_session_id.is_none());
}

/// The CLI stand-in for the hand-built rig: reads a line, prints it back.
const ECHO_LOOP: &str =
    "stty -echo 2>/dev/null; while IFS= read -r line; do printf '%s\r\n' \"$line\"; done";

/// A registry over a real pty, a real grid and a throwaway store, with a scanner that
/// never finds an id — which is what keeps a codex session unresumable for as long as
/// the test needs it to be.
fn unresumable_rig() -> SessionRegistry {
    let store: Arc<dyn SessionStore> = Arc::new(SqliteStore::in_memory().expect("store"));
    let scanner: IdScanner = Arc::new(|_source, _cwd, _since_ms| None);
    SessionRegistry::new(
        Arc::new(PtyHost::new(1_024)),
        Arc::new(VtTerminals::new(200)),
        store,
        Bus::new(),
        RegistryConfig {
            program_override: Some((
                "/bin/sh".to_string(),
                vec!["-c".to_string(), ECHO_LOOP.to_string()],
            )),
            discover_id: Some(scanner),
            // Tight enough that a test does not wait on a production window.
            discovery_window: |_| (Duration::from_millis(200), Duration::from_millis(20)),
            ..Default::default()
        },
    )
}

async fn wait_until<T>(secs: u64, mut probe: impl FnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + Duration::from_secs(secs);
    loop {
        if let Some(value) = probe() {
            return value;
        }
        assert!(Instant::now() < deadline, "the condition never came true");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}
