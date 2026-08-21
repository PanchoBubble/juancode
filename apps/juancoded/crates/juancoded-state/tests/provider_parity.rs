//! Provider parity: what differs per CLI, and what must not.
//!
//! The three providers differ in exactly three ways, and each one is asserted here:
//! how their conversation id becomes known, how a permission mode is expressed, and
//! whether that mode touches the environment at all. Everything else about a spawn is
//! the same for all three, which is the property the whole daemon exists to keep.
//!
//! These build a registry by hand rather than booting the tree, because the seam being
//! tested is the one the tree fills in: the id scanner. A fake scanner answers at once
//! and records what it was asked, so "the registry goes looking, for the right thing,
//! only when there is something to look for" is checkable without a real CLI writing a
//! real rollout file.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use juancoded_cordis::services::pty::PtyHost;
use juancoded_cordis::services::terminal::VtTerminals;
use juancoded_cordis::Bus;
use juancoded_core::model::{ProviderId, SessionStatus};
use juancoded_core::provider::IdSource;
use juancoded_persistence::{SessionStore, SqliteStore};
use juancoded_state::registry::{AdoptRequest, CreateRequest, IdScanner, RegistryConfig};
use juancoded_state::SessionRegistry;

/// What the fake scanner was asked for: the source, and the directory.
type Asked = Arc<Mutex<Vec<(IdSource, String)>>>;

struct Rig {
    registry: SessionRegistry,
    store: Arc<dyn SessionStore>,
    asked: Asked,
}

/// A registry over a real pty, a real grid and a throwaway store, with `program`
/// standing in for every CLI and a scanner that answers `answer` immediately.
fn rig(program: &str, args: &[&str], answer: Option<&'static str>) -> Rig {
    let store: Arc<dyn SessionStore> = Arc::new(SqliteStore::in_memory().expect("store"));
    let asked: Asked = Arc::new(Mutex::new(Vec::new()));
    let recorder = Arc::clone(&asked);
    let scanner: IdScanner = Arc::new(move |source, cwd, _since_ms| {
        recorder
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push((source, cwd.to_string()));
        answer.map(str::to_string)
    });
    let config = RegistryConfig {
        program_override: Some((
            program.to_string(),
            args.iter().map(|a| a.to_string()).collect(),
        )),
        discover_id: Some(scanner),
        // Tight enough that a test does not wait on a production window.
        discovery_window: |_| (Duration::from_secs(5), Duration::from_millis(20)),
        ..Default::default()
    };
    let registry = SessionRegistry::new(
        Arc::new(PtyHost::new(1_024)),
        Arc::new(VtTerminals::new(200)),
        Arc::clone(&store),
        Bus::new(),
        config,
    );
    Rig {
        registry,
        store,
        asked,
    }
}

/// The CLI stand-in for the tests that only care about lifecycle: reads a line,
/// prints it back.
const ECHO_LOOP: &str =
    "stty -echo 2>/dev/null; while IFS= read -r line; do printf '%s\r\n' \"$line\"; done";

/// The stand-in for the tests that assert on the child's own environment: dump it,
/// then stay alive, because a permission flip can only restart a live session.
const ENV_THEN_WAIT: &str = "/usr/bin/env; read ignored";

