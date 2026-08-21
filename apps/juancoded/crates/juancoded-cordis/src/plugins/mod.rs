//! The plugins the daemon boots. Providers first, glue second.
//!
//! Every one of these is a value implementing [`crate::plugin::Plugin`]; none of them
//! is referenced by name from anywhere but an entry list, which is what makes the
//! composition a config question rather than a code question.

mod activity_log;
mod core_pty;
mod input_guard;
mod pty_to_grid;
mod vt_terminal;

pub use activity_log::ActivityLog;
pub use core_pty::CorePty;
pub use input_guard::InputGuard;
pub use pty_to_grid::PtyToGrid;
pub use vt_terminal::VtTerminal;

use std::sync::Arc;

use crate::entry::{Entry, EntryList};
use crate::loader::Loader;

/// Register every built-in plugin with a loader. Registering does not mount: the entry
/// list decides what runs.
pub fn register_builtins(loader: &mut Loader) {
    loader
        .register(Arc::new(VtTerminal))
        .register(Arc::new(CorePty))
        .register(Arc::new(InputGuard))
        .register(Arc::new(PtyToGrid))
        .register(Arc::new(ActivityLog));
}

/// The tree the daemon boots by default. `activity-log` is in it and stays PENDING
/// until a transcripts service exists, which is the state `dump-config` has to make
/// visible rather than swallow.
pub fn default_entries() -> EntryList {
    EntryList::new()
        .push(Entry::new("terminal", "vt-terminal"))
        .push(Entry::new("pty", "core-pty"))
        .push(Entry::new("input-guard", "input-guard"))
        .push(Entry::new("pty-to-grid", "pty-to-grid"))
        .push(Entry::new("activity-log", "activity-log"))
}
