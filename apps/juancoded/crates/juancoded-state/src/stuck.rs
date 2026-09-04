//! The stuck-session detector: it says a session is going nowhere, and stops there.
//!
//! Two different failures wear the same face from the dock — a pane that has not
//! changed in ten minutes — and neither of them is visible to anything else the daemon
//! runs. The reaper's whole job is the *opposite* case: it looks for sessions that are
//! verifiably idle so it can free their RAM, and a session that claims to be working
//! is the first thing [`crate::reaper::evaluate`] refuses to touch. So the sessions in
//! this module are precisely the ones nothing else will ever look at again.
//!
//! * **A loop.** The agent calls the same tool with the same arguments, reads the same
//!   answer, and calls it again. Ported from `deepseek-ai/deepseek-harness`'s
//!   `packages/guard/repeat-tool-reminder`: count consecutive calls with identical
//!   canonicalised arguments, and advise at [`REPEAT_THRESHOLDS`].
//! * **A stall.** The agent claims to be working and produces nothing: no transcript
//!   record, no pty output, for longer than a turn ever takes.
//!
//! # It advises, it never enforces
//!
//! The upstream loop-breaker never vetoes a call, never rewrites one, and never
//! appears in the tool list; the decision stays with the model. Keeping that property
//! here is not a style choice, it is the only thing that makes the heuristic safe to
//! be wrong: a [`StuckAlert`] is a sentence a human reads on Telegram. Nothing in this
//! module kills a session, types into a pty, or changes what a tool does. The one
//! place their design does not transfer is the injection — they put the advisory into
//! the model's own context, and we cannot, because we do not own the tool pipeline and
//! writing into the prompt box would steal it from whoever is typing.
//!
//! # Where the loop signal comes from
//!
//! The transcript seam ([`juancoded_transcripts`]), not the VT grid. The seam already
//! carries [`TranscriptEvent::ToolCall`] with the arguments as compact JSON, which is
//! exactly what a canonicaliser needs, and its claude source drops `isSidechain`
//! lines — a sub-agent's conversation never reaches us — so "per-agent keying" is
//! satisfied by one chain per session and needs no second key.
//!
//! Only *live* records may be fed to [`RepeatChain::on_event`]. The pump already draws
//! that line for the activity detector (its `fresh` set): a session's backlog, read in
//! one go at bind or after a restart, is history, and history must not raise an alert
//! about a loop that ended yesterday. In memory only, per the ticket: a resumed
//! session starts on a fresh chain and that is accepted.
//!
//! # What is a run
//!
//! Four rules, each of them a way the count is wrong if it is missing.
//!
//! 1. **Identical canonical arguments.** Deep key-sort, then compact JSON, so a CLI
//!    that emits its keys in a different order does not read as a different call.
//! 2. **Bookkeeping tools are transparent.** `grep X -> todo_write -> grep X` is two
//!    consecutive `grep X`, because otherwise a loop launders itself through a todo
//!    write and the count never leaves 1.
//! 3. **Denied calls count.** A model hammering a call it keeps being denied is the
//!    loop most worth breaking, so nothing here looks at
//!    [`TranscriptEvent::ToolResult`]'s `ok`.
//! 4. **A user prompt resets.** [`TranscriptEvent::TurnStart`] is the human steering,
//!    and whatever the agent was repeating before it is not this turn's problem.
//!
//! Everything else on the seam — prose, thinking, steps, usage, a turn ending — is
//! inert. It does not extend a run and it does not break one.
//!
//! # What the stall half reuses, and what it must not invent
//!
//! It reuses the reaper's liveness signal wholesale: the same [`ReaperProbes`]
//! instance, the same [`ReapProbe`] per session, the same three brakes. That is
//! deliberate and it is the lesson of juancode-qb5, where an idle reaper keyed on pty
//! *input* killed busy sessions, because a dispatched agent is typed at exactly once
//! and then works for hours. So:
//!
//! * liveness is **output and transcript growth**, never input — this module never
//!   reads [`ReapProbe::last_input_ms`];
//! * dormancy must be **observed** across [`StallPolicy::min_quiet_samples`] separate
//!   sweeps, because elapsed time is a shared clock and one stall reads identically
//!   for every session at once;
//! * a sample gap past [`StallPolicy::max_sample_gap_ms`] **re-anchors** rather than
//!   counting unwatched time as evidence;
//! * at most [`StallPolicy::max_alerts_per_sweep`] sessions may be named in one sweep,
//!   and a session already named is quiet for [`StallPolicy::renotify_ms`].
//!
//! The reaper needs those brakes because being wrong costs a killed agent. Being wrong
//! here costs one Telegram message, so they are cheap insurance rather than the
//! feature — but a notifier that pages twenty-five times in one second is a notifier
//! somebody mutes, and a muted notifier detects nothing.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use juancoded_core::model::SessionActivity;
use juancoded_transcripts::TranscriptEvent;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tracing::{debug, info};

