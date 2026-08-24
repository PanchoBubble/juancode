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
use tracing::info;

use juancoded_cordis::services::queue::{QueueApi, QueueService};
use juancoded_cordis::services::transcripts::TranscriptsService;
use juancoded_cordis::{Bus, ContributionRegistry, Loader};
use juancoded_state::{SessionsApi, StoreService};

use crate::conn;
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
    pub bus: Bus,
}

impl CoreHandles {
    pub fn from_loader(loader: &Loader, sessions: Arc<dyn SessionsApi>) -> Self {
        // Both halves of the transcript plane or neither. The hub with no store is a
        // reader whose records nobody keeps, and a store with no hub is a table nothing
        // fills; either one alone would advertise a history that does not survive.
        let transcripts = loader
            .services()
            .resolve::<TranscriptsService>()
            .ok()
            .zip(loader.services().resolve::<StoreService>().ok())
            .map(|(hub, store)| TranscriptPlane::new(hub, store));
        Self {
            sessions,
            contributions: loader.contributions().clone(),
            queue: loader.services().resolve::<QueueService>().ok(),
            transcripts,
            bus: loader.bus().clone(),
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
        )
    });
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

    info!(socket = %config.socket.display(), port = config.port, "juancoded listening");

    let uds_app = app.clone();
    let uds_task = tokio::spawn(async move { axum::serve(uds, uds_app).await });
    let tcp_task = tokio::spawn(async move { axum::serve(tcp, app).await });

    tokio::select! {
        r = uds_task => r?.context("unix listener stopped")?,
        r = tcp_task => r?.context("tcp listener stopped")?,
    }
    Ok(())
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
