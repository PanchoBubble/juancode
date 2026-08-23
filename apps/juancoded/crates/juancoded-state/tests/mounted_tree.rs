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

const DUMP: &str = "\
juancoded config: 8 entries (7 active, 1 pending, 0 disabled, 0 failed), 4 services, 4 events, 3 contributions

entries
├─ [ACTIVE  ] sessions        session-registry  needs=pty,store,terminal  effects=1
├─ [ACTIVE  ] terminal        vt-terminal       effects=1
├─ [ACTIVE  ] pty             core-pty          effects=2
├─ [ACTIVE  ] input-guard     input-guard       needs=pty  effects=1
├─ [ACTIVE  ] pty-to-grid     pty-to-grid       needs=pty,terminal  effects=3
├─ [ACTIVE  ] store           sqlite-store      effects=1
├─ [PENDING ] activity-log    activity-log      needs=transcripts  missing=transcripts
└─ [ACTIVE  ] session-chrome  session-chrome    effects=3

services
├─ pty       <- pty
├─ sessions  <- sessions
├─ store     <- store
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
fn the_daemons_tree_has_the_state_layer_in_it_as_ordinary_rows() {
    let mut entries = plugins::default_entries();
    entries.set_config("store", serde_json::json!({ "path": ":memory:" }));
    let (loader, report, sessions) = boot_with(&entries).expect("the tree mounts");

    assert_eq!(dump_config(&loader), DUMP);
    // The one row that is not running is the pre-existing pending example, not
    // anything this crate added.
    assert_eq!(
        report.diagnostics(),
        ["activity-log (activity-log) is PENDING: no service claims transcripts"]
    );
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
    let mut entries = plugins::default_entries();
    entries.set_config("store", serde_json::json!({ "path": ":memory:" }));
    entries.set_disabled("store", true);
    let err = boot_with(&entries)
        .err()
        .expect("without a store there is no `sessions` service to resolve");
    assert!(err.to_string().contains("sessions"), "{err}");
}

#[test]
fn unmounting_the_tree_takes_the_sessions_service_with_it() {
    let mut entries = plugins::default_entries();
    entries.set_config("store", serde_json::json!({ "path": ":memory:" }));
    let (mut loader, _, _) = boot_with(&entries).expect("the tree mounts");
    assert!(loader.services().has("sessions"));
    loader.shutdown();
    assert!(
        !loader.services().has("sessions"),
        "a registration that outlives its plugin is a leak"
    );
}
