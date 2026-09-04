//! Shared scaffolding for the state-layer regression tests.
//!
//! Every test here drives the real tree — real cordis services, a real pty, a real
//! `alacritty_terminal` grid, a real SQLite file — with a two-line shell loop
//! standing in for a provider CLI. It reads a line and prints it back, so a test can
//! paint any screen it needs, escape sequences included.
//!
//! It turns the tty's own echo off first, and it says so before a test may write, and
//! both halves matter. With echo on, every write reaches the grid twice, once from
//! the line discipline and once from the child, and the two copies can interleave with
//! a later write or land either side of a screen assertion. Turning echo off is not
//! enough on its own, because the child needs a moment to do it: `create` waits for the
//! stand-in's ready marker, so a test asserting on screen state is never asserting on a
//! race it created itself.
#![allow(dead_code)]

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use juancoded_cordis::Loader;
use juancoded_core::model::ProviderId;
use juancoded_state::registry::{CreateRequest, SessionEvent};
use juancoded_state::SessionsApi;
use tokio::sync::broadcast::Receiver;

/// The stand-in CLI: echo off, say so, then one line in, one line out.
const ECHO_LOOP: &str = "stty -echo 2>/dev/null; printf '\\033]777;juancoded-ready\\007'; \
                         while IFS= read -r line; do printf '%s\r\n' \"$line\"; done";

/// How the stand-in says echo is off. An OSC number nobody implements, so it reaches
/// the scrollback and leaves the grid untouched: a test asserting on a screen must not
/// have to account for the handshake that got it there.
const READY: &str = "juancoded-ready";

/// A booted tree plus the store file it is using, so a test can drop it and boot a
/// second tree over the same file.
pub struct Harness {
    pub sessions: Arc<dyn SessionsApi>,
    loader: Option<Loader>,
    pub store: PathBuf,
    pub dir: PathBuf,
    /// A restart hands the store file to the next tree, so its own drop must leave
    /// the directory alone.
    keep_dir: bool,
}

impl Harness {
    /// A fresh tree over a fresh store directory named after `label`.
    pub fn new(label: &str) -> Self {
        let dir = std::env::temp_dir().join(format!(
            "juancoded-state-{label}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).expect("scratch dir");
        let store = dir.join("state.db");
        Self::reopen(dir, store)
    }

    /// A tree over an existing store: the "daemon restarted" case.
    pub fn reopen(dir: PathBuf, store: PathBuf) -> Self {
        let entries = juancoded_state::test_entries_at(
            store.to_str().expect("utf8 store path"),
            "/bin/sh",
            &["-c", ECHO_LOOP],
        );
        let (loader, report, sessions) =
            juancoded_state::boot_with(&entries).expect("the tree mounts");
        // Every row in the daemon's tree has its providers now that `transcripts` is
        // mounted, so anything pending here is a mounting bug rather than the standing
        // example it used to be.
        assert!(report.pending.is_empty(), "{:?}", report.diagnostics());
        Self {
            sessions,
            loader: Some(loader),
            store,
            dir,
            keep_dir: false,
        }
    }

    /// Drop the whole tree and boot a new one over the same store file.
    pub fn restart(mut self) -> Self {
        let (dir, store) = (self.dir.clone(), self.store.clone());
        self.keep_dir = true;
        drop(self);
        Self::reopen(dir, store)
    }

    /// Create a session and wait until its stand-in has turned echo off.
    ///
    /// The wait is the point. With echo on, a write is reflected by the line
    /// discipline *and* printed by the child, and the second copy can land after a
    /// screen assertion has already read the first, which shows up much later as a
    /// replay that holds everything twice.
    pub async fn create(&self, cwd: &str, cols: u16, rows: u16, owner: u64) -> String {
        // Subscribed before the spawn, or the marker can be gone before we listen.
        let mut rx = self.sessions.subscribe();
        let id = self
            .sessions
            .create(CreateRequest {
                provider: ProviderId::Claude,
                cwd: cwd.into(),
                cols,
                rows,
                skip_permissions: false,
                model: None,
                preset: None,
                isolate_worktree: false,
                dispatch_id: None,
                owner,
            })
            .expect("create")
            .id;
        // Read the marker off the raw stream rather than the grid: it is an OSC the
        // grid deliberately does not render, and a chunk boundary can fall inside it.
        let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
        let mut seen = String::new();
        loop {
            let event = tokio::time::timeout_at(deadline, rx.recv())
                .await
                .expect("the stand-in CLI never signalled that echo was off")
                .expect("the session bus closed");
            if let SessionEvent::Output { session_id, bytes } = event {
                if session_id == id {
                    seen.push_str(&String::from_utf8_lossy(&bytes));
                    if seen.contains(READY) {
                        return id;
                    }
                }
            }
        }
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        // Unmounting the tree unwinds every plugin's effects, which is what kills the
        // ptys this test spawned. `sessions` is a clone-cheap handle and its Arc may
        // still be alive in the test's own local, so the loader is the thing that has
        // to go.
        drop(self.loader.take());
        if !self.keep_dir {
            std::fs::remove_dir_all(&self.dir).ok();
        }
    }
}

/// Wait for an event matching `pred`, or fail. `secs` is generous on purpose: these
/// tests spawn real processes on a machine that may be busy building.
pub async fn wait_for(
    rx: &mut Receiver<SessionEvent>,
    secs: u64,
    mut pred: impl FnMut(&SessionEvent) -> bool,
) -> SessionEvent {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(secs);
    loop {
        let event = tokio::time::timeout_at(deadline, rx.recv())
            .await
            .expect("timed out waiting for a session event")
            .expect("the session bus closed");
        if pred(&event) {
            return event;
        }
    }
}

/// Wait until the session's rendered screen contains `needle`.
pub async fn wait_for_screen(sessions: &Arc<dyn SessionsApi>, id: &str, needle: &str, secs: u64) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(secs);
    loop {
        if sessions
            .snapshot(id)
            .is_some_and(|s| s.text().contains(needle))
        {
            return;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "the grid never showed {needle:?}; it shows {:?}",
            sessions.snapshot(id).map(|s| s.text())
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

pub async fn wait_for_exit(rx: &mut Receiver<SessionEvent>, id: &str) -> Option<i32> {
    match wait_for(
        rx,
        20,
        |e| matches!(e, SessionEvent::Exit { session_id, .. } if session_id == id),
    )
    .await
    {
        SessionEvent::Exit { exit_code, .. } => exit_code,
        _ => unreachable!("the predicate only matches an exit"),
    }
}