use crate::reaper::{ReapProbe, ReaperProbes};
use crate::service::SessionsApi;

// MARK: - the repeat chain

/// Run lengths that earn an advisory, from `repeat-tool-reminder`.
///
/// Each fires once per run: a run of nine advises at 3, 5 and 8, not seven times.
pub const REPEAT_THRESHOLDS: [u32; 3] = [3, 5, 8];

/// How much of the canonical arguments a message may quote.
///
/// **For the message only.** A tool call can carry a whole file, and a human reading a
/// Telegram ping wants the head of it; the chain always compares the full canonical
/// string, so two calls that differ only past this point are two different calls.
pub const ARG_HEAD: usize = 160;

/// Tools that do not advance a chain and do not break one.
///
/// A bookkeeping call records what the agent already decided; it reads nothing and
/// changes nothing a repeated call would see differently. Treating one as an ordinary
/// call is what lets a loop launder itself: `grep X -> todo_write -> grep X` would be
/// three runs of one instead of one run of two.
pub fn is_bookkeeping(tool: &str) -> bool {
    matches!(
        tool,
        "TodoWrite" | "todo_write" | "TodoRead" | "todo_read" | "todowrite" | "todoread"
    )
}

/// Deep key-sort, then compact JSON.
///
/// A tool call's arguments are a JSON object whose key order is whatever the CLI
/// happened to serialise; two calls that differ only in that order are the same call
/// and must land in the same run. Input that is not JSON at all passes through
/// verbatim rather than being dropped — a source that hands us a bare string is still
/// comparable to itself.
pub fn canonical_args(input: &str) -> String {
    match serde_json::from_str::<Value>(input) {
        Ok(value) => sorted(value).to_string(),
        Err(_) => input.to_string(),
    }
}

/// `serde_json::Map` preserves insertion order under the `preserve_order` feature and
/// sorts otherwise, so the sort is done here rather than relied on.
fn sorted(value: Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut keys: Vec<String> = map.keys().cloned().collect();
            keys.sort();
            let mut out = serde_json::Map::with_capacity(keys.len());
            let mut map = map;
            for key in keys {
                if let Some(v) = map.remove(&key) {
                    out.insert(key, sorted(v));
                }
            }
            Value::Object(out)
        }
        Value::Array(items) => Value::Array(items.into_iter().map(sorted).collect()),
        other => other,
    }
}

/// Head of `text`, cut on a character boundary, marked when it cut.
fn head(text: &str, max: usize) -> String {
    if text.len() <= max {
        return text.to_string();
    }
    let mut end = max;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", &text[..end])
}

/// Which of the two failures an alert is about.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum StuckKind {
    /// The same tool, the same canonical arguments, [`StuckAlert::run`] times running.
    Repeat,
    /// Claiming to work and producing nothing for [`StuckAlert::quiet_ms`].
    Stall,
}

impl StuckKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Repeat => "repeat",
            Self::Stall => "stall",
        }
    }
}

