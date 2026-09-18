//! The global `heavy` slot queue: memory-heavy commands serialized across every
//! agent session on one machine.
//!
//! Ported from `JuancodeServices/HeavyQueue.swift`, which is deleted in the same
//! change. The daemon is the right owner: the queue is machine state that outlives
//! any one app launch, and moving it here is what makes the line readable and
//! reorderable from the phone rather than only from the Mac it is running on.
//!
//! ## The registry format
//!
//! The queue is a shared filesystem registry, not a process. `~/.claude/bin/heavy`
//! writes one JSON entry per job under `<root>/queue/<pid>.json`:
//!
//! ```json
//! { "pid": 123, "child": 124, "prio": 0, "since": 1758000000,
//!   "started": 1758000004, "slot": 1, "cmd": "pnpm test", "cwd": "/repo" }
//! ```
//!
//! and admits jobs in (priority desc, enqueue time asc) order, re-reading its own
//! entry on every poll (~3s). That last part is the whole mechanism this module
//! drives: rewriting an entry's `prio` moves it up or down the line, and no signal
//! is needed because the waiting wrapper is already looking. A slot held is a
//! directory `<root>/slot-<n>` containing the holder's pid.
//!
//! Capacity lives in `~/.claude/heavy-queue.json` (`slots`, `workerCap`), which the
//! wrapper also re-reads every poll — so raising `slots` lets jobs already in line
//! through. Every other key in that file, `rules` included, belongs to the wrapper
//! and is preserved verbatim on a write.
//!
//! ## What this module will not do
//!
//! It never deletes another job's files. A dead entry is left on disk for the
//! wrapper's own `reap` to clear, because the only thing distinguishing "gone" from
//! "mid-rewrite" here is a liveness probe that can race.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::{Map, Value};

/// Capacity the wrapper falls back to with no config file, matching `heavy`'s own
/// defaults. A number invented here rather than read is a number the queue would
/// disagree with the panel about.
const DEFAULT_SLOTS: i64 = 1;
const DEFAULT_WORKER_CAP: i64 = 4;

/// One memory-heavy command in the queue — either holding a slot (`slot > 0`) or
/// waiting in line.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct HeavyJob {
    /// The wrapper's pid — also the registry filename and the id a cancel signals.
    pub pid: i32,
    /// The actual command's pid, once it is running. The wrapper forwards SIGTERM.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub child: Option<i32>,
    /// Higher runs sooner. Default 0; `HEAVY_PRIO=n heavy …` or a client sets others.
    pub prio: i64,
    /// Epoch seconds when the job joined the queue.
    pub since: i64,
    /// Epoch seconds when it got a slot and actually started; absent while waiting.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started: Option<i64>,
    /// Slot index it holds, or 0 while waiting.
    pub slot: i32,
    pub cmd: String,
    pub cwd: String,
}

impl HeavyJob {
    pub fn running(&self) -> bool {
        self.slot > 0
    }

    /// Last path component of the working directory — the project label a client
    /// draws beside the command.
    pub fn project(&self) -> &str {
        Path::new(&self.cwd)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
    }

    /// A job with nothing but a pid, for tests and for a slot holder with no entry.
    pub fn new(pid: i32) -> Self {
        Self {
            pid,
            child: None,
            prio: 0,
            since: 0,
            started: None,
            slot: 0,
            cmd: String::new(),
            cwd: String::new(),
        }
    }
}

/// The whole queue at a moment: its capacity and the two ordered lists.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HeavyQueueSnapshot {
    pub slots: i64,
    pub worker_cap: i64,
    pub running: Vec<HeavyJob>,
    pub waiting: Vec<HeavyJob>,
}

impl Default for HeavyQueueSnapshot {
    fn default() -> Self {
        Self {
            slots: DEFAULT_SLOTS,
            worker_cap: DEFAULT_WORKER_CAP,
            running: Vec::new(),
            waiting: Vec::new(),
        }
    }
}

