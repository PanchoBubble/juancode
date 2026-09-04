//! Listeners: a TCP port for the sidecar and any remote client, and a Unix socket
//! for the local Swift app (no port, no firewall prompt, and the hop the spike
//! measures).

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use axum::extract::{ws::WebSocketUpgrade, State};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::Router;
use tracing::{info, warn};

use juancoded_cordis::services::queue::{QueueApi, QueueService};
use juancoded_cordis::services::transcripts::TranscriptsService;
use juancoded_cordis::{Bus, ContributionRegistry, Loader};
use juancoded_state::{
    ReaperConfig, ReaperProbes, SessionReaper, SessionsApi, StallPolicy, StoreService, StuckWatch,
};

use crate::conn;
use crate::identity::{self, DaemonIdentity};
use crate::queue_delivery;
use crate::seed::SeedTiming;
use crate::transcript_pump::{self, TranscriptPlane};

/// What a connection needs from the booted tree: the sessions it drives, the chrome the
/// tree contributes to the built-in surfaces, the steering queue it mutates, and the bus
/// those changes are published on.
///
/// All four come out of **one** loader, which is what [`Self::from_loader`] is for. A
/// handle set assembled field by field could serve one tree's sessions over another
/// tree's bus, and the symptom of that is a queue snapshot that simply never arrives:
/// no error, no log, just a dock that never updates.
#[derive(Clone)]
pub struct CoreHandles {
    pub sessions: Arc<dyn SessionsApi>,
    pub contributions: ContributionRegistry,
    /// `None` when the tree mounted no `queue` row. Queue frames then say so rather
    /// than pretending to have queued something.
    pub queue: Option<Arc<dyn QueueApi>>,
    /// `None` when the tree mounted no `transcripts` row, or no `store` for it to keep
    /// history in. A `subscribeTranscript` then answers with an empty replay rather
    /// than with records this core cannot produce.
    pub transcripts: Option<TranscriptPlane>,
    /// The idle-session reaper. `None` would be a core that never sleeps anything;
    /// this daemon always builds one, because the alternative is what this ticket was
    /// filed about — 19 live sessions, none of them ever dormant. Its two knobs are at
    /// the daemon's boot defaults until a client sends `setReaperPolicy`.
    pub reaper: Option<Arc<SessionReaper>>,
    /// The stuck-session detector. Advisory only: it broadcasts
    /// `SessionEvent::Stuck` and nothing in this process acts on it.
    pub stuck: Option<Arc<StuckWatch>>,
    pub bus: Bus,
    /// Captured once, here, and handed to every connection unchanged. A daemon that
    /// recomputed its identity per connection could not be caught being stale.
    pub identity: Arc<DaemonIdentity>,
}

impl CoreHandles {
    pub fn from_loader(loader: &Loader, sessions: Arc<dyn SessionsApi>) -> Self {
        let sessions_retention = sessions.retention();
        // Both halves of the transcript plane or neither. The hub with no store is a
        // reader whose records nobody keeps, and a store with no hub is a table nothing
        // fills; either one alone would advertise a history that does not survive.
        let transcripts = loader
            .services()
            .resolve::<TranscriptsService>()
            .ok()
            .zip(loader.services().resolve::<StoreService>().ok())
            .map(|(hub, store)| TranscriptPlane::new(hub, store));
        let queue = loader.services().resolve::<QueueService>().ok();
        // The reaper reads the transcripts hub directly for its size probe: the hub
        // already holds every binding it has resolved, so one call per sweep replaces a
        // path resolution per session and nothing has to shell out to `stat`.
        // The same probe seam the reaper gets, on purpose: the stuck detector's stall
        // half must not invent a second definition of liveness (juancode-qb5).
        let probes = ReaperProbes::live(loader.services().resolve::<TranscriptsService>().ok());
        let reaper = Some(Arc::new(SessionReaper::new(
            Arc::clone(&sessions),
            queue.clone(),
            probes.clone(),
            ReaperConfig::from_env(),
        )));
        let stuck = {
            let bus_sessions = Arc::clone(&sessions);
            Some(Arc::new(StuckWatch::new(
                Arc::clone(&sessions),
                probes,
                StallPolicy::default(),
                Arc::new(move |id: &str, alert| bus_sessions.publish_stuck(id, alert)),
            )))
        };
        Self {
            sessions,
            contributions: loader.contributions().clone(),
            queue,
            transcripts,
            reaper,
            stuck,
            bus: loader.bus().clone(),
            // The retention the registry actually applies, not a second read of the
            // environment: those differ for any tree built with a config of its own,
            // and a number on the wire that nobody enforces is worse than none.
            identity: Arc::new(DaemonIdentity::capture(sessions_retention)),
        }
    }
}