fn request(provider: ProviderId, cwd: &str) -> CreateRequest {
    CreateRequest {
        provider,
        cwd: cwd.into(),
        cols: 120,
        rows: 40,
        skip_permissions: false,
        model: None,
        dispatch_id: None,
        owner: 1,
    }
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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_codex_session_starts_unresumable_and_becomes_resumable_when_its_id_lands() {
    let rig = rig("/bin/sh", &["-c", ECHO_LOOP], Some("codex-conversation-1"));
    let meta = rig
        .registry
        .create(request(ProviderId::Codex, "/tmp"))
        .expect("create");
    assert!(
        meta.cli_session_id.is_none(),
        "codex has no flag to pin an id, so at spawn there is nothing to resume"
    );

    let learned = wait_until(5, || {
        rig.registry
            .meta(&meta.id)
            .and_then(|m| m.cli_session_id.clone())
    })
    .await;
    assert_eq!(learned, "codex-conversation-1");

    // It was asked about codex's rollouts, for this session's directory.
    let asked = rig.asked.lock().unwrap_or_else(|e| e.into_inner()).clone();
    assert!(
        asked
            .iter()
            .any(|(source, cwd)| *source == IdSource::CodexRollout && cwd == "/tmp"),
        "asked the wrong thing: {asked:?}"
    );

    // And it survives a restart of the daemon, which is what makes it a resumable
    // session rather than a fact in memory.
    let stored = rig
        .store
        .all()
        .expect("store")
        .into_iter()
        .find(|m| m.id == meta.id)
        .expect("the session row");
    assert_eq!(
        stored.cli_session_id.as_deref(),
        Some("codex-conversation-1")
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_opencode_session_is_asked_about_opencodes_own_database() {
    let rig = rig("/bin/sh", &["-c", ECHO_LOOP], Some("ses_abc123"));
    let meta = rig
        .registry
        .create(request(ProviderId::Opencode, "/tmp"))
        .expect("create");
    let learned = wait_until(5, || {
        rig.registry
            .meta(&meta.id)
            .and_then(|m| m.cli_session_id.clone())
    })
    .await;
    assert_eq!(learned, "ses_abc123");
    let asked = rig.asked.lock().unwrap_or_else(|e| e.into_inner()).clone();
    assert!(
        asked
            .iter()
            .all(|(source, _)| *source == IdSource::OpencodeDb),
        "opencode's id is in its database, nowhere else: {asked:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_claude_session_is_never_asked_because_we_named_its_conversation() {
    let rig = rig("/bin/sh", &["-c", ECHO_LOOP], Some("should-never-be-used"));
    let meta = rig
        .registry
        .create(request(ProviderId::Claude, "/tmp"))
        .expect("create");
    assert_eq!(
        meta.cli_session_id.as_deref(),
        Some(meta.id.as_str()),
        "claude takes our id, so it is resumable at once"
    );
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(
        rig.asked
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .is_empty(),
        "nothing to discover, so nothing was read off the disk"
    );
    // And the id we pinned is still the id.
    assert_eq!(
        rig.registry
            .meta(&meta.id)
            .and_then(|m| m.cli_session_id.clone())
            .as_deref(),
        Some(meta.id.as_str())
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_adopted_conversation_is_not_gone_looking_for() {
    let rig = rig(
        "/bin/sh",
        &["-c", ECHO_LOOP],
        Some("some-other-conversation"),
    );
    let meta = rig
        .registry
        .adopt_external(AdoptRequest {
            provider: ProviderId::Codex,
            cli_session_id: "adopted-conversation".into(),
            cwd: "/tmp".into(),
            start_ms: 1_700_000_000_000,
            cols: 120,
            rows: 40,
            owner: 1,
        })
        .expect("adopt")
        .expect("a conversation we did not already own");

    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(
        rig.asked
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .is_empty(),
        "we were told the id; looking for another one could only get it wrong"
    );
    assert_eq!(
        rig.registry
            .meta(&meta.id)
            .and_then(|m| m.cli_session_id.clone())
            .as_deref(),
        Some("adopted-conversation")
    );
}

/// Every provider's child gets OUR environment, entry for entry, and the permission
/// mode reaches each CLI the way that CLI expresses it: a flag for the two that have
/// one, and for opencode the single sanctioned env entry, set only for a session that
/// asked for it.
///
/// `/usr/bin/env` stands in for the CLI, so what lands in the session's scrollback is
/// the child's own environment and the diff is against what the child really saw. This
/// is the ticket's "identical env to a plain terminal", measured through the registry
/// rather than argued from the spawn code.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_provider_inherits_our_environment_and_only_opencode_bypass_adds_to_it() {
    for (provider, skip, overlay) in [
        (ProviderId::Opencode, true, vec!["OPENCODE_PERMISSION"]),
        (ProviderId::Opencode, false, vec![]),
        (ProviderId::Claude, true, vec![]),
        (ProviderId::Claude, false, vec![]),
        (ProviderId::Codex, true, vec![]),
        (ProviderId::Codex, false, vec![]),
    ] {
        let rig = rig("/usr/bin/env", &[], None);
        let mut req = request(provider, "/tmp");
        req.skip_permissions = skip;
        let meta = rig.registry.create(req).expect("create");
        let dump = wait_until(10, || {
            rig.registry
                .scrollback(&meta.id)
                .filter(|s| s.contains("PATH="))
        })
        .await;
        let child = parse_env(&dump);
        let case = format!("{provider:?} with skip_permissions={skip}");

        for key in &overlay {
            assert!(
                child.contains_key(*key),
                "{case}: the overlay entry {key} never reached the child"
            );
        }
        let added: Vec<&String> = child
            .iter()
            .filter(|(k, v)| {
                !overlay.contains(&k.as_str()) && std::env::var(k).is_err() && !undiffable(k, v)
            })
            .map(|(k, _)| k)
            .collect();
        assert!(
            added.is_empty(),
            "{case}: the child was given entries we never had: {added:?}"
        );
        for (key, value) in std::env::vars() {
            if undiffable(&key, &value) {
                continue;
            }
            assert_eq!(
                child.get(&key),
                Some(&value),
                "{case}: {key} did not survive the spawn intact"
            );
        }
    }
}

/// Parse an `env` dump read back off a pty, where line endings are `\r\n`.
fn parse_env(dump: &str) -> std::collections::HashMap<String, String> {
    dump.lines()
        .filter_map(|line| line.trim_end_matches('\r').split_once('='))
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

/// A key that cannot be compared this way. `DYLD_*` is stripped by macOS when
/// exec'ing a system binary, so `/usr/bin/env` never sees the one `cargo` puts in a
/// test binary's environment; a multi-line value cannot be read back out of a
/// line-oriented dump at all.
fn undiffable(key: &str, value: &str) -> bool {
    key.starts_with("DYLD_") || key.contains('\n') || value.contains('\n')
}

/// Flipping the mode restarts the CLI, and the restart is what carries the new mode:
/// for opencode that means the overlay appears on the second spawn and not the first.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn flipping_bypass_on_opencode_re_spawns_with_the_overlay() {
    let rig = rig("/bin/sh", &["-c", ENV_THEN_WAIT], None);
    let meta = rig
        .registry
        .create(request(ProviderId::Opencode, "/tmp"))
        .expect("create");
    let before = wait_until(10, || {
        rig.registry
            .scrollback(&meta.id)
            .filter(|s| s.contains("PATH="))
    })
    .await;
    assert!(!before.contains("OPENCODE_PERMISSION="));

    let attached = rig
        .registry
        .set_skip_permissions(&meta.id, true, 1, 120, 40)
        .expect("flip");
    assert!(attached.meta.skip_permissions);
    assert_eq!(attached.meta.status, SessionStatus::Running);

    let after = wait_until(10, || {
        rig.registry
            .scrollback(&meta.id)
            .filter(|s| s.contains("OPENCODE_PERMISSION="))
    })
    .await;
    assert!(
        after.len() > before.len(),
        "the second spawn's dump should be added to the history, not replace it"
    );
}