impl HeavyQueueSnapshot {
    pub fn is_empty(&self) -> bool {
        self.running.is_empty() && self.waiting.is_empty()
    }

    pub fn total(&self) -> usize {
        self.running.len() + self.waiting.len()
    }

    /// Whether `pid` is a job this queue holds. What a cancel is checked against:
    /// a pid with no entry here is not this daemon's to signal.
    pub fn holds(&self, pid: i32) -> bool {
        self.running
            .iter()
            .chain(&self.waiting)
            .any(|j| j.pid == pid)
    }
}

/// A liveness probe, injectable so the tests need no processes.
pub type AliveProbe = Box<dyn Fn(i32) -> bool + Send + Sync>;
/// The command line behind a pid, for a slot held with no registry entry.
pub type CommandProbe = Box<dyn Fn(i32) -> Option<String> + Send + Sync>;

/// Reader/controller for the registry. Read-mostly: the only writes are one job's
/// priority (an atomic rewrite of its own entry), the capacity (an atomic rewrite of
/// the config that preserves every other key), and a cancel, which is a signal.
pub struct HeavyQueue {
    /// `/tmp/claude-heavy-$UID` — the lock root the wrapper uses.
    pub root: PathBuf,
    /// `~/.claude/heavy-queue.json` — slots + worker cap live here, beside rules
    /// this module never reads and never rewrites.
    pub config_path: PathBuf,
    is_alive: AliveProbe,
    command_for_pid: CommandProbe,
}