/// One advisory about one session. Carries no instruction and nothing acts on it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StuckAlert {
    pub kind: StuckKind,
    /// The tool the run is on. `None` for a stall.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool: Option<String>,
    /// How many consecutive identical calls. `0` for a stall.
    pub run: u32,
    /// How long the session has been dormant while claiming to work. `0` for a repeat.
    pub quiet_ms: i64,
    /// The sentence a human reads. The **only** place head-truncated arguments appear.
    pub advice: String,
}

/// One session's run of consecutive identical tool calls.
///
/// In memory only, and deliberately so: persisting it would mean a daemon restart
/// resurrecting a run whose session has since been steered, and the ticket accepts a
/// resumed session starting fresh.
#[derive(Debug)]
pub struct RepeatChain {
    /// `tool` and the full canonical arguments, joined. `None` before the first call.
    key: Option<String>,
    tool: String,
    /// Full canonical arguments, never truncated: this is the comparison.
    args: String,
    run: u32,
    /// Highest threshold already advised on within this run, so each fires once.
    advised: u32,
    /// Ascending run lengths that earn an advisory. [`REPEAT_THRESHOLDS`] in the
    /// daemon; the calibration replay lowers it, which is the only reason it is not a
    /// constant — a threshold nobody can move is a threshold nobody can measure.
    thresholds: Vec<u32>,
}

impl Default for RepeatChain {
    fn default() -> Self {
        Self {
            key: None,
            tool: String::new(),
            args: String::new(),
            run: 0,
            advised: 0,
            thresholds: REPEAT_THRESHOLDS.to_vec(),
        }
    }
}

impl RepeatChain {
    pub fn new() -> Self {
        Self::default()
    }

    /// The same chain against different thresholds, ascending.
    pub fn with_thresholds(thresholds: Vec<u32>) -> Self {
        let mut thresholds = thresholds;
        thresholds.sort_unstable();
        Self {
            thresholds,
            ..Self::default()
        }
    }

    /// The run length right now. Zero before the first call of a chain.
    pub fn run(&self) -> u32 {
        self.run
    }

    /// The tool the current run is on, if any.
    pub fn tool(&self) -> Option<&str> {
        self.key.is_some().then_some(self.tool.as_str())
    }

    /// Drop the run. The human steered, or the session did.
    pub fn reset(&mut self) {
        self.key = None;
        self.tool.clear();
        self.args.clear();
        self.run = 0;
        self.advised = 0;
    }

    /// Fold one seam event in, and advise if this call crossed a threshold.
    ///
    /// Everything that is not a tool call or a turn start is inert: it neither extends
    /// a run nor breaks one, which is what makes the bookkeeping rule above hold for
    /// the prose and the tool results that sit between two identical calls.
    pub fn on_event(&mut self, event: &TranscriptEvent) -> Option<StuckAlert> {
        match event {
            TranscriptEvent::TurnStart { .. } => {
                self.reset();
                None
            }
            TranscriptEvent::ToolCall { name, input, .. } => self.on_call(name, input),
            _ => None,
        }
    }

    fn on_call(&mut self, name: &str, input: &str) -> Option<StuckAlert> {
        if is_bookkeeping(name) {
            return None; // transparent: neither extends the run nor breaks it
        }
        let args = canonical_args(input);
        let key = format!("{name}\u{1}{args}");
        if self.key.as_deref() == Some(key.as_str()) {
            self.run = self.run.saturating_add(1);
        } else {
            self.key = Some(key);
            self.tool = name.to_string();
            self.args = args;
            self.run = 1;
            self.advised = 0;
        }
        let crossed = self
            .thresholds
            .iter()
            .copied()
            .filter(|t| *t <= self.run && *t > self.advised)
            .next_back()?;
        self.advised = crossed;
        let generic = self.thresholds.first() == Some(&crossed);
        Some(StuckAlert {
            kind: StuckKind::Repeat,
            tool: Some(self.tool.clone()),
            run: self.run,
            quiet_ms: 0,
            advice: repeat_advice(&self.tool, self.run, &self.args, generic, crossed >= 8),
        })
    }
}

