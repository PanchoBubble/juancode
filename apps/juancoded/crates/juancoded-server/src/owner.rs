//! Who owns this daemon's lifetime, and what it does when that owner disappears.
//!
//! THE HOLE THIS FILLS
//!
//! `dev-app.sh` traps EXIT/INT/TERM/HUP and reaps the daemon it started, so a normal
//! quit, a ctrl-c and a `set -e` abort all end the core with the app. None of that
//! survives the launch being SIGKILLed, force-quit, or dying with its terminal in a
//! way bash never sees: a trap in a process that no longer exists does not fire, and
//! what is left is a daemon at PPID 1 holding ptys that nothing will ever end. That
//! is the exact process pair this work started from — juancoded from 09:39 at PPID 1
//! still serving an app relaunched at 16:40.
//!
//! macOS has no `prctl(PR_SET_PDEATHSIG)`, so the kernel will not do it. The daemon
//! has to do it itself, which is this module: it knows which process claims it, it
//! polls whether that process is still there, and when it is not it shuts itself down
//! through the same orderly path as SIGTERM.
//!
//! OWNERSHIP IS DECLARED, NEVER INFERRED
//!
//! A daemon is owned only when something SAYS so. Two spellings, one meaning:
//!
//! * `JUANCODE_OWNER_PID` in the environment at spawn — the launcher's own pid,
//!   handed over at the one moment ownership is a fact rather than a guess.
//! * the launcher's ownership record (`juancoded.owner`, written by
//!   `apps/native/scripts/juancoded.sh`), which is how a LATER launch that claims an
//!   already-running daemon becomes its owner.
//!
//! Anything started outside that path — `cargo run -p juancoded`, a daemon somebody
//! keeps alive on purpose — has neither, reads as UNOWNED, and this watchdog never
//! touches it. That is the deliberate asymmetry: "nobody claimed me" means live
//! forever, and only an explicit claim can ever end a process. Ownership inferred
//! from "it happens to be on my port" is what made the original bug possible, and it
//! is exactly what is not allowed to end a pty.
//!
//! WHY NOT A CLIENT CONNECTION
//!
//! Tying the lifetime to the app's WebSocket would be wrong twice: the app does not
//! spawn the daemon (`CoreBoot` only connects to it), so a dropped socket is a
//! reconnect and not a death; and it would end an independently-started daemon the
//! moment a developer closed their client. A pid handed over at spawn is a fact about
//! who created this process, cannot be acquired by merely connecting, and is legible
//! in `ps` and on the wire.
//!
//! PID REUSE, AND WHICH WAY IT FAILS
//!
//! An owner pid can in principle be recycled by an unrelated process, and then this
//! watchdog reads a dead owner as alive and the daemon lives longer than it should.
//! That direction is a stale process; the other direction is somebody's running
//! agents killed by mistake. No start-time check is worth adding until the cheap
//! failure is the one that hurts.

use std::path::{Path, PathBuf};
use std::time::Duration;

use tracing::{info, warn};

/// The launcher's ownership record, beside the daemon's own run file. A constant
/// because a bash script writes it by path and these two spellings must not drift
/// (`OWN_FILE` in `apps/native/scripts/juancoded.sh`).
pub const OWNER_FILE: &str = "juancoded.owner";

/// How long a daemon keeps serving after its owner is gone before it ends itself.
///
/// Deliberately generous. This countdown only ever runs after a BAD death — a normal
/// quit reaps the daemon immediately through the launcher's trap — so a long grace
/// costs nothing but a couple of minutes of a doomed process, while a short one ends
/// live ptys in the middle of a legitimate relaunch. Two minutes covers an
/// incremental `swift build` plus `cargo build` plus app launch on this machine,
/// where a single fork+exec already costs a quarter of a second and minutes under
/// load. Override with `JUANCODE_OWNER_GRACE_SECONDS`.
pub const DEFAULT_GRACE: Duration = Duration::from_secs(120);

/// How often the owner is checked. One `kill(pid, 0)` and one small file read, so the
/// cost is irrelevant next to being two minutes late noticing.
pub const DEFAULT_POLL: Duration = Duration::from_secs(2);

/// Who claims this daemon, as of one check.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ownership {
    /// Nobody claims it. Nothing will reap it, and this watchdog will not either.
    Unowned,
    /// A live process claims it.
    Owned(u32),
    /// A claim exists and the claimant is gone. This is the countdown state.
    Orphaned(u32),
}