pub struct ServeConfig {
    /// TCP port for remote clients and the Node sidecar. Deliberately NOT 4280 by
    /// default while both cores exist: the Swift app owns that port and the oracle
    /// sidecar sits on 4281, so a spike must never be able to fight either of them
    /// for a socket. juancode-52e8.2 is where the active core takes over 4280.
    pub port: u16,
    /// Unix socket path for the local client.
    pub socket: PathBuf,
    /// Where to record this daemon's identity while it is listening, so a launcher
    /// can decide whether the running daemon matches the checkout without opening a
    /// socket. `None` writes nothing, which is what a test wants: the default path is
    /// a real one under `$HOME`, and a test that overwrote it would tell the
    /// developer's own live daemon it had stopped.
    pub run_file: Option<PathBuf>,
}

impl Default for ServeConfig {
    fn default() -> Self {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
        Self {
            port: std::env::var("JUANCODED_PORT")
                .ok()
                .and_then(|p| p.parse().ok())
                .unwrap_or(4290),
            socket: std::env::var("JUANCODED_SOCKET")
                .map(PathBuf::from)
                .unwrap_or_else(|_| PathBuf::from(format!("{home}/.juancode/juancoded.sock"))),
            run_file: juancoded_persistence::db_path()
                .parent()
                .map(|d| d.join(identity::RUN_FILE)),
        }
    }
}

/// Whether something is accepting connections on `path` right now. A refused
/// connect means the file is a leftover from a crashed run and is safe to unlink;
/// a successful one means a live daemon owns it.
async fn is_live(path: &std::path::Path) -> bool {
    if !path.exists() {
        return false;
    }
    tokio::net::UnixStream::connect(path).await.is_ok()
}

fn router(handles: CoreHandles) -> Router {
    Router::new()
        // Both spellings, on purpose: the Swift core serves `/api/health` and remote
        // clients probe it, so a core that only answered `/health` would look down to
        // everything that already exists.
        .route("/health", get(|| async { "ok" }))
        .route("/api/health", get(|| async { "ok" }))
        .route("/ws", get(ws_handler))
        .with_state(handles)
}

async fn ws_handler(ws: WebSocketUpgrade, State(handles): State<CoreHandles>) -> impl IntoResponse {
    ws.on_upgrade(move |socket| conn::handle(socket, handles))
}

