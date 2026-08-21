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
    /// Open a grid for `session`. Opening one that exists resizes it instead.
    fn open(&self, session: &str, cols: usize, rows: usize);
    fn feed(&self, session: &str, bytes: &[u8]);
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
        match grids.get_mut(session) {
            Some(model) => model.resize(cols, rows),
            None => {
                grids.insert(
                    session.to_string(),
                    TerminalModel::new(cols, rows, self.history),
                );
            }
        }
    }

    fn feed(&self, session: &str, bytes: &[u8]) {
        if let Some(model) = self.grids().get_mut(session) {
            model.feed(bytes);
        }
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
