//! Re-exec this daemon onto a freshly built binary without killing its sessions.
//!
//! Tier 2 of juancode-hz7n. `stop_serving` flushes and then the loader drops, the
//! master fds close, the kernel SIGHUPs each pty's foreground group and every CLI
//! dies; the next boot reads the rows back and forces them exited, because a row that
//! claimed to be running would be a session no client could get bytes out of. Scrollback
//! and the grid are already durable — the only thing that cannot be rebuilt from the
//! store is the live fd/pid wiring, and `execv` carries exactly that for free. It keeps
//! the pid, the fd table and the children, so nothing is ever signalled: no SIGHUP, no
//! SIGTERM, no `--resume`, no lost transcript.
//!
//! ## The order, and why it is this order
//!
//! 1. **Resolve and check the binary.** Everything after this point is hard to undo,
//!    so the one failure that is easy to predict is predicted first.
//! 2. **Flush.** `flush_all` is the same call `stop_serving` makes, and for the same
//!    reason: scrollback is written on a throttle, so without it the swap eats the
//!    last couple of seconds of every live session — which would defeat the point.
//! 3. **Hand off.** Each reader thread stops at a chunk boundary (leaving everything
//!    after it in the kernel's pty buffer, for the next image to read), each carried
//!    master loses `FD_CLOEXEC`, and each handle is leaked so no `UnixMasterWriter`
//!    drop can hand a live CLI an EOF on stdin.
//! 4. **Settle, then flush again.** The chunk each reader was already holding is
//!    published before it stops; this is what gets it folded into the ring and written.
//! 5. **Exec**, with the environment otherwise untouched — env fidelity is the property
//!    this daemon exists for, and exec preserves it without anyone doing anything.
//!
//! The listeners need no step of their own: both sockets are close-on-exec (std and
//! tokio create every socket with `SOCK_CLOEXEC`), so they are gone the instant the new
//! image starts and it wins its own bind. The Unix socket *path* survives, and the new
//! image reclaims it exactly as any boot over a stale path does — `is_live` fails to
//! connect, so it unlinks and binds.
//!
//! ## Why it is not shipped on
//!
//! A daemon that can replace its own code on request is a daemon that can be asked to
//! run a binary somebody else chose. This is debug builds only and behind an env flag
//! on top, so a release build has no route at all. The watch loop that would rebuild
//! and trigger this automatically is a separate ticket; this is the mechanism, driven
//! by an explicit command.

use std::path::{Path, PathBuf};
use std::time::Duration;

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use axum::{Json, Router};
use tracing::{error, info, warn};

use juancoded_core::pty::make_cloexec;
use juancoded_core::reexec;

use crate::serve::CoreHandles;

/// The env flag that has to be set for the route to exist at all, on top of the build
/// being a debug one.
pub const ENABLE_ENV: &str = "JUANCODED_REEXEC";

/// How long the pumps get to fold the last chunk each reader published before the
/// final flush. Generous next to a broadcast hop, and paid once per swap.
const SETTLE: Duration = Duration::from_millis(150);

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ReexecRequest {
    /// The binary to become. Defaults to our own path, which is what a rebuild in
    /// place has already replaced.
    pub binary: Option<String>,
}

pub fn routes() -> Router<CoreHandles> {
    Router::new().route("/api/reexec", post(reexec_now))
}

/// Whether this build and this environment allow a self-exec.
fn enabled() -> bool {
    cfg!(debug_assertions) && std::env::var(ENABLE_ENV).is_ok_and(|v| v != "0" && !v.is_empty())
}

async fn reexec_now(
    State(handles): State<CoreHandles>,
    body: Option<Json<ReexecRequest>>,
) -> Response {
    if !enabled() {
        return (
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({
                "error": format!(
                    "re-exec is a debug-build mechanism and is off; start the daemon with \
                     {ENABLE_ENV}=1 to enable it."
                )
            })),
        )
            .into_response();
    }
    let req = body.map(|Json(b)| b).unwrap_or_default();
    let binary = match resolve_binary(req.binary.as_deref()) {
        Ok(path) => path,
        Err(e) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({ "error": format!("{e:#}") })),
            )
                .into_response()
        }
    };

    match swap_onto(&handles, &binary).await {
        // Unreachable on success: `execv` does not return.
        Ok(()) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        Err(e) => {
            error!(binary = %binary.display(), error = %e, "the re-exec did not happen");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({ "error": format!("{e:#}") })),
            )
                .into_response()
        }
    }
}

