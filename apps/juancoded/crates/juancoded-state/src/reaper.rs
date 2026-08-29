//! The idle-session reaper: what makes a session go dormant instead of holding a
//! ~300MB CLI process tree forever.
//!
//! Ported from `apps/native/Sources/JuancodeServices/SessionReaper.swift`, and from
//! the *fixed* version of it rather than the one the port ticket described. Four
//! properties are load-bearing, each of them the answer to something that went wrong
//! on a real machine; a port that kept the structure and dropped any one of them
//! would be a port of the bug.
//!
//! 1. **Liveness is output, never input.** A dispatched agent is typed at exactly
//!    once, when it is created, and then works for hours. Keying idleness on
//!    keystrokes reads "dormant" at its busiest. So the streak watches what the pty
//!    *says* ([`ReapSample::output_bytes`]) and what the detector *remembers*
//!    ([`ReapSample::last_busy_ms`]). Output is read as a rate with a floor, and
//!    deliberately not as "any byte at all": a settled TUI still repaints itself, and
//!    keying on that is precisely what defeated the older sweep this replaced.
//! 2. **Nothing dies off a stale verdict.** A sweep stats a transcript per session, so
//!    the first session's verdict is already seconds old by the time the loop reaches
//!    the last one. [`SessionReaper::kill_time_veto`] re-reads protection, activity,
//!    open tool calls, the queue and resumability immediately *before* each kill, in
//!    both the idle path and the cap path, and logs `reap_skipped` with the veto.
//!    Skipping that re-read is what killed a focused pane that was `isProtected`.
//! 3. **Three brakes against a bulk sweep.** Dormancy must be *observed* across
//!    [`Policy::min_quiet_samples`] separate sweeps; a sample gap past
//!    [`Policy::max_sample_gap_ms`] re-anchors rather than counting unwatched time as
//!    evidence; and at most [`ReaperConfig::max_sleeps_per_sweep`] sessions may be
//!    slept per tick. Elapsed time is a *shared* clock — one stall or one settings
//!    change reads identically for every session at once, which is how 25 of them get
//!    judged dormant in the same second. A count of observations cannot be shared.
//! 4. **Every kill says why, on what evidence, and the app quit is not a reap.**
//!    Sleeping writes one `session_sleep` line carrying the reason and the sampled
//!    signals. The daemon's own shutdown is labelled `quit` in `main.rs` and flips no
//!    dormant flag at all, because a month of blame landed on the reaper for
//!    interrupted agents that a process exit had killed.
//!
//! The busy/idle question itself is *not* re-invented here: it is
//! [`juancoded_core::activity::ActivityDetector`]'s, including the structured
//! transcript signal, and [`ReapSample::open_tool_call`] is that detector's uncapped
//! "a call is still out there" fact rather than a second notion of busy.
//!
//! The decision rule ([`Policy`], [`evaluate`], [`cap_surplus`]) is pure and
//! clock-injected; the OS probes are a seam so tests pin them.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicI64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use juancoded_core::model::{now_ms, SessionActivity};
use tracing::{debug, info, warn};

use crate::grid::ClientId;
use crate::service::SessionsApi;

/// Why a session was put to sleep. The distinction exists because every dormancy
/// used to write the same bare line, so a verified idle reap, a cap eviction and a
/// process exit killing 25 mid-turn agents were indistinguishable after the fact.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SleepReason {
    /// The idle reaper: every independent signal quiet across the whole window.
    IdleReap,
    /// The live-session ceiling: least-recently-active session evicted to bound RAM.
    LiveCap,
}

impl SleepReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::IdleReap => "idle_reap",
            Self::LiveCap => "live_cap",
        }
    }
}

/// Everything the reaper reads about one session, gathered under that session's own
/// locks in a single call so the sweep's decision and its kill-time re-check cannot
/// drift apart.
#[derive(Debug, Clone, PartialEq)]
pub struct ReapProbe {
    pub id: String,
    pub cwd: String,
    /// `Some` once the CLI's own conversation id is known. An unresumable session is
    /// exempt: killing one loses the conversation.
    pub cli_session_id: Option<String>,
    pub running: bool,
    /// The pty child's pid, `None` once the child is gone.
    pub child_pid: Option<u32>,
    pub activity: SessionActivity,
    /// The detector's *uncapped* unresolved-tool-call fact. A delegated subagent
    /// legitimately runs past the state machine's hold cap, and past that cap the
    /// state falls back to idle while the tool is still running — inside the reap
    /// window. So the open call is its own hard veto.
    pub open_tool_call: bool,
    pub last_input_ms: i64,
    pub last_output_ms: i64,
    pub output_bytes: u64,
    /// ms-since-epoch of the last moment the detector classified this session
    /// non-idle. `activity` is a snapshot at sweep time; a whole turn can start and
    /// finish inside one sweep gap and leave it reading idle.
    pub last_busy_ms: i64,
    pub updated_at: i64,
}

// MARK: - the pure eligibility policy

