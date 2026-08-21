//! `dump-config`: the tree the daemon actually booted, not the tree the config asked
//! for.
//!
//! Every entry row is addressed by its id, which is the same string
//! `EntryList::set_disabled` takes, so reading the output tells you exactly what to
//! type to change it. Rows that did not load say why on the same line: a PENDING
//! plugin naming the key it waits for is the difference between a diagnosable harness
//! and cordis's silent one.
//!
//! Services and events are sorted by name. `TypeId` ordering is not stable across
//! builds and a diagnostic that reorders itself between runs is not a diagnostic.

use std::fmt::Write as _;

use crate::loader::Loader;
use crate::plugin::FiberState;

/// Render the booted tree.
pub fn dump_config(loader: &Loader) -> String {
    let fibers = loader.fibers();
    let services = loader.services().rows();
    let events = loader.bus().rows();

    let active = fibers.iter().filter(|f| f.state.is_active()).count();
    let pending = fibers.iter().filter(|f| f.state.is_pending()).count();
    let disabled = fibers
        .iter()
        .filter(|f| matches!(f.state, FiberState::Disabled))
        .count();
    let failed = fibers
        .iter()
        .filter(|f| matches!(f.state, FiberState::Failed { .. }))
        .count();

    let mut out = String::new();
    let _ = writeln!(
        out,
        "juancoded config: {} entries ({active} active, {pending} pending, {disabled} disabled, {failed} failed), {} services, {} events",
        fibers.len(),
        services.len(),
        events.len()
    );

    let id_w = width(fibers.iter().map(|f| f.id()));
    let name_w = width(fibers.iter().map(|f| f.plugin_name()));

    let _ = writeln!(out, "\nentries");
    for (i, fiber) in fibers.iter().enumerate() {
        let mut row = format!(
            "{} [{:<8}] {:<id_w$}  {:<name_w$}",
            branch(i, fibers.len()),
            fiber.state.label(),
            fiber.id(),
            fiber.plugin_name(),
        );
        if !fiber.inject().is_empty() {
            let _ = write!(row, "  needs={}", fiber.inject().join(","));
        }
        match &fiber.state {
            FiberState::Active => {
                let _ = write!(row, "  effects={}", fiber.effect_count());
            }
            FiberState::Pending { missing } => {
                let missing: Vec<&str> = if missing.is_empty() {
                    fiber.inject().to_vec()
                } else {
                    missing.iter().map(String::as_str).collect()
                };
                let _ = write!(row, "  missing={}", missing.join(","));
            }
            FiberState::Failed { error } => {
                let _ = write!(row, "  error={error}");
            }
            FiberState::Disabled => {}
        }
        let _ = writeln!(out, "{}", row.trim_end());
    }

    let _ = writeln!(out, "\nservices");
    if services.is_empty() {
        let _ = writeln!(out, "└─ (none)");
    } else {
        let key_w = width(services.iter().map(|s| s.key));
        for (i, service) in services.iter().enumerate() {
            let _ = writeln!(
                out,
                "{} {:<key_w$}  <- {}",
                branch(i, services.len()),
                service.key,
                service.provider
            );
        }
    }

    let _ = writeln!(out, "\nevents");
    if events.is_empty() {
        let _ = writeln!(out, "└─ (none)");
    } else {
        let name_w = width(events.iter().map(|e| e.name));
        for (i, event) in events.iter().enumerate() {
            let listeners = if event.listeners.is_empty() {
                "(none)".to_string()
            } else {
                event.listeners.join(",")
            };
            let _ = writeln!(
                out,
                "{} {:<name_w$}  {:<7}  {}  {}",
                branch(i, events.len()),
                event.name,
                event.mode.as_str(),
                event.listeners.len(),
                listeners
            );
        }
    }
    out
}

fn branch(index: usize, total: usize) -> &'static str {
    if index + 1 == total {
        "└─"
    } else {
        "├─"
    }
}

fn width<'a>(items: impl Iterator<Item = &'a str>) -> usize {
    items.map(str::len).max().unwrap_or(0)
}
