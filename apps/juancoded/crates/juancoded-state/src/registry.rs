//! The session registry: the one owner of every session's lifecycle, and the one
//! authority over its grid.
//!
//! Everything structural about this file exists to make a class of bug unwritable
//! rather than fixed:
//!
//! * **One grid, one feeder.** The pty pump publishes bytes on the bus; the
//!   `pty-to-grid` plugin is the only listener that feeds a grid, and the grid lives
//!   behind the `terminal` service's single lock. There is no second parser to race
//!   on the same stream (juancode-9goj), because there is no second parser.
//! * **One resize authority.** [`GridState`] arbitrates, the registry writes the pty
//!   and the grid from the same call, and clients are told which of the three
//!   outcomes happened. A viewer cannot disagree with the pty about cols/rows
//!   (juancode-1th, juancode-8llo).
//! * **Scrollback is never replayed at a guessed width.** Bytes are persisted with
//!   the grid they were written at, and the replay grid is rebuilt at that grid —
//!   the same code path after an exit and after a daemon restart (juancode-grnu).
//! * **The daemon never waits on a client.** Output goes out over a broadcast that
//!   drops a slow receiver's backlog instead of blocking the producer, so a wedged
//!   surface stalls itself and nothing else (juancode-d89, o9h2, jpvj).
//!
//! Pty feeds are deliberately *not* coalesced. Measured parse cost is 0.0769 ms per
//! 16 KB here and parse was never the lag source, so batching would trade a real
//! latency floor for an imaginary saving.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::sync::broadcast;
use tracing::{debug, warn};

use juancoded_cordis::events::{ExitInfo, OutputFrame, SessionExit, SessionOutput};
use juancoded_cordis::services::pty::PtySpawnApi;
use juancoded_cordis::services::terminal::TerminalApi;
use juancoded_cordis::Bus;
use juancoded_core::activity::{
    ActivityDetector, ScreenText, PROMPT_REGION_ROWS, SETTLE_MS, WATCHDOG_MS,
};
use juancoded_core::changes::{self, ChangeStat};
use juancoded_core::model::{now_ms, ProviderId, SessionActivity, SessionMeta, SessionStatus};
use juancoded_core::provider::{resolve_bin, Providers, SpawnOptions};
use juancoded_core::pty::{PtyEvent, PtyHandle, SpawnSpec};
use juancoded_persistence::{Scrollback, SessionStore};
use juancoded_vt::Snapshot;

use crate::grid::{ClientId, GridState, ResizeOutcome};

/// How long between scrollback flushes for a session that keeps producing output. A
/// hard-killed daemon loses at most this much history; a write per chunk would put a
/// SQLite blob on the hot path for nothing.
const FLUSH_EVERY: Duration = Duration::from_secs(2);

/// What the registry publishes. One bus for every consumer: WebSocket connections,
/// the sidecar, a future TUI.
#[derive(Debug, Clone)]
pub enum SessionEvent {
    Output {
        session_id: String,
        bytes: Arc<Vec<u8>>,
    },
    Activity {
        session_id: String,
        state: SessionActivity,
        notify: bool,
        changes: Option<ChangeStat>,
        dispatch_id: Option<String>,
    },
    Exit {
        session_id: String,
        exit_code: Option<i32>,
    },
}

#[derive(Debug, Clone)]
pub struct CreateRequest {
    pub provider: ProviderId,
    pub cwd: String,
    pub cols: u16,
    pub rows: u16,
    pub skip_permissions: bool,
    pub model: Option<String>,
    pub dispatch_id: Option<String>,
    /// The connection that will drive this session's grid. It claims ownership up
    /// front: the client that spawned a session at a size owns that size.
    pub owner: ClientId,
}

/// Adopting a conversation that was started outside juancode, by its own CLI id.
#[derive(Debug, Clone)]
pub struct AdoptRequest {
    pub provider: ProviderId,
    pub cli_session_id: String,
    pub cwd: String,
    /// When the conversation really began, not when we noticed it.
    pub start_ms: i64,
    pub cols: u16,
    pub rows: u16,
    pub owner: ClientId,
}

/// The payload of an `attached` frame, plus the exit a client that missed it is owed.
#[derive(Debug, Clone)]
pub struct Attached {
    pub meta: SessionMeta,
    pub scrollback: String,
    /// `Some` when the session is already over: the client is re-told the exit rather
    /// than left waiting for one that already happened.
    pub replay_exit: Option<Option<i32>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StateError {
    /// No such session, live or remembered.
    NotFound,
    /// The session exists but has no live pty.
    NotRunning,
    NotADirectory(String),
    DispatchAlreadyProcessed(String),
    /// A dead session with no CLI conversation id to resume from.
    Unresumable(String),
    Spawn(String),
    Store(String),
}

impl std::fmt::Display for StateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotFound => write!(f, "Session not found"),
            Self::NotRunning => write!(f, "Session is not running"),
            Self::NotADirectory(cwd) => write!(f, "\"{cwd}\" is not an existing directory"),
            Self::DispatchAlreadyProcessed(id) => {
                write!(f, "Dispatch {id} was already processed")
            }
            Self::Unresumable(reason) => write!(f, "{reason}"),
            Self::Spawn(why) => write!(f, "{why}"),
            Self::Store(why) => write!(f, "{why}"),
        }
    }
}

