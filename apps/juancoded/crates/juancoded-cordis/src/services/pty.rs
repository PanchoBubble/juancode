//! The `pty` service: spawn a real CLI in a real pty, behind a key.
//!
//! A thin adapter over `juancoded_core::pty::PtyHandle`. It adds a session-keyed
//! index and nothing else; in particular it does not touch the child's environment,
//! because env fidelity is the property the whole daemon exists to preserve and
//! `PtyHandle::spawn` already guarantees it by construction.

use std::collections::BTreeMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};
use juancoded_core::pty::{PtyHandle, SpawnSpec, STOP_GRACE};

use crate::service::Service;

/// What consumers of the `pty` key may do.
pub trait PtySpawnApi: Send + Sync {
    fn spawn(&self, session: &str, spec: SpawnSpec) -> Result<PtyHandle>;
    fn handle(&self, session: &str) -> Option<PtyHandle>;
    fn write(&self, session: &str, bytes: &[u8]) -> Result<()>;
    /// End a session's child: ask it to stop, let it flush, then insist. The session
    /// key is free again the moment this returns, so a respawn can reuse it.
    fn stop(&self, session: &str) -> Result<()>;
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

    fn stop(&self, session: &str) -> Result<()> {
        match self.live_map().remove(session) {
            Some(handle) => handle.stop(),
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
        //
        // Every child is asked first and waited for together, not one after another:
        // a CLI needs its grace to flush its transcript (juancode-6cqj), and N
        // sessions serialised would cost N graces on the way out of the process.
        let handles: Vec<PtyHandle> = self.live_map().values().cloned().collect();
        for handle in &handles {
            handle.request_stop();
        }
        let deadline = Instant::now() + STOP_GRACE;
        while Instant::now() < deadline && handles.iter().any(|h| !h.has_exited()) {
            std::thread::sleep(Duration::from_millis(10));
        }
        for handle in &handles {
            if !handle.has_exited() {
                let _ = handle.kill();
            }
        }
    }
}