impl HeavyQueue {
    /// The queue this machine's `heavy` wrapper actually uses, unless the two
    /// overrides say otherwise.
    ///
    /// `JUANCODE_HEAVY_ROOT` moves the registry, and moves the config with it
    /// (`<root>/heavy-queue.json`) unless `JUANCODE_HEAVY_CONFIG` names one. One
    /// variable rather than two by default is deliberate: a test or a conformance
    /// run that redirected only the registry would still have `heavySetSlots`
    /// rewriting the developer's real `~/.claude/heavy-queue.json`, which is a live
    /// file other tooling on the machine reads.
    pub fn from_env() -> Self {
        let root_override = std::env::var("JUANCODE_HEAVY_ROOT")
            .ok()
            .filter(|s| !s.is_empty());
        let root = root_override
            .clone()
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(format!("/tmp/claude-heavy-{}", current_uid())));
        let config_path = match std::env::var("JUANCODE_HEAVY_CONFIG")
            .ok()
            .filter(|s| !s.is_empty())
        {
            Some(path) => PathBuf::from(path),
            None if root_override.is_some() => root.join("heavy-queue.json"),
            None => home_dir().join(".claude/heavy-queue.json"),
        };
        Self::new(root, config_path)
    }

    pub fn new(root: PathBuf, config_path: PathBuf) -> Self {
        Self {
            root,
            config_path,
            is_alive: Box::new(pid_is_alive),
            command_for_pid: Box::new(ps_command),
        }
    }

    /// The same queue with both probes replaced, so a test is a temp directory and
    /// nothing else — no processes spawned, none signalled.
    pub fn with_probes(mut self, is_alive: AliveProbe, command_for_pid: CommandProbe) -> Self {
        self.is_alive = is_alive;
        self.command_for_pid = command_for_pid;
        self
    }

    pub fn queue_dir(&self) -> PathBuf {
        self.root.join("queue")
    }

    // MARK: - Read

    /// The current queue: live entries only, split into running and waiting and each
    /// ordered the way the wrapper admits them.
    pub fn snapshot(&self) -> HeavyQueueSnapshot {
        let (slots, worker_cap) = self.capacity();
        let mut jobs = self.live_entries();
        jobs.extend(self.unregistered_slot_holders(&jobs));
        let (running, waiting) = order(jobs);
        HeavyQueueSnapshot {
            slots,
            worker_cap,
            running,
            waiting,
        }
    }

    /// `slots` and `workerCap` from the config, with the wrapper's own defaults.
    pub fn capacity(&self) -> (i64, i64) {
        let Some(obj) = read_json_object(&self.config_path) else {
            return (DEFAULT_SLOTS, DEFAULT_WORKER_CAP);
        };
        let read = |key: &str, fallback: i64| {
            obj.get(key)
                .and_then(Value::as_i64)
                .map(|n| n.max(1))
                .unwrap_or(fallback)
        };
        (
            read("slots", DEFAULT_SLOTS),
            read("workerCap", DEFAULT_WORKER_CAP),
        )
    }

    /// Registry entries whose wrapper process is still alive. Dead ones are left on
    /// disk for the wrapper to reap — this never deletes another job's files.
    pub fn live_entries(&self) -> Vec<HeavyJob> {
        let Ok(dir) = std::fs::read_dir(self.queue_dir()) else {
            return Vec::new();
        };
        let mut jobs: Vec<HeavyJob> = dir
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|e| e == "json"))
            .filter_map(|p| decode_entry(&std::fs::read(&p).ok()?))
            .filter(|job| (self.is_alive)(job.pid))
            .collect();
        // Directory order is whatever the filesystem hands back; sort so a snapshot
        // is a value two reads of an unchanged registry agree on.
        jobs.sort_by_key(|j| j.pid);
        jobs
    }

    /// Slots held by a wrapper with no registry entry — an older wrapper, or one
    /// whose entry was lost. Surfaced so a busy queue is never drawn as idle.
    pub fn unregistered_slot_holders(&self, known: &[HeavyJob]) -> Vec<HeavyJob> {
        let Ok(dir) = std::fs::read_dir(&self.root) else {
            return Vec::new();
        };
        let known_pids: BTreeSet<i32> = known.iter().map(|j| j.pid).collect();
        let mut result = Vec::new();
        for entry in dir.flatten() {
            let path = entry.path();
            let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            let Some(slot) = name
                .strip_prefix("slot-")
                .and_then(|n| n.parse::<i32>().ok())
            else {
                continue;
            };
            if slot <= 0 {
                continue;
            }
            let Some(pid) = std::fs::read_to_string(path.join("pid"))
                .ok()
                .and_then(|raw| raw.trim().parse::<i32>().ok())
            else {
                continue;
            };
            if known_pids.contains(&pid) || !(self.is_alive)(pid) {
                continue;
            }
            result.push(HeavyJob {
                slot,
                cmd: (self.command_for_pid)(pid).unwrap_or_else(|| "(unknown job)".into()),
                ..HeavyJob::new(pid)
            });
        }
        result
    }

    // MARK: - Write

    /// Set a job's priority. The wrapper re-reads its own entry every poll, so this
    /// takes effect within one poll (~3s) — no signal needed.
    pub fn set_priority(&self, pid: i32, prio: i64) -> bool {
        let file = self.queue_dir().join(format!("{pid}.json"));
        let Some(mut obj) = read_json_object(&file) else {
            return false;
        };
        obj.insert("prio".into(), Value::from(prio));
        let Ok(out) = serde_json::to_vec(&Value::Object(obj)) else {
            return false;
        };
        // Same-directory temp + rename: a reader never sees a half-written entry,
        // and neither does the wrapper polling its own priority out of it.
        write_atomic(
            &file,
            &self.queue_dir().join(format!(".{pid}.panel.tmp")),
            &out,
        )
    }

    /// Change how many heavy jobs may run at once. The wrapper re-reads this every
    /// poll, so raising it lets jobs already in line through. Rules and every other
    /// key in the config are preserved.
    pub fn set_slots(&self, slots: i64) -> bool {
        if slots < 1 {
            return false;
        }
        let mut obj = read_json_object(&self.config_path).unwrap_or_default();
        obj.insert("slots".into(), Value::from(slots));
        let Ok(out) = serde_json::to_vec_pretty(&Value::Object(obj)) else {
            return false;
        };
        if let Some(dir) = self.config_path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let tmp = self.config_path.with_extension("json.tmp");
        write_atomic(&self.config_path, &tmp, &out)
    }

    /// Cancel a job: SIGTERM to the wrapper, which forwards it to the running
    /// command and cleans up its slot and registry entry.
    pub fn cancel(&self, pid: i32) -> bool {
        if pid <= 0 {
            return false;
        }
        // SAFETY: `kill` with a positive pid and a real signal number touches no
        // memory this process owns; the worst case is EPERM/ESRCH.
        unsafe { libc::kill(pid, libc::SIGTERM) == 0 }
    }
}