/// The escalating text, generic first and specific after.
///
/// The first threshold names nothing on purpose: three identical calls is often a
/// human's own retry loop or a poll that is about to succeed, so the cheapest useful
/// thing to say is that it happened. By the fifth the run is worth naming, and the
/// arguments are quoted — head-truncated, and here only.
fn repeat_advice(tool: &str, run: u32, args: &str, generic: bool, insistent: bool) -> String {
    if generic {
        return format!(
            "This session has made the same tool call {run} times in a row. \
             Re-read the last result: change approach, or conclude."
        );
    }
    let quoted = head(args, ARG_HEAD);
    if insistent {
        format!(
            "This session has called `{tool}` {run} times in a row with identical arguments \
             ({quoted}). Nothing about the call has changed in {run} attempts and the result \
             will not either. Stop, and either change approach or say what is blocking."
        )
    } else {
        format!(
            "This session has called `{tool}` {run} times in a row with identical arguments \
             ({quoted}). The result will not change. Re-read it, then change approach or conclude."
        )
    }
}

// MARK: - the stall policy

/// The thresholds the stall rule reads. Separated from [`StuckWatch`] so the pure half
/// is exercisable without a registry, the way [`crate::reaper::Policy`] is.
#[derive(Debug, Clone, Copy)]
pub struct StallPolicy {
    /// How long a session may claim to be working while producing nothing before it is
    /// worth a message.
    ///
    /// Ten minutes because that is comfortably longer than any turn we have measured
    /// and because the cost of being early is a wrong Telegram ping. It is not a kill
    /// threshold and must never be treated as one.
    pub quiet_ms: i64,
    /// How many separate sweeps must observe the session dormant.
    pub min_quiet_samples: u32,
    /// The longest gap between two samples that still counts as an unbroken streak.
    /// Past it nobody was watching, and unobserved time is not evidence.
    pub max_sample_gap_ms: i64,
    /// How long after naming a session it stays quiet, so one wedged agent does not
    /// page every sweep for an hour.
    pub renotify_ms: i64,
    /// Ceiling on sessions named in one sweep.
    pub max_alerts_per_sweep: usize,
    /// Pty output since the anchor that still counts as no progress.
    ///
    /// Inherited from [`crate::reaper::Policy::output_floor_bytes`] rather than
    /// measured for this case: a settled TUI repaints itself, so "any byte at all" is
    /// the signal that defeated the sweep the reaper replaced. The transcript-growth
    /// check below it is the signal that actually carries the verdict.
    pub output_floor_bytes: u64,
}

impl Default for StallPolicy {
    fn default() -> Self {
        Self {
            quiet_ms: 10 * 60 * 1_000,
            min_quiet_samples: 3,
            max_sample_gap_ms: 10 * 60 * 1_000,
            renotify_ms: 30 * 60 * 1_000,
            max_alerts_per_sweep: 3,
            output_floor_bytes: 64 * 1024,
        }
    }
}

/// One session's observable state at a stall sweep. The fields are
/// [`ReapProbe`]'s, narrowed to the ones a stall verdict may read — note that
/// `last_input_ms` is not among them.
#[derive(Debug, Clone, PartialEq)]
pub struct StallSample {
    /// [`SessionActivity::Busy`] is the session claiming to work.
    pub activity: SessionActivity,
    /// The activity detector's uncapped "a call is still out there" fact. A subagent
    /// legitimately runs past the state machine's hold cap and the state then falls
    /// back to idle while the tool is still running, so this is its own claim to be
    /// working.
    pub open_tool_call: bool,
    /// Running total of pty bytes. Read as a delta since the anchor, never as "any
    /// byte at all".
    pub output_bytes: u64,
    /// The session's CLI transcript size, `None` when it cannot be located. Append-only,
    /// so growth is the agent having produced something.
    pub transcript_size_bytes: Option<u64>,
    /// ms-since-epoch of the last moment the detector classified this session
    /// non-idle. Evidence in the message; not the verdict.
    pub last_busy_ms: i64,
}

