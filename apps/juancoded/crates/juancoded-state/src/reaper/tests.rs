//! The eligibility state machine, measured against the Swift `SessionReaperTests`
//! oracle case for case.
//!
//! Every independent signal — detector state, open tool call, queue, process-tree
//! shape, CPU rate, transcript size, output rate, the busy latch, keystrokes,
//! resumability — must hold for the full window before a session is eligible, and any
//! disturbance restarts the streak. The asymmetry is deliberate: a false "busy" only
//! delays freeing RAM, a false "idle" kills real work.

use super::*;

const WINDOW_MS: i64 = 30 * 60 * 1_000;
const T0: i64 = 1_000_000_000_000;
/// The production sweep cadence at the default window. The streak is evidence
/// gathered one sweep at a time, so a test that asks "would this be reaped" walks a
/// real chain of samples rather than comparing two distant timestamps.
const SWEEP_MS: i64 = 90_000;

/// An all-clear sample: idle, resumable, quiet tree, no recent input, no output.
fn idle_sample() -> ReapSample {
    ReapSample {
        activity: SessionActivity::Idle,
        resumable: true,
        queue_empty: true,
        last_input_ms: T0 - WINDOW_MS, // long before the streak
        descendant_count: 3,
        cpu_time_ms: 10_000,
        transcript_size_bytes: None,
        output_bytes: 0,
        last_output_ms: T0 - WINDOW_MS,
        last_busy_ms: 0,
        open_tool_call: false,
        protected: false,
    }
}

fn base_at_t0() -> Baseline {
    anchor(&idle_sample(), T0)
}

fn eval(sample: &ReapSample, baseline: Option<&Baseline>, now: i64) -> Verdict {
    evaluate(sample, baseline, now, WINDOW_MS, &Policy::default())
}

/// Walk a sweep chain from `T0` to `T0 + span_ms`, feeding each sweep the sample
/// `make(now)` returns and carrying the baseline forward exactly as the reaper does.
fn walk(span_ms: i64, step_ms: i64, make: impl Fn(i64) -> ReapSample) -> Verdict {
    let mut baseline: Option<Baseline> = None;
    let mut now = T0;
    loop {
        let verdict = eval(&make(now), baseline.as_ref(), now);
        match verdict {
            Verdict::Holding(ref b) => baseline = Some(b.clone()),
            other => return other,
        }
        if now >= T0 + span_ms {
            return verdict;
        }
        now += step_ms;
    }
}

fn holding(v: &Verdict) -> &Baseline {
    match v {
        Verdict::Holding(b) => b,
        other => panic!("expected holding, got {other:?}"),
    }
}

// MARK: - hard resets

#[test]
fn busy_is_never_eligible() {
    let mut s = idle_sample();
    s.activity = SessionActivity::Busy;
    assert_eq!(
        eval(&s, Some(&base_at_t0()), T0 + WINDOW_MS),
        Verdict::NotIdle
    );
}

/// A pending permission menu is not in the transcript until it is answered; killing
/// there aborts the tool call and a resume will not re-render the prompt.
#[test]
fn waiting_input_is_never_eligible() {
    let mut s = idle_sample();
    s.activity = SessionActivity::WaitingInput;
    assert_eq!(
        eval(&s, Some(&base_at_t0()), T0 + WINDOW_MS),
        Verdict::NotIdle
    );
}

#[test]
fn a_non_empty_queue_is_never_eligible() {
    let mut s = idle_sample();
    s.queue_empty = false;
    assert_eq!(
        eval(&s, Some(&base_at_t0()), T0 + WINDOW_MS),
        Verdict::NotIdle
    );
}

/// A delegated subagent goes screen- and transcript-quiet and legitimately outlives
/// the detector's hold cap, so the open call is its own hard veto.
#[test]
fn an_open_tool_call_is_never_eligible() {
    let mut s = idle_sample();
    s.open_tool_call = true;
    assert_eq!(
        eval(&s, Some(&base_at_t0()), T0 + WINDOW_MS),
        Verdict::NotIdle
    );
}

#[test]
fn a_protected_session_is_never_eligible() {
    let mut s = idle_sample();
    s.protected = true;
    assert_eq!(
        eval(&s, Some(&base_at_t0()), T0 + WINDOW_MS),
        Verdict::NotIdle
    );
}

#[test]
fn a_disabled_window_never_tracks() {
    assert_eq!(
        evaluate(&idle_sample(), None, T0, 0, &Policy::default()),
        Verdict::NotIdle
    );
}

// MARK: - the streak

#[test]
fn the_first_idle_sweep_captures_a_baseline() {
    let v = eval(&idle_sample(), None, T0);
    assert_eq!(holding(&v).idle_since_ms, T0);
    assert_eq!(holding(&v).quiet_samples, 1);
}