/// Serve on both listeners until one of them fails.
pub async fn serve(handles: CoreHandles, config: ServeConfig) -> Result<()> {
    // One pump for the daemon, not one per connection: a queued message is delivered
    // because a session can take it, not because somebody is watching the dock.
    let identity = Arc::clone(&handles.identity);
    let _pump = handles.queue.clone().map(|queue| {
        queue_delivery::spawn_pump(
            Arc::clone(&handles.sessions),
            queue,
            SeedTiming::default(),
            queue_delivery::PUMP_TICK,
        )
    });
    // The other pump, and the same reason for being one: a transcript is read because
    // a session wrote one, not because a client is looking at the pane.
    let _transcripts = handles.transcripts.clone().map(|plane| {
        transcript_pump::spawn_pump(
            Arc::clone(&handles.sessions),
            plane,
            transcript_pump::PUMP_TICK,
            handles.stuck.clone(),
        )
    });
    // And the fourth, which is the only one that changes nothing: the stall sweep
    // notices a session claiming to work with nothing behind it and says so. It never
    // kills, sleeps or types — the reaper is the thing that acts, and it refuses to
    // touch exactly these sessions.
    let _stuck = handles.stuck.as_ref().map(|watch| watch.spawn());
    // And the third: a session goes dormant because it has been verifiably idle, not
    // because somebody is looking at the dock. Nothing here binds or spawns — the loop
    // is a no-op tick while the window is disabled and the cap is off.
    let _reaper = handles.reaper.as_ref().map(|reaper| reaper.spawn());
    let app = router(handles);

    if let Some(dir) = config.socket.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("mkdir {}", dir.display()))?;
    }
    // Refuse before touching anything if a daemon is already there. The socket path
    // is shared state: unlinking it while another instance holds it leaves that
    // instance running but unreachable, which is how a failed second start used to
    // break the first one.
    if is_live(&config.socket).await {
        anyhow::bail!(
            "another juancoded is already listening on {}",
            config.socket.display()
        );
    }
    // TCP first, so a port clash fails before the socket path is disturbed.
    let tcp = tokio::net::TcpListener::bind(("127.0.0.1", config.port))
        .await
        .with_context(|| format!("bind 127.0.0.1:{}", config.port))?;
    // Only now is the leftover socket provably stale.
    let _ = std::fs::remove_file(&config.socket);
    let uds = tokio::net::UnixListener::bind(&config.socket)
        .with_context(|| format!("bind {}", config.socket.display()))?;

    // Only now, with both listeners up, is this process the daemon. Written here and
    // not in `main` so a start that lost the race for the socket cannot overwrite the
    // run file belonging to the daemon that won it.
    if let Some(path) = config.run_file.as_deref() {
        if let Err(e) = identity::write_run_file(&identity, config.port, path) {
            // Not fatal: the run file is how a launcher AVOIDS ending a healthy
            // daemon. Refusing to serve without one would trade a missing warning for
            // a dead core.
            warn!("could not write the run file at {}: {e:#}", path.display());
        }
    }
    info!(
        socket = %config.socket.display(),
        port = config.port,
        pid = identity.pid,
        build_stamp_ms = identity.build_stamp_ms,
        sessions_per_project = identity.sessions_per_project,
        "juancoded listening"
    );

    let uds_app = app.clone();
    let uds_task = tokio::spawn(async move { axum::serve(uds, uds_app).await });
    let tcp_task = tokio::spawn(async move { axum::serve(tcp, app).await });

    let outcome: Result<()> = tokio::select! {
        r = uds_task => r?.context("unix listener stopped"),
        r = tcp_task => r?.context("tcp listener stopped"),
    };
    // A daemon that stopped must stop claiming a pid. A crash leaves the file behind
    // instead, which is why every reader checks the pid is alive before trusting it.
    if let Some(path) = config.run_file.as_deref() {
        identity::remove_run_file(path);
    }
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_missing_or_stale_socket_is_not_live_but_a_bound_one_is() {
        let dir = std::env::temp_dir().join(format!("juancoded-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("probe.sock");

        assert!(!is_live(&path).await, "a missing path cannot be live");

        // A plain file standing in for a socket left behind by a crashed run.
        std::fs::write(&path, b"").unwrap();
        assert!(!is_live(&path).await, "a stale path must be reclaimable");
        std::fs::remove_file(&path).unwrap();

        let _listener = tokio::net::UnixListener::bind(&path).unwrap();
        assert!(is_live(&path).await, "a bound socket must read as live");
        std::fs::remove_file(&path).ok();
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn a_second_serve_refuses_and_leaves_the_first_socket_intact() {
        let dir = std::env::temp_dir().join(format!("juancoded-test2-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("live.sock");

        let held = tokio::net::UnixListener::bind(&socket).unwrap();

        let err = serve(
            crate::testing::handles(),
            ServeConfig {
                port: 0,
                socket: socket.clone(),
                run_file: None,
            },
        )
        .await
        .expect_err("second serve must refuse");
        assert!(err.to_string().contains("already listening"), "{err}");
        // The live socket is still connectable — the refusal touched nothing.
        assert!(is_live(&socket).await);
        drop(held);
        std::fs::remove_dir_all(&dir).ok();
    }
}
