//! `juancoded` — the harness core as a daemon.
//!
//! Owns the ptys, the VT grids, the session state and the wire protocol; owns no UI.
//! The Swift app (and, later, a TUI) is a client over the socket.
//!
//! Boot is two steps and no more: apply the entry list, then serve the `sessions`
//! service the tree mounted. Everything the daemon can do is a plugin in that tree,
//! and `--dump-config` prints it without opening a socket.
//!
//! One subcommand runs instead of serving: `import-swift`, which copies the Swift
//! core's session history into this core's store and exits. It is here rather than in
//! a tool of its own because the store it writes is this binary's, chosen by this
//! binary's environment — a separate tool would have to reimplement that choice and
//! could get it wrong in exactly the way that matters.
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

    // One-shot subcommands run and exit without booting the tree or binding a socket.
    // `import-swift` in particular must NOT have a daemon behind it: its writes go
    // straight to the file, and a live daemon holds the same rows in memory and would
    // write its own copy back over them on the way out.
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if argv.first().is_some_and(|a| a == "import-swift") {
        return import_swift(&argv[1..]);
    }

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
    // Labelled, and labelled `quit` rather than left to look like a reap. The ptys are
    // this process's children and die with it, so every live agent is interrupted here
    // — the reaper's own sleeps say `session_sleep reason=idle_reap|live_cap`, and a
    // month of blame for interrupted agents landed on the reaper the last time these
    // two wrote the same line. Nothing here flips `dormant`: these sessions were not
    // judged idle, they were ended.
    let interrupted: Vec<String> = live
        .ids()
        .into_iter()
        .filter(|id| live.is_running(id))
        .collect();
    if !interrupted.is_empty() {
        info!(
            reason = "quit",
            sessions = interrupted.len(),
            "ending live sessions with the daemon; this is not a reap"
        );
    }
    info!(sessions = flushed, "persisted live scrollback");
    if let Some(path) = run_file {
        identity::remove_run_file(path);
    }
}

const IMPORT_USAGE: &str = "\
usage: juancoded import-swift <swift juancode.db> [--into <db>] [--dry-run] [--force]

Copy the Swift core's session history into this core's store. Additive and
idempotent: a session the destination already holds keeps its own row, and
scrollback is only written where the destination has none. Running it twice
writes nothing the second time.

  --into <db>   destination store (default: this core's own, from the environment)
  --dry-run     report what would move and write nothing
  --force       import even though a daemon looks live on the destination
";

/// The `import-swift` subcommand: read a Swift `juancode.db`, write what this core's
/// store does not already hold, print what moved.
///
/// The live-daemon check is the only thing here that is not a thin wrapper over
/// `juancoded_persistence::import_swift`. A running daemon has every session in memory
/// with its own copy of the scrollback ring, and flushes all of them on the way out —
/// so an import underneath one is silently undone at the next quit, which looks exactly
/// like an import that never worked. Refusing is the only honest answer; `--force` is
/// there for someone who is sure.
///
/// It asks about THIS destination, not about daemons in general. The run file sits
/// beside the store its daemon serves, so importing into a copy in a scratch directory
/// is allowed while the real daemon runs — which is how this got measured against the
/// user's own data without touching it.
fn import_swift(args: &[String]) -> Result<()> {
    let mut source: Option<std::path::PathBuf> = None;
    let mut dest = juancoded_persistence::db_path();
    let mut dry_run = false;
    let mut force = false;
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--dry-run" => dry_run = true,
            "--force" => force = true,
            "-h" | "--help" => {
                print!("{IMPORT_USAGE}");
                return Ok(());
            }
            "--into" => {
                dest = rest
                    .next()
                    .map(std::path::PathBuf::from)
                    .ok_or_else(|| anyhow::anyhow!("--into needs a path\n\n{IMPORT_USAGE}"))?;
            }
            other if other.starts_with('-') => {
                anyhow::bail!("unknown option {other}\n\n{IMPORT_USAGE}");
            }
            other => source = Some(std::path::PathBuf::from(other)),
        }
    }
    let Some(source) = source else {
        anyhow::bail!("no source database\n\n{IMPORT_USAGE}");
    };
    if source == dest {
        anyhow::bail!("source and destination are the same file");
    }

    if !dry_run && !force {
        if let Some(pid) = daemon_serving(&dest) {
            anyhow::bail!(
                "a daemon (pid {pid}) is serving {} and would write its own copy of every \
                 session back over this import when it quits. Stop it first, or pass \
                 --force.",
                dest.display()
            );
        }
    }

    let store = juancoded_persistence::SqliteStore::open(&dest)?;
    let report = juancoded_persistence::import_swift::import_from_swift(&source, &store, dry_run)?;

    let verb = if dry_run { "would import" } else { "imported" };
    println!("source      {}", source.display());
    println!("destination {}", dest.display());
    println!("sessions    {} read", report.sessions_seen);
    println!(
        "            {verb} {}, {} already here",
        report.sessions_imported, report.sessions_already_present
    );
    println!(
        "scrollback  {verb} {} ({:.1} MB), {} already here, {} empty at source",
        report.scrollback_imported,
        report.scrollback_bytes as f64 / (1024.0 * 1024.0),
        report.scrollback_already_present,
        report.scrollback_empty_at_source,
    );
    for (id, why) in &report.skipped {
        warn!(session = id, "skipped: {why}");
    }
    if report.wrote_nothing() && !dry_run {
        println!("nothing to do; this store already holds everything that file has");
    }
    Ok(())
}

/// The pid of a live daemon serving the store at `db`, if there is one.
///
/// The run file is written beside the store, names the pid that wrote it, and is
/// removed on a clean shutdown. A crash leaves it behind, so the pid has to be checked
/// rather than trusted — signal 0 delivers nothing and only asks whether the process is
/// there, which is the whole question.
fn daemon_serving(db: &std::path::Path) -> Option<i32> {
    let run_file = db.parent()?.join(identity::RUN_FILE);
    let body = std::fs::read_to_string(run_file).ok()?;
    let pid: i32 = body
        .lines()
        .find_map(|l| l.strip_prefix("pid="))?
        .trim()
        .parse()
        .ok()?;
    // Safety: signal 0 sends nothing; the call only reports whether the pid exists.
    let alive = unsafe { libc::kill(pid, 0) } == 0;
    alive.then_some(pid)
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