#[test]
fn idle_before_the_window_is_served_holds() {
    let v = walk(WINDOW_MS - 2 * SWEEP_MS, SWEEP_MS, |_| idle_sample());
    assert!(matches!(v, Verdict::Holding(_)));
}

#[test]
fn all_clear_for_the_full_window_is_eligible() {
    assert_eq!(walk(WINDOW_MS, SWEEP_MS, |_| idle_sample()), Verdict::Eligible);
}

/// The gap rule. Every stride is longer than `max_sample_gap_ms`, so the streak keeps
/// re-anchoring and never accrues either the window or the evidence: time nobody
/// watched is not evidence of dormancy.
#[test]
fn a_window_served_in_too_few_observed_sweeps_is_not_eligible() {
    let v = walk(WINDOW_MS * 4, WINDOW_MS * 2, |_| idle_sample());
    assert_eq!(holding(&v).quiet_samples, 1);
}

/// The evidence rule on its own, with the gap rule held out of the way. Belt to the
/// gap rule's braces: between them, no shared clock can make a session eligible
/// without this reaper having watched *that session* in particular.
#[test]
fn too_few_observations_hold_even_with_the_window_served() {
    let policy = Policy {
        min_quiet_samples: 4,
        ..Policy::default()
    };
    let base = Baseline {
        last_sample_ms: T0 + WINDOW_MS - 1_000,
        quiet_samples: 2,
        ..base_at_t0()
    };
    let v = evaluate(
        &idle_sample(),
        Some(&base),
        T0 + WINDOW_MS,
        WINDOW_MS,
        &policy,
    );
    let held = holding(&v).clone();
    assert_eq!(held.quiet_samples, 3, "three observations is not four");
    // One more sweep and the same session, unchanged, is eligible.
    assert_eq!(
        evaluate(
            &idle_sample(),
            Some(&held),
            T0 + WINDOW_MS + 1_000,
            WINDOW_MS,
            &policy
        ),
        Verdict::Eligible
    );
}

#[test]
fn evidence_accrues_one_sweep_at_a_time() {
    let mut baseline: Option<Baseline> = None;
    for i in 0..3 {
        let v = eval(&idle_sample(), baseline.as_ref(), T0 + i * SWEEP_MS);
        assert_eq!(holding(&v).quiet_samples, i as u32 + 1);
        baseline = Some(holding(&v).clone());
    }
}

// MARK: - OS ground truth restarts the streak

/// A Bash tool or a spawned subagent: the detector may say idle, the tree says no.
#[test]
fn an_extra_child_restarts_the_streak() {
    let mut s = idle_sample();
    s.descendant_count = 4;
    let now = T0 + WINDOW_MS;
    let v = eval(&s, Some(&base_at_t0()), now);
    assert_eq!(holding(&v).idle_since_ms, now);
    assert_eq!(holding(&v).descendant_count, 4);
}

#[test]
fn a_vanished_child_restarts_the_streak() {
    let mut s = idle_sample();
    s.descendant_count = 2;
    let v = eval(&s, Some(&base_at_t0()), T0 + WINDOW_MS);
    assert_eq!(holding(&v).idle_since_ms, T0 + WINDOW_MS);
}

#[test]
fn a_cpu_rate_above_the_busy_threshold_restarts_the_streak() {
    // 90s of wall clock, 60s of CPU: 666‰, well over the 400‰ bound.
    let mut s = idle_sample();
    s.cpu_time_ms = 10_000 + 60_000;
    let base = Baseline {
        last_sample_ms: T0,
        ..base_at_t0()
    };
    let v = eval(&s, Some(&base), T0 + SWEEP_MS);
    assert_eq!(holding(&v).idle_since_ms, T0 + SWEEP_MS);
}

/// The floor. A sweep pair that lands milliseconds apart has a tiny rate divisor, and
/// any jitter would read as busy without it.
#[test]
fn a_cpu_delta_under_the_floor_is_never_busy() {
    let mut s = idle_sample();
    s.cpu_time_ms = 10_000 + 1_999; // under cpu_floor_ms
    let base = Baseline {
        last_sample_ms: T0,
        ..base_at_t0()
    };
    let v = eval(&s, Some(&base), T0 + 10);
    assert_eq!(
        holding(&v).idle_since_ms,
        T0,
        "the anchor must survive a sub-floor delta"
    );
}

/// Regression for the rule this replaced. An idle CLI is not a quiet process: it
/// repaints its TUI at a measured ~5.8% of a core, forever. Under an absolute budget
/// that was spent in ~90s and re-anchored the streak every sweep, so nothing was ever
/// reaped — 47 live sessions, 12.4GB of footprint, 20GB of swap.
#[test]
fn the_idle_repaint_rate_survives_the_whole_window() {
    const PERMILLE_OF_CORE: i64 = 58;
    let mut baseline: Option<Baseline> = None;
    let mut cpu: u64 = 10_000;
    let mut now = T0;
    let mut verdict = Verdict::NotIdle;
    while now <= T0 + WINDOW_MS {
        let mut s = idle_sample();
        s.cpu_time_ms = cpu;
        verdict = eval(&s, baseline.as_ref(), now);
        match verdict {
            Verdict::Holding(ref b) => baseline = Some(b.clone()),
            _ => break,
        }
        now += SWEEP_MS;
        cpu += (SWEEP_MS * PERMILLE_OF_CORE / 1_000) as u64;
    }
    assert_eq!(verdict, Verdict::Eligible);
}