/// One session's observable state at a sweep tick.
#[derive(Debug, Clone, PartialEq)]
pub struct ReapSample {
    /// Anything but [`SessionActivity::Idle`] resets the streak — including
    /// `WaitingInput`: a pending permission menu is not in the transcript until it is
    /// answered, so killing there aborts the tool call and a resume will not re-render
    /// the prompt.
    pub activity: SessionActivity,
    pub resumable: bool,
    /// Whether the session has nothing queued. Queued messages mean deliveries are
    /// imminent; reaping would strand them.
    pub queue_empty: bool,
    /// Protects a half-typed, unsubmitted prompt no other signal can see.
    pub last_input_ms: i64,
    /// Live descendants of the pty child: Bash tools, spawned subagents, MCP servers.
    /// Compared against the count at idle-entry — any change means the tree is (or
    /// was) doing something.
    pub descendant_count: usize,
    /// Cumulative CPU of the whole tree, ms. Compared as a *rate* against the previous
    /// sweep, never as a total since idle-entry: an idle CLI is not a quiet process.
    pub cpu_time_ms: u64,
    /// The session's CLI transcript size, `None` when it cannot be located — treated
    /// as "no evidence of activity", with the tree and CPU signals still guarding.
    /// Size rather than mtime: the file is append-only, so growth is what means the
    /// agent produced something, while mtime also moves on flushes that add nothing.
    pub transcript_size_bytes: Option<u64>,
    /// The running total of bytes the pty has produced, and when the last one landed.
    /// The total is the signal — read as a rate, so a repainting TUI cannot hold a
    /// session alive forever; the timestamp is only ever evidence in a log line.
    pub output_bytes: u64,
    pub last_output_ms: i64,
    pub last_busy_ms: i64,
    pub open_tool_call: bool,
    /// Externally protected (the open pane, the active Oracle). Never reaped.
    pub protected: bool,
}

/// The idle streak's anchor, captured when a session is first seen idle and
/// re-captured whenever any signal is disturbed.
#[derive(Debug, Clone, PartialEq)]
pub struct Baseline {
    pub idle_since_ms: i64,
    pub descendant_count: usize,
    pub cpu_time_ms: u64,
    pub transcript_size_bytes: Option<u64>,
    /// When the *previous* sweep sampled, and what it saw. The CPU and output signals
    /// are rates between consecutive sweeps, so they need the last sample and not only
    /// the idle-entry anchor.
    pub last_sample_ms: i64,
    pub last_sample_cpu_ms: u64,
    pub last_sample_output_bytes: u64,
    /// How many consecutive sweeps have *observed* this session quiet, this one
    /// included. See the third brake in the module docs.
    pub quiet_samples: u32,
}

/// The sweep's decision for one session.
#[derive(Debug, Clone, PartialEq)]
pub enum Verdict {
    /// Not idle (busy / waiting / protected / queued / tool open) — drop the streak.
    NotIdle,
    /// Idle, but the window is not served yet, or an OS signal was disturbed. Carry
    /// this baseline to the next sweep.
    Holding(Baseline),
    /// Verifiably idle across the whole window: safe to reap.
    Eligible,
}

/// The thresholds the decision rule reads. Separated from [`ReaperConfig`] so the
/// pure half can be exercised without a registry.
#[derive(Debug, Clone, Copy)]
pub struct Policy {
    /// How fast the tree may burn CPU between two sweeps before the streak is
    /// disturbed, in permille of one core.
    ///
    /// An idle CLI is NOT a quiet process: it keeps repainting its TUI, measured at a
    /// median 5.8% of a core (p90 7.0%, max 10.9%) across 51 idle sessions over five
    /// minutes. The original rule — an absolute 5s of CPU since idle-entry — was
    /// therefore unmeetable: 40 of those 51 blew past 5s inside a *single* sweep, the
    /// baseline re-anchored every time, and nothing was ever reaped. 400‰ leaves ~4x
    /// headroom over idle repainting and still catches real local compute.
    pub cpu_busy_permille: i64,
    /// Floor under the rate check: a delta this small is never work, whatever the
    /// interval. Guards a sweep pair that lands milliseconds apart.
    pub cpu_floor_ms: u64,
    /// How fast the pty may produce output between two sweeps before the streak is
    /// disturbed, with [`Self::output_floor_bytes`] as the floor under it.
    ///
    /// Chosen bounds, not measurements, and deliberately loose: a false "busy" only
    /// delays freeing RAM, a false "idle" kills work. 64KB inside one 90s sweep is
    /// ~700 B/s sustained — orders of magnitude more than a status line redrawing
    /// itself and far less than a build log or a tool dumping a file. Token streaming
    /// is slower than this and is deliberately not what it catches: the detector
    /// already calls that busy, and `last_busy_ms` carries it.
    pub output_busy_bytes_per_sec: u64,
    pub output_floor_bytes: u64,
    /// How many separate sweeps must observe a session quiet, on top of the window.
    pub min_quiet_samples: u32,
    /// The longest gap between two samples that still counts as an unbroken streak.
    /// Past it nobody was watching — a stalled loop, a suspended machine, a clock
    /// jump — and unobserved time is not evidence of dormancy.
    pub max_sample_gap_ms: i64,
}

