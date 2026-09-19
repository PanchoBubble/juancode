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
#[cfg(unix)]
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::PathBuf;
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

/// Where an [`AdoptSpec`] came from, and what it has to describe: one live pty,
/// named by the fd it occupies in this process's table and the pid behind it.
///
/// Serialisable because the one producer of these writes them to a file and the one
/// consumer is the next image of the same process, after an `execv`.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct AdoptSpec {
    /// The master fd, as numbered in *our* fd table. An exec preserves the table, so
    /// the number still names the same pty on the other side.
    pub master_fd: i32,
    pub pid: u32,
    pub cols: u16,
    pub rows: u16,
    /// `ttyname(master_fd)` as it was on the export side. Checked again on adopt: an
    /// fd number that still exists but names a different tty is the one corruption
    /// that would otherwise produce a session wired to a stranger.
    pub tty: Option<String>,
}

/// A running pty. Cloneable handle; dropping every clone does not end the child
/// (the registry owns the lifetime and calls `stop` explicitly).
#[derive(Clone)]
pub struct PtyHandle {
    inner: Arc<Inner>,
}

/// The master end of a pty, however this process came by it: opened here, or
/// inherited across an exec. Two implementations, one contract — nothing above this
/// line may be able to tell an adopted pty from a spawned one.
trait MasterEnd: Send {
    fn resize(&self, cols: u16, rows: u16) -> Result<()>;
    /// The master's fd number, for a handoff.
    #[cfg(unix)]
    fn raw_fd(&self) -> Option<RawFd>;
    #[cfg(unix)]
    fn tty_name(&self) -> Option<PathBuf>;
}

/// A master this process opened, still owned by `portable-pty`.
struct SpawnedMaster(Box<dyn MasterPty + Send>);

impl MasterEnd for SpawnedMaster {
    fn resize(&self, cols: u16, rows: u16) -> Result<()> {
        self.0.resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;
        Ok(())
    }

    #[cfg(unix)]
    fn raw_fd(&self) -> Option<RawFd> {
        self.0.as_raw_fd()
    }

    #[cfg(unix)]
    fn tty_name(&self) -> Option<PathBuf> {
        // `tty_name_of` rather than portable-pty's own `tty_name()`, which answers
        // from a field it recorded at `openpty`. The export side and the adopt side
        // have to be asking the same question of the same fd, or the check is a
        // comparison of two different facts that happen to agree most of the time.
        self.0.as_raw_fd().and_then(tty_name_of)
    }
}

/// A master this process did not open: a bare fd carried across an exec.
///
/// `portable-pty` has no public constructor for its own `UnixMasterPty` from a raw
/// fd, so the adopt path owns the fd directly. The one behaviour deliberately NOT
/// reproduced is `UnixMasterWriter::drop`, which writes `\n` + VEOF to the child —
/// nothing above this trait depends on a drop that hands a live CLI an EOF.
#[cfg(unix)]
struct AdoptedMaster(OwnedFd);

#[cfg(unix)]
impl MasterEnd for AdoptedMaster {
    fn resize(&self, cols: u16, rows: u16) -> Result<()> {
        let size = libc::winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        // SAFETY: a master pty fd we own and a winsize we just built. The kernel
        // raises SIGWINCH on the foreground group itself, as it does for the ioctl
        // portable-pty issues for a spawned master.
        let rc = unsafe { libc::ioctl(self.0.as_raw_fd(), libc::TIOCSWINSZ, &size) };
        if rc != 0 {
            return Err(std::io::Error::last_os_error()).context("TIOCSWINSZ");
        }
        Ok(())
    }

    fn raw_fd(&self) -> Option<RawFd> {
        Some(self.0.as_raw_fd())
    }

    fn tty_name(&self) -> Option<PathBuf> {
        tty_name_of(self.0.as_raw_fd())
    }
}

/// The child behind a pty: something to block on until it is reaped, and something to
/// take out if it will not go.
trait ChildEnd: Send {
    /// Block until the child is reaped, and report the code the wire uses: `-1` when
    /// a signal took it, its own status otherwise, `None` when the wait itself failed.
    fn wait_code(&mut self) -> Option<i32>;
    fn kill(&mut self) -> Result<()>;
}

struct SpawnedChild(Box<dyn portable_pty::Child + Send + Sync>);