/// Thinking and delegation write transcript records the screen never shows.
#[test]
fn a_transcript_that_grew_restarts_the_streak() {
    let mut s = idle_sample();
    s.transcript_size_bytes = Some(4_097);
    let base = Baseline {
        transcript_size_bytes: Some(4_096),
        ..base_at_t0()
    };
    let v = eval(&s, Some(&base), T0 + WINDOW_MS);
    assert_eq!(holding(&v).idle_since_ms, T0 + WINDOW_MS);
    assert_eq!(holding(&v).transcript_size_bytes, Some(4_097));
}

/// The file is also touched on flushes that append no records — mtime moves, size
/// does not, and only size means the agent produced something.
#[test]
fn an_unchanged_transcript_stays_eligible() {
    assert_eq!(
        walk(WINDOW_MS, SWEEP_MS, |_| {
            let mut s = idle_sample();
            s.transcript_size_bytes = Some(4_096);
            s
        }),
        Verdict::Eligible
    );
}

/// An unlocatable transcript is no evidence of activity; the other signals guard.
#[test]
fn a_missing_transcript_does_not_block() {
    assert_eq!(walk(WINDOW_MS, SWEEP_MS, |_| idle_sample()), Verdict::Eligible);
}

// MARK: - output and the detector's memory are liveness, keystrokes are not

/// The bug this reaper's fix was filed for. A dispatched agent is typed at exactly
/// once, when it is created; from then on it works for hours with no input at all, so
/// keying idleness on input reads "dormant" while it is at its busiest. What it does
/// do is produce output.
#[test]
fn a_session_producing_output_with_no_input_survives() {
    const PER_SWEEP: u64 = 512 * 1024; // a tool streaming its log: ~5.8 KB/s over 90s
    let v = walk(WINDOW_MS * 2, SWEEP_MS, |now| {
        let mut s = idle_sample();
        s.last_input_ms = T0 - WINDOW_MS; // dispatched, never typed at again
        s.output_bytes = (((now - T0) / SWEEP_MS + 1) as u64) * PER_SWEEP;
        s
    });
    // Re-anchored every sweep by the output, so it never accrues a streak.
    assert_eq!(
        holding(&v).quiet_samples,
        1,
        "a session producing output is not dormant"
    );
}

/// The other half: output that is only a TUI redrawing itself must NOT hold a session
/// alive, or the reaper stops reaping and the machine goes back to swapping — which
/// is the failure mode of the old sweep that keyed on "any output at all".
#[test]
fn a_trickle_of_repaint_output_still_reaps() {
    const PER_SWEEP: u64 = 4 * 1024; // ~45 B/s: a status line, not work
    assert_eq!(
        walk(WINDOW_MS, SWEEP_MS, |now| {
            let mut s = idle_sample();
            s.output_bytes = (((now - T0) / SWEEP_MS + 1) as u64) * PER_SWEEP;
            s
        }),
        Verdict::Eligible
    );
}

/// `activity` is a snapshot: a turn can start and finish inside one sweep gap, so the
/// sample says idle while the session was working seconds ago. The detector's own
/// latch is what carries that.
#[test]
fn a_turn_between_two_sweeps_restarts_the_streak() {
    let briefly_busy_at = T0 + WINDOW_MS / 2;
    let v = walk(WINDOW_MS, SWEEP_MS, |now| {
        let mut s = idle_sample();
        s.last_busy_ms = if now > briefly_busy_at {
            briefly_busy_at
        } else {
            0
        };
        s
    });
    assert!(
        holding(&v).idle_since_ms > briefly_busy_at,
        "a session that worked mid-window is not dormant"
    );
}

/// It worked before the streak began — that is what "idle since" means.
#[test]
fn a_busy_latch_older_than_the_streak_does_not_block() {
    assert_eq!(
        walk(WINDOW_MS, SWEEP_MS, |_| {
            let mut s = idle_sample();
            s.last_busy_ms = T0 - 1;
            s
        }),
        Verdict::Eligible
    );
}

// MARK: - exemptions

/// Codex discovers its id late; killing before capture loses the conversation.
#[test]
fn an_unresumable_session_is_exempt_even_after_a_full_window() {
    let v = walk(WINDOW_MS * 2, SWEEP_MS, |_| {
        let mut s = idle_sample();
        s.resumable = false;
        s
    });
    assert!(matches!(v, Verdict::Holding(_)));
}