impl Default for Policy {
    fn default() -> Self {
        Self {
            cpu_busy_permille: 400,
            cpu_floor_ms: 2_000,
            output_busy_bytes_per_sec: 1_024,
            output_floor_bytes: 64 * 1024,
            min_quiet_samples: 3,
            max_sample_gap_ms: 10 * 60 * 1_000,
        }
    }
}

/// How long to wait between sweeps, given the window and the configured ceiling.
///
/// Bounded by the window as well as by the ceiling, because the streak needs
/// [`Policy::min_quiet_samples`] separate observations *inside* the window: at the 90s
/// production cadence a one-minute window could never be served, and a one-minute
/// window is this feature's acceptance criterion. A quarter of the window gives four
/// observations where three are required. The 200ms floor is there so a tiny window —
/// a test's, or a fat-fingered setting — cannot turn the loop into a spin.
pub fn sweep_interval_ms(window_ms: i64, ceiling_ms: u64) -> u64 {
    if window_ms > 0 {
        ceiling_ms.min(((window_ms as u64) / 4).max(200))
    } else {
        ceiling_ms
    }
}

/// A fresh streak anchor from this sample. One observation of evidence, so
/// `quiet_samples` starts at 1.
pub fn anchor(sample: &ReapSample, now_ms: i64) -> Baseline {
    Baseline {
        idle_since_ms: now_ms,
        descendant_count: sample.descendant_count,
        cpu_time_ms: sample.cpu_time_ms,
        transcript_size_bytes: sample.transcript_size_bytes,
        last_sample_ms: now_ms,
        last_sample_cpu_ms: sample.cpu_time_ms,
        last_sample_output_bytes: sample.output_bytes,
        quiet_samples: 1,
    }
}

/// The same streak, one observation older: the anchor is kept, the sample point moves
/// to this sweep, and the evidence count grows by one.
pub fn advance(base: &Baseline, sample: &ReapSample, now_ms: i64) -> Baseline {
    Baseline {
        last_sample_ms: now_ms,
        last_sample_cpu_ms: sample.cpu_time_ms,
        last_sample_output_bytes: sample.output_bytes,
        quiet_samples: base.quiet_samples.saturating_add(1),
        ..base.clone()
    }
}

/// Evaluate one session against its tracked streak. `baseline` is what the previous
/// sweep returned in [`Verdict::Holding`], `None` when untracked.
pub fn evaluate(
    sample: &ReapSample,
    baseline: Option<&Baseline>,
    now_ms: i64,
    window_ms: i64,
    policy: &Policy,
) -> Verdict {
    if window_ms <= 0 {
        return Verdict::NotIdle; // reaping disabled
    }
    // Hard resets: the detector says work (or a prompt) is pending, a tool call is
    // still open, a queued message is about to be delivered, or the session is
    // protected.
    if sample.activity != SessionActivity::Idle
        || sample.open_tool_call
        || !sample.queue_empty
        || sample.protected
    {
        return Verdict::NotIdle;
    }

    let fresh = anchor(sample, now_ms);
    let Some(base) = baseline else {
        return Verdict::Holding(fresh); // idle-entry
    };

    // OS ground truth the detector cannot fake. Any disturbance restarts the streak
    // from now, with the current tree shape / CPU as the new baseline.
    let tree_changed = sample.descendant_count != base.descendant_count;
    let interval_ms = (now_ms - base.last_sample_ms).max(1);
    let cpu_delta = sample.cpu_time_ms.saturating_sub(base.last_sample_cpu_ms);
    let cpu_moved = cpu_delta >= policy.cpu_floor_ms
        && (cpu_delta as i128) * 1_000 > (interval_ms as i128) * (policy.cpu_busy_permille as i128);
    // Append-only transcript: growth means the agent produced records. A bare mtime
    // bump does not — the file is also touched on flushes that append none.
    let transcript_grew = match (sample.transcript_size_bytes, base.transcript_size_bytes) {
        (Some(now), Some(then)) => now > then,
        _ => false,
    };
    // Output as a rate, for the same reason as CPU and with the same floor: what the
    // pty says is liveness for a session nobody types at, but a repainting TUI must
    // not be able to hold a session alive forever.
    let output_delta = sample.output_bytes.saturating_sub(base.last_sample_output_bytes);
    let output_moved = output_delta >= policy.output_floor_bytes
        && (output_delta as i128) * 1_000
            > (interval_ms as i128) * (policy.output_busy_bytes_per_sec as i128);
    let typed_since_idle = sample.last_input_ms > base.idle_since_ms;
    // The detector's memory of the streak: a turn that ran and finished between two
    // sweeps leaves `activity` idle but moves this.
    let worked_since_idle = sample.last_busy_ms > base.idle_since_ms;
    // Nobody was watching for `interval_ms`, so nothing was verified in it.
    let unobserved_gap = interval_ms > policy.max_sample_gap_ms;
    if tree_changed
        || cpu_moved
        || transcript_grew
        || output_moved
        || typed_since_idle
        || worked_since_idle
        || unobserved_gap
    {
        return Verdict::Holding(fresh);
    }

    // Streak intact: reap only once the whole window has been served, the last
    // keystroke is older than the window, enough separate sweeps have seen it, and a
    // resume is possible. The sample point advances even while holding, so the next
    // sweep's rate is measured against this sweep rather than against idle-entry.
    let held = advance(base, sample, now_ms);
    if now_ms - base.idle_since_ms >= window_ms
        && now_ms - sample.last_input_ms >= window_ms
        && held.quiet_samples >= policy.min_quiet_samples
        && sample.resumable
    {
        Verdict::Eligible
    } else {
        Verdict::Holding(held)
    }
}