impl std::error::Error for StateError {}

/// The reason a dead session cannot be revived, worded for a human.
pub const UNRESUMABLE_REASON: &str =
    "No prior CLI conversation could be found to resume this session.";

/// Knobs the daemon sets once at boot.
pub struct RegistryConfig {
    /// Bytes of scrollback kept per session, in memory and in the DB.
    pub scrollback_cap: usize,
    /// Sessions kept per project. 0 = unlimited.
    pub retention: usize,
    /// Grid a client with no viewport of its own gets. The spawn width is permanent
    /// for whatever the CLI prints in its first turn, so this is deliberately roomy.
    pub default_grid: (u16, u16),
    /// Stand in a program for every provider. Tests point this at `/bin/cat` so they
    /// need no CLI installed; production leaves it `None` and resolves from PATH.
    pub program_override: Option<(String, Vec<String>)>,
}

impl Default for RegistryConfig {
    fn default() -> Self {
        Self {
            scrollback_cap: std::env::var("JUANCODE_SCROLLBACK")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(256 * 1024),
            retention: juancoded_persistence::sessions_per_project(),
            default_grid: (120, 40),
            program_override: None,
        }
    }
}

/// Everything one pty launch needs. A struct rather than six positional arguments,
/// because a resize path that swaps cols and rows is exactly the bug this file exists
/// to make unwritable.
struct SpawnPlan {
    program: String,
    args: Vec<String>,
    cwd: String,
    cols: u16,
    rows: u16,
}

/// What reviving a session needs to know: which CLI, where, and whether there is a
/// conversation to resume.
struct Revival {
    provider: ProviderId,
    cwd: String,
    resume: Option<String>,
    cols: u16,
    rows: u16,
}

struct LiveSession {
    meta: Mutex<SessionMeta>,
    /// `None` once the child is gone. The session row outlives its pty.
    pty: Mutex<Option<PtyHandle>>,
    scrollback: Mutex<Ring>,
    grid: Mutex<GridState>,
    activity: Mutex<ActivityDetector>,
    opts: Mutex<SpawnOptions>,
    /// Bumped on every spawn. A pump whose epoch is stale lost its pty to a respawn
    /// and must not report that pty's exit as the session's.
    epoch: AtomicU64,
}

struct Ring {
    bytes: Vec<u8>,
    cap: usize,
    dirty: bool,
    last_flush: Instant,
    /// The grid the stored copy of these bytes was written at. The pair is the unit:
    /// changing the width without rewriting the row would leave the store holding
    /// bytes and a number that never described each other.
    saved_grid: Option<(u16, u16)>,
}

impl Ring {
    fn new(cap: usize) -> Self {
        Self {
            bytes: Vec::new(),
            cap,
            dirty: false,
            last_flush: Instant::now(),
            saved_grid: None,
        }
    }

    fn push(&mut self, bytes: &[u8]) {
        self.bytes.extend_from_slice(bytes);
        if self.bytes.len() > self.cap {
            let drop_to = self.bytes.len() - self.cap;
            self.bytes.drain(..drop_to);
        }
        self.dirty = true;
    }

    fn due(&self) -> bool {
        self.dirty && self.last_flush.elapsed() >= FLUSH_EVERY
    }
}

struct Inner {
    sessions: Mutex<HashMap<String, Arc<LiveSession>>>,
    events: broadcast::Sender<SessionEvent>,
    pty: Arc<dyn PtySpawnApi>,
    terminal: Arc<dyn TerminalApi>,
    store: Arc<dyn SessionStore>,
    bus: Bus,
    config: RegistryConfig,
}

/// The state layer, as one value. Clone-cheap; every clone is the same registry.
#[derive(Clone)]
pub struct SessionRegistry {
    inner: Arc<Inner>,
}

impl SessionRegistry {
    /// Build the registry over the services it composes with, and rehydrate whatever
    /// the store remembers. Spawns nothing and binds nothing.
    pub fn new(
        pty: Arc<dyn PtySpawnApi>,
        terminal: Arc<dyn TerminalApi>,
        store: Arc<dyn SessionStore>,
        bus: Bus,
        config: RegistryConfig,
    ) -> Self {
        let (events, _) = broadcast::channel(4096);
        let inner = Arc::new(Inner {
            sessions: Mutex::new(HashMap::new()),
            events,
            pty,
            terminal,
            store,
            bus,
            config,
        });
        let registry = Self { inner };
        registry.hydrate();
        registry
    }

