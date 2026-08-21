//! The `pty` service: spawn a real CLI in a real pty, behind a key.
//!
//! A thin adapter over `juancoded_core::pty::PtyHandle`. It adds a session-keyed
//! index and nothing else; in particular it does not touch the child's environment,
//! because env fidelity is the property the whole daemon exists to preserve and
//! `PtyHandle::spawn` already guarantees it by construction.

use std::collections::BTreeMap;
use std::sync::Mutex;

use anyhow::{anyhow, Result};
use juancoded_core::pty::{PtyHandle, SpawnSpec};

use crate::service::Service;

/// What consumers of the `pty` key may do.
pub trait PtySpawnApi: Send + Sync {
    fn spawn(&self, session: &str, spec: SpawnSpec) -> Result<PtyHandle>;
    fn handle(&self, session: &str) -> Option<PtyHandle>;
    fn write(&self, session: &str, bytes: &[u8]) -> Result<()>;
    fn kill(&self, session: &str) -> Result<()>;
    fn live(&self) -> Vec<String>;
}

/// The contract marker: `ctx.resolve::<PtySpawnService>()` yields `Arc<dyn PtySpawnApi>`.
pub struct PtySpawnService;

impl Service for PtySpawnService {
    const KEY: &'static str = "pty";
    type Api = dyn PtySpawnApi;
}

/// The real implementation, over `portable-pty` via `juancoded-core`.
pub struct PtyHost {
    buffer: usize,
    live: Mutex<BTreeMap<String, PtyHandle>>,
}

impl PtyHost {
    pub fn new(buffer: usize) -> Self {
        Self {
            buffer,
            live: Mutex::new(BTreeMap::new()),
        }
    }

    fn live_map(&self) -> std::sync::MutexGuard<'_, BTreeMap<String, PtyHandle>> {
        self.live.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl Default for PtyHost {
    fn default() -> Self {
        Self::new(1_024)
    }
}

impl PtySpawnApi for PtyHost {
    fn spawn(&self, session: &str, spec: SpawnSpec) -> Result<PtyHandle> {
        if self.live_map().contains_key(session) {
            return Err(anyhow!("session `{session}` already has a pty"));
        }
        let handle = PtyHandle::spawn(spec, self.buffer)?;
        self.live_map().insert(session.to_string(), handle.clone());
        Ok(handle)
    }

    fn handle(&self, session: &str) -> Option<PtyHandle> {
        self.live_map().get(session).cloned()
    }

    fn write(&self, session: &str, bytes: &[u8]) -> Result<()> {
        self.handle(session)
            .ok_or_else(|| anyhow!("no pty for session `{session}`"))?
            .write(bytes)
    }

    fn kill(&self, session: &str) -> Result<()> {
        match self.live_map().remove(session) {
            Some(handle) => handle.kill(),
            None => Err(anyhow!("no pty for session `{session}`")),
        }
    }

    fn live(&self) -> Vec<String> {
        self.live_map().keys().cloned().collect()
    }
}

impl Drop for PtyHost {
    fn drop(&mut self) {
        // The service owning a child means the service is responsible for it: an
        // unmount that left `claude` processes behind would be a worse leak than any
        // registration this crate protects against.
        for (_, handle) in self.live_map().iter() {
            let _ = handle.kill();
        }
    }
}