impl StallSample {
    /// Whether the session is asserting that work is in flight.
    ///
    /// [`SessionActivity::WaitingInput`] deliberately is not: a session at a permission
    /// prompt is stuck on a human, the activity broadcast already pinged that human,
    /// and a second message saying the same thing is noise.
    pub fn claims_working(&self) -> bool {
        self.activity == SessionActivity::Busy || self.open_tool_call
    }
}

/// A dormancy streak: when it started, what it started from, and how many sweeps have
/// seen it.
#[derive(Debug, Clone, PartialEq)]
pub struct StallStreak {
    pub since_ms: i64,
    pub output_bytes: u64,
    pub transcript_size_bytes: Option<u64>,
    pub last_sample_ms: i64,
    pub quiet_samples: u32,
}

/// The sweep's decision for one session.
#[derive(Debug, Clone, PartialEq)]
pub enum StallVerdict {
    /// Working, or not claiming to be. Drop the streak.
    Moving,
    /// Dormant, but not for long enough or not across enough sweeps yet.
    Holding(StallStreak),
    /// Dormant across the whole window and enough observations: worth a message.
    /// Carries the streak so the caller keeps observing rather than re-anchoring.
    Stalled { streak: StallStreak, quiet_ms: i64 },
}

/// A fresh streak from this sample. One observation, so `quiet_samples` starts at 1.
pub fn stall_anchor(sample: &StallSample, now_ms: i64) -> StallStreak {
    StallStreak {
        since_ms: now_ms,
        output_bytes: sample.output_bytes,
        transcript_size_bytes: sample.transcript_size_bytes,
        last_sample_ms: now_ms,
        quiet_samples: 1,
    }
}

/// Evaluate one session against its tracked streak.
///
/// Pure and clock-injected, like [`crate::reaper::evaluate`], and for the same reason:
/// the brakes are the part that has to be provable, and a rule that reads a wall clock
/// cannot be.
pub fn evaluate_stall(
    sample: &StallSample,
    streak: Option<&StallStreak>,
    now_ms: i64,
    policy: &StallPolicy,
) -> StallVerdict {
    if policy.quiet_ms <= 0 || !sample.claims_working() {
        return StallVerdict::Moving;
    }
    let fresh = stall_anchor(sample, now_ms);
    let Some(base) = streak else {
        return StallVerdict::Holding(fresh);
    };
    // Nobody was watching across the gap — a suspended machine, a stalled sweep, a
    // clock jump. Unobserved time is not evidence of dormancy, so start again from now.
    if now_ms - base.last_sample_ms > policy.max_sample_gap_ms {
        debug!(
            gap_ms = now_ms - base.last_sample_ms,
            "stall streak re-anchored across a sample gap"
        );
        return StallVerdict::Holding(fresh);
    }
    // The structured signal first: the transcript is append-only, so growth is the
    // agent having produced something even while the screen sits still. A transcript
    // that cannot be located contributes nothing either way and leaves the verdict to
    // the pty.
    let transcript_grew = match (base.transcript_size_bytes, sample.transcript_size_bytes) {
        (Some(before), Some(now)) => now > before,
        _ => false,
    };
    let output_grew =
        sample.output_bytes.saturating_sub(base.output_bytes) > policy.output_floor_bytes;
    if transcript_grew || output_grew {
        return StallVerdict::Moving;
    }
    let advanced = StallStreak {
        last_sample_ms: now_ms,
        quiet_samples: base.quiet_samples.saturating_add(1),
        ..base.clone()
    };
    let quiet_ms = now_ms - advanced.since_ms;
    if quiet_ms >= policy.quiet_ms && advanced.quiet_samples >= policy.min_quiet_samples {
        StallVerdict::Stalled {
            streak: advanced,
            quiet_ms,
        }
    } else {
        StallVerdict::Holding(advanced)
    }
}