/// A half-typed, unsubmitted prompt is invisible to every other signal.
#[test]
fn a_keystroke_during_the_streak_restarts_it() {
    let mut s = idle_sample();
    s.last_input_ms = T0 + 60_000;
    let v = eval(&s, Some(&base_at_t0()), T0 + WINDOW_MS);
    assert_eq!(holding(&v).idle_since_ms, T0 + WINDOW_MS);
}

/// Typed just before going idle: the streak is intact but the keystroke itself must
/// also age past the window.
#[test]
fn a_keystroke_younger_than_the_window_holds() {
    let v = walk(WINDOW_MS - 2 * SWEEP_MS, SWEEP_MS, |_| {
        let mut s = idle_sample();
        s.last_input_ms = T0 - 1_000;
        s
    });
    assert!(matches!(v, Verdict::Holding(_)));
}

// MARK: - the live-session cap

fn candidate(id: &str, last_active_ms: i64, sleepable: bool) -> CapCandidate {
    CapCandidate {
        id: id.to_string(),
        last_active_ms,
        sleepable,
    }
}

#[test]
fn the_cap_is_off_when_under_the_ceiling() {
    let c = vec![candidate("a", 1, true), candidate("b", 2, true)];
    assert!(cap_surplus(&c, 3).is_empty());
}

#[test]
fn the_cap_sleeps_the_least_recently_active_first() {
    let c = vec![
        candidate("a", 300, true),
        candidate("b", 100, true),
        candidate("c", 200, true),
    ];
    assert_eq!(cap_surplus(&c, 1), vec!["b".to_string(), "c".to_string()]);
}

/// Busy sessions are holding the RAM, so they count toward the total — but they are
/// never chosen.
#[test]
fn the_cap_skips_busy_sessions_but_still_counts_them() {
    let c = vec![
        candidate("busy", 1, false),
        candidate("idle", 2, true),
        candidate("fresh", 3, true),
    ];
    assert_eq!(cap_surplus(&c, 2), vec!["idle".to_string()]);
}

/// An over-cap machine full of busy sessions stays over cap rather than killing work.
#[test]
fn the_cap_never_exceeds_the_sleepable_candidates() {
    let c = vec![
        candidate("a", 1, false),
        candidate("b", 2, false),
        candidate("c", 3, true),
    ];
    assert_eq!(cap_surplus(&c, 1), vec!["c".to_string()]);
}

#[test]
fn the_cap_is_disabled_at_zero() {
    let c = vec![candidate("a", 1, true), candidate("b", 2, true)];
    assert!(cap_surplus(&c, 0).is_empty());
}

// MARK: - cadence

/// A 90s sweep can never gather three observations inside a one-minute window, and a
/// one-minute window is the acceptance criterion for this feature. The cadence is
/// therefore bounded by the window as well as by the configured ceiling.
#[test]
fn the_sweep_cadence_fits_inside_the_window() {
    let cases = [
        (30 * 60 * 1_000i64, 90_000u64), // production: the ceiling wins
        (60_000, 15_000),                // one minute: four observations, three needed
        (2_000, 500),
        (400, 200), // the floor, so a tiny window cannot become a spin loop
    ];
    for (window_ms, expect_ms) in cases {
        assert_eq!(
            sweep_interval_ms(window_ms, 90_000),
            expect_ms,
            "window {window_ms}"
        );
    }
}

/// The point of the cadence rule: every window a person can actually set is served in
/// observations, not merely in elapsed time.
#[test]
fn every_settable_window_gathers_enough_observations() {
    let needed = Policy::default().min_quiet_samples as i64;
    for minutes in [1i64, 2, 5, 15, 30, 60, 240] {
        let window = minutes * 60_000;
        let samples = window / sweep_interval_ms(window, 90_000) as i64;
        assert!(
            samples >= needed,
            "a {minutes}-minute window gathers only {samples} observations"
        );
    }
}

/// Below four times the 200ms floor the floor outranks the observation target, and it
/// is allowed to: the streak then takes *longer* than the window rather than shorter.
/// A sub-second idle window is a test's, not a person's, and erring long is the safe
/// direction — a late reap costs RAM, an early one costs work.
#[test]
fn a_sub_second_window_errs_long_rather_than_short() {
    let policy = Policy::default();
    let window = 400i64;
    let step = sweep_interval_ms(window, 90_000) as i64;
    let mut baseline: Option<Baseline> = None;
    let mut now = T0;
    let mut sweeps = 0u32;
    loop {
        let v = evaluate(&idle_sample(), baseline.as_ref(), now, window, &policy);
        sweeps += 1;
        match v {
            Verdict::Holding(b) => baseline = Some(b),
            Verdict::Eligible => break,
            Verdict::NotIdle => panic!("an all-clear sample is not NotIdle"),
        }
        now += step;
        assert!(now - T0 < 10_000, "the streak never became eligible");
    }
    assert!(
        now - T0 >= window,
        "eligible after {}ms, sooner than the {window}ms window",
        now - T0
    );
    assert_eq!(
        sweeps, policy.min_quiet_samples,
        "the evidence rule, not the clock, is what held it"
    );
}

