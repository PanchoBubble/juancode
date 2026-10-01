//! The handoff: what one image of this daemon tells the next about the ptys it is
//! carrying across an `execv` of itself.
//!
//! An exec keeps the pid, the open fds and the child processes, so a daemon that
//! re-execs onto a freshly built binary never signals its CLIs: no SIGHUP, no
//! SIGTERM, no `--resume`, no lost transcript. The one thing exec does NOT carry is
//! the knowledge of which fd belongs to which session, and that is all this file is.
//!
//! It is a file rather than an argv entry because argv is what the exec reproduces
//! verbatim — a second re-exec would have to know to strip an entry the first one
//! added. The path travels in one env var, which the adopting side removes from its
//! own environment the moment it has read it, so no spawned CLI ever sees it.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::pty::AdoptSpec;

/// Names the handoff file. Set immediately before the exec and unset by the image
/// that reads it.
pub const HANDOFF_ENV: &str = "JUANCODED_REEXEC_HANDOFF";

/// The handoff format this image writes. Version 1 is the unversioned shape the first
/// re-exec wrote, which version 2 reads unchanged; the field exists so that the day the
/// shape does change, an image that cannot read a file refuses it instead of misreading
/// fd numbers out of it.
pub const HANDOFF_VERSION: u32 = 2;

/// The oldest format this image can adopt from.
pub const HANDOFF_MIN_VERSION: u32 = 1;

/// The argument that makes a binary answer which handoff formats it reads and exit,
/// before it boots anything. The outgoing image runs the incoming one with it BEFORE
/// handing a single pty over: a binary that cannot answer, or answers with a range
/// that excludes [`HANDOFF_VERSION`], is refused while refusing still costs nothing.
pub const PROBE_ARG: &str = "--handoff-probe";

/// What a binary prints for [`PROBE_ARG`]: `juancoded-handoff <min> <max>`.
pub fn probe_line() -> String {
    format!("juancoded-handoff {HANDOFF_MIN_VERSION} {HANDOFF_VERSION}")
}

/// Whether a probe's stdout says that binary can adopt a handoff of `version`.
pub fn probe_accepts(stdout: &str, version: u32) -> bool {
    stdout.lines().any(|line| {
        let mut words = line.split_whitespace();
        if words.next() != Some("juancoded-handoff") {
            return false;
        }
        let min = words.next().and_then(|w| w.parse::<u32>().ok());
        let max = words.next().and_then(|w| w.parse::<u32>().ok());
        matches!((min, max), (Some(min), Some(max)) if (min..=max).contains(&version))
    })
}

fn version_one() -> u32 {
    1
}

/// One live pty, named by the session it belongs to and described well enough for the
/// next image of this process to take it over.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SessionHandoff {
    pub session: String,
    #[serde(flatten)]
    pub spec: AdoptSpec,
}

/// What the file holds. A struct rather than a bare list so the reader can refuse a
/// file another daemon wrote.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Handoff {
    /// Absent in a file the first, unversioned, re-exec wrote, which is version 1.
    #[serde(default = "version_one")]
    pub version: u32,
    /// The pid that wrote it, which an exec preserves — so a file whose pid is not
    /// ours came from a different daemon and names fds in a different table.
    pub pid: u32,
    pub sessions: Vec<SessionHandoff>,
}

/// Write the handoff where the next image will look for it, and return the path.
pub fn write(dir: &Path, sessions: Vec<SessionHandoff>) -> Result<PathBuf> {
    std::fs::create_dir_all(dir).with_context(|| format!("mkdir {}", dir.display()))?;
    let path = dir.join(format!("reexec-handoff-{}.json", std::process::id()));
    let handoff = Handoff {
        version: HANDOFF_VERSION,
        pid: std::process::id(),
        sessions,
    };
    std::fs::write(&path, serde_json::to_vec(&handoff)?)
        .with_context(|| format!("write {}", path.display()))?;
    Ok(path)
}