/// Split and order jobs the way the wrapper admits them: running by slot, waiting by
/// priority (highest first), then by how long they have been queued. Pure.
pub fn order(jobs: Vec<HeavyJob>) -> (Vec<HeavyJob>, Vec<HeavyJob>) {
    let (mut running, mut waiting): (Vec<_>, Vec<_>) =
        jobs.into_iter().partition(HeavyJob::running);
    running.sort_by_key(|j| (j.slot, j.pid));
    waiting.sort_by_key(|j| (-j.prio, j.since, j.pid));
    (running, waiting)
}

/// The priority that puts `pid` at the head of the line: one better than the best
/// priority currently queued. Pure, and the number a client sends as
/// `heavySetPriority` — the arithmetic lives here so two clients cannot disagree
/// about what "run this next" means.
pub fn move_to_front_priority(snapshot: &HeavyQueueSnapshot) -> i64 {
    let best = snapshot.waiting.iter().map(|j| j.prio).max().unwrap_or(0);
    (best + 1).max(1)
}

/// The priority rewrites that move `pid` one place up or down the waiting line, as
/// `(pid, prio)` pairs to apply in order. Empty when it cannot move.
///
/// Equal priorities are ordered by age, so a plain swap would move nothing — step
/// past the neighbour instead.
pub fn nudge_priorities(snapshot: &HeavyQueueSnapshot, pid: i32, up: bool) -> Vec<(i32, i64)> {
    let list = &snapshot.waiting;
    let Some(i) = list.iter().position(|j| j.pid == pid) else {
        return Vec::new();
    };
    let Some(j) = (if up { i.checked_sub(1) } else { Some(i + 1) }) else {
        return Vec::new();
    };
    let Some(theirs) = list.get(j) else {
        return Vec::new();
    };
    let mine = &list[i];
    if mine.prio == theirs.prio {
        vec![(pid, mine.prio + if up { 1 } else { -1 })]
    } else {
        vec![(pid, theirs.prio), (theirs.pid, mine.prio)]
    }
}

/// Decode one registry entry. Tolerant by construction: the wrapper writes
/// `child: null` while waiting, and a file read mid-rewrite is simply not an entry.
pub fn decode_entry(data: &[u8]) -> Option<HeavyJob> {
    let obj = serde_json::from_slice::<Value>(data).ok()?;
    let obj = obj.as_object()?;
    let int = |key: &str| obj.get(key).and_then(Value::as_i64);
    let text = |key: &str| {
        obj.get(key)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string()
    };
    Some(HeavyJob {
        pid: int("pid")? as i32,
        child: int("child").map(|n| n as i32),
        prio: int("prio").unwrap_or(0),
        since: int("since").unwrap_or(0),
        started: int("started"),
        slot: int("slot").unwrap_or(0) as i32,
        cmd: text("cmd"),
        cwd: text("cwd"),
    })
}