/// The sentence a human reads for a stall.
pub fn stall_advice(quiet_ms: i64, open_tool_call: bool) -> String {
    let minutes = (quiet_ms / 60_000).max(1);
    if open_tool_call {
        format!(
            "This session has had a tool call open for {minutes} min with no transcript record \
             and no output. It may be wedged rather than working."
        )
    } else {
        format!(
            "This session has claimed to be working for {minutes} min with no transcript record \
             and no output. It may be wedged rather than working."
        )
    }
}

// MARK: - the watcher

/// Where an alert goes. A closure rather than a channel so the pure half stays
/// testable and so this crate does not have to know the wire exists.
pub type AlertSink = Arc<dyn Fn(&str, StuckAlert) + Send + Sync>;

/// Owns the per-session repeat chains and the stall sweep. One per daemon.
///
/// Deliberately not part of the registry: the registry owns state that a client can
/// change, and this owns a heuristic's memory. Losing all of it on a restart is
/// correct, which is a very different property from anything the registry holds.
pub struct StuckWatch {
    sessions: Arc<dyn SessionsApi>,
    probes: ReaperProbes,
    policy: StallPolicy,
    sweep_interval: Duration,
    sink: AlertSink,
    chains: Mutex<HashMap<String, RepeatChain>>,
    streaks: Mutex<HashMap<String, StallStreak>>,
    /// When each session was last named, so [`StallPolicy::renotify_ms`] can be served.
    notified: Mutex<HashMap<String, i64>>,
}

/// How often the stall sweep runs. A quarter of the default window, so the three
/// observations the policy requires fit inside it with one to spare — the same
/// relationship [`crate::reaper::sweep_interval_ms`] keeps.
pub const STALL_SWEEP: Duration = Duration::from_secs(150);

impl StuckWatch {
    pub fn new(
        sessions: Arc<dyn SessionsApi>,
        probes: ReaperProbes,
        policy: StallPolicy,
        sink: AlertSink,
    ) -> Self {
        Self {
            sessions,
            probes,
            policy,
            sweep_interval: STALL_SWEEP,
            sink,
            chains: Mutex::new(HashMap::new()),
            streaks: Mutex::new(HashMap::new()),
            notified: Mutex::new(HashMap::new()),
        }
    }

    /// Override the sweep cadence. Tests drive [`Self::sweep_once`] by hand instead;
    /// this exists for a daemon that wants a different rhythm.
    pub fn with_sweep_interval(mut self, interval: Duration) -> Self {
        self.sweep_interval = interval;
        self
    }

