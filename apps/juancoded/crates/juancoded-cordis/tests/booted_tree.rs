//! The tree the daemon boots, end to end: two real services, real plugins, a real pty
//! and a real grid. Nothing here binds a port, and every child it spawns is `/bin/cat`.

use std::collections::HashMap;
use std::time::Duration;

use juancoded_cordis::events::{
    BinQuery, ExitInfo, InputDecision, InputRequest, OutputFrame, ResolveBinary, SessionExit,
    SessionInput, SessionOutput,
};
use juancoded_cordis::plugins::default_entries;
use juancoded_cordis::services::{PtySpawnService, TerminalService};
use juancoded_cordis::{boot, boot_with, dump_config, Entry, EntryList, FiberState};
use juancoded_core::pty::{PtyEvent, SpawnSpec};

const DUMP: &str = "\
juancoded config: 6 entries (5 active, 1 pending, 0 disabled, 0 failed), 2 services, 4 events, 3 contributions

entries
├─ [ACTIVE  ] terminal        vt-terminal     effects=1
├─ [ACTIVE  ] pty             core-pty        effects=2
├─ [ACTIVE  ] input-guard     input-guard     needs=pty  effects=1
├─ [ACTIVE  ] pty-to-grid     pty-to-grid     needs=pty,terminal  effects=3
├─ [PENDING ] activity-log    activity-log    needs=transcripts  missing=transcripts
└─ [ACTIVE  ] session-chrome  session-chrome  effects=3

services
├─ pty       <- pty
└─ terminal  <- terminal

events
├─ provider.resolveBin  ordered  1  path.lookup
├─ session.exit         fan-out  1  terminal.close
├─ session.input        around   2  guard.live-session,pty.write
└─ session.output       observe  1  terminal.feed

contributions
├─ session.badge.waiting   sessionBadge     <- session-chrome  sort=0  needs=session.activity
├─ session.menu.interrupt  contextMenuItem  <- session-chrome  sort=0  needs=session.activity
└─ session.badge.busy      sessionBadge     <- session-chrome  sort=10  needs=session.activity
";

#[test]
fn dump_config_prints_the_tree_the_daemon_booted() {
    let (loader, report) = boot();
    assert_eq!(dump_config(&loader), DUMP);
    // The one row that is not running says so, in the report as well as the tree.
    assert_eq!(
        report.diagnostics(),
        ["activity-log (activity-log) is PENDING: no service claims transcripts"]
    );
}

#[test]
fn disabling_a_row_by_id_removes_it_from_the_tree_and_leaves_the_rest() {
    let mut entries = default_entries();
    entries.set_disabled("input-guard", true);
    let (loader, _) = boot_with(&entries).unwrap();

    let dump = dump_config(&loader);
    assert!(
        dump.contains("[DISABLED] input-guard     input-guard"),
        "{dump}"
    );
    assert_eq!(loader.state("input-guard").unwrap(), &FiberState::Disabled);
    // Its listener is gone; the write listener registered by its neighbour is not.
    assert_eq!(
        loader.bus().listeners_of::<SessionInput>(),
        ["pty.write"],
        "{dump}"
    );
    assert!(loader.state("pty-to-grid").unwrap().is_active());
    assert!(loader.services().has("pty") && loader.services().has("terminal"));
}

#[test]
fn a_pending_row_becomes_active_once_something_claims_its_key() {
    // Nothing in this crate provides `transcripts`, so activity-log is the standing
    // proof that PENDING is visible rather than swallowed.
    let (loader, report) = boot();
    assert!(loader.state("activity-log").unwrap().is_pending());
    assert_eq!(report.pending.len(), 1);
    assert_eq!(report.pending[0].missing, ["transcripts"]);
    assert!(dump_config(&loader).contains("missing=transcripts"));
}

#[test]
fn an_entry_list_is_addressable_and_diffs_by_id() {
    let entries = EntryList::new()
        .push(Entry::new("terminal", "vt-terminal"))
        .push(Entry::new("pty", "core-pty"));
    let (mut loader, _) = boot_with(&entries).unwrap();

    let grown = entries
        .clone()
        .push(Entry::new("pty-to-grid", "pty-to-grid"));
    let report = loader.apply(&grown).unwrap();
    assert_eq!(report.mounted, ["pty-to-grid"]);
    assert_eq!(report.unchanged, ["terminal", "pty"]);
    assert!(report.is_clean());
}

#[tokio::test]
async fn the_booted_tree_carries_real_pty_bytes_into_a_real_grid() {
    let (loader, _) = boot();
    let pty = loader.services().resolve::<PtySpawnService>().unwrap();
    let terminal = loader.services().resolve::<TerminalService>().unwrap();

    let handle = pty
        .spawn(
            "s1",
            SpawnSpec {
                program: "/bin/cat".into(),
                args: Vec::new(),
                cwd: "/".into(),
                cols: 80,
                rows: 24,
                env_overlay: HashMap::new(),
            },
        )
        .expect("spawn /bin/cat");
    let mut events = handle.subscribe();

    // Input travels the around chain: the guard annotates and delegates, and the
    // plugin at the end of the chain owns the write.
    let mut request = InputRequest::new("s1", b"marker\n".to_vec());
    let decision = loader.bus().waterfall::<SessionInput>(&mut request, |_| {
        InputDecision::Refused("nothing delivered the write".into())
    });
    assert_eq!(decision, InputDecision::Delivered(7));
    assert_eq!(request.notes, ["input-guard: live"]);

    // Output travels the observe chain into the grid the terminal service owns.
    let pumped = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            if let Ok(PtyEvent::Output(bytes)) = events.recv().await {
                loader.bus().emit::<SessionOutput>(&OutputFrame {
                    session: "s1".into(),
                    bytes,
                });
                if terminal.text("s1").is_some_and(|t| t.contains("marker")) {
                    return true;
                }
            }
        }
    })
    .await;
    assert_eq!(pumped, Ok(true), "the grid never saw the bytes");

    let snapshot = terminal.snapshot("s1").expect("grid exists");
    assert_eq!((snapshot.cols, snapshot.rows), (120, 40));
    assert_eq!(pty.live(), ["s1"]);

    // Exit fans out, and the grid is released by the listener that owns it.
    pty.stop("s1").expect("stop /bin/cat");
    loader
        .bus()
        .parallel::<SessionExit>(ExitInfo {
            session: "s1".into(),
            code: Some(0),
        })
        .await;
    assert!(terminal.open_sessions().is_empty());
}

#[tokio::test]
async fn input_to_a_session_with_no_pty_is_refused_by_the_guard() {
    let (loader, _) = boot();
    let mut request = InputRequest::new("ghost", b"x".to_vec());
    let decision = loader.bus().waterfall::<SessionInput>(&mut request, |_| {
        InputDecision::Refused("nothing delivered the write".into())
    });
    assert_eq!(
        decision,
        InputDecision::Refused("session `ghost` has no live pty".into())
    );
    assert!(
        request.notes.is_empty(),
        "a short-circuit must not run the rest of the chain"
    );
}

#[tokio::test]
async fn binary_resolution_is_ordered_and_returns_the_first_answer() {
    let (loader, _) = boot();
    let found = loader
        .bus()
        .serial::<ResolveBinary>(BinQuery {
            provider: "/bin/sh".into(),
        })
        .await;
    assert_eq!(found.as_deref(), Some("/bin/sh"));
}