/// Read the handoff this image was exec'd with, if there is one, and consume it.
///
/// Consuming is the point: the file names fds in exactly one fd table, and a leftover
/// read by a later boot would adopt numbers that mean something else entirely. The env
/// var goes with it, so the next CLI this daemon spawns inherits the environment the
/// user actually has.
///
/// A file that cannot be read or was written by another pid is a boot with no handoff:
/// every session then comes back the ordinary exited way. A file this image CAN read
/// but whose version it does not understand is different, and louder: the fds in it
/// are live ptys with CLIs on the other end, so they are kept open rather than closed
/// (closing one hangs its CLI up) and only get `FD_CLOEXEC` back, so no CLI spawned
/// from here inherits them. The file is kept beside the store as `*.rejected` for
/// whoever has to work out what happened. The probe the outgoing image runs exists so
/// this branch is never reached in practice.
pub fn take() -> Option<Handoff> {
    let path = std::env::var(HANDOFF_ENV).ok()?;
    std::env::remove_var(HANDOFF_ENV);
    let body = match std::fs::read(&path) {
        Ok(b) => b,
        Err(e) => {
            tracing::warn!(path, error = %e, "the handoff file named by the environment is not readable");
            return None;
        }
    };
    let loose: serde_json::Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(e) => {
            let _ = std::fs::remove_file(&path);
            tracing::warn!(path, error = %e, "the handoff file is not a handoff");
            return None;
        }
    };
    let pid = loose.get("pid").and_then(serde_json::Value::as_u64);
    if pid != Some(u64::from(std::process::id())) {
        let _ = std::fs::remove_file(&path);
        tracing::warn!(
            path,
            wrote = pid,
            ours = std::process::id(),
            "the handoff was written by another process, so its fd numbers are not ours"
        );
        return None;
    }
    let version = loose
        .get("version")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(1);
    let readable = (u64::from(HANDOFF_MIN_VERSION)..=u64::from(HANDOFF_VERSION)).contains(&version);
    let parsed = readable
        .then(|| serde_json::from_value::<Handoff>(loose.clone()))
        .transpose();
    match parsed {
        Ok(Some(handoff)) => {
            let _ = std::fs::remove_file(&path);
            Some(handoff)
        }
        outcome => {
            let why = match outcome {
                Err(e) => format!("version {version} but not its shape: {e}"),
                _ => format!(
                    "version {version}, and this image reads {HANDOFF_MIN_VERSION}..={HANDOFF_VERSION}"
                ),
            };
            let fds = keep_but_seal(&loose);
            let kept = format!("{path}.rejected");
            let _ = std::fs::rename(&path, &kept);
            tracing::error!(
                handoff = kept,
                why,
                fds = ?fds,
                "THE HANDOFF CANNOT BE READ BY THIS BINARY. Its ptys are still open and \
                 their CLIs still alive, but nothing is reading them. Upgrade back onto a \
                 binary that reads this format, or restart the daemon to end them."
            );
            None
        }
    }
}

/// Put `FD_CLOEXEC` back on every master a rejected handoff names, without closing
/// any. Returns the fds it touched.
fn keep_but_seal(loose: &serde_json::Value) -> Vec<i64> {
    let fds: Vec<i64> = loose
        .get("sessions")
        .and_then(serde_json::Value::as_array)
        .map(|sessions| {
            sessions
                .iter()
                .filter_map(|s| s.get("master_fd").and_then(serde_json::Value::as_i64))
                .filter(|fd| *fd > 2 && *fd <= i64::from(i32::MAX))
                .collect()
        })
        .unwrap_or_default();
    #[cfg(unix)]
    for fd in &fds {
        let _ = crate::pty::make_cloexec(*fd as i32);
    }
    fds
}

/// Close a carried master nobody adopted.
///
/// The fd crossed the exec with `FD_CLOEXEC` cleared, so leaving it is two leaks at
/// once: a descriptor held for the life of the daemon, and a pty handed to every CLI
/// spawned afterwards. Closing it also hangs up whatever is on the other end, which is
/// the honest outcome for a session this image cannot serve.
#[cfg(unix)]
pub fn discard(spec: &AdoptSpec) {
    if spec.master_fd > 2 {
        // SAFETY: an fd this process carried across its own exec and that nothing else
        // has taken ownership of — the adopt path is the only other claimant and it
        // did not run for this one.
        unsafe {
            libc::close(spec.master_fd);
        }
    }
}