impl ChildEnd for SpawnedChild {
    fn wait_code(&mut self) -> Option<i32> {
        // A child killed by a signal has no exit status of its own, and portable-pty
        // reports 1 for it — indistinguishable from a real failure. -1 is the
        // convention the wire already uses for "a signal took it", so clients can
        // tell a kill from a crash.
        self.0.wait().ok().map(|status| {
            if status.signal().is_some() {
                -1
            } else {
                status.exit_code() as i32
            }
        })
    }

    fn kill(&mut self) -> Result<()> {
        self.0.kill()?;
        Ok(())
    }
}

/// A child this image did not spawn, waited on by pid.
///
/// `waitpid` still works across the exec that brought us here: exec keeps the pid and
/// the parent/child relationships, so the adopted pid is as much our child as one we
/// forked ourselves.
#[cfg(unix)]
struct AdoptedChild(libc::pid_t);

#[cfg(unix)]
impl ChildEnd for AdoptedChild {
    fn wait_code(&mut self) -> Option<i32> {
        let mut status: libc::c_int = 0;
        loop {
            // SAFETY: a pid that is our own child and a status slot we own.
            let reaped = unsafe { libc::waitpid(self.0, &mut status, 0) };
            if reaped == self.0 {
                break;
            }
            if reaped < 0 {
                if std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
                    continue;
                }
                // ECHILD: somebody else already reaped it, so there is no status to
                // report and guessing one would invent an exit code.
                return None;
            }
        }
        if libc::WIFSIGNALED(status) {
            Some(-1)
        } else {
            Some(libc::WEXITSTATUS(status))
        }
    }

    fn kill(&mut self) -> Result<()> {
        signal_group(self.0 as u32, libc::SIGKILL);
        Ok(())
    }
}

/// A reader over a raw master fd, with `portable-pty`'s one piece of pty-specific
/// behaviour reproduced: macOS answers a read on a master whose slave has closed with
/// `EIO` rather than a zero-length read, and treating that as an error rather than as
/// EOF would leave the pump spinning on a pty nobody is on the other end of.
#[cfg(unix)]
struct FdReader(OwnedFd);

#[cfg(unix)]
impl Read for FdReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        // SAFETY: an fd we own and a buffer we were handed; the count is its length.
        let n = unsafe { libc::read(self.0.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len()) };
        if n >= 0 {
            return Ok(n as usize);
        }
        let err = std::io::Error::last_os_error();
        match err.raw_os_error() {
            Some(libc::EIO) => Ok(0),
            _ => Err(err),
        }
    }
}

/// A writer over a raw master fd. Closes on drop and nothing more — see
/// [`AdoptedMaster`] for why the EOF byte is not reproduced.
#[cfg(unix)]
struct FdWriter(OwnedFd);

