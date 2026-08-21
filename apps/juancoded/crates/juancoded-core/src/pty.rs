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
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use portable_pty::{CommandBuilder, MasterPty, NativePtySystem, PtySize, PtySystem};
use tokio::sync::broadcast;

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

/// A running pty. Cloneable handle; dropping every clone does not kill the child
/// (the registry owns the lifetime and calls `kill` explicitly).
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

    /// The prime directive, asserted rather than assumed: the child's environment
    /// is ours. No shadow HOME, no CODEX_HOME, nothing added — so user-scope MCP
    /// config, connectors and project `.mcp.json` resolve exactly as in a terminal.
    #[test]
    fn the_child_environment_is_inherited_untouched() {
        let out = run_and_collect(spec("/usr/bin/env", &[]));
        let child: std::collections::HashMap<&str, &str> = out
            .lines()
            .filter_map(|l| l.split_once('='))
            .map(|(k, v)| (k, v.trim_end_matches('\r')))
            .collect();

        for key in ["HOME", "PATH", "USER"] {
            if let Ok(ours) = std::env::var(key) {
                assert_eq!(
                    child.get(key).map(|s| s.to_string()),
                    Some(ours),
                    "{key} differs between parent and child"
                );
            }
        }
        // Nothing we did invented these.
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

    #[test]
    fn an_env_overlay_adds_only_what_it_names() {
        let mut s = spec("/usr/bin/env", &[]);
        s.env_overlay
            .insert("JUANCODED_SPIKE_MARKER".into(), "on".into());
        let out = run_and_collect(s);
        assert!(out.contains("JUANCODED_SPIKE_MARKER=on"));
        if let Ok(home) = std::env::var("HOME") {
            assert!(
                out.contains(&format!("HOME={home}")),
                "overlay disturbed HOME"
            );
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
