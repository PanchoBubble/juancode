//! The plugin/effect seam — cordis's central idea, expressed natively.
//!
//! In cordis, "registrations are reversible effects": a plugin registers something
//! and gets back a handle whose disposal undoes it. In Swift that needs bookkeeping
//! and discipline. In Rust it is a value whose `Drop` unregisters, so a leaked
//! registration is a compile-time-visible mistake rather than a runtime leak — which
//! is one of the four reasons in the epic for moving.
//!
//! juancode-52e8.4 builds the real thing (typed event bus, entry list, dump-config).
//! What is here is the shape, proven by test.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use tracing::debug;

type Entries = Arc<Mutex<HashMap<String, Vec<String>>>>;

/// A registry of contributions keyed by extension point.
#[derive(Clone, Default)]
pub struct EffectRegistry {
    entries: Entries,
}

/// A live registration. Dropping it removes the contribution — no explicit
/// teardown path to forget.
#[must_use = "dropping the guard immediately unregisters the contribution"]
pub struct EffectGuard {
    entries: Entries,
    point: String,
    id: String,
}

impl EffectRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Contribute `id` to extension point `point` for as long as the guard lives.
    pub fn register(&self, point: &str, id: &str) -> EffectGuard {
        if let Ok(mut entries) = self.entries.lock() {
            entries
                .entry(point.to_string())
                .or_default()
                .push(id.to_string());
        }
        debug!(point, id, "registered");
        EffectGuard {
            entries: Arc::clone(&self.entries),
            point: point.to_string(),
            id: id.to_string(),
        }
    }

    pub fn entries(&self, point: &str) -> Vec<String> {
        self.entries
            .lock()
            .ok()
            .and_then(|e| e.get(point).cloned())
            .unwrap_or_default()
    }

    /// Everything currently registered — the seed of `dump-config`.
    pub fn dump(&self) -> HashMap<String, Vec<String>> {
        self.entries.lock().map(|e| e.clone()).unwrap_or_default()
    }
}

impl Drop for EffectGuard {
    fn drop(&mut self) {
        if let Ok(mut entries) = self.entries.lock() {
            if let Some(list) = entries.get_mut(&self.point) {
                if let Some(pos) = list.iter().position(|i| i == &self.id) {
                    list.remove(pos);
                }
                if list.is_empty() {
                    entries.remove(&self.point);
                }
            }
        }
        debug!(point = %self.point, id = %self.id, "unregistered on drop");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_registration_lives_exactly_as_long_as_its_guard() {
        let reg = EffectRegistry::new();
        {
            let _g = reg.register("sidebar.section", "tracked-prs");
            assert_eq!(reg.entries("sidebar.section"), ["tracked-prs"]);
        }
        assert!(
            reg.entries("sidebar.section").is_empty(),
            "guard drop did not unregister"
        );
    }

    #[test]
    fn guards_unregister_only_their_own_entry() {
        let reg = EffectRegistry::new();
        let a = reg.register("panel", "changes");
        let b = reg.register("panel", "reasoning");
        drop(a);
        assert_eq!(reg.entries("panel"), ["reasoning"]);
        drop(b);
        assert!(reg.dump().is_empty(), "empty points should not linger");
    }

    #[test]
    fn dump_reports_every_point() {
        let reg = EffectRegistry::new();
        let _a = reg.register("panel", "changes");
        let _b = reg.register("command", "openEditor");
        let dump = reg.dump();
        assert_eq!(dump.len(), 2);
        assert_eq!(dump["command"], ["openEditor"]);
    }
}
