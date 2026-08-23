//! The loader: mount an entry list, gate on services, diff by id.
//!
//! Two rules do most of the work here.
//!
//! **Load order is declared, not sequenced.** A plugin names the service keys it needs
//! and the loader mounts it when they exist. Mounting one plugin can satisfy another,
//! so a pass repeats until it stops making progress. There is no hand-ordered boot.
//!
//! **PENDING is never silent.** cordis's own tutorial names this as its footgun: a
//! plugin waiting on a service nobody provides prints nothing and does nothing. Here
//! every settle logs a warning per pending fiber, [`LoadReport`] carries them out to
//! the caller, and `dump-config` prints the missing key next to the row.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use crate::bus::Bus;
use crate::contribution::ContributionRegistry;
use crate::entry::{DuplicateId, Entry, EntryList};
use crate::plugin::{Context, FiberState, Plugin};
use crate::service::ServiceRegistry;

/// One row of the booted tree.
pub struct Fiber {
    pub entry: Entry,
    pub state: FiberState,
    /// How many times this row has been mounted. A diff that "only touches what
    /// changed" is exactly the claim that this number does not move.
    pub mounts: u64,
    plugin: Option<Arc<dyn Plugin>>,
    ctx: Option<Arc<Context>>,
}

impl Fiber {
    pub fn id(&self) -> &str {
        &self.entry.id
    }

    pub fn plugin_name(&self) -> &str {
        &self.entry.name
    }