    /// Read the store back into the session map.
    ///
    /// Every row comes back **exited**: its pty died with the previous daemon, and a
    /// row that claimed to be running would be a session no client could ever get
    /// bytes out of. The scrollback comes back with the grid it was written at, which
    /// is the whole point of storing the two together.
    fn hydrate(&self) {
        let rows = match self.inner.store.all() {
            Ok(rows) => rows,
            Err(e) => {
                warn!(error = %e, "could not read the session store");
                return;
            }
        };
        let mut sessions = self.lock_sessions();
        for mut meta in rows {
            let scrollback = self.inner.store.scrollback(&meta.id).ok().flatten();
            let (cols, rows_) = scrollback
                .as_ref()
                .map(|s| (s.cols, s.rows))
                .unwrap_or(self.inner.config.default_grid);
            if meta.status == SessionStatus::Running {
                meta.status = SessionStatus::Exited;
                meta.updated_at = now_ms();
                let _ = self.inner.store.upsert(&meta);
            }
            let mut ring = Ring::new(self.inner.config.scrollback_cap);
            if let Some(Scrollback { bytes, .. }) = scrollback {
                ring.bytes = bytes;
                ring.saved_grid = Some((cols, rows_));
            }
            let opts = SpawnOptions {
                skip_permissions: meta.skip_permissions,
                model: None,
            };
            sessions.insert(
                meta.id.clone(),
                Arc::new(LiveSession {
                    meta: Mutex::new(meta),
                    pty: Mutex::new(None),
                    scrollback: Mutex::new(ring),
                    grid: Mutex::new(GridState::new(cols, rows_)),
                    activity: Mutex::new(ActivityDetector::new()),
                    opts: Mutex::new(opts),
                    epoch: AtomicU64::new(0),
                }),
            );
        }
        debug!(sessions = sessions.len(), "rehydrated from the store");
    }

    pub fn subscribe(&self) -> broadcast::Receiver<SessionEvent> {
        self.inner.events.subscribe()
    }

    pub fn ids(&self) -> Vec<String> {
        self.lock_sessions().keys().cloned().collect()
    }

    pub fn meta(&self, id: &str) -> Option<SessionMeta> {
        let live = self.get(id)?;
        let meta = live.meta.lock().unwrap_or_else(|e| e.into_inner()).clone();
        Some(meta)
    }

    pub fn is_running(&self, id: &str) -> bool {
        self.get(id)
            .is_some_and(|l| l.pty.lock().unwrap_or_else(|e| e.into_inner()).is_some())
    }

    pub fn activity(&self, id: &str) -> Option<SessionActivity> {
        let live = self.get(id)?;
        let state = live
            .activity
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .state();
        Some(state)
    }

    /// The session's rendered screen. A dead session's grid is rebuilt on demand from
    /// its persisted bytes at the grid they were written at, so this never returns a
    /// picture laid out at a width the CLI never used.
    pub fn snapshot(&self, id: &str) -> Option<Snapshot> {
        let live = self.get(id)?;
        self.ensure_replay_grid(id, &live);
        self.inner.terminal.snapshot(id)
    }

    pub fn scrollback(&self, id: &str) -> Option<String> {
        let live = self.get(id)?;
        let ring = live.scrollback.lock().unwrap_or_else(|e| e.into_inner());
        Some(String::from_utf8_lossy(&ring.bytes).to_string())
    }

    /// The grid this session's authority currently holds.
    pub fn grid(&self, id: &str) -> Option<(u16, u16)> {
        let live = self.get(id)?;
        let grid = live.grid.lock().unwrap_or_else(|e| e.into_inner());
        Some((grid.cols, grid.rows))
    }

    pub fn grid_owner(&self, id: &str) -> Option<ClientId> {
        let live = self.get(id)?;
        let owner = live.grid.lock().unwrap_or_else(|e| e.into_inner()).owner();
        owner
    }

    // MARK: - lifecycle

    pub fn create(&self, req: CreateRequest) -> Result<SessionMeta, StateError> {
        // The dispatch claim comes first, before any check that could fail for its
        // own reasons: a dispatch delivered twice must start one session, and the
        // second delivery has to be told which outcome it is looking at.
        if let Some(dispatch_id) = &req.dispatch_id {
            let claimed = self
                .inner
                .store
                .claim_dispatch(dispatch_id, None)
                .map_err(|e| StateError::Store(e.to_string()))?;
            if !claimed {
                return Err(StateError::DispatchAlreadyProcessed(dispatch_id.clone()));
            }
        }
        if !std::path::Path::new(&req.cwd).is_dir() {
            return Err(StateError::NotADirectory(req.cwd.clone()));
        }

        let id = uuid::Uuid::new_v4().to_string();
        let spec = Providers::spec(req.provider);
        let opts = SpawnOptions {
            skip_permissions: req.skip_permissions,
            model: req.model.clone(),
        };
        let (program, args) = self.program_for(req.provider, &id, &opts, None)?;

        let title = std::path::Path::new(&req.cwd)
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| req.cwd.clone());
        let mut meta = SessionMeta::new(
            id.clone(),
            req.provider,
            req.cwd.clone(),
            title,
            now_ms(),
            req.skip_permissions,
        );
        // Claude pins its conversation id to ours, so the session is resumable at
        // once; the others have to be discovered from their own state later.
        if spec.pins_session_id {
            meta.cli_session_id = Some(id.clone());
        }
        meta.dispatch_id = req.dispatch_id.clone();

