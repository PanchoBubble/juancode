//! `juancoded` — the harness core as a daemon.
//!
//! Owns the ptys, the VT grids and the wire protocol; owns no UI. The Swift app
//! (and, later, a TUI) is a client over the socket.
//!
//! Ports: the Unix socket is the local client's path; TCP defaults to 4290 —
//! not 4280 (the Swift app) and not 4281 (the oracle sidecar), so running all three
//! at once is never a port fight. Overridable with JUANCODED_PORT / JUANCODED_SOCKET.

use std::sync::Arc;

use anyhow::Result;
use juancoded_core::registry::Registry;
use juancoded_plugins::EffectRegistry;
use juancoded_server::{serve, ServeConfig};
use tracing::info;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_env("JUANCODED_LOG").unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .init();

    let registry = Arc::new(Registry::new());
    // Not wired into anything yet (juancode-52e8.4 does that); constructed here so
    // the daemon has one owner for it from the start.
    let effects = EffectRegistry::new();
    let config = ServeConfig::default();

    info!(
        version = env!("CARGO_PKG_VERSION"),
        extension_points = effects.dump().len(),
        "juancoded starting"
    );

    tokio::select! {
        r = serve(Arc::clone(&registry), config) => r?,
        _ = tokio::signal::ctrl_c() => info!("interrupted, shutting down"),
    }
    Ok(())
}