// MARK: - the sweep

/// The pure policy above says when a session *may* be slept. Everything here is about
/// what the sweep does with that verdict: the per-sweep budget, the re-check at the
/// instant of the kill, protection, and the order the flag and the kill happen in.
mod sweep {
    use super::*;
    use crate::registry::{AdoptRequest, Attached, CreateRequest, SessionEvent};
    use crate::{QueuedMessage, ResizeOutcome, StateError};
    use juancoded_core::model::SessionMeta;
    use juancoded_vt::Snapshot;
    use tokio::sync::broadcast;

    /// What the registry would answer, scripted. Only the handful of `SessionsApi`
    /// methods the reaper actually calls are real; everything else refuses loudly, so
    /// a reaper that grew a dependency on some other part of the registry fails here
    /// rather than passing on a fixture's guess.
    struct Fake {
        probes: Mutex<Vec<ReapProbe>>,
        killed: Mutex<Vec<String>>,
        dormant: Mutex<Vec<String>>,
        /// The audit trail this suite exists for: every `mark_dormant` and every
        /// `kill`, in the order they happened.
        calls: Mutex<Vec<String>>,
        /// Run when a session is flagged dormant. The seam that reproduces "the world
        /// changed between the verdict and the kill" — the sweep decides for every
        /// session up front, and by the time it reaches the second one the first kill
        /// has already happened.
        #[allow(clippy::type_complexity)]
        on_dormant: Mutex<Option<Box<dyn Fn(&Fake, &str) + Send + Sync>>>,
        events: broadcast::Sender<SessionEvent>,
    }

    impl Fake {
        fn new(probes: Vec<ReapProbe>) -> Arc<Self> {
            let (events, _) = broadcast::channel(64);
            Arc::new(Self {
                probes: Mutex::new(probes),
                killed: Mutex::new(Vec::new()),
                dormant: Mutex::new(Vec::new()),
                calls: Mutex::new(Vec::new()),
                on_dormant: Mutex::new(None),
                events,
            })
        }

        fn edit(&self, id: &str, f: impl FnOnce(&mut ReapProbe)) {
            let mut probes = self.probes.lock().unwrap();
            if let Some(p) = probes.iter_mut().find(|p| p.id == id) {
                f(p);
            }
        }

        fn killed(&self) -> Vec<String> {
            self.killed.lock().unwrap().clone()
        }

        fn calls(&self) -> Vec<String> {
            self.calls.lock().unwrap().clone()
        }
    }

    impl SessionsApi for Fake {
        fn ids(&self) -> Vec<String> {
            self.probes.lock().unwrap().iter().map(|p| p.id.clone()).collect()
        }

        fn is_running(&self, id: &str) -> bool {
            self.reap_probe(id).map(|p| p.running).unwrap_or(false)
        }

        fn reap_probe(&self, id: &str) -> Option<ReapProbe> {
            self.probes.lock().unwrap().iter().find(|p| p.id == id).cloned()
        }

        fn mark_dormant(&self, id: &str) -> bool {
            self.calls.lock().unwrap().push(format!("dormant:{id}"));
            self.dormant.lock().unwrap().push(id.to_string());
            let hook = self.on_dormant.lock().unwrap().take();
            if let Some(hook) = hook {
                hook(self, id);
                *self.on_dormant.lock().unwrap() = Some(hook);
            }
            true
        }

        fn kill(&self, id: &str) -> Result<(), StateError> {
            self.calls.lock().unwrap().push(format!("kill:{id}"));
            self.killed.lock().unwrap().push(id.to_string());
            self.edit(id, |p| {
                p.running = false;
                p.child_pid = None;
            });
            Ok(())
        }

        fn queue(&self, _id: &str) -> Vec<QueuedMessage> {
            Vec::new()
        }

        fn subscribe(&self) -> broadcast::Receiver<SessionEvent> {
            self.events.subscribe()
        }