/// One ownership record, as the launcher writes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Claim {
    /// Which daemon this record is about. A record naming another pid is somebody
    /// else's and is ignored — reading it as ours is how a daemon would shut down
    /// because an unrelated launch ended.
    pub daemon_pid: Option<u32>,
    /// The launch process that owns that daemon.
    pub owner_pid: Option<u32>,
    /// The launch's own token, carried for logs only. The launcher matches on it; we
    /// never do, because a token that changed hands is still a live owner.
    pub token: Option<String>,
}

impl Claim {
    /// Parse the `key=value` record. First occurrence of a key wins, matching the
    /// `sed | head -1` the shell side reads it with.
    pub fn parse(body: &str) -> Self {
        let mut claim = Claim {
            daemon_pid: None,
            owner_pid: None,
            token: None,
        };
        for line in body.lines() {
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            let value = value.trim();
            match key.trim() {
                "daemon_pid" if claim.daemon_pid.is_none() => claim.daemon_pid = value.parse().ok(),
                "owner_pid" if claim.owner_pid.is_none() => claim.owner_pid = value.parse().ok(),
                "token" if claim.token.is_none() && !value.is_empty() => {
                    claim.token = Some(value.to_string())
                }
                _ => {}
            }
        }
        claim
    }

    /// Read the record, or `None` when there is no readable one. A missing or
    /// unparseable file means unowned, which is the safe answer.
    pub fn read(path: &Path) -> Option<Self> {
        std::fs::read_to_string(path).ok().map(|b| Self::parse(&b))
    }

    /// The owner this record names for `daemon_pid`, or `None` when it is about some
    /// other daemon, names no owner, or names one that cannot own anything (pid 0,
    /// and pid 1 — `launchd` is what a process gets reparented TO, so a record naming
    /// it is a record of an owner that already died).
    pub fn owner_of(&self, daemon_pid: u32) -> Option<u32> {
        if self.daemon_pid != Some(daemon_pid) {
            return None;
        }
        self.owner_pid.filter(|&p| p > 1)
    }
}

/// Whether a pid is a live process we could signal.
///
/// `kill(pid, 0)` sends nothing; it only asks. `EPERM` counts as alive on purpose —
/// the process exists, it is simply not ours to signal, and treating "not mine" as
/// "gone" would end a daemon whose owner is alive under another uid.
pub fn process_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    let Ok(pid) = i32::try_from(pid) else {
        return false;
    };
    // SAFETY: signal 0 is the existence probe; it delivers nothing and touches no
    // memory we own.
    if unsafe { libc::kill(pid, 0) } == 0 {
        return true;
    }
    std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// Everything the watchdog needs to decide, all of it injectable so the state machine
/// is testable without spawning processes or waiting two minutes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Watchdog {
    /// This daemon's pid, so a claim about another daemon can be ignored.
    pub daemon_pid: u32,
    /// The owner handed over at spawn, before any record exists to read.
    pub spawn_owner: Option<u32>,
    /// The launcher's ownership record. `None` in tests and for a core with no data
    /// directory, which then has only its spawn owner.
    pub owner_file: Option<PathBuf>,
    pub grace: Duration,
    pub poll: Duration,
}

/// Why the watchdog is asking for a shutdown, for the log line that explains an exit
/// nobody typed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Orphaned {
    pub owner_pid: u32,
    /// How long the owner had been gone when the daemon gave up on it.
    pub waited: Duration,
}

impl Watchdog {
    /// Read `JUANCODE_OWNER_PID` and `JUANCODE_OWNER_GRACE_SECONDS`. An unset,
    /// unparseable or nonsense owner leaves the daemon unowned rather than guessing;
    /// a grace of 0 disables the countdown entirely, which is the escape hatch for
    /// anyone who wants the old outlive-everything behaviour back.
    pub fn from_env(daemon_pid: u32, owner_file: Option<PathBuf>) -> Self {
        let spawn_owner = std::env::var("JUANCODE_OWNER_PID")
            .ok()
            .and_then(|v| v.trim().parse::<u32>().ok())
            .filter(|&p| p > 1);
        let grace = std::env::var("JUANCODE_OWNER_GRACE_SECONDS")
            .ok()
            .and_then(|v| v.trim().parse::<u64>().ok())
            .map(Duration::from_secs)
            .unwrap_or(DEFAULT_GRACE);
        Self {
            daemon_pid,
            spawn_owner,
            owner_file,
            grace,
            poll: DEFAULT_POLL,
        }
    }