        let live = Arc::new(LiveSession {
            meta: Mutex::new(meta.clone()),
            pty: Mutex::new(None),
            scrollback: Mutex::new(Ring::new(self.inner.config.scrollback_cap)),
            grid: Mutex::new(GridState::new(req.cols, req.rows)),
            activity: Mutex::new(ActivityDetector::new()),
            opts: Mutex::new(opts),
            epoch: AtomicU64::new(0),
        });
        // The creating client owns the grid it spawned the session at.
        live.grid
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .request(req.owner);

        self.lock_sessions().insert(id.clone(), Arc::clone(&live));
        self.inner
            .store
            .upsert(&meta)
            .map_err(|e| StateError::Store(e.to_string()))?;

        // The grid exists before the first byte can arrive, so the output path never
        // gets to invent a geometry of its own.
        self.inner
            .terminal
            .open(&id, req.cols as usize, req.rows as usize);

        let plan = SpawnPlan {
            program,
            args,
            cwd: req.cwd.clone(),
            cols: req.cols,
            rows: req.rows,
        };
        match self.spawn_into(&id, &live, plan) {
            Ok(()) => Ok(meta),
            Err(e) => {
                self.lock_sessions().remove(&id);
                self.inner.terminal.close(&id);
                let _ = self.inner.store.delete(&id);
                Err(e)
            }
        }
    }

    /// Adopt a conversation started outside juancode. `Ok(None)` means we already own
    /// it, which is a no-op rather than a duplicate.
    pub fn adopt_external(&self, req: AdoptRequest) -> Result<Option<SessionMeta>, StateError> {
        let used = self
            .inner
            .store
            .used_cli_session_ids()
            .map_err(|e| StateError::Store(e.to_string()))?;
        if used.iter().any(|u| u == &req.cli_session_id) {
            return Ok(None);
        }
        if !std::path::Path::new(&req.cwd).is_dir() {
            return Err(StateError::NotADirectory(req.cwd.clone()));
        }

        let id = uuid::Uuid::new_v4().to_string();
        let opts = SpawnOptions::default();
        let (program, args) =
            self.program_for(req.provider, &id, &opts, Some(&req.cli_session_id))?;

        let title = std::path::Path::new(&req.cwd)
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| req.cwd.clone());
        let mut meta = SessionMeta::new(
            id.clone(),
            req.provider,
            req.cwd.clone(),
            title,
            req.start_ms,
            false,
        );
        // The age that matters is the conversation's, not the adoption's.
        meta.created_at = req.start_ms;
        meta.cli_session_id = Some(req.cli_session_id.clone());

        let live = Arc::new(LiveSession {
            meta: Mutex::new(meta.clone()),
            pty: Mutex::new(None),
            scrollback: Mutex::new(Ring::new(self.inner.config.scrollback_cap)),
            grid: Mutex::new(GridState::new(req.cols, req.rows)),
            activity: Mutex::new(ActivityDetector::new()),
            opts: Mutex::new(opts),
            epoch: AtomicU64::new(0),
        });
        live.grid
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .request(req.owner);
        self.lock_sessions().insert(id.clone(), Arc::clone(&live));
        self.inner
            .store
            .upsert(&meta)
            .map_err(|e| StateError::Store(e.to_string()))?;
        self.inner
            .terminal
            .open(&id, req.cols as usize, req.rows as usize);

        let plan = SpawnPlan {
            program,
            args,
            cwd: req.cwd.clone(),
            cols: req.cols,
            rows: req.rows,
        };
        match self.spawn_into(&id, &live, plan) {
            Ok(()) => Ok(Some(meta)),
            Err(e) => {
                self.lock_sessions().remove(&id);
                self.inner.terminal.close(&id);
                let _ = self.inner.store.delete(&id);
                Err(e)
            }
        }
    }

    /// Attach a client. A live session hands back its scrollback; a dead one hands
    /// back its scrollback *and* re-states the exit, so a client is never left
    /// waiting for an event that already happened.
    pub fn attach(
        &self,
        id: &str,
        owner: ClientId,
        cols: u16,
        rows: u16,
    ) -> Result<Attached, StateError> {
        let live = self.get(id).ok_or(StateError::NotFound)?;
        // Arbitrated: a bare attach from a secondary viewer must not move the grid.
        self.resize(id, owner, cols, rows);
        self.flush_scrollback(id, &live, true);
        let meta = live.meta.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let scrollback = {
            let ring = live.scrollback.lock().unwrap_or_else(|e| e.into_inner());
            String::from_utf8_lossy(&ring.bytes).to_string()
        };
        let replay_exit = if meta.status == SessionStatus::Exited {
            Some(meta.exit_code)
        } else {
            None
        };
        Ok(Attached {
            meta,
            scrollback,
            replay_exit,
        })
    }

    /// Revive a dead session in place. `Ok(None)` means it was already live.
    pub fn reactivate(
        &self,
        id: &str,
        owner: ClientId,
        cols: u16,
        rows: u16,
    ) -> Result<Option<Attached>, StateError> {
        let live = self.get(id).ok_or(StateError::NotFound)?;
        if live.pty.lock().unwrap_or_else(|e| e.into_inner()).is_some() {
            return Ok(None);
        }
        let (provider, cwd, cli_session_id) = {
            let meta = live.meta.lock().unwrap_or_else(|e| e.into_inner());
            (meta.provider, meta.cwd.clone(), meta.cli_session_id.clone())
        };
        let Some(cli_session_id) = cli_session_id else {
            return Err(StateError::Unresumable(UNRESUMABLE_REASON.to_string()));
        };
        self.respawn(
            id,
            &live,
            Revival {
                provider,
                cwd,
                resume: Some(cli_session_id),
                cols,
                rows,
            },
        )?;
        self.attach(id, owner, cols, rows).map(Some)
    }

    /// Flip a live session's permission mode by restarting the CLI in place: same
    /// session id, same scrollback, new argv. The client stays attached to the id it
    /// already knows.
    pub fn set_skip_permissions(
        &self,
        id: &str,
        skip: bool,
        owner: ClientId,
        cols: u16,
        rows: u16,
    ) -> Result<Attached, StateError> {
        let live = self.get(id).ok_or(StateError::NotRunning)?;
        if live.pty.lock().unwrap_or_else(|e| e.into_inner()).is_none() {
            return Err(StateError::NotRunning);
        }
        let (provider, cwd, cli_session_id) = {
            let meta = live.meta.lock().unwrap_or_else(|e| e.into_inner());
            (meta.provider, meta.cwd.clone(), meta.cli_session_id.clone())
        };
        {
            let mut opts = live.opts.lock().unwrap_or_else(|e| e.into_inner());
            opts.skip_permissions = skip;
        }
        {
            let mut meta = live.meta.lock().unwrap_or_else(|e| e.into_inner());
            meta.skip_permissions = skip;
            meta.updated_at = now_ms();
        }
        // `respawn` retires the old pty, and retiring is what stops its exit from
        // being reported as the session's.
        self.respawn(
            id,
            &live,
            Revival {
                provider,
                cwd,
                resume: cli_session_id,
                cols,
                rows,
            },
        )?;
        self.attach(id, owner, cols, rows)
    }

    pub fn input(&self, id: &str, data: &[u8]) -> Result<(), StateError> {
        use juancoded_cordis::events::{InputDecision, InputRequest, SessionInput};
        if self.get(id).is_none() {
            return Err(StateError::NotFound);
        }
        // Input goes through the around chain, so policy (a live-pty guard today, a
        // steering queue's claim boundary later) can refuse it without the registry
        // knowing that any policy exists.
        let mut request = InputRequest::new(id, data.to_vec());
        let decision = self.inner.bus.waterfall::<SessionInput>(&mut request, |_| {
            InputDecision::Refused("no writer is mounted for `session.input`".into())
        });
        match decision {
            InputDecision::Delivered(_) => Ok(()),
            InputDecision::Refused(why) => Err(StateError::Spawn(why)),
        }
    }

    /// The one resize path. Arbitrates, writes the pty and the grid together, and
    /// reports which of the three outcomes happened.
    pub fn resize(&self, id: &str, owner: ClientId, cols: u16, rows: u16) -> ResizeOutcome {
        let Some(live) = self.get(id) else {
            // Nothing to resize, and not denied: the client should re-assert once the
            // session exists rather than give up on it.
            return ResizeOutcome::NOTHING;
        };
        let pty = live.pty.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let mut grid = live.grid.lock().unwrap_or_else(|e| e.into_inner());
        if !grid.request(owner) {
            return ResizeOutcome::DENIED;
        }
        let applied = match &pty {
            Some(handle) => handle.resize(cols, rows).unwrap_or(false),
            None => false,
        };
        let changed = (grid.cols, grid.rows) != (cols, rows);
        grid.set(cols, rows, pty.is_some());
        drop(grid);

        if pty.is_some() {
            // The grid follows the pty in the same call, from the same numbers. This
            // is what makes "the client cannot disagree about cols/rows" structural
            // rather than a thing we remember to do.
            self.inner.terminal.resize(id, cols as usize, rows as usize);
        } else if changed {
            // A dead session's grid is a replay surface: re-lay the persisted bytes
            // out at the new width instead of reflowing a picture that was never
            // drawn at it.
            self.rebuild_replay_grid(id, &live, cols, rows);
        }
        ResizeOutcome {
            applied,
            denied: false,
        }
    }

    /// Re-assert the owner's grid once the TUI is up. A CLI that installs its SIGWINCH
    /// handler late can miss a resize that landed during boot, and one genuine
    /// re-assert on a settled screen is enough to make it re-read the size.
    pub fn reapply_grid(&self, id: &str) -> bool {
        let Some(live) = self.get(id) else {
            return false;
        };
        let (cols, rows, needed) = {
            let grid = live.grid.lock().unwrap_or_else(|e| e.into_inner());
            (grid.cols, grid.rows, grid.needs_reapply())
        };
        if !needed {
            return false;
        }
        let pty = live.pty.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let Some(handle) = pty else { return false };
        let applied = handle.resize(cols, rows).unwrap_or(false);
        self.inner.terminal.resize(id, cols as usize, rows as usize);
        live.grid
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .settled();
        applied
    }

    /// A connection went away: drop its grid claims so the next client can take over.
    pub fn release_client(&self, owner: ClientId) {
        for live in self.lock_sessions().values() {
            live.grid
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .release(owner);
        }
    }

    pub fn kill(&self, id: &str) -> Result<(), StateError> {
        let live = self.get(id).ok_or(StateError::NotFound)?;
        if live.pty.lock().unwrap_or_else(|e| e.into_inner()).is_none() {
            return Err(StateError::NotRunning);
        }
        self.inner
            .pty
            .kill(id)
            .map_err(|e| StateError::Spawn(e.to_string()))
    }

    // MARK: - internals

    fn get(&self, id: &str) -> Option<Arc<LiveSession>> {
        self.lock_sessions().get(id).cloned()
    }

    fn lock_sessions(&self) -> std::sync::MutexGuard<'_, HashMap<String, Arc<LiveSession>>> {
        self.inner
            .sessions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
    }

    fn program_for(
        &self,
        provider: ProviderId,
        id: &str,
        opts: &SpawnOptions,
        resume: Option<&str>,
    ) -> Result<(String, Vec<String>), StateError> {
        let spec = Providers::spec(provider);
        let args = match resume {
            Some(cli_id) => (spec.resume_args)(cli_id, opts),
            None => (spec.start_args)(id, opts),
        };
        if let Some((program, override_args)) = &self.inner.config.program_override {
            return Ok((program.clone(), override_args.clone()));
        }
        let env_key = match provider {
            ProviderId::Claude => "JUANCODE_CLAUDE_BIN",
            ProviderId::Codex => "JUANCODE_CODEX_BIN",
            ProviderId::Opencode => "JUANCODE_OPENCODE_BIN",
        };
        let override_path = std::env::var(env_key).ok();
        let program =
            resolve_bin(provider.as_str(), override_path.as_deref()).ok_or_else(|| {
                StateError::Spawn(format!(
                    "Failed to start {}: not on PATH",
                    provider.as_str()
                ))
            })?;
        Ok((program, args))
    }

    /// Give up the pty a session is holding, ahead of the one that replaces it.
    ///
    /// The epoch moves *before* the kill, and it moves under the meta lock — the same
    /// lock [`Self::on_exit`] re-reads it under. Both halves are load bearing. Killing
    /// first leaves a window in which the dying child's exit still matches its pump's
    /// epoch, and that exit would mark a live session dead, drop the replacement's
    /// handle and reap the replacement itself. Bumping without the lock only narrows
    /// the window: a pump that read the epoch a moment earlier is already past the
    /// check. Under the lock the two orders are the only two, and both end with the
    /// session running.
    fn retire_pty(&self, id: &str, live: &Arc<LiveSession>) {
        {
            let _serialised = live.meta.lock().unwrap_or_else(|e| e.into_inner());
            live.epoch.fetch_add(1, Ordering::SeqCst);
        }
        let _ = self.inner.pty.kill(id);
        let mut slot = live.pty.lock().unwrap_or_else(|e| e.into_inner());
        *slot = None;
    }

    /// Spawn a pty for a session that has none, and start its pump.
    fn spawn_into(
        &self,
        id: &str,
        live: &Arc<LiveSession>,
        plan: SpawnPlan,
    ) -> Result<(), StateError> {
        let provider = live.meta.lock().unwrap_or_else(|e| e.into_inner()).provider;
        let opts = live.opts.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let env_overlay = (Providers::spec(provider).spawn_env)(&opts);
        let handle = self
            .inner
            .pty
            .spawn(
                id,
                SpawnSpec {
                    program: plan.program,
                    args: plan.args,
                    cwd: plan.cwd,
                    cols: plan.cols,
                    rows: plan.rows,
                    env_overlay,
                },
            )
            .map_err(|e| StateError::Spawn(format!("Failed to start {provider:?}: {e}")))?;
        let epoch = live.epoch.fetch_add(1, Ordering::SeqCst) + 1;
        {
            let mut slot = live.pty.lock().unwrap_or_else(|e| e.into_inner());
            *slot = Some(handle.clone());
        }
        {
            let mut grid = live.grid.lock().unwrap_or_else(|e| e.into_inner());
            grid.set(plan.cols, plan.rows, true);
        }
        self.start_pump(id.to_string(), Arc::clone(live), epoch, handle);
        Ok(())
    }

    /// Restart a session's CLI in place, keeping its id, scrollback and grid.
    fn respawn(
        &self,
        id: &str,
        live: &Arc<LiveSession>,
        revival: Revival,
    ) -> Result<(), StateError> {
        let Revival {
            provider,
            cwd,
            resume,
            cols,
            rows,
        } = revival;
        let opts = live.opts.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let (program, args) = self.program_for(provider, id, &opts, resume.as_deref())?;
        // Retire whatever pty the session is still holding, or the spawn below
        // refuses the session key as already taken.
        self.retire_pty(id, live);
        // The old grid held a dead session's replay; the CLI is about to repaint from
        // scratch, so start it clean at the grid the reviving client asked for.
        self.inner.terminal.close(id);
        self.inner.terminal.open(id, cols as usize, rows as usize);
        {
            let mut meta = live.meta.lock().unwrap_or_else(|e| e.into_inner());
            meta.status = SessionStatus::Running;
            meta.exit_code = None;
            meta.updated_at = now_ms();
        }
        {
            let mut det = live.activity.lock().unwrap_or_else(|e| e.into_inner());
            det.reset();
        }
        self.spawn_into(
            id,
            live,
            SpawnPlan {
                program,
                args,
                cwd,
                cols,
                rows,
            },
        )?;
        let meta = live.meta.lock().unwrap_or_else(|e| e.into_inner()).clone();
        self.inner
            .store
            .upsert(&meta)
            .map_err(|e| StateError::Store(e.to_string()))?;
        Ok(())
    }

    /// The one writer of a session's byte history, and the only place output enters
    /// the system. It publishes; it never waits on anyone who reads.
    fn start_pump(&self, id: String, live: Arc<LiveSession>, epoch: u64, pty: PtyHandle) {
        let registry = self.clone();
        let mut rx = pty.subscribe();
        tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(PtyEvent::Output(bytes)) => {
                        if live.epoch.load(Ordering::SeqCst) != epoch {
                            break;
                        }
                        registry.on_output(&id, &live, bytes);
                    }
                    Ok(PtyEvent::Exit(code)) => {
                        // A respawn replaced this pty; its death is not the session's,
                        // and reporting it would exit a live session. `on_exit` reads
                        // the epoch again under the meta lock, which is what makes the
                        // decision a decision rather than a guess.
                        registry.on_exit(&id, &live, code, epoch).await;
                        break;
                    }
                    // Lagged means *our* backlog was dropped, not the grid's: the
                    // grid is fed from this task and nowhere else.
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        debug!(session = id, dropped = n, "pty pump lagged");
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });
    }

    fn on_output(&self, id: &str, live: &Arc<LiveSession>, bytes: Arc<Vec<u8>>) {
        let chunk = Arc::clone(&bytes);
        // The bus feeds the grid: one listener, one grid, one lock. Emitting first
        // means the screen the activity classifier re-reads already includes this
        // chunk, which is the only ordering that makes settle correct.
        self.inner.bus.emit::<SessionOutput>(&OutputFrame {
            session: id.to_string(),
            bytes: Arc::clone(&bytes),
        });
        {
            let mut ring = live.scrollback.lock().unwrap_or_else(|e| e.into_inner());
            ring.push(&bytes);
        }
        self.flush_scrollback(id, live, false);
        let _ = self.inner.events.send(SessionEvent::Output {
            session_id: id.to_string(),
            bytes,
        });

        let (transition, armed, prev) = {
            let mut det = live.activity.lock().unwrap_or_else(|e| e.into_inner());
            let prev = det.state();
            let step = det.on_output(&chunk, || self.screen_text(id));
            (step.transition, step.armed, prev)
        };
        if let Some(t) = transition {
            self.broadcast_activity(id, live, prev, t);
        }
        if let Some(armed) = armed {
            self.arm_settle(id, live, armed);
        }
    }

    fn arm_settle(&self, id: &str, live: &Arc<LiveSession>, armed: juancoded_core::Armed) {
        let settle = (self.clone(), Arc::clone(live), id.to_string());
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(SETTLE_MS)).await;
            settle
                .0
                .settle(&settle.2, &settle.1, armed.generation, false);
        });
        if armed.watchdog {
            let watchdog = (self.clone(), Arc::clone(live), id.to_string());
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(WATCHDOG_MS)).await;
                watchdog
                    .0
                    .settle(&watchdog.2, &watchdog.1, armed.generation, true);
            });
        }
    }

    fn settle(
        &self,
        id: &str,
        live: &Arc<LiveSession>,
        generation: u64,
        demote_stale_footer: bool,
    ) {
        let screen = self.screen_text(id);
        let (transition, prev) = {
            let mut det = live.activity.lock().unwrap_or_else(|e| e.into_inner());
            let prev = det.state();
            (det.settle(generation, demote_stale_footer, &screen), prev)
        };
        if let Some(t) = transition {
            self.broadcast_activity(id, live, prev, t);
            // A settled screen is a fully initialised TUI, which is the one moment a
            // missed spawn-time resize is safe to re-assert.
            self.reapply_grid(id);
        }
    }

    fn broadcast_activity(
        &self,
        id: &str,
        live: &Arc<LiveSession>,
        prev: SessionActivity,
        transition: juancoded_core::Transition,
    ) {
        let (cwd, dispatch_id) = {
            let meta = live.meta.lock().unwrap_or_else(|e| e.into_inner());
            (meta.effective_cwd().to_string(), meta.dispatch_id.clone())
        };
        // Only a notifying turn boundary is worth two `git` invocations.
        let changes = if changes::should_compute(prev, transition.state, transition.notify) {
            changes::rollup(&cwd).filter(|c| !c.is_empty())
        } else {
            None
        };
        let _ = self.inner.events.send(SessionEvent::Activity {
            session_id: id.to_string(),
            state: transition.state,
            notify: transition.notify,
            changes,
            dispatch_id,
        });
    }

    /// Record a pty's death as the session's, unless that pty has been retired.
    ///
    /// `epoch` is the pump's. It is compared under the meta lock because that is the
    /// lock [`Self::retire_pty`] moves the epoch under: a stale exit must not reach
    /// any of what follows, least of all the `pty.kill` that would reap the
    /// replacement child.
    async fn on_exit(&self, id: &str, live: &Arc<LiveSession>, code: Option<i32>, epoch: u64) {
        // The check and the write are one critical section: splitting them would put
        // the window straight back.
        let Some(cwd) = ({
            let mut meta = live.meta.lock().unwrap_or_else(|e| e.into_inner());
            if live.epoch.load(Ordering::SeqCst) != epoch {
                None
            } else {
                meta.status = SessionStatus::Exited;
                meta.exit_code = code;
                meta.updated_at = now_ms();
                Some(meta.cwd.clone())
            }
        }) else {
            return;
        };
        {
            let mut slot = live.pty.lock().unwrap_or_else(|e| e.into_inner());
            *slot = None;
        }
        // Reap the pty service's entry for a child that ended on its own, so the
        // input guard starts refusing writes and a later revive can reuse the key.
        let _ = self.inner.pty.kill(id);
        // Persist before the grid goes: the bytes and the grid they were written at
        // have to land together or the replay has to guess.
        self.flush_scrollback(id, live, true);
        let meta = live.meta.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if let Err(e) = self.inner.store.upsert(&meta) {
            warn!(session = id, error = %e, "could not persist the exit");
        }
        {
            let mut det = live.activity.lock().unwrap_or_else(|e| e.into_inner());
            det.reset();
        }
        self.inner
            .bus
            .parallel::<SessionExit>(ExitInfo {
                session: id.to_string(),
                code,
            })
            .await;
        let _ = self.inner.events.send(SessionEvent::Exit {
            session_id: id.to_string(),
            exit_code: code,
        });
        self.prune_project(&cwd);
    }

    /// Trim this project's history to the cap. Only exited sessions are candidates:
    /// the cap is about how much we remember, never about killing live work.
    fn prune_project(&self, cwd: &str) {
        let pruned = match self
            .inner
            .store
            .prune_project(cwd, self.inner.config.retention)
        {
            Ok(pruned) => pruned,
            Err(e) => {
                warn!(error = %e, "retention pass failed");
                return;
            }
        };
        if pruned.is_empty() {
            return;
        }
        let doomed: HashSet<String> = pruned.into_iter().collect();
        let mut sessions = self.lock_sessions();
        for id in &doomed {
            sessions.remove(id);
            self.inner.terminal.close(id);
        }
        debug!(
            project = cwd,
            dropped = doomed.len(),
            "retention cap applied"
        );
    }

    /// Write the byte ring and the grid it was written at. `force` skips the
    /// time-based throttle (an exit or an attach must not read a stale row).
    fn flush_scrollback(&self, id: &str, live: &Arc<LiveSession>, force: bool) {
        let (cols, rows) = {
            let grid = live.grid.lock().unwrap_or_else(|e| e.into_inner());
            (grid.cols, grid.rows)
        };
        let bytes = {
            let mut ring = live.scrollback.lock().unwrap_or_else(|e| e.into_inner());
            // A width change is as much a reason to rewrite as a byte change: the
            // stored row is the pair, and a stale half of it is the whole bug.
            let regridded = ring.saved_grid != Some((cols, rows));
            if !ring.dirty && !regridded {
                return;
            }
            if !force && !regridded && !ring.due() {
                return;
            }
            ring.dirty = false;
            ring.last_flush = Instant::now();
            ring.saved_grid = Some((cols, rows));
            ring.bytes.clone()
        };
        if let Err(e) = self.inner.store.save_scrollback(id, cols, rows, &bytes) {
            warn!(session = id, error = %e, "could not persist scrollback");
        }
    }

    /// Make sure a non-running session has a grid to be read from, rebuilt at the
    /// grid its bytes were written at. A running session always has one already.
    fn ensure_replay_grid(&self, id: &str, live: &Arc<LiveSession>) {
        if self.inner.terminal.snapshot(id).is_some() {
            return;
        }
        let (cols, rows) = {
            let grid = live.grid.lock().unwrap_or_else(|e| e.into_inner());
            (grid.cols, grid.rows)
        };
        self.rebuild_replay_grid(id, live, cols, rows);
    }

    fn rebuild_replay_grid(&self, id: &str, live: &Arc<LiveSession>, cols: u16, rows: u16) {
        let bytes = {
            let ring = live.scrollback.lock().unwrap_or_else(|e| e.into_inner());
            ring.bytes.clone()
        };
        self.inner.terminal.close(id);
        self.inner.terminal.open(id, cols as usize, rows as usize);
        if !bytes.is_empty() {
            self.inner.terminal.feed(id, &bytes);
        }
        // The bytes are now the picture at this grid, so the store has to say so
        // before anything else reads it back.
        self.flush_scrollback(id, live, true);
    }

    fn screen_text(&self, id: &str) -> ScreenText {
        match self.inner.terminal.snapshot(id) {
            Some(snapshot) => ScreenText {
                full: snapshot.text(),
                bottom: snapshot.bottom_text(PROMPT_REGION_ROWS),
            },
            None => ScreenText::default(),
        }
    }
}