#[cfg(unix)]
impl Write for FdWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        // SAFETY: an fd we own and a buffer we were handed; the count is its length.
        let n = unsafe { libc::write(self.0.as_raw_fd(), buf.as_ptr().cast(), buf.len()) };
        if n >= 0 {
            Ok(n as usize)
        } else {
            Err(std::io::Error::last_os_error())
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// The name of the terminal an fd names.
///
/// `ptsname`, not `ttyname`: the fd here is always the MASTER end, and `ttyname` on a
/// master answers nothing on macOS — which is how the first version of the adopt check
/// refused every pty it was given. `ptsname` asks the master for its slave's path,
/// which is the stable name both sides of an exec can compare.
///
/// `ptsname` writes into a static buffer, so the result is copied before anything else
/// can call it. Both callers run once, at a handoff or at boot.
#[cfg(unix)]
fn tty_name_of(fd: RawFd) -> Option<PathBuf> {
    // SAFETY: an fd we own. The returned pointer is into libc's own storage and is
    // copied out of before this function returns.
    let raw = unsafe { libc::ptsname(fd) };
    if raw.is_null() {
        return None;
    }
    // SAFETY: a non-null return from ptsname is a NUL-terminated path.
    let name = unsafe { std::ffi::CStr::from_ptr(raw) };
    Some(PathBuf::from(
        String::from_utf8_lossy(name.to_bytes()).into_owned(),
    ))
}

struct Inner {
    master: Mutex<Box<dyn MasterEnd>>,
    writer: Mutex<Box<dyn Write + Send>>,
    child: Mutex<Box<dyn ChildEnd>>,
    events: broadcast::Sender<PtyEvent>,
    /// The grid the pty currently believes it has.
    size: Mutex<(u16, u16)>,
    /// Set by the reader thread once the child is reaped, just before it publishes
    /// the exit. The stop ladder waits on this rather than on `child`, which the
    /// reader thread is itself blocked in `wait()` on.
    exited: AtomicBool,
    /// A receiver made BEFORE the reader thread started, handed to the first consumer
    /// that asks for it.
    ///
    /// A `broadcast::Receiver` only ever sees what is sent after it exists, and
    /// between a pty starting and its pump subscribing there is a real window. For a
    /// spawned pty it is short (the child has to start first) and was survivable by
    /// luck; for an adopted one it is the whole of `hydrate`, including a full replay
    /// of the stored scrollback into a grid — and the bytes a live CLI printed during
    /// it came back as a hole in the middle of its answer.
    first: Mutex<Option<broadcast::Receiver<PtyEvent>>>,
    /// Asked for on the way to an exec. The reader stops at the next chunk boundary
    /// and leaves everything after it in the kernel's pty buffer, for the next image
    /// to read once it has adopted the master. See [`PtyHandle::quiesce`].
    quiesced: AtomicBool,
    /// Read once at spawn. Asking the child for it later would mean taking the lock
    /// the reader thread holds while it waits, and the signal path must not be able
    /// to block on the thread whose exit it is waiting for.
    pid: Option<u32>,
}

/// Signal the child's whole process group, falling back to the child alone.
///
/// `portable-pty` puts the child in a session of its own, so it leads a group whose
/// id is its pid, and every helper the CLI spawns inherits that group. Signalling
/// only the pid leaves those helpers running after the session is gone; the Swift
/// core sends `killpg` for exactly this reason. `ESRCH` (already reaped, or never a
/// group leader) is not a failure worth reporting to a caller who asked for a stop.
#[cfg(unix)]
fn signal_group(pid: u32, sig: libc::c_int) {
    let pid = pid as libc::pid_t;
    // SAFETY: a pid we spawned and own, and a valid signal number. A pid that no
    // longer exists answers ESRCH, which is the outcome we wanted anyway.
    unsafe {
        if libc::killpg(pid, sig) != 0 {
            libc::kill(pid, sig);
        }
    }
}

/// `killpg` with no bare-pid fallback, for the sweep after the child is already gone.
///
/// [`signal_group`] falls back to `kill(pid, sig)` when `killpg` fails, which is right
/// while the child is alive and wrong the moment it is not: a reaped pid can be
/// recycled, and the fallback would then signal a stranger. The group id stays safe to
/// name for as long as the group has members, which is exactly the case this is for —
/// an empty group answers `ESRCH` and nothing happens, which is the outcome we wanted.
#[cfg(unix)]
fn signal_group_only(pid: u32, sig: libc::c_int) {
    // SAFETY: a group id we spawned and a valid signal number. A group that no longer
    // exists answers ESRCH, which needs no handling.
    unsafe {
        libc::killpg(pid as libc::pid_t, sig);
    }
}

/// Start the one thread that reads a pty and publishes what it says.
///
/// Shared by [`PtyHandle::spawn`] and [`PtyHandle::adopt`] rather than written twice:
/// the ordering here — drain to EOF, reap, set `exited`, then publish the exit — is
/// what the stop ladder waits on, and two copies of it would be two answers to when a
/// session is over.
fn start_reader(inner: Arc<Inner>, mut reader: Box<dyn Read + Send>) -> Result<()> {
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
                        let _ = inner
                            .events
                            .send(PtyEvent::Output(Arc::new(buf[..n].to_vec())));
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                }
                if inner.quiesced.load(Ordering::SeqCst) {
                    // Not an exit, and deliberately silent: the child is alive and is
                    // about to belong to another image of this process. Publishing an
                    // `Exit` here would tell every client a live session had ended.
                    return;
                }
            }
            let code = inner.child.lock().ok().and_then(|mut c| c.wait_code());
            inner.exited.store(true, Ordering::SeqCst);
            let _ = inner.events.send(PtyEvent::Exit(code));
        })
        .context("failed to start pty reader thread")?;
    Ok(())
}

