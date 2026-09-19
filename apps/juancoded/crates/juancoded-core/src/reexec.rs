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
/// A file that cannot be read, cannot be parsed, or was written by another pid is a
/// boot with no handoff — every session then comes back the ordinary exited way.
pub fn take() -> Option<Handoff> {
    let path = std::env::var(HANDOFF_ENV).ok()?;
    std::env::remove_var(HANDOFF_ENV);
    let body = std::fs::read(&path);
    let _ = std::fs::remove_file(&path);
    let body = match body {
        Ok(b) => b,
        Err(e) => {
            tracing::warn!(path, error = %e, "the handoff file named by the environment is not readable");
            return None;
        }
    };
    let handoff: Handoff = match serde_json::from_slice(&body) {
        Ok(h) => h,
        Err(e) => {
            tracing::warn!(path, error = %e, "the handoff file is not a handoff");
            return None;
        }
    };
    if handoff.pid != std::process::id() {
        tracing::warn!(
            path,
            wrote = handoff.pid,
            ours = std::process::id(),
            "the handoff was written by another process, so its fd numbers are not ours"
        );
        return None;
    }
    Some(handoff)
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
        std::fs::remove_dir_all(&dir).ok();
    }
}
