//! The pty host: spawn a real CLI, fan its output out to N subscribers, write
//! input back, resize, and report the exit.
//!
//! `portable-pty` rather than raw `forkpty` (which the Swift core uses) so ConPTY
//! comes for free on Windows later. Env fidelity is preserved by construction:
//! `CommandBuilder::new` seeds from `std::env::vars_os()`, so the child sees our
//! whole environment. The only entries we add are a provider's `spawn_env` overlay
//! (opencode bypass only) — never a shadow HOME/CODEX_HOME, never TERM.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use portable_pty::{CommandBuilder, MasterPty, NativePtySystem, PtySize, PtySystem};
use tokio::sync::broadcast;

/// How long a CLI gets to write its own state out after being asked to stop.
///
/// `claude` traps SIGTERM to flush its transcript, and hard-killing before that flush
/// lost the last few prompts of every session: they were in our scrollback but not in
/// the transcript, and a `--resume` repaints from the transcript (juancode-6cqj). The
/// Swift core waits the same 3 seconds for the same reason.
pub const STOP_GRACE: Duration = Duration::from_secs(3);

/// How often the grace wait re-checks. Short enough that the common case (a CLI that
/// exits at once) costs a millisecond, not the whole grace.
const REAP_POLL: Duration = Duration::from_millis(10);

/// What a live pty emits. `Output` carries raw bytes exactly as read; the wire
/// layer decides how to frame them.
#[derive(Debug, Clone)]
pub enum PtyEvent {
    Output(Arc<Vec<u8>>),
    Exit(Option<i32>),
}

/// How to launch one pty.
pub struct SpawnSpec {
    pub program: String,
    pub args: Vec<String>,
    pub cwd: String,
    pub cols: u16,
    pub rows: u16,
    /// Entries overlaid on the inherited environment. Almost always empty.
    pub env_overlay: HashMap<String, String>,
}

/// A running pty. Cloneable handle; dropping every clone does not end the child
/// (the registry owns the lifetime and calls `stop` explicitly).
#[derive(Clone)]
pub struct PtyHandle {
    inner: Arc<Inner>,
}

struct Inner {
    master: Mutex<Box<dyn MasterPty + Send>>,
    writer: Mutex<Box<dyn Write + Send>>,
    child: Mutex<Box<dyn portable_pty::Child + Send + Sync>>,
    events: broadcast::Sender<PtyEvent>,
    /// The grid the pty currently believes it has.
    size: Mutex<(u16, u16)>,
    /// Set by the reader thread once the child is reaped, just before it publishes
    /// the exit. The stop ladder waits on this rather than on `child`, which the
    /// reader thread is itself blocked in `wait()` on.
    exited: AtomicBool,
    /// Read once at spawn. Asking the child for it later would mean taking the lock
    /// the reader thread holds while it waits, and the signal path must not be able
    /// to block on the thread whose exit it is waiting for.
    pid: Option<u32>,
}

