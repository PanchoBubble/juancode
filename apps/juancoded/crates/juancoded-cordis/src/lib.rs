//! Cordis-in-Rust: the composition core the rest of the daemon mounts into.
//!
//! Five ideas are ported from cordis, the plugin framework under DeepSeek Harness,
//! and each one lands somewhere the language already wanted it:
//!
//! 1. **A keyed service registry** ([`service`]). A service claims a stable key such
//!    as `terminal` or `pty`; consumers resolve by key against a contract trait and
//!    never see the implementation.
//! 2. **Registrations are reversible effects** ([`effect`]). Every registration hands
//!    back a guard that unregisters on `Drop`, and a scope unwinds its guards in
//!    reverse registration order. This is the idea Rust holds better than the
//!    framework it came from: teardown is the compiler's job, not the author's.
//! 3. **Dependency-gated load order** ([`loader`]). A plugin declares the keys it
//!    needs and stays PENDING until they exist. Unlike cordis, PENDING is loud: it is
//!    logged, carried in [`loader::LoadReport`], and printed by `dump-config`.
//! 4. **The entry list as composition** ([`entry`]). An ordered list of rows with
//!    stable ids and a `disabled` flag; the loader diffs by id and touches only what
//!    changed.
//! 5. **A typed event bus with explicit dispatch modes** ([`bus`]). observe, around
//!    with `next()`, fan-out, and ordered-with-return. The mode is the trait the event
//!    implements, so a mismatched dispatch does not compile.
//!
//! [`contribution`] is the sixth thing, and it is ours rather than cordis's: a plugin
//! changes the built-in surfaces by registering a descriptor, which is an effect like
//! any other and disappears with its plugin.
//!
//! Deliberately not ported: groups/isolate realms and per-agent scoped registration
//! with shadowing. Both exist to keep tenants from seeing each other's services, and
//! this daemon serves one app.
//!
//! Nothing here starts on its own. It binds no port and spawns no child until an entry
//! list is applied by hand; see `examples/dump_config.rs`.

pub mod bus;
pub mod contribution;
pub mod dump;
pub mod effect;
pub mod entry;
pub mod events;
pub mod loader;
pub mod plugin;
pub mod plugins;
pub mod service;
pub mod services;

pub use bus::{AroundEvent, Bus, DispatchMode, FanOutEvent, Next, ObserveEvent, SerialEvent};
pub use contribution::{
    Activation, ActivationOutcome, Badge, Contribution, ContributionRegistry, DataNeed, MenuTarget,
    Placement, Scope, SettingsField, Snapshot as ContributionSnapshot, Tone,
};
pub use dump::dump_config;
pub use effect::{Effect, EffectScope};
pub use entry::{Entry, EntryList};
pub use loader::{Fiber, LoadReport, Loader};
pub use plugin::{Context, FiberState, Plugin};
pub use service::{ResolveError, Service, ServiceRegistry, ServiceTaken};

/// A loader with every built-in plugin registered and the default tree applied.
///
/// The one call the daemon makes at boot. It mounts plugins, it does not open sockets.
pub fn boot() -> (Loader, LoadReport) {
    boot_with(&plugins::default_entries()).expect("the default tree has unique ids")
}

/// Same, against a caller-supplied tree.
pub fn boot_with(entries: &EntryList) -> Result<(Loader, LoadReport), entry::DuplicateId> {
    let mut loader = Loader::new();
    plugins::register_builtins(&mut loader);
    let report = loader.apply(entries)?;
    Ok((loader, report))
}