    /// Records one session's CLI has **newly** appended. Backlog must never reach here:
    /// see the module docs.
    pub fn on_transcript<'a>(
        &self,
        session: &str,
        events: impl IntoIterator<Item = &'a TranscriptEvent>,
    ) {
        let mut alerts = Vec::new();
        {
            let mut chains = self.lock_chains();
            let chain = chains.entry(session.to_string()).or_default();
            for event in events {
                if let Some(alert) = chain.on_event(event) {
                    alerts.push(alert);
                }
            }
        }
        for alert in alerts {
            info!(
                session,
                tool = alert.tool.as_deref().unwrap_or("-"),
                run = alert.run,
                "repeat-tool advisory"
            );
            (self.sink)(session, alert);
        }
    }

    /// A session ended, or was slept. Its chain and its streak go with it — the next
    /// life starts on a fresh count.
    pub fn forget(&self, session: &str) {
        self.lock_chains().remove(session);
        self.lock_streaks().remove(session);
        self.lock_notified().remove(session);
    }

    /// The run length a session's chain is on. For tests and the dump.
    pub fn run_of(&self, session: &str) -> u32 {
        self.lock_chains().get(session).map_or(0, RepeatChain::run)
    }

    /// One sweep over every live session. Returns the sessions named this sweep.
    ///
    /// Nothing here kills, sleeps or types. The worst a wrong verdict can do is send a
    /// message.
    pub fn sweep_once(&self) -> Vec<String> {
        let now = (self.probes.now_ms)();
        let sizes = (self.probes.transcript_sizes)();
        let prior = self.lock_streaks().clone();
        let mut next: HashMap<String, StallStreak> = HashMap::new();
        let mut stalled: Vec<(String, StallSample, i64)> = Vec::new();
        let live: Vec<String> = self.sessions.ids();
        for id in &live {
            let Some(probe) = self.sessions.reap_probe(id) else {
                continue;
            };
            if !probe.running {
                continue;
            }
            let sample = sample_of(&probe, sizes.get(id).copied());
            match evaluate_stall(&sample, prior.get(id), now, &self.policy) {
                StallVerdict::Moving => {}
                StallVerdict::Holding(streak) => {
                    next.insert(id.clone(), streak);
                }
                StallVerdict::Stalled { streak, quiet_ms } => {
                    next.insert(id.clone(), streak);
                    stalled.push((id.clone(), sample, quiet_ms));
                }
            }
        }
        *self.lock_streaks() = next;

        // Oldest stall first, so a cap that bites names the session that has been
        // wedged longest rather than whichever id sorted first.
        stalled.sort_by(|a, b| b.2.cmp(&a.2));
        let mut named = Vec::new();
        for (id, sample, quiet_ms) in stalled {
            if named.len() >= self.policy.max_alerts_per_sweep {
                debug!(session = %id, "stall alert withheld: sweep cap reached");
                break;
            }
            {
                let mut notified = self.lock_notified();
                if let Some(last) = notified.get(&id) {
                    if now - *last < self.policy.renotify_ms {
                        continue;
                    }
                }
                notified.insert(id.clone(), now);
            }
            let alert = StuckAlert {
                kind: StuckKind::Stall,
                tool: None,
                run: 0,
                quiet_ms,
                advice: stall_advice(quiet_ms, sample.open_tool_call),
            };
            info!(
                session = %id,
                quiet_ms,
                open_tool_call = sample.open_tool_call,
                last_busy_ms = sample.last_busy_ms,
                "stall advisory"
            );
            (self.sink)(&id, alert);
            named.push(id);
        }
        // A session that has gone away stops being remembered, so a long-lived daemon
        // does not accumulate a chain per session it ever ran.
        let ids: std::collections::HashSet<&String> = live.iter().collect();
        self.lock_chains().retain(|id, _| ids.contains(id));
        self.lock_notified().retain(|id, _| ids.contains(id));
        named
    }

    /// Run the sweep loop until the returned handle is dropped or the task aborted.
    pub fn spawn(self: &Arc<Self>) -> tokio::task::JoinHandle<()> {
        let watch = Arc::clone(self);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(watch.sweep_interval).await;
                watch.sweep_once();
            }
        })
    }

    fn lock_chains(&self) -> std::sync::MutexGuard<'_, HashMap<String, RepeatChain>> {
        self.chains.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn lock_streaks(&self) -> std::sync::MutexGuard<'_, HashMap<String, StallStreak>> {
        self.streaks.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn lock_notified(&self) -> std::sync::MutexGuard<'_, HashMap<String, i64>> {
        self.notified.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// Narrow the reaper's probe to what a stall verdict may read.
pub fn sample_of(probe: &ReapProbe, transcript_size_bytes: Option<u64>) -> StallSample {
    StallSample {
        activity: probe.activity,
        open_tool_call: probe.open_tool_call,
        output_bytes: probe.output_bytes,
        transcript_size_bytes,
        last_busy_ms: probe.last_busy_ms,
    }
}

#[cfg(test)]
#[path = "stuck/tests.rs"]
mod tests;