/// Signal 0 to test for a live process; EPERM means alive but not ours.
pub fn pid_is_alive(pid: i32) -> bool {
    if pid <= 0 {
        return false;
    }
    // SAFETY: signal 0 delivers nothing and only performs the permission and
    // existence checks.
    if unsafe { libc::kill(pid, 0) } == 0 {
        return true;
    }
    std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// The command line of a pid via `ps`, for slot holders with no registry entry.
pub fn ps_command(pid: i32) -> Option<String> {
    let out = std::process::Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", "command="])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!text.is_empty()).then_some(text)
}

fn read_json_object(path: &Path) -> Option<Map<String, Value>> {
    let data = std::fs::read(path).ok()?;
    match serde_json::from_slice::<Value>(&data).ok()? {
        Value::Object(map) => Some(map),
        _ => None,
    }
}

/// Write `bytes` to `target` through `tmp` in the same directory, so a concurrent
/// reader sees the old file or the new one and never a half of either.
fn write_atomic(target: &Path, tmp: &Path, bytes: &[u8]) -> bool {
    if std::fs::write(tmp, bytes).is_err() {
        return false;
    }
    if std::fs::rename(tmp, target).is_err() {
        let _ = std::fs::remove_file(tmp);
        return false;
    }
    true
}

fn current_uid() -> u32 {
    // SAFETY: `getuid` takes no arguments and cannot fail.
    unsafe { libc::getuid() }
}

fn home_dir() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/"))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A temp registry root, plus the queue reading it. Nothing is spawned: the
    /// queue is a directory of JSON files, so a temp root is a complete fake.
    struct Fixture {
        root: PathBuf,
    }

    impl Fixture {
        fn new(name: &str) -> Self {
            let root = std::env::temp_dir().join(format!(
                "heavy-queue-tests-{}-{name}-{:?}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            std::fs::create_dir_all(root.join("queue")).unwrap();
            Self { root }
        }

        fn config(&self) -> PathBuf {
            self.root.join("heavy-queue.json")
        }

        /// Every pid is alive unless listed in `dead`.
        fn queue(&self, dead: &[i32], command: Option<&str>) -> HeavyQueue {
            let dead: Vec<i32> = dead.to_vec();
            let command = command.map(str::to_string);
            HeavyQueue::new(self.root.clone(), self.config()).with_probes(
                Box::new(move |pid| !dead.contains(&pid)),
                Box::new(move |_| command.clone()),
            )
        }

        fn write_entry(&self, pid: i32, prio: i64, since: i64, slot: i32, cmd: &str) {
            let entry = serde_json::json!({
                "pid": pid, "prio": prio, "since": since, "slot": slot,
                "cmd": cmd, "cwd": "/repo/pandora", "child": Value::Null,
            });
            std::fs::write(
                self.root.join(format!("queue/{pid}.json")),
                serde_json::to_vec(&entry).unwrap(),
            )
            .unwrap();
        }

        fn write_slot(&self, slot: i32, pid: i32) {
            let dir = self.root.join(format!("slot-{slot}"));
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(dir.join("pid"), format!("{pid}\n")).unwrap();
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    fn job(pid: i32, prio: i64, since: i64, slot: i32) -> HeavyJob {
        HeavyJob {
            prio,
            since,
            slot,
            ..HeavyJob::new(pid)
        }
    }

    #[test]
    fn waiting_orders_by_priority_then_age() {
        let (running, waiting) = order(vec![
            job(1, 0, 100, 0),
            job(2, 5, 300, 0),
            job(3, 0, 50, 0),
            job(4, 5, 200, 0),
        ]);
        assert!(running.is_empty());
        assert_eq!(
            waiting.iter().map(|j| j.pid).collect::<Vec<_>>(),
            [4, 2, 3, 1]
        );
    }

    #[test]
    fn running_splits_out_and_sorts_by_slot() {
        let (running, waiting) = order(vec![job(1, 9, 10, 0), job(2, 0, 20, 2), job(3, 0, 30, 1)]);
        assert_eq!(running.iter().map(|j| j.pid).collect::<Vec<_>>(), [3, 2]);
        assert_eq!(waiting.iter().map(|j| j.pid).collect::<Vec<_>>(), [1]);
    }

    #[test]
    fn snapshot_skips_dead_entries_and_reads_capacity() {
        let fx = Fixture::new("snapshot");
        fx.write_entry(11, 0, 0, 1, "pnpm test");
        fx.write_entry(22, 3, 200, 0, "pnpm test");
        fx.write_entry(33, 0, 100, 0, "pnpm test"); // dead: its wrapper is gone
        std::fs::write(fx.config(), r#"{"slots":2,"workerCap":6}"#).unwrap();

        let snap = fx.queue(&[33], Some("cmd")).snapshot();
        assert_eq!(snap.slots, 2);
        assert_eq!(snap.worker_cap, 6);
        assert_eq!(snap.running.iter().map(|j| j.pid).collect::<Vec<_>>(), [11]);
        assert_eq!(snap.waiting.iter().map(|j| j.pid).collect::<Vec<_>>(), [22]);
        assert_eq!(snap.total(), 2);
    }

    #[test]
    fn capacity_falls_back_to_the_wrappers_defaults() {
        let fx = Fixture::new("capacity");
        assert_eq!(fx.queue(&[], None).capacity(), (1, 4));
    }

    #[test]
    fn a_slot_holder_without_an_entry_is_still_reported() {
        let fx = Fixture::new("holder");
        fx.write_slot(1, 777);
        let snap = fx.queue(&[], Some("/bin/zsh heavy pnpm test")).snapshot();
        assert_eq!(
            snap.running.iter().map(|j| j.pid).collect::<Vec<_>>(),
            [777]
        );
        assert_eq!(snap.running[0].cmd, "/bin/zsh heavy pnpm test");
    }

    #[test]
    fn a_slot_holder_with_an_entry_is_not_duplicated() {
        let fx = Fixture::new("dup");
        fx.write_entry(777, 0, 0, 1, "pnpm test");
        fx.write_slot(1, 777);
        assert_eq!(fx.queue(&[], Some("cmd")).snapshot().running.len(), 1);
    }

    #[test]
    fn a_dead_slot_holder_is_ignored() {
        let fx = Fixture::new("deadholder");
        fx.write_slot(1, 777);
        assert!(fx.queue(&[777], Some("cmd")).snapshot().is_empty());
    }

    #[test]
    fn decode_ignores_garbage() {
        assert!(decode_entry(b"{").is_none());
        assert!(decode_entry(br#"{"prio":1}"#).is_none());
        assert!(decode_entry(b"[]").is_none());
    }

    #[test]
    fn set_priority_rewrites_only_the_priority() {
        let fx = Fixture::new("setprio");
        fx.write_entry(42, 0, 900, 0, "pnpm build");
        let q = fx.queue(&[], None);
        assert!(q.set_priority(42, 7));

        let job = q.snapshot().waiting.remove(0);
        assert_eq!(job.prio, 7);
        assert_eq!(job.since, 900);
        assert_eq!(job.cmd, "pnpm build");
    }

    #[test]
    fn set_priority_on_a_missing_entry_fails() {
        let fx = Fixture::new("missingprio");
        assert!(!fx.queue(&[], None).set_priority(999, 1));
    }

    #[test]
    fn set_slots_preserves_every_other_key() {
        let fx = Fixture::new("setslots");
        std::fs::write(
            fx.config(),
            r#"{"slots":1,"workerCap":3,"heapCapMB":3072,"rules":[{"name":"pandora-ci"}]}"#,
        )
        .unwrap();
        let q = fx.queue(&[], None);
        assert!(q.set_slots(4));

        let written = read_json_object(&fx.config()).unwrap();
        assert_eq!(written["slots"], Value::from(4));
        assert_eq!(written["workerCap"], Value::from(3));
        assert_eq!(written["heapCapMB"], Value::from(3072));
        assert_eq!(written["rules"][0]["name"], Value::from("pandora-ci"));
        assert_eq!(q.capacity(), (4, 3));
    }

    #[test]
    fn set_slots_refuses_a_capacity_below_one() {
        let fx = Fixture::new("zeroslots");
        let q = fx.queue(&[], None);
        assert!(!q.set_slots(0));
        assert!(!fx.config().exists(), "a refusal must not write the config");
    }

    #[test]
    fn move_to_front_beats_the_best_queued_priority() {
        let fx = Fixture::new("front");
        fx.write_entry(1, 4, 10, 0, "a");
        fx.write_entry(2, 0, 20, 0, "b");
        let q = fx.queue(&[], None);
        let prio = move_to_front_priority(&q.snapshot());
        assert_eq!(prio, 5);
        assert!(q.set_priority(2, prio));
        assert_eq!(
            q.snapshot()
                .waiting
                .iter()
                .map(|j| j.pid)
                .collect::<Vec<_>>(),
            [2, 1]
        );
    }

    #[test]
    fn nudge_up_past_an_equally_prioritised_neighbour() {
        let fx = Fixture::new("nudge-eq");
        fx.write_entry(1, 0, 10, 0, "a");
        fx.write_entry(2, 0, 20, 0, "b");
        let q = fx.queue(&[], None);
        for (pid, prio) in nudge_priorities(&q.snapshot(), 2, true) {
            q.set_priority(pid, prio);
        }
        assert_eq!(
            q.snapshot()
                .waiting
                .iter()
                .map(|j| j.pid)
                .collect::<Vec<_>>(),
            [2, 1]
        );
    }

    #[test]
    fn nudge_swaps_with_a_higher_prioritised_neighbour() {
        let fx = Fixture::new("nudge-swap");
        fx.write_entry(1, 5, 10, 0, "a");
        fx.write_entry(2, 1, 20, 0, "b");
        let q = fx.queue(&[], None);
        for (pid, prio) in nudge_priorities(&q.snapshot(), 2, true) {
            q.set_priority(pid, prio);
        }
        let after = q.snapshot().waiting;
        assert_eq!(after.iter().map(|j| j.pid).collect::<Vec<_>>(), [2, 1]);
        assert_eq!(after.iter().map(|j| j.prio).collect::<Vec<_>>(), [5, 1]);
    }

    #[test]
    fn nudge_at_the_edge_is_a_no_op() {
        let fx = Fixture::new("nudge-edge");
        fx.write_entry(1, 0, 10, 0, "a");
        fx.write_entry(2, 0, 20, 0, "b");
        let q = fx.queue(&[], None);
        let snap = q.snapshot();
        assert!(nudge_priorities(&snap, 1, true).is_empty());
        assert!(nudge_priorities(&snap, 2, false).is_empty());
        assert!(nudge_priorities(&snap, 999, true).is_empty());
    }

    #[test]
    fn holds_is_what_a_cancel_is_checked_against() {
        let fx = Fixture::new("holds");
        fx.write_entry(1, 0, 10, 1, "a");
        fx.write_entry(2, 0, 20, 0, "b");
        let snap = fx.queue(&[], None).snapshot();
        assert!(snap.holds(1));
        assert!(snap.holds(2));
        assert!(!snap.holds(3));
    }

    #[test]
    fn a_pid_that_cannot_exist_is_never_alive_and_never_signalled() {
        assert!(!pid_is_alive(0));
        assert!(!pid_is_alive(-1));
        let fx = Fixture::new("cancel");
        assert!(!fx.queue(&[], None).cancel(0));
    }

    #[test]
    fn the_root_override_moves_the_config_with_it() {
        // Both reads happen inside `from_env`, so this asserts the pairing rather
        // than the variable: a root override that left the config pointing at
        // $HOME would have `set_slots` rewriting the real one.
        let dir = std::env::temp_dir().join(format!("heavy-env-{}", std::process::id()));
        std::env::set_var("JUANCODE_HEAVY_ROOT", &dir);
        std::env::remove_var("JUANCODE_HEAVY_CONFIG");
        let q = HeavyQueue::from_env();
        assert_eq!(q.root, dir);
        assert_eq!(q.config_path, dir.join("heavy-queue.json"));
        std::env::remove_var("JUANCODE_HEAVY_ROOT");
    }
}