        // Nothing below is on the reaper's path.
        fn meta(&self, _id: &str) -> Option<SessionMeta> {
            unimplemented!("the reaper reads `reap_probe`, not `meta`")
        }
        fn activity(&self, _id: &str) -> Option<juancoded_core::model::SessionActivity> {
            unimplemented!("the reaper reads `reap_probe`, not `activity`")
        }
        fn snapshot(&self, _id: &str) -> Option<Snapshot> {
            unimplemented!()
        }
        fn grid(&self, _id: &str) -> Option<(u16, u16)> {
            unimplemented!()
        }
        fn grid_owner(&self, _id: &str) -> Option<ClientId> {
            unimplemented!()
        }
        fn retention(&self) -> usize {
            0
        }
        fn create(&self, _req: CreateRequest) -> Result<SessionMeta, StateError> {
            unimplemented!()
        }
        fn adopt_external(&self, _req: AdoptRequest) -> Result<Option<SessionMeta>, StateError> {
            unimplemented!()
        }
        fn attach(&self, _i: &str, _o: ClientId, _c: u16, _r: u16) -> Result<Attached, StateError> {
            unimplemented!()
        }
        fn reactivate(
            &self,
            _i: &str,
            _o: ClientId,
            _c: u16,
            _r: u16,
        ) -> Result<Option<Attached>, StateError> {
            unimplemented!()
        }
        fn set_skip_permissions(
            &self,
            _i: &str,
            _s: bool,
            _o: ClientId,
            _c: u16,
            _r: u16,
        ) -> Result<Attached, StateError> {
            unimplemented!()
        }
        fn input(&self, _id: &str, _data: &[u8]) -> Result<(), StateError> {
            unimplemented!()
        }
        fn queue_message(&self, _i: &str, _t: &str) -> Result<Option<QueuedMessage>, StateError> {
            unimplemented!()
        }
        fn dequeue_message(&self, _i: &str, _m: &str) -> Result<bool, StateError> {
            unimplemented!()
        }
        fn resize(&self, _i: &str, _o: ClientId, _c: u16, _r: u16) -> ResizeOutcome {
            unimplemented!()
        }
        fn release_client(&self, _owner: ClientId) {}
        fn on_transcript(&self, _id: &str, _r: &[juancoded_transcripts::TranscriptRecord]) {}
        fn flush_all(&self) -> usize {
            0
        }
    }

    /// A live, idle, resumable session with a pty child.
    fn probe(id: &str, last_active_ms: i64) -> ReapProbe {
        ReapProbe {
            id: id.into(),
            cwd: "/tmp/project".into(),
            cli_session_id: Some(format!("cli-{id}")),
            running: true,
            child_pid: Some(4242),
            activity: SessionActivity::Idle,
            open_tool_call: false,
            last_input_ms: 0,
            last_output_ms: last_active_ms,
            output_bytes: 0,
            last_busy_ms: 0,
            updated_at: last_active_ms,
        }
    }

    struct Rig {
        fake: Arc<Fake>,
        reaper: Arc<SessionReaper>,
        clock: Arc<AtomicI64>,
    }

    /// A reaper over scripted sessions and a hand-cranked clock, with the two OS
    /// probes pinned quiet so only the scripted signals move.
    fn rig(probes: Vec<ReapProbe>, window_ms: i64, max_live: usize) -> Rig {
        let fake = Fake::new(probes);
        let clock = Arc::new(AtomicI64::new(T0));
        let tick = Arc::clone(&clock);
        let reaper = Arc::new(SessionReaper::new(
            Arc::clone(&fake) as Arc<dyn SessionsApi>,
            None,
            ReaperProbes {
                now_ms: Arc::new(move || tick.load(Ordering::Relaxed)),
                descendant_count: Arc::new(|_| 0),
                tree_cpu_time_ms: Arc::new(|_| 0),
                transcript_sizes: Arc::new(HashMap::new),
            },
            ReaperConfig {
                window_ms,
                max_live,
                ..ReaperConfig::default()
            },
        ));
        Rig {
            fake,
            reaper,
            clock,
        }
    }

    impl Rig {
        /// Advance the clock and sweep, the way the loop does.
        fn tick(&self, by_ms: i64) -> Vec<String> {
            self.clock.fetch_add(by_ms, Ordering::Relaxed);
            self.reaper.sweep_once()
        }

        /// Enough sweeps at `step` to serve `window` and gather the evidence.
        fn run(&self, window: i64, step: i64) -> Vec<String> {
            let mut slept = Vec::new();
            self.reaper.sweep_once(); // the anchoring sweep, at T0
            let mut elapsed = 0;
            while elapsed <= window + step {
                slept.extend(self.tick(step));
                elapsed += step;
            }
            slept
        }
    }

    const WINDOW: i64 = 60_000;
    const STEP: i64 = 15_000;

    /// The whole point: a session that has been quiet for the window, with every
    /// signal agreeing, is flagged dormant and then killed — in that order, so the
    /// exited row already carries the flag.
    #[test]
    fn an_idle_session_is_flagged_dormant_before_it_is_killed() {
        let rig = rig(vec![probe("a", T0)], WINDOW, 0);
        let slept = rig.run(WINDOW, STEP);
        assert_eq!(slept, vec!["a".to_string()]);
        assert_eq!(
            rig.fake.calls(),
            vec!["dormant:a".to_string(), "kill:a".to_string()],
            "the flag has to land before the pty dies or the exited row loses it"
        );
    }

