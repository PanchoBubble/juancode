//! Who this daemon is, captured once at boot and never recomputed.
//!
//! The daemon outlives the app that talks to it. That is a feature — a pty must
//! survive an app relaunch — and it is also the trap this module exists to close:
//! an app that reconnects to a daemon started hours ago, under a different build
//! and a different environment, has no way to tell from the wire that it is looking
//! at a mirror of something two hours stale. It just shows an empty, confident list.
//!
//! So the handshake carries the daemon's identity, and both consumers compare it
//! against their own:
//!
//! * the app, over `serverInfo.daemon` (see `DaemonIdentity` in the Swift client);
//! * `dev-app.sh`, over the run file this module writes, before it decides whether
//!   to adopt the running daemon or end it.
//!
//! Everything here is decided at boot on purpose. `build_stamp` is the mtime of the
//! executable **as it was when this process started**; comparing it against that
//! path's mtime *now* is exactly the "somebody rebuilt the core and the old one is
//! still serving" test. Recomputing it lazily would answer the wrong question.

use std::io::Write;
use std::path::Path;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use serde_json::{json, Value};

use crate::owner::{self, Ownership, Watchdog};

/// Milliseconds since the epoch, or `None` for a clock we could not read.
fn millis(t: SystemTime) -> Option<i64> {
    t.duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|d| i64::try_from(d.as_millis()).ok())
}

/// What a client needs to decide whether this daemon is the one it meant to talk to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DaemonIdentity {
    pub pid: u32,
    /// When this daemon captured its identity, which is boot plus the millisecond or
    /// two it takes to mount the tree.
    pub started_at_ms: Option<i64>,
    /// The binary that is running, absolute where the OS could resolve it.
    pub exe: Option<String>,
    /// mtime of `exe` at boot. A newer mtime on disk means the checkout moved on and
    /// this process did not.
    pub build_stamp_ms: Option<i64>,
    pub version: &'static str,
    /// `JUANCODE_BUILD_ID` as this daemon saw it. `dev-app.sh` stamps the same value
    /// into the app it launches, so an exact match is available in the sanctioned
    /// launch path and the mtime comparison is the fallback everywhere else.
    pub build_id: Option<String>,
    /// The directory this daemon's own SQLite lives in — never the app's mirror.
    pub data_dir: Option<String>,
    /// The per-project session cap this daemon actually applies. Read from its
    /// environment at boot, so an app launched later with a different
    /// `JUANCODE_SESSIONS_PER_PROJECT` is describing a value the daemon never saw.
    pub sessions_per_project: usize,
    /// Who will end this daemon, and after how long. The one part of the identity
    /// that is deliberately NOT frozen at boot: everything above is a fact about the
    /// build, which cannot change while the process runs, whereas ownership changes
    /// hands the moment a later launch claims a running daemon. `to_value` therefore
    /// resolves it per frame, which is also the only way a client that just claimed
    /// this daemon sees itself as the owner.
    pub lifetime: Arc<Watchdog>,
}

impl DaemonIdentity {
    /// Capture the running process's identity. Called once, from `CoreHandles`.
    pub fn capture(sessions_per_project: usize) -> Self {
        let owner_file = juancoded_persistence::db_path()
            .parent()
            .map(|d| d.join(owner::OWNER_FILE));
        Self::capture_owned(
            sessions_per_project,
            Arc::new(Watchdog::from_env(std::process::id(), owner_file)),
        )
    }

    /// `capture` with the lifetime contract handed in, for the tests that must not
    /// read the developer's real ownership record.
    pub fn capture_owned(sessions_per_project: usize, lifetime: Arc<Watchdog>) -> Self {
        let exe = std::env::current_exe().ok();
        let build_stamp_ms = exe
            .as_deref()
            .and_then(|p| std::fs::metadata(p).ok())
            .and_then(|m| m.modified().ok())
            .and_then(millis);
        Self {
            pid: std::process::id(),
            started_at_ms: millis(SystemTime::now()),
            exe: exe.map(|p| p.to_string_lossy().into_owned()),
            build_stamp_ms,
            version: env!("CARGO_PKG_VERSION"),
            build_id: std::env::var("JUANCODE_BUILD_ID")
                .ok()
                .filter(|v| !v.trim().is_empty()),
            data_dir: juancoded_persistence::db_path()
                .parent()
                .map(|p| p.to_string_lossy().into_owned()),
            sessions_per_project,
            lifetime,
        }
    }