    /// Whether this watchdog can ever end the daemon. False means no claim exists to
    /// act on, or the countdown was disabled.
    pub fn is_armed(&self) -> bool {
        !self.grace.is_zero() && (self.spawn_owner.is_some() || self.owner_file.is_some())
    }

    /// The owner as of right now.
    ///
    /// The record wins over the spawn owner when it is about this daemon, because it
    /// is the live account of ownership: a later launch that claims a running daemon
    /// writes itself in there, and adopting that new owner is what lets a relaunch
    /// cancel a countdown. The spawn owner is the fallback for the window before the
    /// record exists — and for the case where it is deleted out from under us, where
    /// "the launcher that started me is gone" is still the truth.
    pub fn ownership(&self, alive: &impl Fn(u32) -> bool) -> Ownership {
        let claimed = self
            .owner_file
            .as_deref()
            .and_then(Claim::read)
            .and_then(|c| c.owner_of(self.daemon_pid))
            .or(self.spawn_owner);
        match claimed {
            None => Ownership::Unowned,
            Some(pid) if alive(pid) => Ownership::Owned(pid),
            Some(pid) => Ownership::Orphaned(pid),
        }
    }

    /// Run until the daemon must end itself. Returns only when the owner has been
    /// gone for the whole grace period; an unowned daemon, or one whose owner comes
    /// back or is replaced by a live claim, never returns from here.
    ///
    /// It is one arm of `main`'s `select!`, beside the signal handler, so an orphaned
    /// daemon takes the SAME shutdown path as a SIGTERM — the run file is removed and
    /// the plugin tree unwinds in reverse mount order. A watchdog that called
    /// `process::exit` would be a second, worse shutdown path that skips the flush the
    /// first one exists for.
    pub async fn watch(&self) -> Orphaned {
        self.watch_with(process_alive, tokio::time::sleep).await
    }