/// The binary this daemon is about to become, checked as far as it can be checked
/// without running it.
///
/// Worth being fussy about: every failure caught here is one that would otherwise
/// happen after the ptys have been handed over, when there is no good way back.
fn resolve_binary(asked: Option<&str>) -> anyhow::Result<PathBuf> {
    let path = match asked {
        Some(p) => PathBuf::from(p),
        None => std::env::current_exe().map_err(|e| anyhow::anyhow!("no path of our own: {e}"))?,
    };
    let meta = std::fs::metadata(&path)
        .map_err(|e| anyhow::anyhow!("{} cannot be read: {e}", path.display()))?;
    if !meta.is_file() {
        anyhow::bail!("{} is not a file", path.display());
    }
    if !executable(&path) {
        anyhow::bail!("{} is not executable", path.display());
    }
    // A text file with a shebang execs fine; anything else that is not a Mach-O or an
    // ELF would fail with ENOEXEC *after* the handoff, which is the one moment there
    // is nothing useful to do about it.
    let mut magic = [0u8; 4];
    use std::io::Read;
    std::fs::File::open(&path)?.read_exact(&mut magic)?;
    let runnable = matches!(
        magic,
        // Mach-O (64-bit, both endiannesses) and the fat/universal wrappers.
        [0xcf, 0xfa, 0xed, 0xfe]
            | [0xfe, 0xed, 0xfa, 0xcf]
            | [0xca, 0xfe, 0xba, 0xbe]
            | [0xbe, 0xba, 0xfe, 0xca]
            // ELF.
            | [0x7f, b'E', b'L', b'F']
    ) || magic.starts_with(b"#!");
    if !runnable {
        anyhow::bail!(
            "{} does not start like something exec can run",
            path.display()
        );
    }
    Ok(path)
}

#[cfg(unix)]
fn executable(path: &Path) -> bool {
    use std::ffi::CString;
    let Ok(c) = CString::new(path.as_os_str().as_encoded_bytes()) else {
        return false;
    };
    // SAFETY: a NUL-terminated path we own and the documented access mode.
    unsafe { libc::access(c.as_ptr(), libc::X_OK) == 0 }
}

#[cfg(not(unix))]
fn executable(_path: &Path) -> bool {
    true
}

/// Quiesce, hand the ptys over and become `binary`. Returns only on failure.
#[cfg(unix)]
async fn swap_onto(handles: &CoreHandles, binary: &Path) -> anyhow::Result<()> {
    let Some(pty) = handles.pty.clone() else {
        anyhow::bail!("this tree mounted no `pty` service, so there is nothing to carry");
    };

    // The same flush the shutdown path makes, and the bulk of the work: everything a
    // live session has printed since its last throttled write.
    let flushed = handles.sessions.flush_all();
    let carried = pty.hand_off();
    // The pumps are tokio tasks and the exec removes them without ceremony; what they
    // must not lose is the chunk each reader published on its way to stopping. This is
    // that window, and the flush below is what puts it in the store.
    tokio::time::sleep(SETTLE).await;
    handles.sessions.flush_all();

    let dir = juancoded_persistence::db_path()
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(std::env::temp_dir);
    let fds: Vec<i32> = carried.iter().map(|c| c.spec.master_fd).collect();
    let sessions = carried.len();
    let handoff = match reexec::write(&dir, carried) {
        Ok(path) => path,
        Err(e) => {
            undo(&fds, None);
            return Err(e);
        }
    };
    info!(
        binary = %binary.display(),
        sessions,
        flushed,
        handoff = %handoff.display(),
        "re-execing onto a new binary; the live ptys come with us"
    );

    // The ONE entry added to the environment, and the adopting side removes it from
    // its own the moment it has read the file — so no CLI this daemon spawns after the
    // swap ever sees it. Everything else `execv` carries across untouched, which is
    // the whole reason this daemon is worth having.
    std::env::set_var(reexec::HANDOFF_ENV, &handoff);
    let err = exec_self(binary);
    undo(&fds, Some(&handoff));
    Err(err)
}

