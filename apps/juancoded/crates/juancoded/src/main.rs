//! `juancoded` — the harness core as a daemon.
//!
//! Owns the ptys, the VT grids, the session state and the wire protocol; owns no UI.
//! The Swift app (and, later, a TUI) is a client over the socket.
//!
//! Boot is two steps and no more: apply the entry list, then serve the `sessions`
//! service the tree mounted. Everything the daemon can do is a plugin in that tree,
//! and `--dump-config` prints it without opening a socket.
//!
//! Ports: the Unix socket is the local client's path; TCP defaults to 4290 —
//! not 4280 (the Swift app) and not 4281 (the oracle sidecar), so running all three
//! at once is never a port fight. Overridable with JUANCODED_PORT / JUANCODED_SOCKET.

use anyhow::Result;
use juancoded_server::{serve, CoreHandles, ServeConfig};
use tracing::{info, warn};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_env("JUANCODED_LOG").unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .init();

    let dump_only = std::env::args().any(|a| a == "--dump-config");
    let (loader, report, sessions) = juancoded_state::boot()?;
    for line in report.diagnostics() {
        warn!("{line}");
    }
    if dump_only {
        print!("{}", juancoded_cordis::dump_config(&loader));
        return Ok(());
    }

    let config = ServeConfig::default();
    info!(
        version = env!("CARGO_PKG_VERSION"),
        sessions = sessions.ids().len(),
        "juancoded starting"
    );

    let handles = CoreHandles::from_loader(&loader, sessions);
    tokio::select! {
        r = serve(handles, config) => r?,
        _ = tokio::signal::ctrl_c() => info!("interrupted, shutting down"),
    }
    // Dropping the loader unwinds every plugin's effects in reverse mount order,
    // which is the only shutdown path there is.
    drop(loader);
    Ok(())
}