    /// `watch` with the clock and the liveness probe injected.
    pub async fn watch_with<A, S, F>(&self, alive: A, mut sleep: S) -> Orphaned
    where
        A: Fn(u32) -> bool,
        S: FnMut(Duration) -> F,
        F: std::future::Future<Output = ()>,
    {
        if !self.is_armed() {
            if self.grace.is_zero() {
                warn!("JUANCODE_OWNER_GRACE_SECONDS=0 — this daemon will outlive its owner");
            } else {
                info!("no owner declared; this daemon will not end itself");
            }
            // Never resolves: an unowned daemon has no shutdown to schedule, and this
            // arm of the select must simply never win.
            return std::future::pending::<Orphaned>().await;
        }
        match self.ownership(&alive) {
            Ownership::Owned(pid) => info!(
                owner_pid = pid,
                grace_secs = self.grace.as_secs(),
                "owned; ending this daemon when that process is gone"
            ),
            Ownership::Orphaned(pid) => warn!(
                owner_pid = pid,
                "the owner declared at spawn is already gone; starting the countdown"
            ),
            Ownership::Unowned => {}
        }

        // The countdown, and the pid it belongs to. A different pid means a different
        // death, so the wait restarts rather than inheriting somebody else's elapsed
        // time.
        let mut gone: Option<(u32, Duration)> = None;
        loop {
            sleep(self.poll).await;
            match self.ownership(&alive) {
                Ownership::Unowned => {
                    if let Some((pid, _)) = gone.take() {
                        info!(
                            owner_pid = pid,
                            "the claim on this daemon was withdrawn; standing down"
                        );
                    }
                }
                Ownership::Owned(pid) => {
                    if let Some((was, _)) = gone.take() {
                        info!(
                            gone_owner_pid = was,
                            owner_pid = pid,
                            "a live launch claimed this daemon; countdown cancelled"
                        );
                    }
                }
                Ownership::Orphaned(pid) => {
                    let waited = match gone {
                        Some((was, waited)) if was == pid => waited + self.poll,
                        _ => {
                            warn!(
                                owner_pid = pid,
                                grace_secs = self.grace.as_secs(),
                                "owner is gone — shutting down unless a launch claims this daemon"
                            );
                            self.poll
                        }
                    };
                    if waited >= self.grace {
                        return Orphaned {
                            owner_pid: pid,
                            waited,
                        };
                    }
                    gone = Some((pid, waited));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::HashSet;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("juancoded-owner-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write_claim(path: &Path, daemon_pid: u32, owner_pid: u32) {
        std::fs::write(
            path,
            format!("daemon_pid={daemon_pid}\ntoken=1234-5\nowner_pid={owner_pid}\n"),
        )
        .unwrap();
    }

    #[test]
    fn this_process_is_alive_and_an_impossible_pid_is_not() {
        assert!(process_alive(std::process::id()));
        assert!(!process_alive(0));
        // Above the default kern.maxproc ceiling, so nothing can hold it.
        assert!(!process_alive(4_000_000));
    }

    #[test]
    fn a_claim_about_another_daemon_is_not_ours() {
        let claim = Claim::parse("daemon_pid=999\ntoken=abc\nowner_pid=1234\n");
        assert_eq!(claim.daemon_pid, Some(999));
        assert_eq!(claim.owner_pid, Some(1234));
        assert_eq!(claim.token.as_deref(), Some("abc"));
        assert_eq!(claim.owner_of(999), Some(1234));
        assert_eq!(
            claim.owner_of(1000),
            None,
            "a record about another daemon must never name our owner"
        );
    }

    #[test]
    fn a_record_naming_launchd_or_nothing_is_unowned() {
        // `owner_pid=1` is what a reparented owner looks like: the launch is gone and
        // launchd inherited its children. Believing it would keep the daemon alive
        // forever, which is the bug.
        assert_eq!(
            Claim::parse("daemon_pid=7\nowner_pid=1\n").owner_of(7),
            None
        );
        assert_eq!(
            Claim::parse("daemon_pid=7\nowner_pid=0\n").owner_of(7),
            None
        );
        assert_eq!(Claim::parse("daemon_pid=7\n").owner_of(7), None);
        assert_eq!(Claim::parse("garbage\n").owner_of(7), None);
        // First occurrence wins, like the `sed | head -1` on the shell side.
        assert_eq!(
            Claim::parse("owner_pid=42\nowner_pid=99\ndaemon_pid=7\n").owner_of(7),
            Some(42)
        );
    }

    #[test]
    fn the_record_wins_over_the_spawn_owner_when_it_names_this_daemon() {
        let dir = temp_dir("precedence");
        let file = dir.join(OWNER_FILE);
        let dog = Watchdog {
            daemon_pid: 7,
            spawn_owner: Some(100),
            owner_file: Some(file.clone()),
            grace: DEFAULT_GRACE,
            poll: DEFAULT_POLL,
        };
        let live: HashSet<u32> = [100, 200].into_iter().collect();
        let alive = |pid: u32| live.contains(&pid);

        // No record yet: the spawn owner is all there is.
        assert_eq!(dog.ownership(&alive), Ownership::Owned(100));

        // A record about somebody else's daemon changes nothing.
        write_claim(&file, 999, 200);
        assert_eq!(dog.ownership(&alive), Ownership::Owned(100));

        // A record about us hands ownership over.
        write_claim(&file, 7, 200);
        assert_eq!(dog.ownership(&alive), Ownership::Owned(200));

        // And a record naming a dead owner is the countdown state, not unowned.
        write_claim(&file, 7, 300);
        assert_eq!(dog.ownership(&alive), Ownership::Orphaned(300));

        // Deleted record: back to the spawn owner, because "the launcher that started
        // me is gone" is still true.
        std::fs::remove_file(&file).unwrap();
        assert_eq!(dog.ownership(&alive), Ownership::Owned(100));
        std::fs::remove_dir_all(&dir).ok();
    }

    /// A clock that does not really sleep, so a two-minute grace is a handful of
    /// ticks. It yields, which matters: a fake sleep that is immediately ready never
    /// hands control back to the runtime, and a `timeout` around it could never fire.
    macro_rules! fake_clock {
        ($elapsed:expr) => {
            |d: Duration| {
                *$elapsed.borrow_mut() += d;
                async { tokio::task::yield_now().await }
            }
        };
    }

    #[tokio::test]
    async fn an_unowned_daemon_never_ends_itself() {
        let dog = Watchdog {
            daemon_pid: 7,
            spawn_owner: None,
            owner_file: None,
            grace: DEFAULT_GRACE,
            poll: Duration::from_millis(1),
        };
        assert!(!dog.is_armed());
        let elapsed = RefCell::new(Duration::ZERO);
        let outcome = tokio::time::timeout(
            Duration::from_millis(30),
            dog.watch_with(|_| false, fake_clock!(elapsed)),
        )
        .await;
        assert!(
            outcome.is_err(),
            "a daemon nobody claimed must never shut itself down"
        );
    }

    #[tokio::test]
    async fn a_zero_grace_disarms_the_countdown() {
        let dog = Watchdog {
            daemon_pid: 7,
            spawn_owner: Some(100),
            owner_file: None,
            grace: Duration::ZERO,
            poll: Duration::from_millis(1),
        };
        assert!(!dog.is_armed());
        let elapsed = RefCell::new(Duration::ZERO);
        let outcome = tokio::time::timeout(
            Duration::from_millis(30),
            dog.watch_with(|_| false, fake_clock!(elapsed)),
        )
        .await;
        assert!(outcome.is_err(), "grace 0 must opt out entirely");
    }

    #[tokio::test]
    async fn a_dead_owner_ends_the_daemon_only_after_the_full_grace() {
        let dog = Watchdog {
            daemon_pid: 7,
            spawn_owner: Some(100),
            owner_file: None,
            grace: Duration::from_secs(120),
            poll: Duration::from_secs(2),
        };
        let elapsed = RefCell::new(Duration::ZERO);
        let orphaned = dog.watch_with(|_| false, fake_clock!(elapsed)).await;
        assert_eq!(orphaned.owner_pid, 100);
        assert_eq!(orphaned.waited, Duration::from_secs(120));
        // 60 ticks of 2s, and not one second less: the grace is the whole point.
        assert_eq!(*elapsed.borrow(), Duration::from_secs(120));
    }

    #[tokio::test]
    async fn a_relaunch_that_claims_the_daemon_cancels_the_countdown() {
        let dir = temp_dir("claim");
        let file = dir.join(OWNER_FILE);
        write_claim(&file, 7, 100);
        let dog = Watchdog {
            daemon_pid: 7,
            spawn_owner: Some(100),
            owner_file: Some(file.clone()),
            grace: Duration::from_secs(10),
            poll: Duration::from_secs(1),
        };
        // Owner 100 is dead from the start; 200 is the relaunch, and it is alive.
        let elapsed = RefCell::new(Duration::ZERO);
        let claimed = file.clone();
        let clock = |d: Duration| {
            *elapsed.borrow_mut() += d;
            // Five seconds in, half way through the grace, a new launch claims it.
            if *elapsed.borrow() == Duration::from_secs(5) {
                write_claim(&claimed, 7, 200);
            }
            async { tokio::task::yield_now().await }
        };
        let outcome = tokio::time::timeout(
            Duration::from_millis(50),
            dog.watch_with(|p| p == 200, clock),
        )
        .await;
        assert!(
            outcome.is_err(),
            "a daemon a live launch has claimed must not shut down"
        );
        assert!(
            *elapsed.borrow() > Duration::from_secs(10),
            "it ran past the grace period without ending"
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn a_second_death_restarts_the_countdown_instead_of_inheriting_it() {
        let dir = temp_dir("second-death");
        let file = dir.join(OWNER_FILE);
        write_claim(&file, 7, 100);
        let dog = Watchdog {
            daemon_pid: 7,
            spawn_owner: None,
            owner_file: Some(file.clone()),
            grace: Duration::from_secs(10),
            poll: Duration::from_secs(1),
        };
        // 100 is gone; 200 claims at 5s and is replaced at 6s by a 300 that never was.
        let elapsed = RefCell::new(Duration::ZERO);
        let claimed = file.clone();
        let clock = |d: Duration| {
            *elapsed.borrow_mut() += d;
            let now = *elapsed.borrow();
            if now == Duration::from_secs(5) {
                write_claim(&claimed, 7, 200);
            } else if now == Duration::from_secs(6) {
                write_claim(&claimed, 7, 300);
            }
            async { tokio::task::yield_now().await }
        };
        let orphaned = dog.watch_with(|p| p == 200, clock).await;
        assert_eq!(orphaned.owner_pid, 300);
        assert_eq!(
            orphaned.waited,
            Duration::from_secs(10),
            "the handover must not donate its elapsed time to the next death"
        );
        // The handover tick at 6s is already the first second of the new wait, so a
        // full fresh grace lands at 15s — not 16, and not the 10s an inherited
        // countdown would have produced.
        assert_eq!(*elapsed.borrow(), Duration::from_secs(15));
        std::fs::remove_dir_all(&dir).ok();
    }
}
