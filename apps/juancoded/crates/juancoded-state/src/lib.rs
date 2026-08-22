//! The state layer: the session registry, its store, and the one grid owner.
//!
//! It **mounts into** the cordis tree rather than sitting beside it. `sessions` and
//! `store` are keyed services; the registry resolves `pty`, `terminal` and `store`
//! by key; input travels the `session.input` around chain, output the
//! `session.output` observe chain, and an exit the `session.exit` fan-out. There is
//! one composition mechanism in this daemon and this crate is a consumer of it.
//!
//! Nothing here starts on its own. [`boot`] mounts plugins; it binds no socket and
//! spawns no child until a client asks for a session.

pub mod grid;
pub mod plugins;
pub mod registry;
pub mod service;

pub use grid::{ClientId, ResizeOutcome};
pub use registry::{
    AdoptRequest, Attached, CreateRequest, RegistryConfig, SessionEvent, SessionRegistry,
    StateError, UNRESUMABLE_REASON,
};
pub use service::{SessionsApi, SessionsService, StoreService};

/// Re-exported so the wire layer can speak about queued messages without taking a
/// dependency on the store crate that happens to define them.
pub use juancoded_persistence::QueuedMessage;

use std::sync::Arc;

use anyhow::{Context, Result};
use juancoded_cordis::{EntryList, LoadReport, Loader};

/// Boot the daemon's tree and hand back the loader plus the `sessions` handle.
///
/// The loader is returned because it owns every mounted plugin's effects: dropping it
/// unmounts the tree in reverse, which is what makes shutdown a value going out of
/// scope rather than a checklist.
pub fn boot() -> Result<(Loader, LoadReport, Arc<dyn SessionsApi>)> {
    boot_with(&plugins::default_entries())
}

pub fn boot_with(entries: &EntryList) -> Result<(Loader, LoadReport, Arc<dyn SessionsApi>)> {
    let mut loader = Loader::new();
    juancoded_cordis::plugins::register_builtins(&mut loader);
    plugins::register(&mut loader);
    let report = loader.apply(entries)?;
    let sessions = loader
        .services()
        .resolve::<SessionsService>()
        .context("the `sessions` service did not mount")?;
    Ok((loader, report, sessions))
}

/// The same tree, against a throwaway in-memory store and one stand-in program for
/// every provider. Tests use it; the daemon never does.
pub fn test_entries(program: &str, args: &[&str]) -> EntryList {
    test_entries_at(":memory:", program, args)
}

/// The test tree against a store on disk, so a test can drop the whole tree and boot
/// a second one over the same file — which is what "survives a daemon restart" means.
pub fn test_entries_at(store: &str, program: &str, args: &[&str]) -> EntryList {
    let mut entries = plugins::default_entries();
    entries.set_config("store", serde_json::json!({ "path": store }));
    entries.set_config(
        "sessions",
        serde_json::json!({
            "program": program,
            "args": args,
            "retention": 0,
        }),
    );
    entries
}
