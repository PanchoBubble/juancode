//! The state layer mounts into cordis, and this is the proof rather than the claim.
//!
//! `dump-config` is the whole answer to "where does the state layer live": it prints
//! one entry list, one service registry and one event bus, with `sessions` and
//! `store` as ordinary rows alongside `pty` and `terminal`. If the registry had been
//! built beside the composition core instead of into it, it would be absent from this
//! output and there would be two places to look.

mod harness;

use juancoded_cordis::dump_config;
use juancoded_state::{boot_with, plugins, SessionsService, StoreService};

/// Every row that keeps durable state is pointed at one store, and the tree builder is
/// what points them: naming the file here rather than patching the `store` row is the
/// only way the goal journal and the transcript cursors end up on the same one.
fn entries() -> juancoded_cordis::EntryList {
    plugins::entries_over_store(":memory:")
}

const DUMP: &str = "\
juancoded config: 12 entries (12 active, 0 pending, 0 disabled, 0 failed), 6 services, 4 events, 3 contributions

entries
├─ [ACTIVE  ] sessions             session-registry     needs=pty,store,terminal  effects=1
├─ [ACTIVE  ] terminal             vt-terminal          effects=1
├─ [ACTIVE  ] pty                  core-pty             effects=2
├─ [ACTIVE  ] input-guard          input-guard          needs=pty  effects=1
├─ [ACTIVE  ] goal                 session-goal         effects=2
├─ [ACTIVE  ] pty-to-grid          pty-to-grid          needs=pty,terminal  effects=3
├─ [ACTIVE  ] store                sqlite-store         effects=1
├─ [ACTIVE  ] transcripts          transcripts          effects=1
├─ [ACTIVE  ] transcript-claude    transcript-claude    needs=transcripts  effects=1
├─ [ACTIVE  ] transcript-opencode  transcript-opencode  needs=transcripts  effects=1
├─ [ACTIVE  ] activity-log         activity-log         needs=transcripts  effects=0
└─ [ACTIVE  ] session-chrome       session-chrome       effects=3

services
├─ goal         <- goal
├─ pty          <- pty
├─ sessions     <- sessions
├─ store        <- store
├─ terminal     <- terminal
└─ transcripts  <- transcripts

events
├─ provider.resolveBin  ordered  1  path.lookup
├─ session.exit         fan-out  1  terminal.close
├─ session.input        around   3  guard.live-session,goal.turn-note,pty.write
└─ session.output       observe  1  terminal.feed

contributions
├─ session.badge.waiting   sessionBadge     <- session-chrome  sort=0  needs=session.activity
├─ session.menu.interrupt  contextMenuItem  <- session-chrome  sort=0  needs=session.activity
└─ session.badge.busy      sessionBadge     <- session-chrome  sort=10  needs=session.activity
";

#[test]
fn the_daemons_tree_has_the_state_layer_in_it_as_ordinary_rows() {
    let (loader, report, sessions) = boot_with(&entries()).expect("the tree mounts");

    assert_eq!(dump_config(&loader), DUMP);
    // Nothing in the daemon's tree waits any more, and `activity-log` is why that is a
    // claim worth making: it is the row that sat PENDING on `transcripts` for as long
    // as nothing provided the key, so the empty diagnostics here and its ACTIVE row in
    // the dump are the pending-to-active transition, observed on the real tree rather
    // than on a hand-built one. `juancoded-cordis`'s own tree still omits
    // `transcripts`, so the standing PENDING example is not lost with it.
    assert!(
        report.diagnostics().is_empty(),
        "{:?}",
        report.diagnostics()
    );
    assert!(loader.state("activity-log").unwrap().is_active());
    assert!(
        sessions.ids().is_empty(),
        "mounting must not create sessions"
    );

    // Both keys resolve against their contracts, and neither consumer names an
    // implementation to get there.
    assert!(loader.services().resolve::<SessionsService>().is_ok());
    assert!(loader.services().resolve::<StoreService>().is_ok());
}

#[test]
fn the_registry_row_stays_pending_when_its_store_is_disabled() {
    // Dependency-gated, not order-gated: taking a provider away leaves the consumer
    // visibly waiting rather than half-built or silently absent.
    let mut entries = entries();
    entries.set_disabled("store", true);
    let err = boot_with(&entries)
        .err()
        .expect("without a store there is no `sessions` service to resolve");
    assert!(err.to_string().contains("sessions"), "{err}");
}

#[test]
fn unmounting_the_tree_takes_the_sessions_service_with_it() {
    let (mut loader, _, _) = boot_with(&entries()).expect("the tree mounts");
    assert!(loader.services().has("sessions"));
    loader.shutdown();
    assert!(
        !loader.services().has("sessions"),
        "a registration that outlives its plugin is a leak"
    );
}