    /// Property 1. A dispatched agent nobody types at, streaming a tool's output, must
    /// survive any number of sweeps. This is the failure that cost three agent
    /// batches, and it is measured end to end rather than only in the policy.
    #[test]
    fn a_session_producing_output_is_never_slept() {
        let rig = rig(vec![probe("busy-agent", T0)], WINDOW, 0);
        rig.reaper.sweep_once();
        for i in 1..40 {
            // ~5.8 KB/s over each step: a build log, not a status line.
            rig.fake
                .edit("busy-agent", |p| p.output_bytes = i * 512 * 1024);
            assert!(
                rig.tick(STEP).is_empty(),
                "slept a session that is producing output, at sweep {i}"
            );
        }
        assert!(rig.fake.killed().is_empty());
    }

    /// Property 3. Six sessions go eligible at the same instant; a sweep may take at
    /// most `max_sleeps_per_sweep` of them. No single mistaken threshold can take a
    /// machine's whole session set with it.
    #[test]
    fn one_sweep_never_sleeps_more_than_its_budget() {
        let ids = ["a", "b", "c", "d", "e", "f"];
        let rig = rig(ids.iter().map(|id| probe(id, T0)).collect(), WINDOW, 0);
        rig.reaper.sweep_once();
        let mut per_sweep = Vec::new();
        let mut elapsed = 0;
        while elapsed <= WINDOW * 2 {
            per_sweep.push(rig.tick(STEP));
            elapsed += STEP;
        }
        let budget = ReaperConfig::default().max_sleeps_per_sweep;
        for (i, slept) in per_sweep.iter().enumerate() {
            assert!(
                slept.len() <= budget,
                "sweep {i} took {} of six sessions at once: {slept:?}",
                slept.len()
            );
        }
        // The rest are not lost — they keep their streaks and the next sweep takes
        // them, so reclaiming a backlog is a visible trickle rather than a batch.
        let busy_sweeps: Vec<&Vec<String>> = per_sweep.iter().filter(|s| !s.is_empty()).collect();
        assert_eq!(busy_sweeps.len(), 2, "six sessions over two sweeps: {per_sweep:?}");
        assert_eq!(rig.fake.killed().len(), 6);
    }

    /// Property 2. The sweep decides for every session before it kills any of them, so
    /// by the time it reaches the second one the world has moved. Here the first kill
    /// makes the second session busy; a reaper that acted on its stale verdict would
    /// kill a working agent.
    #[test]
    fn a_verdict_that_went_stale_before_the_kill_is_vetoed() {
        let rig = rig(vec![probe("a", T0), probe("b", T0 + 1)], WINDOW, 0);
        *rig.fake.on_dormant.lock().unwrap() = Some(Box::new(|fake, id| {
            if id == "a" {
                fake.edit("b", |p| p.activity = SessionActivity::Busy);
            }
        }));
        let slept = rig.run(WINDOW, STEP);
        assert_eq!(
            slept,
            vec!["a".to_string()],
            "b started a turn between the verdict and the kill"
        );
        assert_eq!(rig.fake.killed(), vec!["a".to_string()]);
    }

    /// The same re-check, for the signal that actually killed a focused pane: the
    /// session became the one the user is looking at after the verdict was taken.
    #[test]
    fn protection_arriving_before_the_kill_still_saves_the_session() {
        let rig = rig(vec![probe("a", T0), probe("pane", T0 + 1)], WINDOW, 0);
        let reaper = Arc::clone(&rig.reaper);
        *rig.fake.on_dormant.lock().unwrap() = Some(Box::new(move |_fake, id| {
            if id == "a" {
                reaper.set_protected(7 as ClientId, HashSet::from(["pane".to_string()]));
            }
        }));
        let slept = rig.run(WINDOW, STEP);
        assert_eq!(slept, vec!["a".to_string()]);
        assert!(!rig.fake.killed().contains(&"pane".to_string()));
    }

    #[test]
    fn a_protected_session_survives_the_whole_window() {
        let rig = rig(vec![probe("pane", T0)], WINDOW, 0);
        rig.reaper
            .set_protected(1 as ClientId, HashSet::from(["pane".to_string()]));
        assert!(rig.run(WINDOW * 2, STEP).is_empty());
        assert!(rig.fake.killed().is_empty());
    }

    /// A daemon outlives its clients, unlike the in-process core this is ported from.
    /// A protection that survived the connection that declared it would be a session
    /// nobody is looking at that can never be reaped again.
    #[test]
    fn a_client_that_disconnects_stops_protecting_its_pane() {
        let rig = rig(vec![probe("pane", T0)], WINDOW, 0);
        rig.reaper
            .set_protected(1 as ClientId, HashSet::from(["pane".to_string()]));
        assert!(rig.run(WINDOW, STEP).is_empty());
        rig.reaper.release_client(1 as ClientId);
        assert_eq!(rig.run(WINDOW, STEP), vec!["pane".to_string()]);
    }