/// Everything about a carried fd that can be checked before a session is called live.
///
/// The fd surviving an exec is not the same as the fd still naming the pty it named:
/// a number is only a number, and a session wired to the wrong one would print to a
/// stranger. `isatty` rejects anything that is not a terminal, the tty name pins it to
/// the same terminal, `tcgetpgrp` proves the line discipline still has a foreground
/// group, and signal 0 proves the child is there to be waited on.
#[cfg(unix)]
fn verify_adopted(master: &OwnedFd, spec: &AdoptSpec) -> Result<()> {
    let fd = master.as_raw_fd();
    // SAFETY: an fd we own; isatty only inspects it.
    if unsafe { libc::isatty(fd) } != 1 {
        anyhow::bail!("fd {fd} is not a terminal");
    }
    if let Some(expected) = spec.tty.as_deref() {
        match tty_name_of(fd) {
            Some(actual) if actual.to_string_lossy() == expected => {}
            other => anyhow::bail!(
                "fd {fd} names {:?}, not the {expected:?} it was exported as",
                other.as_ref().map(|p| p.display().to_string())
            ),
        }
    }
    // SAFETY: an fd we own; tcgetpgrp only reads the line discipline's state.
    if unsafe { libc::tcgetpgrp(fd) } <= 0 {
        anyhow::bail!("fd {fd} has no foreground process group; nothing is on the other end");
    }
    // SAFETY: signal 0 is the documented existence probe and delivers nothing.
    if unsafe { libc::kill(spec.pid as libc::pid_t, 0) } != 0
        && std::io::Error::last_os_error().raw_os_error() != Some(libc::EPERM)
    {
        anyhow::bail!("pid {} is gone", spec.pid);
    }
    Ok(())
}

/// Clear `FD_CLOEXEC` on `fd`, so it survives into the next image of this process.
///
/// Every pty fd is close-on-exec by construction: `portable-pty`'s `openpty` sets it
/// on the master, and the reader and writer dups are made with `F_DUPFD_CLOEXEC`. That
/// is the right default — a spawned CLI must not inherit another session's master —
/// and carrying exactly one fd per pty across an exec means clearing it on exactly
/// that one and letting the other two die with the image.
#[cfg(unix)]
pub fn make_inheritable(fd: RawFd) -> Result<()> {
    set_cloexec(fd, false)
}

/// Put `FD_CLOEXEC` back. The undo for [`make_inheritable`], for an exec that was
/// prepared for and then did not happen: leaving a master inheritable would hand the
/// next CLI this daemon spawns another session's pty.
#[cfg(unix)]
pub fn make_cloexec(fd: RawFd) -> Result<()> {
    set_cloexec(fd, true)
}

