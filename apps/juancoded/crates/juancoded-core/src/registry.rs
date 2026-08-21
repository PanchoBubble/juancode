//! The session registry: the one owner of every live pty and every VT grid.
//!
//! A port of the shape of `JuancodeCore/SessionRegistry.swift`, reduced to what the
//! spike needs (create / attach / input / resize / kill / scrollback / activity).
//! The important structural claim is the grid ownership: a session's
//! `TerminalModel` sits behind that session's own lock and is fed from exactly one
//! place — the pty pump. Views are `snapshot()` readers. The "two parsers, one
//! stream, different threads" bug class (juancode-9goj, grnu, 1th) cannot be
//! written here.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, Result};
use tokio::sync::broadcast;
use tracing::debug;

use crate::model::{now_ms, ProviderId, SessionActivity, SessionMeta, SessionStatus};
use crate::provider::{resolve_bin, Providers, SpawnOptions};
use crate::pty::{PtyEvent, PtyHandle, SpawnSpec};
use juancoded_vt::{Snapshot, TerminalModel};

/// Scrollback kept per session for `attached` replay. The Swift core persists a
/// larger window to SQLite; the spike keeps a byte ring in memory.
const SCROLLBACK_CAP: usize = 512 * 1024;
/// Quiet time after the last output byte before a session is called idle. The Swift
/// `ActivityDetector` is far richer (prompt shapes, waiting-input detection); this
/// is the spike-level stand-in.
const IDLE_AFTER_MS: u64 = 700;

/// What the registry publishes about a session. One bus for every consumer
/// (WebSocket connections, the sidecar, a future TUI).
#[derive(Debug, Clone)]
pub enum SessionEvent {
    Output {
        session_id: String,
        bytes: Arc<Vec<u8>>,
    },
    Activity {
        session_id: String,
        state: SessionActivity,
    },
    Exit {
        session_id: String,
        exit_code: Option<i32>,
    },
}

/// What a client asked for when creating a session.
#[derive(Debug, Clone)]
pub struct CreateRequest {
    pub provider: ProviderId,
    pub cwd: String,
    pub cols: u16,
    pub rows: u16,
    pub skip_permissions: bool,
    pub model: Option<String>,
    pub dispatch_id: Option<String>,
}

struct LiveSession {
    meta: Mutex<SessionMeta>,
    pty: PtyHandle,
    /// The one grid. Fed only by the pump task; read by snapshotters.
    model: Mutex<TerminalModel>,
    scrollback: Mutex<Vec<u8>>,
    activity: Mutex<SessionActivity>,
    /// Bumped on every output chunk; the idle watchdog only fires when the token it
    /// captured is still current, which is a debounce without a timer per byte.
    output_epoch: Mutex<u64>,
}

pub struct Registry {
    sessions: Mutex<HashMap<String, Arc<LiveSession>>>,
    events: broadcast::Sender<SessionEvent>,
}

impl Default for Registry {
    fn default() -> Self {
        Self::new()
    }
}