#[cfg(not(unix))]
pub fn discard(_spec: &AdoptSpec) {}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(fd: i32) -> AdoptSpec {
        AdoptSpec {
            master_fd: fd,
            pid: 4242,
            cols: 100,
            rows: 30,
            tty: Some("/dev/ttys009".into()),
        }
    }

    /// The round trip, the consuming half of it, and the refusal — all in one test on
    /// purpose. `HANDOFF_ENV` is process-wide state, and two tests setting it would be
    /// two tests racing to read each other's handoff.
    ///
    /// Reading removes both the file and the env var, because the fd numbers inside are
    /// true for exactly one image of one process and a second read of them would name
    /// something else entirely.
    #[test]
    fn a_handoff_is_read_once_and_only_by_the_process_that_wrote_it() {
        let dir = std::env::temp_dir().join(format!("juancoded-handoff-{}", std::process::id()));
        let path = write(
            &dir,
            vec![SessionHandoff {
                session: "s-1".into(),
                spec: spec(19),
            }],
        )
        .expect("write");
        std::env::set_var(HANDOFF_ENV, &path);

        let handoff = take().expect("a handoff we just wrote");
        assert_eq!(handoff.pid, std::process::id());
        assert_eq!(handoff.sessions.len(), 1);
        assert_eq!(handoff.sessions[0].session, "s-1");
        assert_eq!(handoff.sessions[0].spec.master_fd, 19);
        assert_eq!(handoff.sessions[0].spec.cols, 100);

        assert!(!path.exists(), "the file has to be consumed");
        assert!(
            std::env::var(HANDOFF_ENV).is_err(),
            "the env var has to go with it, or every CLI this daemon spawns inherits it"
        );
        assert!(take().is_none(), "a second read finds nothing");

        // And a file written by a different process names fds in a different table:
        // adopting from it would wire a session to whatever those numbers mean here.
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("alien.json");
        let alien = Handoff {
            version: HANDOFF_VERSION,
            pid: std::process::id().wrapping_add(1),
            sessions: vec![SessionHandoff {
                session: "s-1".into(),
                spec: spec(19),
            }],
        };
        std::fs::write(&path, serde_json::to_vec(&alien).unwrap()).unwrap();
        std::env::set_var(HANDOFF_ENV, &path);
        assert!(
            take().is_none(),
            "another process's fd numbers are not ours"
        );

        // A file the first, unversioned re-exec wrote is version 1, and is read.
        let path = dir.join("v1.json");
        let v1 = serde_json::json!({
            "pid": std::process::id(),
            "sessions": [{ "session": "s-1", "master_fd": 19, "pid": 4242,
                           "cols": 100, "rows": 30, "tty": "/dev/ttys009" }],
        });
        std::fs::write(&path, serde_json::to_vec(&v1).unwrap()).unwrap();
        std::env::set_var(HANDOFF_ENV, &path);
        let handoff = take().expect("an unversioned handoff is version 1");
        assert_eq!(handoff.version, 1);
        assert_eq!(handoff.sessions[0].spec.master_fd, 19);

        // A version this image does not read is refused, but its fds are LIVE ptys:
        // kept open, only sealed against inheritance, and the file kept for a human.
        let (keep, _peer) = std::os::unix::net::UnixStream::pair().unwrap();
        let fd = std::os::fd::AsRawFd::as_raw_fd(&keep);
        crate::pty::make_inheritable(fd).unwrap();
        let path = dir.join("future.json");
        let future = serde_json::json!({
            "version": HANDOFF_VERSION + 1,
            "pid": std::process::id(),
            "sessions": [{ "session": "s-1", "master_fd": fd, "something": "new" }],
        });
        std::fs::write(&path, serde_json::to_vec(&future).unwrap()).unwrap();
        std::env::set_var(HANDOFF_ENV, &path);
        assert!(take().is_none(), "a future format is not guessed at");
        // SAFETY: an fd we own; F_GETFD only reads its flags.
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
        assert!(flags >= 0, "the fd must still be open");
        assert_ne!(
            flags & libc::FD_CLOEXEC,
            0,
            "and sealed against the next spawn"
        );
        assert!(
            dir.join("future.json.rejected").exists(),
            "the refused file is kept"
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_probe_answer_names_the_range_of_formats_a_binary_reads() {
        assert!(probe_accepts(&probe_line(), HANDOFF_VERSION));
        assert!(probe_accepts(&probe_line(), HANDOFF_MIN_VERSION));
        assert!(!probe_accepts(&probe_line(), HANDOFF_VERSION + 1));
        assert!(probe_accepts("noise\njuancoded-handoff 1 9\n", 5));
        assert!(!probe_accepts("", HANDOFF_VERSION), "silence is a refusal");
        assert!(!probe_accepts("juancoded-handoff two", HANDOFF_VERSION));
    }
}
