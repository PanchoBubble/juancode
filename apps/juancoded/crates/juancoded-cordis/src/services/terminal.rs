//! The `terminal` service: one VT grid per session, behind a key.
//!
//! A thin adapter over `juancoded-vt`, which owns the real `alacritty_terminal` grid.
//! The adapter adds exactly one thing the grid does not have: a name to look it up by.
//! It deliberately keeps the "one owner" property that makes the VT crate worth having,
//! by holding every grid behind a single mutex and handing out value snapshots only.

use std::collections::BTreeMap;
use std::sync::Mutex;

use juancoded_vt::{Snapshot, TerminalModel};

use crate::service::Service;

/// What consumers of the `terminal` key may do.
pub trait TerminalApi: Send + Sync {
    /// Open a grid for `session` at that geometry, or leave the existing one alone.
    ///
    /// Create-if-absent, deliberately: `open` is called from the output path, whose
    /// caller does not know the session's real grid, and a second authority over
    /// cols/rows is the whole bug class this daemon exists to retire. Changing an
    /// existing grid goes through [`TerminalApi::resize`], which the session registry
    /// owns.
    fn open(&self, session: &str, cols: usize, rows: usize);
    fn feed(&self, session: &str, bytes: &[u8]);
    /// The OSC 0/2 window title the program set since this was last called, if any.
    /// Taking rather than reading: the caller adopts a title once, and a TUI repaints
    /// its own title many times per turn.
    fn take_title(&self, session: &str) -> Option<String>;
    fn resize(&self, session: &str, cols: usize, rows: usize);
    fn snapshot(&self, session: &str) -> Option<Snapshot>;
    /// The visible screen as text, which is what activity detection and search want.
    fn text(&self, session: &str) -> Option<String>;
    fn close(&self, session: &str);
    fn open_sessions(&self) -> Vec<String>;
}

/// The contract marker: `ctx.resolve::<TerminalService>()` yields `Arc<dyn TerminalApi>`.
pub struct TerminalService;

impl Service for TerminalService {
    const KEY: &'static str = "terminal";
    type Api = dyn TerminalApi;
}

/// The real implementation, over `juancoded_vt::TerminalModel`.
pub struct VtTerminals {
    history: usize,
    grids: Mutex<BTreeMap<String, TerminalModel>>,
}

impl VtTerminals {
    pub fn new(history: usize) -> Self {
        Self {
            history,
            grids: Mutex::new(BTreeMap::new()),
        }
    }

    fn grids(&self) -> std::sync::MutexGuard<'_, BTreeMap<String, TerminalModel>> {
        self.grids.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl Default for VtTerminals {
    fn default() -> Self {
        Self::new(2_000)
    }
}

impl TerminalApi for VtTerminals {
    fn open(&self, session: &str, cols: usize, rows: usize) {
        let mut grids = self.grids();
        if grids.contains_key(session) {
            return;
        }
        grids.insert(
            session.to_string(),
            TerminalModel::new(cols, rows, self.history),
        );
    }

    fn feed(&self, session: &str, bytes: &[u8]) {
        if let Some(model) = self.grids().get_mut(session) {
            model.feed(bytes);
        }
    }

    fn take_title(&self, session: &str) -> Option<String> {
        self.grids().get_mut(session).and_then(|m| m.take_title())
    }

    fn resize(&self, session: &str, cols: usize, rows: usize) {
        if let Some(model) = self.grids().get_mut(session) {
            model.resize(cols, rows);
        }
    }

    fn snapshot(&self, session: &str) -> Option<Snapshot> {
        self.grids().get(session).map(|m| m.snapshot())
    }

    fn text(&self, session: &str) -> Option<String> {
        self.grids().get(session).map(|m| m.snapshot().text())
    }

    fn close(&self, session: &str) {
        self.grids().remove(session);
    }

    fn open_sessions(&self) -> Vec<String> {
        self.grids().keys().cloned().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opening_an_existing_grid_leaves_its_geometry_alone() {
        let terminals = VtTerminals::new(100);
        terminals.open("s1", 80, 24);
        terminals.feed("s1", b"hello");
        // The output path re-opens on every frame at whatever default it was
        // configured with; that must never move a grid the registry sized.
        terminals.open("s1", 120, 40);
        let snapshot = terminals.snapshot("s1").expect("grid");
        assert_eq!((snapshot.cols, snapshot.rows), (80, 24));
        assert!(terminals.text("s1").unwrap().contains("hello"));

        // The one authority that does move it.
        terminals.resize("s1", 120, 40);
        let snapshot = terminals.snapshot("s1").expect("grid");
        assert_eq!((snapshot.cols, snapshot.rows), (120, 40));
    }

    #[test]
    fn a_window_title_the_program_set_is_readable_per_session() {
        let terminals = VtTerminals::new(100);
        terminals.open("s1", 80, 24);
        terminals.open("s2", 80, 24);
        terminals.feed("s1", b"\x1b]2;one\x07");
        assert_eq!(
            terminals.take_title("s2"),
            None,
            "titles do not cross grids"
        );
        assert_eq!(terminals.take_title("s1").as_deref(), Some("one"));
        assert_eq!(terminals.take_title("s1"), None);
        assert_eq!(terminals.take_title("nope"), None, "no grid, no title");
    }

    #[test]
    fn closing_forgets_the_grid_so_a_reopen_starts_clean() {
        let terminals = VtTerminals::new(100);
        terminals.open("s1", 40, 10);
        terminals.feed("s1", b"stale");
        terminals.close("s1");
        assert!(terminals.snapshot("s1").is_none());
        terminals.open("s1", 40, 10);
        assert_eq!(terminals.text("s1").unwrap().trim(), "");
    }
}
