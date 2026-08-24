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
use juancoded_server::identity;
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
    // Kept out of the move so the interrupt arm can clear it too: `serve` removes the
    // run file on its own way out, but a ctrl-c never reaches that path, and a file
    // still naming a dead pid is what makes a launcher hesitate over a daemon that is
    // not there.
    let run_file = config.run_file.clone();
    tokio::select! {
        r = serve(handles, config) => r?,
        signal = shutdown_signal() => {
            info!(%signal, "shutting down");
            if let Some(path) = run_file.as_deref() {
                identity::remove_run_file(path);
            }
        }
    }
    // Dropping the loader unwinds every plugin's effects in reverse mount order,
    // which is the only shutdown path there is.
    drop(loader);
    Ok(())
}

/// Resolves when this daemon is asked to stop, whichever way it is asked.
///
/// SIGTERM is here for a reason, not for symmetry: the launcher ends a daemon with
/// TERM and then waits a grace period before SIGKILL, so that the store gets a chance
/// to flush. Default SIGTERM disposition is immediate death with no unwinding, which
/// would have made that grace period a wait over an already-dead process — the exact
/// torn-write-mid-flush the grace period exists to avoid.
async fn shutdown_signal() -> &'static str {
    let mut term = match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
        Ok(s) => s,
        Err(e) => {
            // Nothing to do but keep the interrupt path: a daemon that refused to boot
            // because it could not install a handler would be a worse failure.
            warn!("could not listen for SIGTERM ({e}); only ctrl-c will shut down cleanly");
            let _ = tokio::signal::ctrl_c().await;
            return "interrupt";
        }
    };
    tokio::select! {
        _ = tokio::signal::ctrl_c() => "interrupt",
        _ = term.recv() => "terminate",
    }
}