/// One live session's state for the live-session cap decision.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CapCandidate {
    pub id: String,
    /// Recency for the LRU order: the later of last output and last input.
    pub last_active_ms: i64,
    /// Safe to sleep right now — idle, resumable, nothing queued, unprotected.
    pub sleepable: bool,
}

/// Ids to sleep so at most `max_live` sessions stay live, least-recently-active
/// first. `max_live == 0` disables the cap.
///
/// The idle window alone does not bound memory: a machine accumulates sessions that
/// are each *recently* active and so never serve a full window, while every one holds
/// a full CLI process tree. Measured: 47 concurrent `claude` sessions at a median
/// 290MB phys_footprint each — 12.4GB, with the machine 20GB into swap.
///
/// Never returns more than the number of sleepable candidates: an over-cap machine
/// full of busy sessions stays over cap rather than killing work. Busy sessions still
/// count toward the total, because they are holding the RAM.
pub fn cap_surplus(candidates: &[CapCandidate], max_live: usize) -> Vec<String> {
    if max_live == 0 || candidates.len() <= max_live {
        return Vec::new();
    }
    let over_by = candidates.len() - max_live;
    let mut sleepable: Vec<&CapCandidate> = candidates.iter().filter(|c| c.sleepable).collect();
    sleepable.sort_by(|a, b| {
        (a.last_active_ms, &a.id)
            .partial_cmp(&(b.last_active_ms, &b.id))
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    sleepable
        .into_iter()
        .take(over_by)
        .map(|c| c.id.clone())
        .collect()
}

// MARK: - the OS seam

/// The reaper's injected probes: the clock, the process tree, and the transcript
/// sizes. [`ReaperProbes::live`] wires the real OS.
#[derive(Clone)]
pub struct ReaperProbes {
    pub now_ms: Arc<dyn Fn() -> i64 + Send + Sync>,
    /// `(child pid) -> live descendant count`.
    pub descendant_count: Arc<dyn Fn(u32) -> usize + Send + Sync>,
    /// `(child pid) -> cumulative CPU ms of the whole tree`.
    pub tree_cpu_time_ms: Arc<dyn Fn(u32) -> u64 + Send + Sync>,
    /// Every session whose transcript can be located, and its size in bytes.
    ///
    /// Whole-map rather than per-session on purpose: the transcripts hub already
    /// holds every binding it has resolved, so one call per sweep replaces one path
    /// resolution per session — which is what the Swift reaper's per-cli-id path cache
    /// was for.
    pub transcript_sizes: Arc<dyn Fn() -> HashMap<String, u64> + Send + Sync>,
}

impl Default for ReaperProbes {
    fn default() -> Self {
        Self::live(None)
    }
}

impl ReaperProbes {
    /// Production probes: libproc / `/proc` process walking, and the real transcript
    /// files behind whatever the transcripts hub has bound.
    pub fn live(
        transcripts: Option<Arc<dyn juancoded_cordis::services::transcripts::TranscriptsApi>>,
    ) -> Self {
        Self {
            now_ms: Arc::new(now_ms),
            descendant_count: Arc::new(juancoded_core::proc::descendant_count),
            tree_cpu_time_ms: Arc::new(juancoded_core::proc::tree_cpu_time_ms),
            transcript_sizes: Arc::new(move || match &transcripts {
                Some(hub) => transcript_sizes(hub.as_ref()),
                None => HashMap::new(),
            }),
        }
    }
}

/// Size on disk of every bound transcript, by session id.
///
/// Only `ClaudeJsonl` contributes. An opencode transcript lives in a database shared
/// by every opencode conversation on the machine, so its growth is not attributable to
/// this session; counting it would let one busy conversation pin every other opencode
/// session alive forever, which would take the reaper out for a whole provider. Those
/// sessions are then judged on the five signals that *are* theirs — the detector, the
/// open tool call, the tree, the CPU rate and the output rate.
fn transcript_sizes(
    hub: &dyn juancoded_cordis::services::transcripts::TranscriptsApi,
) -> HashMap<String, u64> {
    use juancoded_transcripts::Binding;
    hub.bindings()
        .into_iter()
        .filter_map(|(session, binding)| match binding {
            Binding::ClaudeJsonl { path } => {
                let size = std::fs::metadata(&path).ok()?.len();
                Some((session, size))
            }
            Binding::OpencodeSqlite { .. } => None,
        })
        .collect()
}

// MARK: - the reaper

/// Knobs the daemon sets at boot; the two the app can move at runtime live in
/// [`SessionReaper`] itself, behind atomics, because a wire frame changes them from a
/// connection task while the sweep is running on another.
#[derive(Debug, Clone, Copy)]
pub struct ReaperConfig {
    /// How long a session must be verifiably idle before its CLI tree is killed.
    /// `0` disables idle reaping (the cap still applies).
    pub window_ms: i64,
    /// Ceiling on simultaneously live sessions. `0` disables the cap.
    pub max_live: usize,
    /// Longest gap between sweeps. The actual cadence is also bounded by the window
    /// (see [`SessionReaper::sweep_interval`]), because a 90s sweep can never gather
    /// three observations inside a one-minute window.
    pub sweep_ceiling_ms: u64,
    /// Hard ceiling on how many sessions one sweep may sleep, idle reaps and cap
    /// evictions together. A sweep that wants more takes the most-dormant ones and
    /// leaves the rest holding their streaks, so reclaiming a backlog is a visible
    /// trickle instead of a batch — and no single mistaken threshold can take the
    /// machine's whole session set with it.
    pub max_sleeps_per_sweep: usize,
    pub policy: Policy,
}

impl Default for ReaperConfig {
    fn default() -> Self {
        Self {
            window_ms: 30 * 60 * 1_000,
            max_live: 12,
            sweep_ceiling_ms: 90_000,
            max_sleeps_per_sweep: 3,
            policy: Policy::default(),
        }
    }
}

impl ReaperConfig {
    /// The daemon's boot defaults, from the environment.
    ///
    /// These are boot *defaults*, exactly as `Config.reapIdleMinutes` is on the Swift
    /// side: the app re-applies the user's Settings value (or its own env override)
    /// over the wire right after it connects. Which is why the environment is read
    /// here and not consulted again when a `setReaperPolicy` frame arrives — the
    /// env-beats-setting precedence belongs to the process that owns the setting, and
    /// a daemon that vetoed the frame would leave the Settings stepper doing nothing
    /// with no way to tell.
    pub fn from_env() -> Self {
        fn num(key: &str) -> Option<i64> {
            std::env::var(key).ok()?.trim().parse().ok()
        }
        let d = Self::default();
        Self {
            window_ms: num("JUANCODE_REAP_IDLE_MINUTES")
                .map(|m| m.max(0) * 60_000)
                .unwrap_or(d.window_ms),
            max_live: num("JUANCODE_MAX_LIVE_SESSIONS")
                .map(|n| n.max(0) as usize)
                .unwrap_or(d.max_live),
            // Floored rather than trusted: a zero here would be a spin loop, and the
            // one place this is set from is a test harness.
            sweep_ceiling_ms: num("JUANCODE_REAP_SWEEP_MS")
                .map(|ms| ms.clamp(50, 3_600_000) as u64)
                .unwrap_or(d.sweep_ceiling_ms),
            ..d
        }
    }
}

/// Owns the sweep loop and the per-session idle streaks. One per daemon.
pub struct SessionReaper {
    sessions: Arc<dyn SessionsApi>,
    /// The steering queue a delivery would come out of. `None` when the tree mounted
    /// no `queue` row, in which case only the registry's own store-backed queue is
    /// consulted.
    queue: Option<Arc<dyn juancoded_cordis::services::queue::QueueApi>>,
    probes: ReaperProbes,
    config: ReaperConfig,
    window_ms: AtomicI64,
    max_live: AtomicUsize,
    /// Tracked idle streaks by session id; entries drop whenever a session stops being
    /// idle, or stops existing.
    baselines: Mutex<HashMap<String, Baseline>>,
    /// Sessions a client declares off-limits: the pane it has open and the active
    /// Oracle. Keyed by the connection that said so, so a client that goes away stops
    /// protecting sessions nobody is looking at any more — a daemon outlives its
    /// clients, unlike the in-process Swift core this is ported from, and a leaked
    /// protection there would be a session that can never be reaped again.
    protected: Mutex<HashMap<ClientId, HashSet<String>>>,
    /// Raised whenever the window or the ceiling moves, so the loop stops waiting out
    /// a cadence it computed under the old policy. Without it, turning auto-sleep on
    /// from Settings would do nothing for up to a full sweep — and at the boot default
    /// of a disabled window that sweep is the 90s ceiling, which is long enough to
    /// read as "the stepper does nothing" all over again.
    policy_changed: tokio::sync::Notify,
}

impl SessionReaper {
    pub fn new(
        sessions: Arc<dyn SessionsApi>,
        queue: Option<Arc<dyn juancoded_cordis::services::queue::QueueApi>>,
        probes: ReaperProbes,
        config: ReaperConfig,
    ) -> Self {
        Self {
            sessions,
            queue,
            probes,
            config,
            window_ms: AtomicI64::new(config.window_ms),
            max_live: AtomicUsize::new(config.max_live),
            baselines: Mutex::new(HashMap::new()),
            protected: Mutex::new(HashMap::new()),
            policy_changed: tokio::sync::Notify::new(),
        }
    }

    pub fn window_ms(&self) -> i64 {
        self.window_ms.load(Ordering::Relaxed)
    }

    pub fn max_live(&self) -> usize {
        self.max_live.load(Ordering::Relaxed)
    }

    /// Change the idle window at runtime (the Settings → Sessions stepper).
    ///
    /// `<= 0` disables idle reaping: sweeps stop tracking and any streak is dropped,
    /// so a later re-enable starts fresh instead of reaping off a stale baseline.
    pub fn set_window_ms(&self, window_ms: i64) {
        self.window_ms.store(window_ms.max(0), Ordering::Relaxed);
        if window_ms <= 0 {
            self.lock_baselines().clear();
        }
        self.policy_changed.notify_one();
    }

    /// Change the live-session ceiling at runtime. `0` disables the cap.
    pub fn set_max_live(&self, max_live: usize) {
        self.max_live.store(max_live, Ordering::Relaxed);
        self.policy_changed.notify_one();
    }

    /// Replace one client's set of sessions that must never be slept — neither by the
    /// idle window nor by the cap. Sleeping the pane somebody is looking at is visible
    /// work vanishing under them, which no amount of freed RAM pays for.
    ///
    /// Also drops any tracked streak for a newly protected session, so unprotecting it
    /// later starts a fresh window rather than reaping off a stale baseline.
    pub fn set_protected(&self, client: ClientId, ids: HashSet<String>) {
        {
            let mut baselines = self.lock_baselines();
            for id in &ids {
                baselines.remove(id);
            }
        }
        let mut protected = self.lock_protected();
        if ids.is_empty() {
            protected.remove(&client);
        } else {
            protected.insert(client, ids);
        }
    }

    /// A client's connection closed: its protections go with it.
    pub fn release_client(&self, client: ClientId) {
        self.lock_protected().remove(&client);
    }

    /// Whether any client has declared this session off-limits right now.
    pub fn is_protected(&self, id: &str) -> bool {
        self.lock_protected().values().any(|set| set.contains(id))
    }

    /// How long to wait before the next sweep.
    ///
    /// Bounded by the window as well as by the configured ceiling, because the streak
    /// needs [`Policy::min_quiet_samples`] separate observations *inside* the window:
    /// at the 90s production cadence a one-minute window could never be served, and
    /// the acceptance criterion for this feature is a one-minute window. A quarter of
    /// the window gives four observations where three are required.
    pub fn sweep_interval(&self) -> Duration {
        Duration::from_millis(sweep_interval_ms(
            self.window_ms(),
            self.config.sweep_ceiling_ms,
        ))
    }

    /// Run the sweep loop until the returned handle is dropped or the task aborted.
    pub fn spawn(self: &Arc<Self>) -> tokio::task::JoinHandle<()> {
        let reaper = Arc::clone(self);
        tokio::spawn(async move {
            loop {
                // A policy change re-plans the wait rather than sweeping at once: the
                // first sweep after "reaping on" should ANCHOR a streak, not judge one.
                tokio::select! {
                    _ = tokio::time::sleep(reaper.sweep_interval()) => reaper.sweep_once(),
                    _ = reaper.policy_changed.notified() => continue,
                };
            }
        })
    }

    /// One sweep over every live session: sample, evaluate, and put the eligible ones
    /// to sleep. Returns the slept session ids.
    pub fn sweep_once(&self) -> Vec<String> {
        let now = (self.probes.now_ms)();
        let window = self.window_ms();
        let budget = self.config.max_sleeps_per_sweep.max(1);

        if window <= 0 {
            self.lock_baselines().clear();
            // The cap is a separate guarantee from the idle window: turning auto-sleep
            // off must not let the machine accumulate without bound.
            let capped = self.sleep_surplus(now, budget, &HashSet::new());
            self.log_sweep(self.live_count(), 0, 0, capped.len(), 0);
            return capped;
        }

        // Every stat this sweep needs, up front and in one call, so the per-session
        // loop below does no I/O of its own.
        let sizes = (self.probes.transcript_sizes)();
        let mut next: HashMap<String, Baseline> = HashMap::new();
        let mut eligible: Vec<(ReapProbe, ReapSample, Option<Baseline>)> = Vec::new();
        let mut live = 0usize;
        let prior_all = self.lock_baselines().clone();
        for id in self.sessions.ids() {
            let Some(probe) = self.sessions.reap_probe(&id) else {
                continue;
            };
            if !probe.running {
                continue;
            }
            live += 1;
            // No live child pid (already exiting) — nothing to reap.
            let Some(pid) = probe.child_pid else { continue };
            let sample = self.sample(&probe, pid, sizes.get(&id).copied());
            let prior = prior_all.get(&id).cloned();
            match evaluate(&sample, prior.as_ref(), now, window, &self.config.policy) {
                Verdict::NotIdle => {} // streak dropped
                Verdict::Holding(baseline) => {
                    next.insert(id.clone(), baseline);
                }
                Verdict::Eligible => eligible.push((probe, sample, prior)),
            }
        }

        // Most-dormant first, so a capped sweep reclaims the stalest RAM and the order
        // is deterministic (id breaks ties) rather than map-iteration-dependent.
        eligible.sort_by(|a, b| {
            let ka = (a.2.as_ref().map(|b| b.idle_since_ms).unwrap_or(now), &a.0.id);
            let kb = (b.2.as_ref().map(|b| b.idle_since_ms).unwrap_or(now), &b.0.id);
            ka.cmp(&kb)
        });

        let mut reaped: Vec<String> = Vec::new();
        let mut deferred = 0usize;
        for (probe, sample, prior) in eligible.iter() {
            let id = probe.id.clone();
            if reaped.len() >= budget {
                // Over budget for this tick: keep the streak (it stays eligible) so the
                // next sweep takes it, and say so in the log.
                deferred += 1;
                next.insert(
                    id,
                    match prior {
                        Some(b) => advance(b, sample, now),
                        None => anchor(sample, now),
                    },
                );
                continue;
            }
            // Re-read the volatile signals at the instant of the kill. Between the
            // verdict above and here the session may have started a turn, opened a tool
            // call, or become the pane the user is looking at — and a stale "eligible"
            // is precisely how a focused, working session gets reaped.
            if let Some(veto) = self.kill_time_veto(&id) {
                info!(
                    event = "reap_skipped",
                    session = %id,
                    project = %probe.cwd,
                    veto,
                    waited_ms = ((self.probes.now_ms)() - now).max(0),
                    "a verdict went stale before the kill"
                );
                next.insert(id, anchor(sample, now));
                continue;
            }
            self.sleep(&id, SleepReason::IdleReap, || {
                self.audit(sample, prior.as_ref(), now)
            });
            reaped.push(id);
        }

        *self.lock_baselines() = next;
        let already: HashSet<String> = reaped.iter().cloned().collect();
        let capped = self.sleep_surplus(now, budget.saturating_sub(reaped.len()), &already);
        self.log_sweep(live, eligible.len(), reaped.len(), capped.len(), deferred);
        reaped.into_iter().chain(capped).collect()
    }

    /// Everything the policy reads about one session, assembled in one place so the
    /// sweep's decision and its kill-time re-check cannot drift apart.
    fn sample(&self, probe: &ReapProbe, pid: u32, transcript_size_bytes: Option<u64>) -> ReapSample {
        ReapSample {
            activity: probe.activity,
            resumable: probe.cli_session_id.is_some(),
            queue_empty: !self.has_queued(&probe.id),
            last_input_ms: probe.last_input_ms,
            descendant_count: (self.probes.descendant_count)(pid),
            cpu_time_ms: (self.probes.tree_cpu_time_ms)(pid),
            transcript_size_bytes,
            output_bytes: probe.output_bytes,
            last_output_ms: probe.last_output_ms,
            last_busy_ms: probe.last_busy_ms,
            open_tool_call: probe.open_tool_call,
            protected: self.is_protected(&probe.id),
        }
    }

    /// Whether a delivery is pending or in flight for this session.
    ///
    /// Both queues are consulted — the mounted `queue` service the delivery pump
    /// drains, and the registry's own store-backed rows — because a false "queued"
    /// only delays freeing RAM while a false "empty" strands a message the user typed.
    fn has_queued(&self, id: &str) -> bool {
        if let Some(queue) = &self.queue {
            if !queue.snapshot(id).is_empty() || queue.claimed(id).is_some() {
                return true;
            }
        }
        !self.sessions.queue(id).is_empty()
    }

    /// Why this session must not be killed right now, or `None` when it may be. The
    /// cheap half of the policy, re-evaluated immediately before every kill in both
    /// the idle path and the cap path; the returned string is the log's `veto` field.
    fn kill_time_veto(&self, id: &str) -> Option<&'static str> {
        let probe = self.sessions.reap_probe(id)?;
        if !probe.running {
            return Some("exited");
        }
        if self.is_protected(id) {
            return Some("protected");
        }
        if probe.activity != SessionActivity::Idle {
            return Some(probe.activity.as_str());
        }
        if probe.open_tool_call {
            return Some("tool_open");
        }
        if self.has_queued(id) {
            return Some("queued");
        }
        if probe.cli_session_id.is_none() {
            return Some("unresumable");
        }
        None
    }

    /// Flag dormant, then kill — in that order, so the exited row the pty's death
    /// finalises already carries `dormant = true` and a client can tell "slept, wake me
    /// on demand" from a crash.
    fn sleep(&self, id: &str, reason: SleepReason, audit: impl FnOnce() -> String) {
        info!(
            event = "session_sleep",
            session = %id,
            reason = reason.as_str(),
            evidence = %audit(),
            "sleeping a session"
        );
        if !self.sessions.mark_dormant(id) {
            debug!(session = %id, "the dormant flag was already set");
        }
        if let Err(e) = self.sessions.kill(id) {
            warn!(session = %id, error = %e, "could not kill a session being slept");
        }
    }

    /// The evidence behind one kill, as one flat field list: how long the streak ran,
    /// how many sweeps observed it, and where each signal stood. Reading one of these
    /// lines should answer "why did this die" without a forensic session.
    fn audit(&self, sample: &ReapSample, baseline: Option<&Baseline>, now: i64) -> String {
        let idle_since = baseline.map(|b| b.idle_since_ms).unwrap_or(now);
        // `never` rather than an age measured from the epoch: a dispatched agent is
        // typed at once at creation and a great many are never typed at at all, so
        // "0 means it never happened" has to be spelled out or the field reads as a
        // 56-year-old keystroke.
        let age = |at: i64| {
            if at > 0 {
                (now - at).to_string()
            } else {
                "never".to_string()
            }
        };
        let mut out = format!(
            "activity={} idleMs={} windowMs={} samples={} inputAge={} busyAge={} \
             outputAge={} descendants={} cpuMs={} outputBytes={} toolOpen={} protected={}",
            sample.activity.as_str(),
            now - idle_since,
            self.window_ms(),
            baseline.map(|b| b.quiet_samples).unwrap_or(0),
            age(sample.last_input_ms),
            age(sample.last_busy_ms),
            age(sample.last_output_ms),
            sample.descendant_count,
            sample.cpu_time_ms,
            sample.output_bytes,
            sample.open_tool_call,
            sample.protected,
        );
        if let Some(base) = baseline {
            let interval = (now - base.last_sample_ms).max(1);
            let permille =
                (sample.cpu_time_ms.saturating_sub(base.last_sample_cpu_ms) as i64) * 1_000
                    / interval;
            let delta = sample.output_bytes.saturating_sub(base.last_sample_output_bytes);
            out.push_str(&format!(
                " cpuPermille={permille} outputDeltaBytes={delta}"
            ));
        }
        if let Some(size) = sample.transcript_size_bytes {
            out.push_str(&format!(" transcriptBytes={size}"));
        }
        out
    }

    /// One line per sweep, whether or not anything died: the denominator that makes
    /// the sleep lines readable.
    fn log_sweep(&self, live: usize, eligible: usize, reaped: usize, capped: usize, deferred: usize) {
        if live == 0 {
            return;
        }
        debug!(
            event = "reap_sweep",
            live,
            eligible,
            reaped,
            cap_slept = capped,
            deferred,
            window_ms = self.window_ms(),
            max_live = self.max_live(),
            budget = self.config.max_sleeps_per_sweep,
            "reaper sweep"
        );
    }

    fn live_count(&self) -> usize {
        self.sessions
            .ids()
            .into_iter()
            .filter(|id| self.sessions.is_running(id))
            .count()
    }

    /// Enforce the live-session ceiling: sleep the least-recently-active sessions that
    /// are safe to sleep until at most `max_live` remain, at most `budget` of them this
    /// sweep. Independent of the idle streak — a session that keeps getting touched
    /// never serves a full window, but still holds a whole CLI process tree.
    fn sleep_surplus(&self, now: i64, budget: usize, already: &HashSet<String>) -> Vec<String> {
        let max_live = self.max_live();
        if max_live == 0 || budget == 0 {
            return Vec::new();
        }
        let live: Vec<ReapProbe> = self
            .sessions
            .ids()
            .into_iter()
            .filter(|id| !already.contains(id))
            .filter_map(|id| self.sessions.reap_probe(&id))
            .filter(|p| p.running)
            .collect();
        let candidates: Vec<CapCandidate> = live
            .iter()
            .map(|p| CapCandidate {
                id: p.id.clone(),
                last_active_ms: p.updated_at.max(p.last_input_ms).max(p.last_output_ms),
                sleepable: self.kill_time_veto(&p.id).is_none(),
            })
            .collect();
        let surplus = cap_surplus(&candidates, max_live);
        if surplus.is_empty() {
            return Vec::new();
        }
        let by_id: HashMap<&str, &ReapProbe> = live.iter().map(|p| (p.id.as_str(), p)).collect();
        let live_count = live.len();
        let mut slept = Vec::new();
        for id in surplus {
            if slept.len() >= budget {
                break;
            }
            let Some(probe) = by_id.get(id.as_str()) else {
                continue;
            };
            // The same instant-of-the-kill re-check as the idle path: the LRU order was
            // computed before this loop started.
            if let Some(veto) = self.kill_time_veto(&id) {
                info!(
                    event = "cap_skipped",
                    session = %id, project = %probe.cwd, veto,
                    "a cap eviction went stale before the kill"
                );
                continue;
            }
            let last_active = probe.updated_at.max(probe.last_input_ms).max(probe.last_output_ms);
            self.sleep(&id, SleepReason::LiveCap, || {
                format!(
                    "activity={} maxLive={max_live} liveCount={live_count} lastActiveMs={}",
                    probe.activity.as_str(),
                    now - last_active
                )
            });
            // Its streak is meaningless now the pty is gone.
            self.lock_baselines().remove(&id);
            slept.push(id);
        }
        slept
    }

    fn lock_baselines(&self) -> std::sync::MutexGuard<'_, HashMap<String, Baseline>> {
        self.baselines.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn lock_protected(&self) -> std::sync::MutexGuard<'_, HashMap<ClientId, HashSet<String>>> {
        self.protected.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[cfg(test)]
mod tests;