    /// The service keys this plugin declares it needs.
    pub fn inject(&self) -> &'static [&'static str] {
        self.plugin.as_ref().map(|p| p.inject()).unwrap_or(&[])
    }

    pub fn effect_count(&self) -> usize {
        self.ctx.as_ref().map(|c| c.effect_count()).unwrap_or(0)
    }

    pub fn effect_labels(&self) -> Vec<String> {
        self.ctx
            .as_ref()
            .map(|c| c.effect_labels())
            .unwrap_or_default()
    }

    /// The live context, while mounted. Tests and diagnostics only.
    pub fn context(&self) -> Option<&Arc<Context>> {
        self.ctx.as_ref()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingRow {
    pub id: String,
    pub plugin: String,
    pub missing: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FailedRow {
    pub id: String,
    pub plugin: String,
    pub error: String,
}

/// What one `apply` did. Held deliberately verbose: this is the thing a human reads
/// when a plugin quietly did not load.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LoadReport {
    pub mounted: Vec<String>,
    pub unmounted: Vec<String>,
    pub unchanged: Vec<String>,
    pub pending: Vec<PendingRow>,
    pub failed: Vec<FailedRow>,
}

impl LoadReport {
    /// Everything that did not load, in words, ready to print.
    pub fn diagnostics(&self) -> Vec<String> {
        let mut out = Vec::new();
        for row in &self.pending {
            out.push(format!(
                "{} ({}) is PENDING: no service claims {}",
                row.id,
                row.plugin,
                row.missing.join(", ")
            ));
        }
        for row in &self.failed {
            out.push(format!("{} ({}) FAILED: {}", row.id, row.plugin, row.error));
        }
        out
    }

    /// True when every entry that should be running is running.
    pub fn is_clean(&self) -> bool {
        self.pending.is_empty() && self.failed.is_empty()
    }
}

/// The composition root. Owns the service registry, the bus, and the booted tree.
#[derive(Default)]
pub struct Loader {
    services: ServiceRegistry,
    bus: Bus,
    contributions: ContributionRegistry,
    plugins: BTreeMap<&'static str, Arc<dyn Plugin>>,
    fibers: Vec<Fiber>,
}

impl Loader {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn services(&self) -> &ServiceRegistry {
        &self.services
    }

    pub fn bus(&self) -> &Bus {
        &self.bus
    }

    /// Everything the mounted tree contributes to the built-in surfaces.
    pub fn contributions(&self) -> &ContributionRegistry {
        &self.contributions
    }

    pub fn fibers(&self) -> &[Fiber] {
        &self.fibers
    }

    pub fn fiber(&self, id: &str) -> Option<&Fiber> {
        self.fibers.iter().find(|f| f.id() == id)
    }

    pub fn state(&self, id: &str) -> Option<&FiberState> {
        self.fiber(id).map(|f| &f.state)
    }

    /// Make a plugin available to entries by name.
    pub fn register(&mut self, plugin: Arc<dyn Plugin>) -> &mut Self {
        self.plugins.insert(plugin.name(), plugin);
        self
    }

    pub fn registered(&self) -> Vec<&'static str> {
        self.plugins.keys().copied().collect()
    }

    /// Reconcile the booted tree with `entries`.
    ///
    /// Rows are matched by id. A row whose plugin name or config changed is remounted;
    /// a row whose `disabled` flipped is mounted or unmounted; an untouched row is left
    /// strictly alone, effects and all.
    pub fn apply(&mut self, entries: &EntryList) -> Result<LoadReport, DuplicateId> {
        entries.validate()?;
        let mut report = LoadReport::default();

        let wanted: BTreeSet<&str> = entries.entries().iter().map(|e| e.id.as_str()).collect();
        let gone: Vec<String> = self
            .fibers
            .iter()
            .map(|f| f.id().to_string())
            .filter(|id| !wanted.contains(id.as_str()))
            .collect();
        for id in gone {
            self.unmount_cascade(&id, &mut report);
            self.fibers.retain(|f| f.id() != id);
        }

        for entry in entries.entries() {
            match self.fibers.iter().position(|f| f.id() == entry.id) {
                Some(idx) => {
                    let existing = &self.fibers[idx];
                    let redefined =
                        existing.entry.name != entry.name || existing.entry.config != entry.config;
                    if redefined {
                        self.unmount_cascade(&entry.id, &mut report);
                        self.fibers[idx].entry = entry.clone();
                        self.start(idx, &mut report);
                    } else if existing.entry.disabled != entry.disabled {
                        self.fibers[idx].entry = entry.clone();
                        if entry.disabled {
                            self.unmount_cascade(&entry.id, &mut report);
                            self.fibers[idx].state = FiberState::Disabled;
                        } else {
                            self.start(idx, &mut report);
                        }
                    } else {
                        self.fibers[idx].entry = entry.clone();
                        report.unchanged.push(entry.id.clone());
                    }
                }
                None => {
                    self.fibers.push(Fiber {
                        entry: entry.clone(),
                        state: FiberState::Disabled,
                        mounts: 0,
                        plugin: self.plugins.get(entry.name.as_str()).cloned(),
                        ctx: None,
                    });
                    let idx = self.fibers.len() - 1;
                    if entry.disabled {
                        self.fibers[idx].state = FiberState::Disabled;
                    } else {
                        self.start(idx, &mut report);
                    }
                }
            }
        }

        let order: BTreeMap<&str, usize> = entries
            .entries()
            .iter()
            .enumerate()
            .map(|(i, e)| (e.id.as_str(), i))
            .collect();
        self.fibers
            .sort_by_key(|f| order.get(f.id()).copied().unwrap_or(usize::MAX));

        self.settle(&mut report);
        self.collect_diagnostics(&mut report);
        for line in report.diagnostics() {
            tracing::warn!("{line}");
        }
        Ok(report)
    }

    /// Unmount everything, newest row first, then close the registry and the bus.
    pub fn shutdown(&mut self) {
        let mut report = LoadReport::default();
        let ids: Vec<String> = self.fibers.iter().rev().map(|f| f.id().into()).collect();
        for id in ids {
            self.unmount_cascade(&id, &mut report);
        }
        self.fibers.clear();
        self.services.shutdown();
        self.bus.shutdown();
        self.contributions.shutdown();
    }

    /// Try to mount the fiber at `idx`, or park it PENDING with the keys it is missing.
    fn start(&mut self, idx: usize, report: &mut LoadReport) {
        let Some(plugin) = self.fibers[idx].plugin.clone().or_else(|| {
            let name = self.fibers[idx].entry.name.clone();
            self.plugins.get(name.as_str()).cloned()
        }) else {
            let name = self.fibers[idx].entry.name.clone();
            self.fibers[idx].state = FiberState::Failed {
                error: format!("no plugin registered under the name `{name}`"),
            };
            return;
        };
        self.fibers[idx].plugin = Some(Arc::clone(&plugin));

        let missing: Vec<String> = plugin
            .inject()
            .iter()
            .filter(|key| !self.services.has(key))
            .map(|key| (*key).to_string())
            .collect();
        if !missing.is_empty() {
            self.fibers[idx].state = FiberState::Pending { missing };
            return;
        }

        let ctx = Arc::new(Context::new(
            self.fibers[idx].entry.id.clone(),
            self.fibers[idx].entry.config.clone(),
            self.services.clone(),
            self.bus.clone(),
            self.contributions.clone(),
        ));
        match plugin.apply(&ctx) {
            Ok(()) => {
                self.fibers[idx].ctx = Some(ctx);
                self.fibers[idx].state = FiberState::Active;
                self.fibers[idx].mounts += 1;
                report.mounted.push(self.fibers[idx].entry.id.clone());
            }
            Err(error) => {
                // A half-applied plugin still unwinds: the context owns whatever it
                // managed to register, and dropping it here takes all of it back.
                ctx.dispose_all();
                self.fibers[idx].state = FiberState::Failed {
                    error: error.to_string(),
                };
            }
        }
    }

    /// Unmount `id`, but unmount whatever depends on its services first.
    fn unmount_cascade(&mut self, id: &str, report: &mut LoadReport) {
        let provided: BTreeSet<String> = self
            .services
            .rows()
            .into_iter()
            .filter(|row| row.provider == id)
            .map(|row| row.key.to_string())
            .collect();

        if !provided.is_empty() {
            let dependents: Vec<String> = self
                .fibers
                .iter()
                .filter(|f| f.id() != id && f.state.is_active())
                .filter(|f| f.inject().iter().any(|k| provided.contains(*k)))
                .map(|f| f.id().to_string())
                .collect();
            for dependent in dependents {
                self.unmount_cascade(&dependent, report);
                if let Some(fiber) = self.fibers.iter_mut().find(|f| f.id() == dependent) {
                    let missing = fiber
                        .inject()
                        .iter()
                        .filter(|k| provided.contains(**k))
                        .map(|k| (*k).to_string())
                        .collect();
                    fiber.state = FiberState::Pending { missing };
                }
            }
        }

        let Some(fiber) = self.fibers.iter_mut().find(|f| f.id() == id) else {
            return;
        };
        if let Some(ctx) = fiber.ctx.take() {
            ctx.dispose_all();
            fiber.state = FiberState::Pending {
                missing: Vec::new(),
            };
            report.unmounted.push(id.to_string());
        }
    }

    /// Repeat mount passes until nothing new can start. Mounting one plugin can supply
    /// the service another was waiting on, which is the whole point of gating on keys.
    fn settle(&mut self, report: &mut LoadReport) {
        loop {
            let candidates: Vec<usize> = self
                .fibers
                .iter()
                .enumerate()
                .filter(|(_, f)| !f.entry.disabled && f.state.is_pending())
                .map(|(i, _)| i)
                .collect();
            if candidates.is_empty() {
                return;
            }
            let mut progressed = false;
            for idx in candidates {
                self.start(idx, report);
                if self.fibers[idx].state.is_active() {
                    progressed = true;
                }
            }
            if !progressed {
                return;
            }
        }
    }

    fn collect_diagnostics(&self, report: &mut LoadReport) {
        report.pending.clear();
        report.failed.clear();
        for fiber in &self.fibers {
            match &fiber.state {
                FiberState::Pending { missing } => report.pending.push(PendingRow {
                    id: fiber.id().to_string(),
                    plugin: fiber.plugin_name().to_string(),
                    missing: if missing.is_empty() {
                        fiber.inject().iter().map(|k| (*k).to_string()).collect()
                    } else {
                        missing.clone()
                    },
                }),
                FiberState::Failed { error } => report.failed.push(FailedRow {
                    id: fiber.id().to_string(),
                    plugin: fiber.plugin_name().to_string(),
                    error: error.clone(),
                }),
                _ => {}
            }
        }
    }
}