#[cfg(not(unix))]
async fn swap_onto(_handles: &CoreHandles, _binary: &Path) -> anyhow::Result<()> {
    anyhow::bail!("re-execing onto a new binary is unix-only")
}

/// Replace this process's image, keeping argv exactly as it was.
///
/// Only returns on failure, and then it returns why.
#[cfg(unix)]
fn exec_self(binary: &Path) -> anyhow::Error {
    use std::ffi::CString;
    let Ok(path) = CString::new(binary.as_os_str().as_encoded_bytes()) else {
        return anyhow::anyhow!("{} has a NUL in it", binary.display());
    };
    let argv: Vec<CString> = std::env::args_os()
        .filter_map(|a| CString::new(a.as_encoded_bytes()).ok())
        .collect();
    let mut raw: Vec<*const libc::c_char> = argv.iter().map(|a| a.as_ptr()).collect();
    raw.push(std::ptr::null());
    // SAFETY: a NUL-terminated path and a NULL-terminated argv, both alive for the
    // duration of the call. On success nothing after this line exists.
    unsafe {
        libc::execv(path.as_ptr(), raw.as_ptr());
    }
    std::io::Error::last_os_error().into()
}

/// Put back what the handoff changed, for an exec that did not happen.
///
/// The fds must not stay inheritable: the next CLI this daemon spawns would be handed
/// another session's master. The reader threads cannot be restarted, so this daemon is
/// deaf on its ptys from here — it is still the better half of a bad outcome, and it is
/// why `resolve_binary` is as fussy as it is.
#[cfg(unix)]
fn undo(fds: &[i32], handoff: Option<&Path>) {
    for fd in fds {
        if let Err(e) = make_cloexec(*fd) {
            warn!(fd, error = %e, "could not put FD_CLOEXEC back on a carried master");
        }
    }
    std::env::remove_var(reexec::HANDOFF_ENV);
    if let Some(path) = handoff {
        let _ = std::fs::remove_file(path);
    }
    error!(
        "the exec failed after the ptys were handed over: this daemon is still serving \
         but has stopped reading them. Restart it to recover."
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_missing_or_unrunnable_binary_is_refused_before_anything_is_handed_over() {
        let dir = std::env::temp_dir().join(format!("juancoded-reexec-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();

        let missing = dir.join("nope");
        assert!(resolve_binary(Some(missing.to_str().unwrap())).is_err());

        // Executable, but not something exec can run: the check that exists because
        // ENOEXEC would land after the point of no return.
        let text = dir.join("plain.txt");
        std::fs::write(&text, b"hello, not a binary").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&text, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let err = resolve_binary(Some(text.to_str().unwrap())).expect_err("refused");
        assert!(err.to_string().contains("exec can run"), "{err}");

        // And our own test binary, which is exactly the shape of the real argument.
        let ours = std::env::current_exe().unwrap();
        assert_eq!(resolve_binary(Some(ours.to_str().unwrap())).unwrap(), ours);

        std::fs::remove_dir_all(&dir).ok();
    }

    /// The gate is two-sided: a release build has no route, and a debug build still
    /// needs the flag. Asserted rather than assumed, because "off by default" is the
    /// only thing standing between this and a daemon that runs a binary of someone
    /// else's choosing.
    #[test]
    fn the_route_is_off_without_the_flag() {
        let restore = std::env::var(ENABLE_ENV).ok();
        std::env::remove_var(ENABLE_ENV);
        assert!(!enabled(), "no flag, no re-exec");
        std::env::set_var(ENABLE_ENV, "0");
        assert!(!enabled(), "an explicit 0 is off");
        std::env::set_var(ENABLE_ENV, "1");
        assert_eq!(enabled(), cfg!(debug_assertions));
        match restore {
            Some(v) => std::env::set_var(ENABLE_ENV, v),
            None => std::env::remove_var(ENABLE_ENV),
        }
    }
}
