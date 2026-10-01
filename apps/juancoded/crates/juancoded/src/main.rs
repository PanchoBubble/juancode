//! `juancoded` — the harness core as a daemon.
//!
//! Owns the ptys, the VT grids, the session state and the wire protocol; owns no UI.
//! The Swift app (and, later, a TUI) is a client over the socket.
//!
//! Boot is two steps and no more: apply the entry list, then serve the `sessions`
//! service the tree mounted. Everything the daemon can do is a plugin in that tree,
//! and `--dump-config` prints it without opening a socket.
//!
//! `upgrade` asks the RUNNING daemon to become this binary without ending a session:
//! it writes a request beside the store, sends SIGUSR2, and waits for the same pid to
//! come back listening on the new code (`juancoded_server::reexec`). `--handoff-probe`
//! is the question the running daemon asks this binary first, answered before anything
//! boots.
//!
//! One more subcommand runs instead of serving: `import-swift`, which copies the Swift
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
    // Before anything else, so the answer costs one exec and boots nothing: the daemon
    // asking is mid-upgrade and waiting on it.
    if std::env::args().nth(1).as_deref() == Some(juancoded_core::reexec::PROBE_ARG) {
        println!("{}", juancoded_core::reexec::probe_line());
        return Ok(());
    }
    // SIGUSR2's default disposition is death, and a fresh image (a boot, or the far
    // side of an upgrade) is not listening for it until its listeners are bound. A
    // tokio handler, once installed, stays for the life of the process, so a stray or
    // repeated signal in that window is dropped instead of ending every pty.
    #[cfg(unix)]
    let _usr2 = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::user_defined2());

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
    if argv.first().is_some_and(|a| a == "upgrade") {
        return upgrade(&argv[1..]).await;
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

const UPGRADE_USAGE: &str = "\
usage: juancoded upgrade [--binary <path>] [--build-id <id>] [--timeout <secs>]

Ask the running daemon (the one whose run file sits beside this environment's store)
to exec <path> in place: same pid, same children, every live session kept. Defaults to
this binary. Exits 0 once the same pid is listening on the new code, non-zero with the
daemon's own reason if it refused, which leaves it serving on the old code.

  --binary <path>   the binary to become (default: this one)
  --build-id <id>   JUANCODE_BUILD_ID for the new image (default: keep the current one)
  --timeout <secs>  how long to wait for the new image (default 90)
";

/// The `upgrade` subcommand: the trigger half of a live upgrade.
///
/// The signal carries no arguments, so the request travels in a file beside the store,
/// written private to this user (the daemon refuses any other kind). The daemon's run
/// file is read first and must advertise `upgrade=sigusr2`: to a daemon that predates
/// the listener, SIGUSR2 is a kill, and this would be the command that ended every
/// session it exists to keep.
async fn upgrade(args: &[String]) -> Result<()> {
    use juancoded_core::reexec::{HANDOFF_MIN_VERSION, HANDOFF_VERSION};
    use juancoded_server::reexec::{FAILURE_FILE, REQUEST_FILE};
    use std::io::Write as _;
    use std::os::unix::fs::OpenOptionsExt;

    let mut binary: Option<std::path::PathBuf> = None;
    let mut build_id: Option<String> = None;
    let mut timeout = std::time::Duration::from_secs(90);
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        let mut value = |name: &str| {
            rest.next()
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("{name} needs a value\n\n{UPGRADE_USAGE}"))
        };
        match arg.as_str() {
            "-h" | "--help" => {
                print!("{UPGRADE_USAGE}");
                return Ok(());
            }
            "--binary" => binary = Some(value("--binary")?.into()),
            "--build-id" => build_id = Some(value("--build-id")?),
            "--timeout" => {
                timeout = std::time::Duration::from_secs(
                    value("--timeout")?
                        .parse()
                        .map_err(|e| anyhow::anyhow!("--timeout: {e}"))?,
                )
            }
            other => anyhow::bail!("unknown argument {other}\n\n{UPGRADE_USAGE}"),
        }
    }
    let binary = match binary {
        Some(b) => {
            std::fs::canonicalize(&b).map_err(|e| anyhow::anyhow!("{}: {e}", b.display()))?
        }
        None => std::env::current_exe()?,
    };

    let db = juancoded_persistence::db_path();
    let dir = db
        .parent()
        .ok_or_else(|| anyhow::anyhow!("{} has no directory", db.display()))?
        .to_path_buf();
    let run_path = dir.join(identity::RUN_FILE);
    let run = read_record(&run_path)
        .ok_or_else(|| anyhow::anyhow!("no daemon run file at {}", run_path.display()))?;
    let pid: i32 = run
        .get("pid")
        .and_then(|p| p.parse().ok())
        .ok_or_else(|| anyhow::anyhow!("{} names no pid", run_path.display()))?;
    if !pid_alive(pid) {
        anyhow::bail!("pid {pid} in {} is not running", run_path.display());
    }
    if run.get("upgrade").map(String::as_str) != Some("sigusr2") {
        anyhow::bail!(
            "daemon pid {pid} predates live upgrades: SIGUSR2 would KILL it and every \
             session it holds. Nothing was sent. It takes one ordinary restart onto a \
             build that has them; every upgrade after that keeps the sessions."
        );
    }
    let theirs: u32 = run
        .get("handoff_version")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    if binary == std::env::current_exe()?
        && !(HANDOFF_MIN_VERSION..=HANDOFF_VERSION).contains(&theirs)
    {
        anyhow::bail!(
            "daemon pid {pid} writes handoff version {theirs}; this binary reads \
             {HANDOFF_MIN_VERSION}..={HANDOFF_VERSION}. Nothing was sent."
        );
    }
    let request = dir.join(REQUEST_FILE);
    if let Ok(meta) = std::fs::metadata(&request) {
        let age = meta.modified().ok().and_then(|m| m.elapsed().ok());
        if age.is_some_and(|a| a < std::time::Duration::from_secs(120)) {
            anyhow::bail!(
                "{} is {}s old: another upgrade looks under way. Remove it if it is not.",
                request.display(),
                age.unwrap_or_default().as_secs()
            );
        }
    }

    let _ = std::fs::remove_file(dir.join(FAILURE_FILE));
    let tmp = dir.join(format!("{REQUEST_FILE}.{}.tmp", std::process::id()));
    {
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp)
            .map_err(|e| anyhow::anyhow!("{}: {e}", tmp.display()))?;
        writeln!(f, "binary={}", binary.display())?;
        if let Some(id) = &build_id {
            writeln!(f, "build_id={id}")?;
        }
        writeln!(f, "requested_by={}", std::process::id())?;
    }
    std::fs::rename(&tmp, &request)?;

    let before = run.get("started_at_ms").cloned().unwrap_or_default();
    let started = std::time::Instant::now();
    // SAFETY: a pid read from the daemon's own run file, checked alive just above, and
    // a signal its run file says it handles.
    if unsafe { libc::kill(pid, libc::SIGUSR2) } != 0 {
        let _ = std::fs::remove_file(&request);
        anyhow::bail!(
            "could not signal pid {pid}: {}",
            std::io::Error::last_os_error()
        );
    }
    println!("asked daemon pid {pid} to become {}", binary.display());

    while started.elapsed() < timeout {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        if let Some(failed) = read_record(&dir.join(FAILURE_FILE)) {
            let _ = std::fs::remove_file(dir.join(FAILURE_FILE));
            anyhow::bail!(
                "the daemon refused and is still serving on its old binary, every session \
                 intact: {}",
                failed
                    .get("error")
                    .map(String::as_str)
                    .unwrap_or("no reason given")
            );
        }
        if !pid_alive(pid) {
            anyhow::bail!(
                "daemon pid {pid} DIED during the upgrade; its sessions are gone. Its log \
                 says why."
            );
        }
        let Some(now) = read_record(&run_path) else {
            continue;
        };
        let same_pid = now.get("pid").and_then(|p| p.parse::<i32>().ok()) == Some(pid);
        let restarted = now.get("started_at_ms").is_some_and(|s| *s != before);
        if same_pid && restarted {
            println!(
                "upgraded in {:.1}s: pid {pid} is now {} (build {})",
                started.elapsed().as_secs_f64(),
                now.get("exe").map(String::as_str).unwrap_or("?"),
                now.get("build_id")
                    .filter(|b| !b.is_empty())
                    .map(String::as_str)
                    .unwrap_or("unstamped"),
            );
            return Ok(());
        }
    }
    anyhow::bail!(
        "daemon pid {pid} did not come back on the new binary within {}s; it is still \
         alive, so check its log before doing anything to it",
        timeout.as_secs()
    )
}

/// `key=value` lines, the run file's shape.
fn read_record(path: &std::path::Path) -> Option<std::collections::HashMap<String, String>> {
    let body = std::fs::read_to_string(path).ok()?;
    Some(
        body.lines()
            .filter_map(|l| l.split_once('='))
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect(),
    )
}

fn pid_alive(pid: i32) -> bool {
    // SAFETY: signal 0 sends nothing; the call only reports whether the pid exists.
    pid > 0 && unsafe { libc::kill(pid, 0) } == 0
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
