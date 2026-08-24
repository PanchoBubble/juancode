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

use std::sync::Arc;

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
    // Kept for the shutdown path: it is the only thing there that can persist what a
    // live session has printed since the last throttled write.
    let live = Arc::clone(&handles.sessions);
    // The lifetime contract the launcher handed this process, so an app that dies
    // BADLY — SIGKILL, force quit, a terminal that vanished — does not leave a daemon
    // at PPID 1 holding ptys forever. macOS has no PDEATHSIG, so this side has to
    // notice. An unowned daemon (`cargo run -p juancoded`, or one somebody keeps on
    // purpose) has nothing to notice and this arm never fires for it.
    let watchdog = Arc::clone(&handles.identity.lifetime);
    // Kept out of the move so the interrupt arm can clear it too: `serve` removes the
    // run file on its own way out, but a ctrl-c never reaches that path, and a file
    // still naming a dead pid is what makes a launcher hesitate over a daemon that is
    // not there.
    let run_file = config.run_file.clone();
    tokio::select! {
        r = serve(handles, config) => r?,
        signal = shutdown_signal() => {
            info!(%signal, "shutting down");
            stop_serving(&live, run_file.as_deref());
        }
        // Deliberately the SAME arm shape as the signal: an orphaned daemon leaves
        // through the identical path a SIGTERM takes, so the run file is cleared and
        // the plugin tree unwinds in reverse mount order. A watchdog that called
        // `process::exit` would be a second shutdown path that skipped the flush the
        // first one exists for.
        orphaned = watchdog.watch() => {
            warn!(
                owner_pid = orphaned.owner_pid,
                waited_secs = orphaned.waited.as_secs(),
                "the launch that owned this daemon is gone; shutting down rather than \
                 outliving it at PPID 1"
            );
            stop_serving(&live, run_file.as_deref());
        }
    }
    // Dropping the loader unwinds every plugin's effects in reverse mount order,
    // which is the only shutdown path there is.
    drop(loader);
    Ok(())
}

/// The one way out of a daemon that WAS serving and is now stopping. Both shutdown
/// arms go through here so there is exactly one answer to "what happens on the way
/// out", and adding a third reason to stop cannot forget half of it.
///
/// The flush is the part that matters. Scrollback is written on a throttle while a
/// session runs and no plugin unmount writes it (teardown is effects going away, and
/// there is no unmount hook), so without this every exit truncates the last couple of
/// seconds of every live session. That was invisible while the daemon outlived the
/// app; it is a lost transcript on every quit now that it does not.
///
/// Deliberately NOT called when `serve` returns on its own. That covers a bind that
/// never succeeded — where another daemon is the live one — and writing this
/// process's rehydrated scrollback then would overwrite ITS rows with older bytes,
/// and remove a run file that is not ours.
fn stop_serving(live: &Arc<dyn juancoded_state::SessionsApi>, run_file: Option<&std::path::Path>) {
    let flushed = live.flush_all();
    info!(sessions = flushed, "persisted live scrollback");
    if let Some(path) = run_file {
        identity::remove_run_file(path);
    }
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