impl PtyHandle {
    /// Spawn the program and start pumping its output onto the event bus.
    ///
    /// The reader runs on a blocking OS thread (a pty read is a blocking syscall
    /// and there is no portable async pty), and every consumer is a `broadcast`
    /// subscriber — the same fan-out seam the Swift core's `FanOut` provides.
    pub fn spawn(spec: SpawnSpec, buffer: usize) -> Result<Self> {
        let pty_system = NativePtySystem::default();
        let pair = pty_system
            .openpty(PtySize {
                rows: spec.rows,
                cols: spec.cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("openpty failed")?;

        let mut cmd = CommandBuilder::new(&spec.program);
        for arg in &spec.args {
            cmd.arg(arg);
        }
        cmd.cwd(&spec.cwd);
        // The ONLY env we touch. Empty for every provider that exposes a flag.
        for (k, v) in &spec.env_overlay {
            cmd.env(k, v);
        }

        let child = pair.slave.spawn_command(cmd).context("spawn failed")?;
        let pid = child.process_id();
        // Drop the slave immediately: holding it open means the master read never
        // sees EOF when the child exits, and the session would hang "running".
        drop(pair.slave);

        let mut reader = pair
            .master
            .try_clone_reader()
            .context("clone reader failed")?;
        let writer = pair.master.take_writer().context("take writer failed")?;
        let (events, _) = broadcast::channel(buffer);

        let inner = Arc::new(Inner {
            master: Mutex::new(pair.master),
            writer: Mutex::new(writer),
            child: Mutex::new(child),
            events: events.clone(),
            size: Mutex::new((spec.cols, spec.rows)),
            exited: AtomicBool::new(false),
            pid,
        });

        let pump_inner = Arc::clone(&inner);
        std::thread::Builder::new()
            .name("juancoded-pty-read".into())
            .spawn(move || {
                let mut buf = vec![0u8; 64 * 1024];
                loop {
                    match reader.read(&mut buf) {
                        Ok(0) => break,
                        Ok(n) => {
                            // A dropped-receiver error is normal (nobody attached);
                            // keep draining the pty regardless or the child blocks.
                            let _ = pump_inner
                                .events
                                .send(PtyEvent::Output(Arc::new(buf[..n].to_vec())));
                        }
                        Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                        Err(_) => break,
                    }
                }
                // A child killed by a signal has no exit status of its own, and
                // portable-pty reports 1 for it — indistinguishable from a real
                // failure. -1 is the convention the wire already uses for "a signal
                // took it", so clients can tell a kill from a crash.
                let code = pump_inner
                    .child
                    .lock()
                    .ok()
                    .and_then(|mut c| c.wait().ok())
                    .map(|status| {
                        if status.signal().is_some() {
                            -1
                        } else {
                            status.exit_code() as i32
                        }
                    });
                pump_inner.exited.store(true, Ordering::SeqCst);
                let _ = pump_inner.events.send(PtyEvent::Exit(code));
            })
            .context("failed to start pty reader thread")?;

        Ok(Self { inner })
    }

    /// Subscribe to the output/exit stream. A late subscriber sees only what comes
    /// next — scrollback replay is the registry's job, not the pty's.
    pub fn subscribe(&self) -> broadcast::Receiver<PtyEvent> {
        self.inner.events.subscribe()
    }

    pub fn write(&self, bytes: &[u8]) -> Result<()> {
        let mut w = self
            .inner
            .writer
            .lock()
            .map_err(|_| anyhow::anyhow!("writer poisoned"))?;
        w.write_all(bytes)?;
        w.flush()?;
        Ok(())
    }

    /// Resize the pty. Returns false when the grid is already what was asked for.
    pub fn resize(&self, cols: u16, rows: u16) -> Result<bool> {
        let mut size = self
            .inner
            .size
            .lock()
            .map_err(|_| anyhow::anyhow!("size poisoned"))?;
        if *size == (cols, rows) {
            return Ok(false);
        }
        let master = self
            .inner
            .master
            .lock()
            .map_err(|_| anyhow::anyhow!("master poisoned"))?;
        master.resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;
        *size = (cols, rows);
        Ok(true)
    }

    pub fn size(&self) -> (u16, u16) {
        self.inner.size.lock().map(|s| *s).unwrap_or((0, 0))
    }

    /// Whether the child has been reaped and its exit published.
    pub fn has_exited(&self) -> bool {
        self.inner.exited.load(Ordering::SeqCst)
    }

    /// The child's pid, as it was at spawn.
    pub fn pid(&self) -> Option<u32> {
        self.inner.pid
    }

    /// Ask the child to stop, and do not wait. SIGTERM is the request a CLI can act
    /// on; see [`STOP_GRACE`] for why asking first matters.
    ///
    /// Returns false when there was nothing to ask (already gone, or no pid).
    pub fn request_stop(&self) -> bool {
        if self.has_exited() {
            return false;
        }
        match self.pid() {
            #[cfg(unix)]
            Some(pid) => {
                // SAFETY: `kill` with a pid we own and a valid signal number. A pid
                // that has already been reaped answers ESRCH, which we ignore.
                unsafe { libc::kill(pid as libc::pid_t, libc::SIGTERM) };
                true
            }
            #[cfg(not(unix))]
            Some(_) => false,
            None => false,
        }
    }

    /// End the child: ask, wait out its flush grace, then insist.
    ///
    /// The wait is bounded and polls a flag, so a CLI that ignores SIGTERM costs the
    /// grace once rather than hanging the caller.
    pub fn stop(&self) -> Result<()> {
        self.stop_within(STOP_GRACE)
    }

    pub fn stop_within(&self, grace: Duration) -> Result<()> {
        if self.request_stop() {
            let deadline = Instant::now() + grace;
            while Instant::now() < deadline {
                if self.has_exited() {
                    return Ok(());
                }
                std::thread::sleep(REAP_POLL);
            }
        }
        if self.has_exited() {
            return Ok(());
        }
        self.kill()
    }

    /// Take the child out now, with no grace. The last rung of [`stop`](Self::stop),
    /// and the right call only when the flush has already had its chance.
    pub fn kill(&self) -> Result<()> {
        let mut child = self
            .inner
            .child
            .lock()
            .map_err(|_| anyhow::anyhow!("child poisoned"))?;
        child.kill()?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn spec(program: &str, args: &[&str]) -> SpawnSpec {
        SpawnSpec {
            program: program.into(),
            args: args.iter().map(|s| s.to_string()).collect(),
            cwd: "/tmp".into(),
            cols: 80,
            rows: 24,
            env_overlay: HashMap::new(),
        }
    }

    /// Drain output until the child exits (or we give up), returning what it wrote.
    fn run_and_collect(spec: SpawnSpec) -> String {
        let pty = PtyHandle::spawn(spec, 256).expect("spawn");
        let mut rx = pty.subscribe();
        let mut out = Vec::new();
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        loop {
            match rx.blocking_recv() {
                Ok(PtyEvent::Output(b)) => out.extend_from_slice(&b),
                Ok(PtyEvent::Exit(_)) => break,
                Err(_) => break,
            }
            if std::time::Instant::now() > deadline {
                break;
            }
        }
        String::from_utf8_lossy(&out).to_string()
    }

    #[test]
    fn output_reaches_a_subscriber_and_the_exit_is_reported() {
        let pty = PtyHandle::spawn(spec("/bin/echo", &["hello-pty"]), 256).expect("spawn");
        let mut rx = pty.subscribe();
        let mut saw_output = false;
        loop {
            match rx.blocking_recv() {
                Ok(PtyEvent::Output(b)) => {
                    if String::from_utf8_lossy(&b).contains("hello-pty") {
                        saw_output = true;
                    }
                }
                Ok(PtyEvent::Exit(code)) => {
                    assert_eq!(code, Some(0));
                    break;
                }
                Err(e) => panic!("stream ended early: {e}"),
            }
        }
        assert!(saw_output, "never saw the child's output");
    }

    /// A key whose value cannot be read back out of a line-oriented `env` dump, or
    /// whose survival is not ours to promise.
    ///
    /// `DYLD_*` is the second kind: macOS strips it when exec'ing a system binary, so
    /// `/usr/bin/env` never sees the one `cargo` puts in a test binary's environment.
    /// A CLI that needs it would not get it from a terminal either.
    fn undiffable(key: &str, value: &str) -> bool {
        key.starts_with("DYLD_") || value.contains('\n') || key.contains('\n')
    }

    fn child_env(out: &str) -> HashMap<String, String> {
        out.lines()
            .filter_map(|line| line.trim_end_matches('\r').split_once('='))
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    /// The prime directive, asserted as a two-way diff rather than a spot check: the
    /// child's environment IS ours, entry for entry. Nothing added, nothing dropped,
    /// no value rewritten. That is what makes user-scope MCP config (`~/.claude.json`),
    /// account connectors, `~/.codex/config.toml` and a project `.mcp.json` resolve for
    /// the spawned CLI exactly as they do in a terminal.
    ///
    /// `examples/env_diff.rs` is the same comparison as a command, for checking a real
    /// launch by hand.
    #[test]
    fn the_child_environment_is_our_environment_entry_for_entry() {
        let out = run_and_collect(spec("/usr/bin/env", &[]));
        let child = child_env(&out);
        let ours: HashMap<String, String> = std::env::vars().collect();

        let added: Vec<&String> = child
            .iter()
            .filter(|(k, v)| !ours.contains_key(*k) && !undiffable(k, v))
            .map(|(k, _)| k)
            .collect();
        assert!(
            added.is_empty(),
            "the child was given entries we never had: {added:?}"
        );

        let mut dropped = Vec::new();
        let mut rewritten = Vec::new();
        for (key, value) in &ours {
            if undiffable(key, value) {
                continue;
            }
            match child.get(key) {
                None => dropped.push(key.clone()),
                Some(theirs) if theirs != value => {
                    rewritten.push(format!("{key}: ours={value:?} child={theirs:?}"))
                }
                _ => {}
            }
        }
        assert!(
            dropped.is_empty(),
            "entries lost on the way in: {dropped:?}"
        );
        assert!(rewritten.is_empty(), "entries rewritten: {rewritten:?}");

        // And the specific shadows the directive names, in case one of them is set
        // for real in the parent and so would not show as "added".
        for forbidden in [
            "CODEX_HOME",
            "CLAUDE_CONFIG_DIR",
            "XDG_CONFIG_HOME_OVERRIDE",
        ] {
            if std::env::var(forbidden).is_err() {
                assert!(
                    !child.contains_key(forbidden),
                    "{forbidden} was injected into the child"
                );
            }
        }
    }

    /// The one sanctioned exception, held to exactly one entry: opencode's opt-in
    /// bypass, which that CLI exposes only as an env var.
    #[test]
    fn an_env_overlay_adds_only_what_it_names_and_changes_nothing_else() {
        let mut s = spec("/usr/bin/env", &[]);
        s.env_overlay
            .insert("OPENCODE_PERMISSION".into(), "{\"edit\":\"allow\"}".into());
        let out = run_and_collect(s);
        let child = child_env(&out);
        let ours: HashMap<String, String> = std::env::vars().collect();

        assert_eq!(
            child.get("OPENCODE_PERMISSION").map(String::as_str),
            Some("{\"edit\":\"allow\"}")
        );
        let extra: Vec<&String> = child
            .iter()
            .filter(|(k, v)| {
                k.as_str() != "OPENCODE_PERMISSION" && !ours.contains_key(*k) && !undiffable(k, v)
            })
            .map(|(k, _)| k)
            .collect();
        assert!(extra.is_empty(), "the overlay brought friends: {extra:?}");
        for (key, value) in &ours {
            if undiffable(key, value) || key == "OPENCODE_PERMISSION" {
                continue;
            }
            assert_eq!(child.get(key), Some(value), "the overlay disturbed {key}");
        }
    }

    /// The ladder's first rung, which is the whole point of it: a CLI that traps
    /// SIGTERM gets to run its handler. `claude` writes its transcript there, and a
    /// SIGKILL first meant a `--resume` repainted a conversation missing its last
    /// few prompts (juancode-6cqj).
    #[test]
    fn a_child_that_traps_sigterm_gets_to_flush_before_it_goes() {
        let pty = PtyHandle::spawn(
            spec(
                "/bin/sh",
                &["-c", "trap 'printf FLUSHED; exit 0' TERM; read ignored"],
            ),
            256,
        )
        .expect("spawn");
        let mut rx = pty.subscribe();
        // Let the shell install its handler before the signal arrives.
        std::thread::sleep(Duration::from_millis(250));
        pty.stop().expect("stop");

        let mut seen = String::new();
        let mut code = None;
        while let Ok(event) = rx.blocking_recv() {
            match event {
                PtyEvent::Output(bytes) => seen.push_str(&String::from_utf8_lossy(&bytes)),
                PtyEvent::Exit(c) => {
                    code = Some(c);
                    break;
                }
            }
        }
        assert!(
            seen.contains("FLUSHED"),
            "the handler never ran; output was {seen:?}"
        );
        assert_eq!(
            code,
            Some(Some(0)),
            "an exit of its own, not a signal that took it"
        );
    }

    /// And the last rung: a child that ignores the request still goes, and the grace
    /// is spent once rather than waited on forever.
    #[test]
    fn a_child_that_ignores_sigterm_is_taken_out_when_the_grace_runs_down() {
        let pty = PtyHandle::spawn(spec("/bin/sh", &["-c", "trap '' TERM; read ignored"]), 256)
            .expect("spawn");
        let mut rx = pty.subscribe();
        std::thread::sleep(Duration::from_millis(250));

        let started = Instant::now();
        pty.stop_within(Duration::from_millis(300)).expect("stop");
        let waited = started.elapsed();
        assert!(
            waited < Duration::from_secs(2),
            "the grace was not bounded: waited {waited:?}"
        );

        loop {
            match rx.blocking_recv() {
                Ok(PtyEvent::Exit(code)) => {
                    assert_eq!(code, Some(-1), "a signal took it, and that is reported");
                    break;
                }
                Ok(_) => continue,
                Err(e) => panic!("the stream ended without an exit: {e}"),
            }
        }
    }

    #[test]
    fn input_round_trips_through_the_pty() {
        let pty = PtyHandle::spawn(spec("/bin/cat", &[]), 256).expect("spawn");
        let mut rx = pty.subscribe();
        pty.write(b"ping\n").expect("write");
        let mut seen = String::new();
        while let Ok(ev) = rx.blocking_recv() {
            if let PtyEvent::Output(b) = ev {
                seen.push_str(&String::from_utf8_lossy(&b));
                if seen.contains("ping") {
                    break;
                }
            }
        }
        assert!(seen.contains("ping"));
        pty.kill().expect("kill");
    }

    #[test]
    fn resize_is_idempotent_and_the_child_sees_the_new_grid() {
        let pty = PtyHandle::spawn(spec("/bin/cat", &[]), 256).expect("spawn");
        assert_eq!(pty.size(), (80, 24));
        assert!(!pty.resize(80, 24).expect("noop resize"));
        assert!(pty.resize(100, 30).expect("resize"));
        assert_eq!(pty.size(), (100, 30));
        pty.kill().expect("kill");
    }
}