impl Registry {
    pub fn new() -> Self {
        let (events, _) = broadcast::channel(4096);
        Self {
            sessions: Mutex::new(HashMap::new()),
            events,
        }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<SessionEvent> {
        self.events.subscribe()
    }

    pub fn ids(&self) -> Vec<String> {
        self.sessions
            .lock()
            .map(|s| s.keys().cloned().collect())
            .unwrap_or_default()
    }

    pub fn meta(&self, session_id: &str) -> Option<SessionMeta> {
        let sessions = self.sessions.lock().ok()?;
        let live = sessions.get(session_id)?;
        live.meta.lock().ok().map(|m| m.clone())
    }

    pub fn activity(&self, session_id: &str) -> Option<SessionActivity> {
        let sessions = self.sessions.lock().ok()?;
        let live = sessions.get(session_id)?;
        live.activity.lock().ok().map(|a| *a)
    }

    /// The session's scrollback, decoded lossily — the `attached` payload.
    pub fn scrollback(&self, session_id: &str) -> Option<String> {
        let sessions = self.sessions.lock().ok()?;
        let live = sessions.get(session_id)?;
        let bytes = live.scrollback.lock().ok()?;
        Some(String::from_utf8_lossy(&bytes).to_string())
    }

    /// A point-in-time projection of the session's grid.
    pub fn snapshot(&self, session_id: &str) -> Option<Snapshot> {
        let sessions = self.sessions.lock().ok()?;
        let live = sessions.get(session_id)?;
        live.model.lock().ok().map(|m| m.snapshot())
    }

    /// Spawn a session. `program_override` lets a test point at `/bin/cat` instead
    /// of needing a real CLI installed — the same seam the Swift `BinaryResolver`
    /// protocol provides.
    pub fn create(
        self: &Arc<Self>,
        req: CreateRequest,
        program_override: Option<(String, Vec<String>)>,
    ) -> Result<SessionMeta> {
        let spec = Providers::spec(req.provider);
        let opts = SpawnOptions {
            skip_permissions: req.skip_permissions,
            model: req.model.clone(),
        };
        let id = uuid::Uuid::new_v4().to_string();

        let (program, args) = match program_override {
            Some(pair) => pair,
            None => {
                let env_key = match req.provider {
                    ProviderId::Claude => "JUANCODE_CLAUDE_BIN",
                    ProviderId::Codex => "JUANCODE_CODEX_BIN",
                    ProviderId::Opencode => "JUANCODE_OPENCODE_BIN",
                };
                let override_path = std::env::var(env_key).ok();
                let program = resolve_bin(req.provider.as_str(), override_path.as_deref())
                    .ok_or_else(|| anyhow!("{} is not on PATH", req.provider.as_str()))?;
                (program, (spec.start_args)(&id, &opts))
            }
        };

        let pty = PtyHandle::spawn(
            SpawnSpec {
                program,
                args,
                cwd: req.cwd.clone(),
                cols: req.cols,
                rows: req.rows,
                env_overlay: (spec.spawn_env)(&opts),
            },
            4096,
        )?;

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
        // Claude pins its own conversation id to ours, so it is resumable at once.
        if spec.pins_session_id {
            meta.cli_session_id = Some(id.clone());
        }
        meta.dispatch_id = req.dispatch_id.clone();

        let live = Arc::new(LiveSession {
            meta: Mutex::new(meta.clone()),
            pty: pty.clone(),
            model: Mutex::new(TerminalModel::new(
                req.cols as usize,
                req.rows as usize,
                10_000,
            )),
            scrollback: Mutex::new(Vec::new()),
            activity: Mutex::new(SessionActivity::Busy),
            output_epoch: Mutex::new(0),
        });

        self.sessions
            .lock()
            .map_err(|_| anyhow!("registry poisoned"))?
            .insert(id.clone(), Arc::clone(&live));

        self.start_pump(id.clone(), live);
        Ok(meta)
    }

    /// The one writer into a session's grid: consume pty events, feed the model,
    /// append scrollback, republish on the session bus.
    fn start_pump(self: &Arc<Self>, session_id: String, live: Arc<LiveSession>) {
        let registry = Arc::clone(self);
        let mut rx = live.pty.subscribe();
        tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(PtyEvent::Output(bytes)) => {
                        if let Ok(mut model) = live.model.lock() {
                            model.feed(&bytes);
                        }
                        if let Ok(mut sb) = live.scrollback.lock() {
                            sb.extend_from_slice(&bytes);
                            if sb.len() > SCROLLBACK_CAP {
                                let drop_to = sb.len() - SCROLLBACK_CAP;
                                sb.drain(..drop_to);
                            }
                        }
                        registry.mark_busy(&session_id, &live);
                        let _ = registry.events.send(SessionEvent::Output {
                            session_id: session_id.clone(),
                            bytes,
                        });
                    }
                    Ok(PtyEvent::Exit(code)) => {
                        if let Ok(mut meta) = live.meta.lock() {
                            meta.status = SessionStatus::Exited;
                            meta.exit_code = code;
                            meta.updated_at = now_ms();
                        }
                        debug!(session_id, ?code, "session exited");
                        let _ = registry.events.send(SessionEvent::Exit {
                            session_id: session_id.clone(),
                            exit_code: code,
                        });
                        break;
                    }
                    // Lagged: the grid is still correct (the pump is the only
                    // writer and broadcast drops only *our* backlog), so keep going.
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        debug!(session_id, dropped = n, "pty pump lagged");
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });
    }

    /// Flip to busy on output and arm the idle watchdog. Only the watchdog whose
    /// epoch is still current gets to declare idle, so a burst of output arms one
    /// effective timer rather than one per chunk.
    fn mark_busy(self: &Arc<Self>, session_id: &str, live: &Arc<LiveSession>) {
        let epoch = {
            let Ok(mut e) = live.output_epoch.lock() else {
                return;
            };
            *e += 1;
            *e
        };
        let changed = {
            let Ok(mut a) = live.activity.lock() else {
                return;
            };
            let was = *a;
            *a = SessionActivity::Busy;
            was != SessionActivity::Busy
        };
        if changed {
            let _ = self.events.send(SessionEvent::Activity {
                session_id: session_id.to_string(),
                state: SessionActivity::Busy,
            });
        }

        let registry = Arc::clone(self);
        let live = Arc::clone(live);
        let id = session_id.to_string();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(IDLE_AFTER_MS)).await;
            let still_current = live
                .output_epoch
                .lock()
                .map(|e| *e == epoch)
                .unwrap_or(false);
            if !still_current {
                return;
            }
            let changed = {
                let Ok(mut a) = live.activity.lock() else {
                    return;
                };
                let was = *a;
                *a = SessionActivity::Idle;
                was != SessionActivity::Idle
            };
            if changed {
                let _ = registry.events.send(SessionEvent::Activity {
                    session_id: id,
                    state: SessionActivity::Idle,
                });
            }
        });
    }

    pub fn input(&self, session_id: &str, data: &[u8]) -> Result<()> {
        self.with_session(session_id, |live| live.pty.write(data))?
    }

    /// Resize the pty and the grid together — one owner, one geometry. Returns
    /// whether it reached a live pty (the `applied` field of `resizeAck`).
    pub fn resize(&self, session_id: &str, cols: u16, rows: u16) -> Result<bool> {
        self.with_session(session_id, |live| {
            let applied = live.pty.resize(cols, rows)?;
            if let Ok(mut model) = live.model.lock() {
                model.resize(cols as usize, rows as usize);
            }
            Ok(applied)
        })?
    }

    pub fn kill(&self, session_id: &str) -> Result<()> {
        self.with_session(session_id, |live| live.pty.kill())?
    }

    fn with_session<T>(
        &self,
        session_id: &str,
        f: impl FnOnce(&Arc<LiveSession>) -> T,
    ) -> Result<T> {
        let sessions = self
            .sessions
            .lock()
            .map_err(|_| anyhow!("registry poisoned"))?;
        let live = sessions
            .get(session_id)
            .ok_or_else(|| anyhow!("no such session"))?;
        Ok(f(live))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn cat_request() -> CreateRequest {
        CreateRequest {
            provider: ProviderId::Claude,
            cwd: "/tmp".into(),
            cols: 80,
            rows: 24,
            skip_permissions: false,
            model: None,
            dispatch_id: None,
        }
    }

    /// Wait for a predicate over registry events, or fail.
    async fn wait_for(
        rx: &mut broadcast::Receiver<SessionEvent>,
        mut pred: impl FnMut(&SessionEvent) -> bool,
    ) -> SessionEvent {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        loop {
            let ev = tokio::time::timeout_at(deadline, rx.recv())
                .await
                .expect("timed out waiting for event")
                .expect("event bus closed");
            if pred(&ev) {
                return ev;
            }
        }
    }

    #[tokio::test]
    async fn create_feeds_the_grid_and_the_scrollback_from_one_pump() {
        let reg = Arc::new(Registry::new());
        let mut rx = reg.subscribe();
        let meta = reg
            .create(
                cat_request(),
                Some(("/bin/echo".into(), vec!["grid-hello".into()])),
            )
            .expect("create");
        assert_eq!(meta.status, SessionStatus::Running);
        // Claude pins its id, so the session is resumable immediately.
        assert_eq!(meta.cli_session_id.as_deref(), Some(meta.id.as_str()));

        wait_for(&mut rx, |ev| matches!(ev, SessionEvent::Exit { .. })).await;

        let snap = reg.snapshot(&meta.id).expect("snapshot");
        assert!(
            snap.text().contains("grid-hello"),
            "grid: {:?}",
            snap.text()
        );
        assert!(reg.scrollback(&meta.id).unwrap().contains("grid-hello"));
        let after = reg.meta(&meta.id).expect("meta");
        assert_eq!(after.status, SessionStatus::Exited);
        assert_eq!(after.exit_code, Some(0));
    }

    #[tokio::test]
    async fn input_lands_in_the_grid_and_activity_settles_to_idle() {
        let reg = Arc::new(Registry::new());
        let mut rx = reg.subscribe();
        let meta = reg
            .create(cat_request(), Some(("/bin/cat".into(), vec![])))
            .expect("create");

        reg.input(&meta.id, b"typed-into-cat\n").expect("input");
        wait_for(&mut rx, |ev| match ev {
            SessionEvent::Output { bytes, .. } => {
                String::from_utf8_lossy(bytes).contains("typed-into-cat")
            }
            _ => false,
        })
        .await;
        assert!(reg
            .snapshot(&meta.id)
            .unwrap()
            .text()
            .contains("typed-into-cat"));

        wait_for(&mut rx, |ev| {
            matches!(
                ev,
                SessionEvent::Activity {
                    state: SessionActivity::Idle,
                    ..
                }
            )
        })
        .await;
        assert_eq!(reg.activity(&meta.id), Some(SessionActivity::Idle));
        reg.kill(&meta.id).expect("kill");
    }

    #[tokio::test]
    async fn resize_moves_the_pty_and_the_grid_together() {
        let reg = Arc::new(Registry::new());
        let meta = reg
            .create(cat_request(), Some(("/bin/cat".into(), vec![])))
            .expect("create");
        assert_eq!(reg.snapshot(&meta.id).unwrap().cols, 80);
        assert!(reg.resize(&meta.id, 100, 30).expect("resize"));
        let snap = reg.snapshot(&meta.id).unwrap();
        assert_eq!((snap.cols, snap.rows), (100, 30));
        // Re-asserting the same grid is a no-op, which is what `applied: false` means.
        assert!(!reg.resize(&meta.id, 100, 30).expect("resize"));
        reg.kill(&meta.id).expect("kill");
    }

    #[tokio::test]
    async fn a_kill_reports_the_exit_on_the_bus() {
        let reg = Arc::new(Registry::new());
        let mut rx = reg.subscribe();
        let meta = reg
            .create(cat_request(), Some(("/bin/cat".into(), vec![])))
            .expect("create");
        reg.kill(&meta.id).expect("kill");
        wait_for(&mut rx, |ev| matches!(ev, SessionEvent::Exit { .. })).await;
        assert_eq!(reg.meta(&meta.id).unwrap().status, SessionStatus::Exited);
    }

    #[tokio::test]
    async fn unknown_sessions_are_errors_not_panics() {
        let reg = Arc::new(Registry::new());
        assert!(reg.input("nope", b"x").is_err());
        assert!(reg.resize("nope", 80, 24).is_err());
        assert!(reg.kill("nope").is_err());
        assert!(reg.snapshot("nope").is_none());
    }
}