    /// The `daemon` object on `serverInfo`. Nulls are emitted rather than omitted:
    /// "the daemon could not read its own mtime" and "this core does not report one"
    /// are different answers, and a client that wants to warn about staleness has to
    /// be able to tell them apart.
    pub fn to_value(&self) -> Value {
        // Live, not captured: see `lifetime`.
        let (state, owner_pid) = match self.lifetime.ownership(&owner::process_alive) {
            Ownership::Unowned => ("unowned", None),
            Ownership::Owned(pid) => ("owned", Some(pid)),
            Ownership::Orphaned(pid) => ("orphaned", Some(pid)),
        };
        json!({
            "pid": self.pid,
            "startedAt": self.started_at_ms,
            "exePath": self.exe,
            "buildStamp": self.build_stamp_ms,
            "version": self.version,
            "buildId": self.build_id,
            "dataDir": self.data_dir,
            "sessionsPerProject": self.sessions_per_project,
            // Who ends this process, in the client's words: `owned` (a live launch
            // will reap it), `orphaned` (its launch is gone and the countdown is
            // running), `unowned` (nobody claimed it, and nothing — including the
            // daemon itself — will ever end it).
            "ownerState": state,
            "ownerPid": owner_pid,
            "ownerGraceMs": i64::try_from(self.lifetime.grace.as_millis()).ok(),
        })
    }
}

/// The run file's name, beside the daemon's own store so a relocated
/// `JUANCODED_DATA_DIR` moves both together. A constant because a shell script reads
/// it by path and the two spellings must not drift.
pub const RUN_FILE: &str = "juancoded.run";

/// Write the run file: the same identity the wire carries, in the one format a
/// `dev-app.sh` can read without a JSON parser.
///
/// Deliberately `key=value` lines and not JSON. The only consumer is a bash script
/// deciding whether to adopt or end this daemon, and a script that has to shell out
/// to a JSON parser it may not have is a script that silently skips the check.
/// Values are written raw: every field here is a path, a number or an identifier we
/// produced, none of them contain newlines.
pub fn write_run_file(identity: &DaemonIdentity, port: u16, path: &Path) -> Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("mkdir {}", dir.display()))?;
    }
    let mut body = String::new();
    let mut line = |k: &str, v: String| {
        body.push_str(k);
        body.push('=');
        body.push_str(&v);
        body.push('\n');
    };
    line("pid", identity.pid.to_string());
    line("port", port.to_string());
    line("version", identity.version.to_string());
    line("started_at_ms", opt(identity.started_at_ms));
    line("exe", identity.exe.clone().unwrap_or_default());
    line("build_stamp_ms", opt(identity.build_stamp_ms));
    line("build_id", identity.build_id.clone().unwrap_or_default());
    line("data_dir", identity.data_dir.clone().unwrap_or_default());
    line(
        "sessions_per_project",
        identity.sessions_per_project.to_string(),
    );
    // The launcher writes its own ownership record; these two are the DAEMON's side
    // of the same question, so `juancoded.sh status` can say whether the watchdog is
    // armed without having to guess from the environment it cannot see.
    line(
        "owner_pid",
        opt(identity.lifetime.spawn_owner.map(i64::from)),
    );
    line(
        "owner_grace_ms",
        i64::try_from(identity.lifetime.grace.as_millis())
            .map(|n| n.to_string())
            .unwrap_or_default(),
    );

    // Write-then-rename: a reader that catches a half-written file would decide the
    // daemon is unidentifiable and offer to kill it, which is the one outcome this
    // whole module exists to avoid taking by accident.
    let tmp = path.with_extension("run.tmp");
    let mut f = std::fs::File::create(&tmp).with_context(|| format!("create {}", tmp.display()))?;
    f.write_all(body.as_bytes())?;
    f.sync_all()?;
    std::fs::rename(&tmp, path).with_context(|| format!("rename into {}", path.display()))?;
    Ok(())
}