impl Drop for Loader {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Mutex;

    use crate::bus::ObserveEvent;
    use crate::service::Service;

    struct Tick;
    impl ObserveEvent for Tick {
        const NAME: &'static str = "test.tick";
        type Payload = u32;
    }

    trait ClockApi: Send + Sync {
        fn now(&self) -> u64;
    }
    struct ClockService;
    impl Service for ClockService {
        const KEY: &'static str = "clock";
        type Api = dyn ClockApi;
    }
    struct FixedClock(u64);
    impl ClockApi for FixedClock {
        fn now(&self) -> u64 {
            self.0
        }
    }

    /// Provides `clock`. Also counts its own mounts, so a test can prove the loader
    /// left it alone.
    struct ClockPlugin(Arc<AtomicUsize>);
    impl Plugin for ClockPlugin {
        fn name(&self) -> &'static str {
            "clock"
        }
        fn apply(&self, ctx: &Context) -> anyhow::Result<()> {
            self.0.fetch_add(1, Ordering::Relaxed);
            let at = ctx.config().get("at").and_then(|v| v.as_u64()).unwrap_or(0);
            ctx.provide::<ClockService>(Arc::new(FixedClock(at)))?;
            Ok(())
        }
    }

    /// Needs `clock`, and records its teardown order into a shared log.
    struct ReporterPlugin(Arc<Mutex<Vec<&'static str>>>);
    impl Plugin for ReporterPlugin {
        fn name(&self) -> &'static str {
            "reporter"
        }
        fn inject(&self) -> &'static [&'static str] {
            &["clock"]
        }
        fn apply(&self, ctx: &Context) -> anyhow::Result<()> {
            let clock = ctx.resolve::<ClockService>()?;
            let log = Arc::clone(&self.0);
            ctx.effect("reporter:first", {
                let log = Arc::clone(&log);
                move || log.lock().unwrap().push("first")
            });
            ctx.on::<Tick, _>("reporter:listener", move |_| {
                let _ = clock.now();
            });
            ctx.effect("reporter:last", {
                let log = Arc::clone(&log);
                move || log.lock().unwrap().push("last")
            });
            Ok(())
        }
    }

    /// A sibling with no dependencies, to prove a disabled row does not disturb it.
    struct SiblingPlugin;
    impl Plugin for SiblingPlugin {
        fn name(&self) -> &'static str {
            "sibling"
        }
        fn apply(&self, ctx: &Context) -> anyhow::Result<()> {
            ctx.on::<Tick, _>("sibling:listener", |_| {});
            Ok(())
        }
    }

    struct NeedsNothingProvided;
    impl Plugin for NeedsNothingProvided {
        fn name(&self) -> &'static str {
            "orphan"
        }
        fn inject(&self) -> &'static [&'static str] {
            &["transcripts"]
        }
        fn apply(&self, _ctx: &Context) -> anyhow::Result<()> {
            Ok(())
        }
    }

    struct Explodes;
    impl Plugin for Explodes {
        fn name(&self) -> &'static str {
            "explodes"
        }
        fn apply(&self, ctx: &Context) -> anyhow::Result<()> {
            ctx.on::<Tick, _>("explodes:listener", |_| {});
            anyhow::bail!("apply failed on purpose")
        }
    }

    fn loader(log: Arc<Mutex<Vec<&'static str>>>, mounts: Arc<AtomicUsize>) -> Loader {
        let mut loader = Loader::new();
        loader
            .register(Arc::new(ClockPlugin(mounts)))
            .register(Arc::new(ReporterPlugin(log)))
            .register(Arc::new(SiblingPlugin))
            .register(Arc::new(NeedsNothingProvided))
            .register(Arc::new(Explodes));
        loader
    }

    fn fresh() -> (Loader, Arc<Mutex<Vec<&'static str>>>, Arc<AtomicUsize>) {
        let log = Arc::new(Mutex::new(Vec::new()));
        let mounts = Arc::new(AtomicUsize::new(0));
        let l = loader(Arc::clone(&log), Arc::clone(&mounts));
        (l, log, mounts)
    }

    #[test]
    fn load_order_comes_from_declared_dependencies_not_from_the_list_order() {
        let (mut loader, _log, _mounts) = fresh();
        // The consumer is listed *before* its provider on purpose.
        let entries = EntryList::new()
            .push(Entry::new("reporter", "reporter"))
            .push(Entry::new("clock", "clock"));
        let report = loader.apply(&entries).unwrap();
        assert!(report.is_clean(), "{:?}", report.diagnostics());
        assert!(loader.state("reporter").unwrap().is_active());
        assert!(loader.state("clock").unwrap().is_active());
    }

    #[test]
    fn a_plugin_waiting_on_a_missing_service_is_reported_not_silent() {
        let (mut loader, _log, _mounts) = fresh();
        let report = loader
            .apply(&EntryList::new().push(Entry::new("orphan", "orphan")))
            .unwrap();
        assert!(!report.is_clean());
        assert_eq!(
            report.pending,
            [PendingRow {
                id: "orphan".into(),
                plugin: "orphan".into(),
                missing: vec!["transcripts".into()],
            }]
        );
        assert_eq!(
            report.diagnostics(),
            ["orphan (orphan) is PENDING: no service claims transcripts"]
        );
        assert_eq!(
            loader.state("orphan").unwrap(),
            &FiberState::Pending {
                missing: vec!["transcripts".into()]
            }
        );
    }

    #[test]
    fn a_pending_plugin_mounts_when_its_service_finally_arrives() {
        let (mut loader, _log, _mounts) = fresh();
        let mut entries = EntryList::new()
            .push(Entry::new("reporter", "reporter"))
            .push(Entry::new("clock", "clock").disabled(true));
        loader.apply(&entries).unwrap();
        assert!(loader.state("reporter").unwrap().is_pending());

        entries.set_disabled("clock", false);
        let report = loader.apply(&entries).unwrap();
        assert!(report.is_clean(), "{:?}", report.diagnostics());
        assert!(loader.state("reporter").unwrap().is_active());
    }

    #[test]
    fn disabling_a_row_by_id_unmounts_it_and_leaves_its_siblings_alone() {
        let (mut loader, log, mounts) = fresh();
        let mut entries = EntryList::new()
            .push(Entry::new("clock", "clock"))
            .push(Entry::new("reporter", "reporter"))
            .push(Entry::new("sibling", "sibling"));
        loader.apply(&entries).unwrap();
        assert_eq!(loader.bus().listeners_of::<Tick>().len(), 2);
        let sibling_mounts = loader.fiber("sibling").unwrap().mounts;

        entries.set_disabled("reporter", true);
        let report = loader.apply(&entries).unwrap();

        assert_eq!(report.unmounted, ["reporter"]);
        assert_eq!(loader.state("reporter").unwrap(), &FiberState::Disabled);
        // Every effect the disabled row held is gone...
        assert_eq!(*log.lock().unwrap(), ["last", "first"]);
        assert_eq!(loader.fiber("reporter").unwrap().effect_count(), 0);
        assert_eq!(loader.bus().listeners_of::<Tick>(), ["sibling:listener"]);
        // ...and nothing else moved.
        assert!(loader.state("clock").unwrap().is_active());
        assert!(loader.state("sibling").unwrap().is_active());
        assert_eq!(mounts.load(Ordering::Relaxed), 1, "clock must not remount");
        assert_eq!(loader.fiber("sibling").unwrap().mounts, sibling_mounts);
        assert!(loader.services().has("clock"));
    }

    #[test]
    fn a_disabled_row_survives_as_a_row_and_comes_back_when_re_enabled() {
        let (mut loader, _log, _mounts) = fresh();
        let mut entries = EntryList::new()
            .push(Entry::new("clock", "clock"))
            .push(Entry::new("reporter", "reporter").disabled(true));
        loader.apply(&entries).unwrap();
        assert_eq!(loader.fibers().len(), 2);
        assert_eq!(loader.fiber("reporter").unwrap().mounts, 0);

        entries.set_disabled("reporter", false);
        loader.apply(&entries).unwrap();
        assert!(loader.state("reporter").unwrap().is_active());
        assert_eq!(loader.fiber("reporter").unwrap().mounts, 1);
    }

    #[test]
    fn a_plugins_effects_unwind_in_reverse_registration_order() {
        let (mut loader, log, _mounts) = fresh();
        let entries = EntryList::new()
            .push(Entry::new("clock", "clock"))
            .push(Entry::new("reporter", "reporter"));
        loader.apply(&entries).unwrap();
        assert_eq!(
            loader.fiber("reporter").unwrap().effect_labels(),
            [
                "reporter:first",
                "test.tick:reporter:listener",
                "reporter:last"
            ]
        );
        loader
            .apply(&EntryList::new().push(Entry::new("clock", "clock")))
            .unwrap();
        assert_eq!(*log.lock().unwrap(), ["last", "first"]);
    }

    #[test]
    fn unmounting_a_provider_takes_its_dependents_down_first() {
        let (mut loader, log, _mounts) = fresh();
        let mut entries = EntryList::new()
            .push(Entry::new("clock", "clock"))
            .push(Entry::new("reporter", "reporter"))
            .push(Entry::new("sibling", "sibling"));
        loader.apply(&entries).unwrap();

        entries.set_disabled("clock", true);
        let report = loader.apply(&entries).unwrap();

        assert_eq!(report.unmounted, ["reporter", "clock"]);
        assert_eq!(*log.lock().unwrap(), ["last", "first"]);
        assert_eq!(
            loader.state("reporter").unwrap(),
            &FiberState::Pending {
                missing: vec!["clock".into()]
            }
        );
        assert_eq!(
            report.diagnostics(),
            ["reporter (reporter) is PENDING: no service claims clock"]
        );
        assert!(loader.state("sibling").unwrap().is_active());
        assert!(!loader.services().has("clock"));
    }

    #[test]
    fn a_config_change_remounts_only_that_row() {
        let (mut loader, _log, mounts) = fresh();
        let mut entries = EntryList::new()
            .push(Entry::new("clock", "clock"))
            .push(Entry::new("sibling", "sibling"));
        loader.apply(&entries).unwrap();
        assert_eq!(mounts.load(Ordering::Relaxed), 1);

        entries.set_config("clock", serde_json::json!({ "at": 42 }));
        let report = loader.apply(&entries).unwrap();
        assert_eq!(report.mounted, ["clock"]);
        assert_eq!(report.unchanged, ["sibling"]);
        assert_eq!(mounts.load(Ordering::Relaxed), 2);
        assert_eq!(loader.fiber("sibling").unwrap().mounts, 1);
        assert_eq!(
            loader.services().resolve::<ClockService>().unwrap().now(),
            42
        );
    }

    #[test]
    fn re_applying_an_unchanged_list_touches_nothing() {
        let (mut loader, _log, mounts) = fresh();
        let entries = EntryList::new()
            .push(Entry::new("clock", "clock"))
            .push(Entry::new("reporter", "reporter"));
        loader.apply(&entries).unwrap();
        let report = loader.apply(&entries).unwrap();
        assert_eq!(report.unchanged, ["clock", "reporter"]);
        assert!(report.mounted.is_empty());
        assert!(report.unmounted.is_empty());
        assert_eq!(mounts.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn a_row_without_a_stable_id_remounts_on_every_read() {
        let (mut loader, _log, mounts) = fresh();
        loader
            .apply(&EntryList::new().push(Entry::anonymous("clock")))
            .unwrap();
        assert_eq!(mounts.load(Ordering::Relaxed), 1);
        let report = loader
            .apply(&EntryList::new().push(Entry::anonymous("clock")))
            .unwrap();
        assert_eq!(
            mounts.load(Ordering::Relaxed),
            2,
            "no id means no continuity"
        );
        assert_eq!(report.mounted.len(), 1);
        assert_eq!(report.unmounted.len(), 1);
        assert!(report.unchanged.is_empty());
    }

    #[test]
    fn a_failed_apply_unwinds_what_it_managed_to_register() {
        let (mut loader, _log, _mounts) = fresh();
        let report = loader
            .apply(&EntryList::new().push(Entry::new("boom", "explodes")))
            .unwrap();
        assert_eq!(report.failed.len(), 1);
        assert_eq!(report.failed[0].error, "apply failed on purpose");
        assert!(
            loader.bus().listeners_of::<Tick>().is_empty(),
            "a half-applied plugin must not leave listeners behind"
        );
    }

    #[test]
    fn an_entry_naming_an_unregistered_plugin_fails_loudly() {
        let (mut loader, _log, _mounts) = fresh();
        let report = loader
            .apply(&EntryList::new().push(Entry::new("ghost", "not-a-plugin")))
            .unwrap();
        assert_eq!(
            report.diagnostics(),
            ["ghost (not-a-plugin) FAILED: no plugin registered under the name `not-a-plugin`"]
        );
    }

    #[test]
    fn duplicate_entry_ids_are_refused_before_anything_mounts() {
        let (mut loader, _log, mounts) = fresh();
        let err = loader
            .apply(
                &EntryList::new()
                    .push(Entry::new("clock", "clock"))
                    .push(Entry::new("clock", "sibling")),
            )
            .unwrap_err();
        assert_eq!(err.0, "clock");
        assert_eq!(mounts.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn shutdown_unwinds_everything() {
        let (mut loader, log, _mounts) = fresh();
        loader
            .apply(
                &EntryList::new()
                    .push(Entry::new("clock", "clock"))
                    .push(Entry::new("reporter", "reporter")),
            )
            .unwrap();
        loader.shutdown();
        assert_eq!(*log.lock().unwrap(), ["last", "first"]);
        assert!(loader.fibers().is_empty());
        assert!(loader.services().keys().is_empty());
        assert!(loader.bus().rows().is_empty());
    }
}