#[cfg(unix)]
fn set_cloexec(fd: RawFd, on: bool) -> Result<()> {
    // SAFETY: an fd we own and the two documented fcntl commands for its flags.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 {
        return Err(std::io::Error::last_os_error()).context("F_GETFD");
    }
    let next = if on {
        flags | libc::FD_CLOEXEC
    } else {
        flags & !libc::FD_CLOEXEC
    };
    // SAFETY: as above; the value is the flags we just read with one bit changed.
    if unsafe { libc::fcntl(fd, libc::F_SETFD, next) } < 0 {
        return Err(std::io::Error::last_os_error()).context("F_SETFD");
    }
    Ok(())
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

        let reader = pair
            .master
            .try_clone_reader()
            .context("clone reader failed")?;
        let writer = pair.master.take_writer().context("take writer failed")?;
        let (events, _) = broadcast::channel(buffer);

        let inner = Arc::new(Inner {
            master: Mutex::new(Box::new(SpawnedMaster(pair.master))),
            writer: Mutex::new(writer),
            child: Mutex::new(Box::new(SpawnedChild(child))),
            first: Mutex::new(Some(events.subscribe())),
            events: events.clone(),
            size: Mutex::new((spec.cols, spec.rows)),
            exited: AtomicBool::new(false),
            quiesced: AtomicBool::new(false),
            pid,
        });

        start_reader(Arc::clone(&inner), reader)?;
        Ok(Self { inner })
    }

    /// Take over a pty this image did not open: a master fd and a child pid carried
    /// across an `execv` of ourselves.
    ///
    /// The result is a `PtyHandle` in every respect — the same broadcast bus, the same
    /// `exited` flag, the same `signal_group` stop ladder — because a half-adopted
    /// handle is worse than a restart: it looks alive and is not. What separates the
    /// two is only how the ends underneath were obtained.
    ///
    /// Everything that can be checked is checked before the handle exists. An fd that
    /// is not a tty, names a different tty than the one exported, or has no live pid
    /// behind it is refused, and the caller degrades that session to the ordinary
    /// exited row.
    #[cfg(unix)]
    pub fn adopt(spec: AdoptSpec, buffer: usize) -> Result<Self> {
        if spec.master_fd <= 2 {
            anyhow::bail!(
                "fd {} is a standard stream, not a carried master",
                spec.master_fd
            );
        }
        // SAFETY: the fd is one this process carried across its own exec, so it is in
        // our table and unowned by any other value. Taking ownership here is what
        // makes the eventual drop close it, exactly as a spawned master's drop does.
        let master = unsafe { OwnedFd::from_raw_fd(spec.master_fd) };
        verify_adopted(&master, &spec)?;
        // Put `FD_CLOEXEC` back the moment it has done its job. The handoff cleared it
        // so the fd would survive the exec; leaving it clear means the next CLI this
        // daemon spawns inherits another session's master, which is exactly the leak
        // `openpty` sets the flag to prevent.
        make_cloexec(master.as_raw_fd())?;

        let reader = FdReader(master.try_clone().context("dup master for the reader")?);
        let writer = FdWriter(master.try_clone().context("dup master for the writer")?);
        let (events, _) = broadcast::channel(buffer);
        let inner = Arc::new(Inner {
            master: Mutex::new(Box::new(AdoptedMaster(master))),
            writer: Mutex::new(Box::new(writer)),
            child: Mutex::new(Box::new(AdoptedChild(spec.pid as libc::pid_t))),
            first: Mutex::new(Some(events.subscribe())),
            events,
            size: Mutex::new((spec.cols, spec.rows)),
            exited: AtomicBool::new(false),
            quiesced: AtomicBool::new(false),
            pid: Some(spec.pid),
        });
        start_reader(Arc::clone(&inner), Box::new(reader))?;
        Ok(Self { inner })
    }

    /// Subscribe to the output/exit stream. A late subscriber sees only what comes
    /// next — scrollback replay is the registry's job, not the pty's.
    pub fn subscribe(&self) -> broadcast::Receiver<PtyEvent> {
        self.inner.events.subscribe()
    }

    /// The stream from the pty's first byte, for the one consumer that owns its
    /// history — the registry's pump, and the ephemeral pane's.
    ///
    /// Taken once: the receiver behind it was made before the reader thread existed,
    /// so it is the only one that can have missed nothing. Everyone after gets an
    /// ordinary [`subscribe`](Self::subscribe), which is what a second viewer wants
    /// anyway.
    pub fn stream(&self) -> broadcast::Receiver<PtyEvent> {
        self.inner
            .first
            .lock()
            .ok()
            .and_then(|mut slot| slot.take())
            .unwrap_or_else(|| self.subscribe())
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
        master.resize(cols, rows)?;
        *size = (cols, rows);
        Ok(true)
    }

    /// Stop reading this pty at the next chunk boundary.
    ///
    /// Only the exec path calls it, and it is what makes the swap lossless. A reader
    /// thread that kept going would pull bytes out of the kernel into a 64KB buffer
    /// that the exec then throws away; stopping leaves them in the pty, where the next
    /// image reads them the moment it has adopted the master. The chunk the reader is
    /// already holding is published first, so nothing in flight is dropped either —
    /// which is why the caller flushes once more after a settle.
    pub fn quiesce(&self) {
        self.inner.quiesced.store(true, Ordering::SeqCst);
    }

    /// Describe this pty well enough for the next image of this process to adopt it,
    /// and clear `FD_CLOEXEC` on the one fd that is carried across.
    ///
    /// Only call this on the way to an `execv`. It leaves an fd inheritable that the
    /// spawn path deliberately does not, and the very next `spawn` in this image would
    /// hand a CLI another session's master.
    #[cfg(unix)]
    pub fn describe_for_adoption(&self) -> Result<AdoptSpec> {
        let master = self
            .inner
            .master
            .lock()
            .map_err(|_| anyhow::anyhow!("master poisoned"))?;
        let fd = master
            .raw_fd()
            .ok_or_else(|| anyhow::anyhow!("this master has no fd to carry"))?;
        let tty = master.tty_name().map(|p| p.to_string_lossy().into_owned());
        let pid = self
            .pid()
            .ok_or_else(|| anyhow::anyhow!("no child pid to wait on after the exec"))?;
        make_inheritable(fd)?;
        let (cols, rows) = self.size();
        Ok(AdoptSpec {
            master_fd: fd,
            pid,
            cols,
            rows,
            tty,
        })
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
                signal_group(pid, libc::SIGTERM);
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
                    return self.reap_group();
                }
                std::thread::sleep(REAP_POLL);
            }
        }
        if self.has_exited() {
            return self.reap_group();
        }
        self.kill()
    }

    /// SIGKILL whatever is left of the child's group once the child itself is gone.
    ///
    /// The child exiting is not the group emptying. A helper that ignores SIGTERM —
    /// a build, a test run, a language server, anything wrapped in `nohup` — outlives
    /// the child that spawned it, and the child is reaped inside the grace, so
    /// returning `Ok` there strands the helper for good. That was the bug the
    /// `orphan-reap` conformance scenario caught (juancode-r34g): both cores gated the
    /// group SIGKILL on the child still being alive, when the members that need it are
    /// precisely the ones that outlived it.
    ///
    /// Always `Ok`: the child is already gone, which is what the caller asked for, and
    /// an empty group is the normal case rather than a failure to report.
    fn reap_group(&self) -> Result<()> {
        #[cfg(unix)]
        if let Some(pid) = self.pid() {
            signal_group_only(pid, libc::SIGKILL);
        }
        Ok(())
    }

    /// Take the child out now, with no grace. The last rung of [`stop`](Self::stop),
    /// and the right call only when the flush has already had its chance.
    pub fn kill(&self) -> Result<()> {
        #[cfg(unix)]
        if let Some(pid) = self.pid() {
            // Never through `child`: the reader thread holds that lock for as long as
            // it is blocked in `wait()`, so a kill routed through it could not run at
            // the one moment it is needed. Signalling by pid takes no lock, which is
            // why the Swift core signals off its serial queue too.
            signal_group(pid, libc::SIGKILL);
            return Ok(());
        }
        let mut child = self
            .inner
            .child
            .lock()
            .map_err(|_| anyhow::anyhow!("child poisoned"))?;
        child.kill()
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

    /// Drain until `marker` appears, or give up. Synchronising on something the child
    /// actually said beats sleeping: `/bin/sh` needs half a second to reach its first
    /// command on a loaded machine, and a signal that lands before the child has set
    /// its handler is answered by the default disposition, not the handler.
    fn wait_for(rx: &mut broadcast::Receiver<PtyEvent>, marker: &str, within: Duration) -> String {
        let deadline = Instant::now() + within;
        let mut seen = String::new();
        while Instant::now() < deadline {
            match rx.try_recv() {
                Ok(PtyEvent::Output(bytes)) => {
                    seen.push_str(&String::from_utf8_lossy(&bytes));
                    if seen.contains(marker) {
                        break;
                    }
                }
                Ok(PtyEvent::Exit(_)) => break,
                Err(broadcast::error::TryRecvError::Empty) => std::thread::sleep(REAP_POLL),
                Err(_) => break,
            }
        }
        seen
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
                &[
                    "-c",
                    "trap 'printf FLUSHED; exit 0' TERM; printf READY; read ignored",
                ],
            ),
            256,
        )
        .expect("spawn");
        let mut rx = pty.subscribe();
        // The marker is printed after the trap, so seeing it means the handler is in
        // place. A fixed sleep instead asked whether a shell can start in 250ms.
        let ready = wait_for(&mut rx, "READY", Duration::from_secs(10));
        assert!(
            ready.contains("READY"),
            "the child never got as far as installing its handler; saw {ready:?}"
        );
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
        let pty = PtyHandle::spawn(
            spec(
                "/bin/sh",
                &["-c", "trap '' TERM; printf READY; read ignored"],
            ),
            256,
        )
        .expect("spawn");
        let mut rx = pty.subscribe();
        // Same handshake as the rung above: signalling before the child has ignored
        // TERM would kill it on the first rung and never reach the escalation.
        let ready = wait_for(&mut rx, "READY", Duration::from_secs(10));
        assert!(
            ready.contains("READY"),
            "the child never started; saw {ready:?}"
        );

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

    /// A helper that outlives the child must not outlive the session.
    ///
    /// The companion to the flush test below: there the helper answers TERM and dying
    /// is what lets the child flush, here it ignores TERM and HUP, so the child is
    /// reaped inside the grace with the helper still running. Returning `Ok` at that
    /// point stranded it (juancode-r34g); the group sweep is what takes it out. The
    /// wire-level version of this is the `orphan-reap` conformance scenario, which both
    /// cores failed until this landed.
    #[test]
    fn stop_reaps_a_helper_that_ignores_the_polite_signal() {
        // Plain characters only: this path is interpolated into a shell script, and a
        // `ThreadId(3)` in the name put unquoted parentheses in it, which the shell read
        // as a syntax error and no pid was ever written. One test uses it, so the pid of
        // the test process is unique enough.
        let pid_file =
            std::env::temp_dir().join(format!("juancoded-orphan-{}.pid", std::process::id()));
        let _ = std::fs::remove_file(&pid_file);
        // The inner shell reports its OWN pid: `$$` is inside single quotes, so the
        // outer shell leaves it for the inner one to expand. `sleep 30` and not a loop —
        // a fixture that could outlive the suite would be the very bug under test.
        let script = format!(
            "/bin/sh -c 'trap \"\" TERM HUP; printf %s $$ >\"{}\"; sleep 30' & printf READY; sleep 30",
            pid_file.display()
        );
        let pty = PtyHandle::spawn(spec("/bin/sh", &["-c", &script]), 256).expect("spawn");
        let mut rx = pty.subscribe();
        let ready = wait_for(&mut rx, "READY", Duration::from_secs(10));
        assert!(
            ready.contains("READY"),
            "the child never started; saw {ready:?}"
        );

        let helper = {
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                if let Ok(raw) = std::fs::read_to_string(&pid_file) {
                    if let Ok(pid) = raw.trim().parse::<i32>() {
                        break pid;
                    }
                }
                assert!(Instant::now() < deadline, "the helper never recorded a pid");
                std::thread::sleep(REAP_POLL);
            }
        };
        // The control: without a live helper here the assertion below would pass for a
        // helper that never started.
        assert!(
            pid_alive(helper),
            "the helper was not running before the stop"
        );

        pty.stop_within(Duration::from_millis(300)).expect("stop");

        let deadline = Instant::now() + Duration::from_secs(5);
        while pid_alive(helper) && Instant::now() < deadline {
            std::thread::sleep(REAP_POLL);
        }
        let survived = pid_alive(helper);
        if survived {
            // Never leave the fixture behind, even on the failing path.
            signal_group_only(helper as u32, libc::SIGKILL);
        }
        let _ = std::fs::remove_file(&pid_file);
        assert!(
            !survived,
            "helper {helper} outlived the session: killing a session has to reap the whole group"
        );
    }

    /// Signal 0 asks whether a pid exists without touching it. `EPERM` means it exists
    /// and belongs to someone else, which for this check is still alive.
    #[cfg(unix)]
    fn pid_alive(pid: i32) -> bool {
        // SAFETY: signal 0 is the documented existence probe and delivers nothing.
        if unsafe { libc::kill(pid, 0) } == 0 {
            return true;
        }
        std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
    }

    /// The signal goes to the group, and that is what makes the flush reachable at
    /// all when the CLI is waiting on a helper of its own. A shell blocked on a
    /// foreground child defers its TERM trap until that child is reaped, so a
    /// pid-only signal means the handler does not run inside the grace and the
    /// escalation takes the session out mid-write. `killpg` reaches the helper too,
    /// the wait returns, and the handler gets its turn. The Swift core signals the
    /// group for the same reason.
    #[test]
    fn a_child_waiting_on_a_helper_of_its_own_still_gets_to_flush() {
        let pty = PtyHandle::spawn(
            spec(
                "/bin/sh",
                &[
                    "-c",
                    "trap 'printf FLUSHED; exit 0' TERM; /bin/sh -c 'printf READY; sleep 30'",
                ],
            ),
            256,
        )
        .expect("spawn");
        let mut rx = pty.subscribe();
        // READY comes from the helper, so seeing it means the helper is already in the
        // group and the outer shell is already blocked waiting on it. Announcing from
        // the outer shell left a window where the signal arrived before the helper
        // existed, and the deferred trap then waited out the whole `sleep`.
        let ready = wait_for(&mut rx, "READY", Duration::from_secs(10));
        assert!(
            ready.contains("READY"),
            "the child never started; saw {ready:?}"
        );

        pty.stop_within(Duration::from_secs(2)).expect("stop");

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
            "the handler never got its turn; output was {seen:?}"
        );
        assert_eq!(
            code,
            Some(Some(0)),
            "an exit of its own, not a signal that took it"
        );
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

    /// The adopt path, without an exec: a master fd and a child pid with no
    /// `portable-pty` value anywhere, which is exactly what the next image of a
    /// re-exec'd daemon wakes up holding.
    ///
    /// What it has to prove is that nothing downstream can tell the result from a
    /// spawned handle — output arrives on the same bus, input reaches the child, the
    /// grid can be changed, and the exit is reported with the same code the wire
    /// already means by it.
    #[cfg(unix)]
    #[test]
    fn an_adopted_pty_behaves_exactly_like_a_spawned_one() {
        let pair = NativePtySystem::default()
            .openpty(PtySize {
                rows: 24,
                cols: 80,
                pixel_width: 0,
                pixel_height: 0,
            })
            .expect("openpty");
        let mut cmd = CommandBuilder::new("/bin/sh");
        cmd.arg("-c");
        cmd.arg("printf READY; read line; printf 'got:%s' \"$line\"; exit 7");
        cmd.cwd("/tmp");
        let child = pair.slave.spawn_command(cmd).expect("spawn");
        let pid = child.process_id().expect("a pid");
        drop(pair.slave);

        let fd = pair.master.as_raw_fd().expect("a master fd");
        let tty = tty_name_of(fd).map(|p| p.to_string_lossy().into_owned());
        assert!(
            tty.is_some(),
            "a master has to be able to name its terminal"
        );
        make_inheritable(fd).expect("clear FD_CLOEXEC");
        // Leaked exactly as the handoff leaks them: dropping the master's writer
        // writes \n + the termios VEOF byte, which is an EOF on the child's stdin.
        std::mem::forget(pair.master);
        std::mem::forget(child);

        let pty = PtyHandle::adopt(
            AdoptSpec {
                master_fd: fd,
                pid,
                cols: 80,
                rows: 24,
                tty,
            },
            256,
        )
        .expect("adopt");
        assert_eq!(pty.pid(), Some(pid), "an adopted handle knows its child");

        let mut rx = pty.stream();
        let ready = wait_for(&mut rx, "READY", Duration::from_secs(10));
        assert!(
            ready.contains("READY"),
            "no output from the adopted pty: {ready:?}"
        );

        assert!(
            pty.resize(100, 30).expect("resize"),
            "the ioctl reached the pty"
        );
        assert_eq!(pty.size(), (100, 30));

        pty.write(b"hello\n").expect("write");
        let echoed = wait_for(&mut rx, "got:hello", Duration::from_secs(10));
        assert!(
            echoed.contains("got:hello"),
            "input did not reach the adopted child: {echoed:?}"
        );

        loop {
            match rx.blocking_recv() {
                Ok(PtyEvent::Exit(code)) => {
                    assert_eq!(code, Some(7), "waitpid reported the child's own status");
                    break;
                }
                Ok(_) => continue,
                Err(e) => panic!("the stream ended without an exit: {e}"),
            }
        }
        assert!(pty.has_exited());
    }

    /// Everything checkable is checked before a session is called live. An fd that is
    /// not a terminal is the cheap case; the expensive one is an fd that IS a terminal
    /// but not the one that was exported, which is what the tty name is for.
    #[cfg(unix)]
    #[test]
    fn adopting_refuses_an_fd_that_is_not_the_pty_it_was_promised() {
        let file = std::fs::File::open("/dev/null").expect("open");
        let err = PtyHandle::adopt(
            AdoptSpec {
                master_fd: file.as_raw_fd(),
                pid: std::process::id(),
                cols: 80,
                rows: 24,
                tty: None,
            },
            16,
        )
        .err()
        .expect("a non-terminal is not a pty");
        assert!(err.to_string().contains("not a terminal"), "{err}");
        // The refusal took ownership of nothing it should not have: the fd is still
        // ours and still usable.
        std::mem::forget(file);

        for fd in [0, 1, 2] {
            assert!(
                PtyHandle::adopt(
                    AdoptSpec {
                        master_fd: fd,
                        pid: std::process::id(),
                        cols: 80,
                        rows: 24,
                        tty: None,
                    },
                    16,
                )
                .is_err(),
                "fd {fd} is a standard stream and must never be adopted"
            );
        }
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