    /// Newly protecting a session drops its streak, so unprotecting it later serves a
    /// fresh window instead of reaping off a baseline gathered before anyone looked.
    #[test]
    fn protecting_a_session_drops_its_streak() {
        let rig = rig(vec![probe("pane", T0)], WINDOW, 0);
        rig.reaper.sweep_once();
        rig.tick(STEP);
        rig.reaper
            .set_protected(1 as ClientId, HashSet::from(["pane".to_string()]));
        rig.reaper.set_protected(1 as ClientId, HashSet::new());
        // The window is already served in wall-clock terms; the evidence is not.
        rig.clock.fetch_add(WINDOW, Ordering::Relaxed);
        assert!(
            rig.reaper.sweep_once().is_empty(),
            "a fresh streak cannot be eligible on its first observation"
        );
    }

    /// The cap is a separate guarantee: it fires with the idle window switched off,
    /// because a session touched every few minutes never serves a window yet still
    /// holds a whole process tree.
    #[test]
    fn the_cap_sleeps_the_least_recently_active_with_the_window_off() {
        let rig = rig(
            vec![probe("old", T0 - 5_000), probe("new", T0), probe("mid", T0 - 1_000)],
            0,
            2,
        );
        assert_eq!(rig.reaper.sweep_once(), vec!["old".to_string()]);
        assert_eq!(rig.fake.calls(), vec!["dormant:old", "kill:old"]);
    }

    /// The cap never chooses a session that is not safe to sleep — it takes the next
    /// one instead. A busy session still counts toward the total, because it is
    /// holding the RAM the cap exists to bound.
    #[test]
    fn the_cap_skips_a_session_it_may_not_sleep_and_takes_the_next() {
        let rig = rig(vec![probe("old", T0 - 5_000), probe("new", T0)], 0, 1);
        rig.fake.edit("old", |p| p.open_tool_call = true);
        assert_eq!(
            rig.reaper.sweep_once(),
            vec!["new".to_string()],
            "an open tool call vetoes a cap eviction like it vetoes a reap"
        );
    }

    /// Property 2 again, on the cap path: the LRU order is computed before the loop
    /// starts, so the second eviction acts on a verdict the first eviction may have
    /// invalidated.
    #[test]
    fn a_cap_eviction_that_went_stale_before_the_kill_is_vetoed() {
        let rig = rig(
            vec![
                probe("oldest", T0 - 9_000),
                probe("older", T0 - 5_000),
                probe("new", T0),
            ],
            0,
            1,
        );
        *rig.fake.on_dormant.lock().unwrap() = Some(Box::new(|fake, id| {
            if id == "oldest" {
                fake.edit("older", |p| p.activity = SessionActivity::Busy);
            }
        }));
        assert_eq!(rig.reaper.sweep_once(), vec!["oldest".to_string()]);
        assert!(!rig.fake.killed().contains(&"older".to_string()));
    }

    /// An over-cap machine full of sessions that may not be slept stays over cap
    /// rather than killing work.
    #[test]
    fn the_cap_never_kills_work_to_get_under_the_ceiling() {
        let rig = rig(vec![probe("a", T0), probe("b", T0 + 1)], 0, 1);
        rig.fake.edit("a", |p| p.activity = SessionActivity::Busy);
        rig.fake.edit("b", |p| p.open_tool_call = true);
        assert!(rig.reaper.sweep_once().is_empty());
        assert!(rig.fake.killed().is_empty());
    }

    /// Turning auto-sleep off must drop every streak, or re-enabling it later reaps
    /// off a baseline gathered while nobody was applying a window.
    #[test]
    fn disabling_the_window_drops_the_streaks() {
        let rig = rig(vec![probe("a", T0)], WINDOW, 0);
        rig.reaper.sweep_once();
        rig.tick(STEP);
        rig.reaper.set_window_ms(0);
        assert!(rig.reaper.sweep_once().is_empty());
        rig.reaper.set_window_ms(WINDOW);
        rig.clock.fetch_add(WINDOW * 2, Ordering::Relaxed);
        assert!(
            rig.reaper.sweep_once().is_empty(),
            "re-enabling starts a fresh window, it does not cash in an old one"
        );
    }

    /// A session with no live child is not something to reap: its pty is already
    /// going, and there is no tree left to free.
    #[test]
    fn a_session_without_a_child_pid_is_skipped() {
        let rig = rig(vec![probe("a", T0)], WINDOW, 0);
        rig.fake.edit("a", |p| p.child_pid = None);
        assert!(rig.run(WINDOW * 2, STEP).is_empty());
    }

    /// Codex discovers its id late; killing before capture loses the conversation.
    #[test]
    fn an_unresumable_session_is_never_slept_by_either_path() {
        let rig = rig(vec![probe("a", T0), probe("b", T0 + 1)], WINDOW, 1);
        rig.fake.edit("a", |p| p.cli_session_id = None);
        rig.fake.edit("b", |p| p.cli_session_id = None);
        assert!(rig.run(WINDOW * 2, STEP).is_empty());
        assert!(rig.fake.killed().is_empty());
    }
}