fn opt(v: Option<i64>) -> String {
    v.map(|n| n.to_string()).unwrap_or_default()
}

/// Best-effort removal on a clean shutdown, so a stopped daemon does not leave a
/// file claiming a pid that has been recycled. A crash leaves it behind; readers
/// check that the pid is alive for exactly that reason.
pub fn remove_run_file(path: &Path) {
    let _ = std::fs::remove_file(path);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A watchdog with no owner and no record to read: what an identity test wants,
    /// because `capture` would otherwise read the developer's live ownership record.
    fn unowned() -> Arc<Watchdog> {
        Arc::new(Watchdog {
            daemon_pid: std::process::id(),
            spawn_owner: None,
            owner_file: None,
            grace: owner::DEFAULT_GRACE,
            poll: owner::DEFAULT_POLL,
        })
    }

    #[test]
    fn capture_reports_this_process() {
        let id = DaemonIdentity::capture_owned(40, unowned());
        assert_eq!(id.pid, std::process::id());
        assert_eq!(id.sessions_per_project, 40);
        assert!(id.started_at_ms.unwrap() > 1_600_000_000_000);
        // The test binary is a real file, so both of these must resolve.
        assert!(id.exe.is_some());
        assert!(id.build_stamp_ms.is_some());
    }

    #[test]
    fn to_value_carries_every_field_a_client_compares() {
        let id = DaemonIdentity::capture_owned(7, unowned());
        let v = id.to_value();
        for key in [
            "pid",
            "startedAt",
            "exePath",
            "buildStamp",
            "version",
            "buildId",
            "dataDir",
            "sessionsPerProject",
            "ownerState",
            "ownerPid",
            "ownerGraceMs",
        ] {
            assert!(v.get(key).is_some(), "serverInfo.daemon is missing {key}");
        }
        assert_eq!(v["sessionsPerProject"], 7);
        // Nobody claimed this one, so the client is told plainly that nothing will
        // end it — never left to infer it from a missing key.
        assert_eq!(v["ownerState"], "unowned");
        assert!(v["ownerPid"].is_null());
    }

    #[test]
    fn a_live_owner_is_reported_as_owned() {
        let id = DaemonIdentity::capture_owned(
            1,
            Arc::new(Watchdog {
                daemon_pid: std::process::id(),
                // This test process: alive by definition, so no clock is needed.
                spawn_owner: Some(std::process::id()),
                owner_file: None,
                grace: std::time::Duration::from_secs(120),
                poll: owner::DEFAULT_POLL,
            }),
        );
        let v = id.to_value();
        assert_eq!(v["ownerState"], "owned");
        assert_eq!(v["ownerPid"], std::process::id());
        assert_eq!(v["ownerGraceMs"], 120_000);
    }

    #[test]
    fn run_file_is_key_value_lines_a_shell_can_read() {
        let dir = std::env::temp_dir().join(format!("juancoded-run-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let id = DaemonIdentity::capture_owned(0, unowned());
        let path = dir.join(RUN_FILE);
        write_run_file(&id, 4290, &path).unwrap();

        let body = std::fs::read_to_string(&path).unwrap();
        let fields: Vec<&str> = body.lines().map(|l| l.split_once('=').unwrap().0).collect();
        assert_eq!(
            fields,
            vec![
                "pid",
                "port",
                "version",
                "started_at_ms",
                "exe",
                "build_stamp_ms",
                "build_id",
                "data_dir",
                "sessions_per_project",
                "owner_pid",
                "owner_grace_ms",
            ]
        );
        assert!(body.contains(&format!("pid={}\n", std::process::id())));
        assert!(body.contains("port=4290\n"));
        assert!(body.contains("sessions_per_project=0\n"));
        // An unowned daemon writes an EMPTY owner_pid rather than omitting the line:
        // a launcher reading a missing key cannot tell "unowned" from "an older
        // daemon that did not report ownership at all".
        assert!(body.contains("owner_pid=\n"));
        assert!(body.contains("owner_grace_ms=120000\n"));
        // No temp file left behind for a reader to trip over.
        assert!(!dir.join("juancoded.run.tmp").exists());

        remove_run_file(&path);
        assert!(!path.exists());
        std::fs::remove_dir_all(&dir).ok();
    }
}
