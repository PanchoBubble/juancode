//! What the detector has to get right, one test per way it has been got wrong.
//!
//! The repeat half is pure and its tests need nothing. The stall half needs a
//! `SessionsApi`, so there is one fake here rather than a shared one: the reaper's
//! fake answers the reaper's questions, and a fake that served both would have to
//! satisfy the union of two decision rules that are deliberately opposites.

use super::*;
use crate::grid::ResizeOutcome;
use crate::registry::{AdoptRequest, Attached, CreateRequest, StateError};
use juancoded_core::model::{SessionActivity, SessionMeta};
use juancoded_persistence::QueuedMessage;
use juancoded_transcripts::{Source, TranscriptRecord};
use juancoded_vt::Snapshot;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Mutex as StdMutex;
use tokio::sync::broadcast;

// MARK: - helpers

fn call(name: &str, input: &str) -> TranscriptEvent {
    TranscriptEvent::ToolCall {
        call: format!("call_{name}_{}", input.len()),
        name: name.into(),
        input: input.into(),
    }
}

fn result(ok: bool) -> TranscriptEvent {
    TranscriptEvent::ToolResult {
        call: "call".into(),
        ok,
        output: if ok { "fine".into() } else { "denied".into() },
    }
}

fn prompt(text: &str) -> TranscriptEvent {
    TranscriptEvent::TurnStart {
        prompt: text.into(),
    }
}

/// Run a chain over events and collect every advisory it raised.
fn advisories(events: &[TranscriptEvent]) -> Vec<StuckAlert> {
    let mut chain = RepeatChain::new();
    events.iter().filter_map(|e| chain.on_event(e)).collect()
}

// MARK: - canonicalisation

#[test]
fn key_order_does_not_make_two_calls_different() {
    assert_eq!(
        canonical_args(r#"{"b":1,"a":{"d":2,"c":3}}"#),
        canonical_args(r#"{"a":{"c":3,"d":2},"b":1}"#)
    );
    // Order inside an array is meaning, not formatting, and must survive.
    assert_ne!(
        canonical_args(r#"{"a":[1,2]}"#),
        canonical_args(r#"{"a":[2,1]}"#)
    );
}

#[test]
fn arguments_that_are_not_json_still_compare_to_themselves() {
    assert_eq!(canonical_args("not json"), "not json");
    assert_ne!(canonical_args("not json"), canonical_args("also not json"));
}

// MARK: - the run

#[test]
fn three_identical_calls_advise_once_and_five_advise_again() {
    let alerts = advisories(&[
        call("Grep", r#"{"pattern":"X"}"#),
        call("Grep", r#"{"pattern":"X"}"#),
        call("Grep", r#"{"pattern":"X"}"#),
        call("Grep", r#"{"pattern":"X"}"#),
        call("Grep", r#"{"pattern":"X"}"#),
    ]);
    assert_eq!(
        alerts.len(),
        2,
        "one advisory at 3 and one at 5, not one per call"
    );
    assert_eq!(alerts[0].run, 3);
    assert_eq!(alerts[1].run, 5);
    assert!(alerts.iter().all(|a| a.kind == StuckKind::Repeat));
}

#[test]
fn the_run_is_broken_by_a_different_call_and_starts_again() {
    let mut chain = RepeatChain::new();
    for _ in 0..2 {
        chain.on_event(&call("Grep", r#"{"pattern":"X"}"#));
    }
    assert_eq!(chain.run(), 2);
    assert!(chain
        .on_event(&call("Grep", r#"{"pattern":"Y"}"#))
        .is_none());
    assert_eq!(chain.run(), 1, "different arguments are a different call");
    assert!(chain
        .on_event(&call("Read", r#"{"pattern":"Y"}"#))
        .is_none());
    assert_eq!(
        chain.run(),
        1,
        "a different tool with the same arguments is a different call"
    );
}

#[test]
fn a_run_of_nine_advises_at_three_five_and_eight_and_no_more() {
    let events: Vec<TranscriptEvent> = (0..9)
        .map(|_| call("Bash", r#"{"command":"ls"}"#))
        .collect();
    let runs: Vec<u32> = advisories(&events).iter().map(|a| a.run).collect();
    assert_eq!(runs, vec![3, 5, 8]);
}

#[test]
fn a_run_that_jumps_a_threshold_advises_at_the_highest_one_it_crossed() {
    // Two calls arrive in one batch after the chain is already at 4: the 5 and the
    // batch's own arrival must not produce two messages for one call.
    let mut chain = RepeatChain::new();
    let c = call("Bash", r#"{"command":"ls"}"#);
    for _ in 0..4 {
        chain.on_event(&c);
    }
    let alert = chain.on_event(&c).expect("crossing 5 advises");
    assert_eq!(alert.run, 5);
    assert!(chain.on_event(&c).is_none(), "6 is not a threshold");
}

// MARK: - the four rules from the ticket

#[test]
fn bookkeeping_is_transparent_so_a_loop_cannot_launder_itself() {
    // grep X -> todo_write -> grep X -> todo_write -> grep X is a run of three.
    let alerts = advisories(&[
        call("Grep", r#"{"pattern":"X"}"#),
        call("TodoWrite", r#"{"todos":[]}"#),
        call("Grep", r#"{"pattern":"X"}"#),
        call("TodoWrite", r#"{"todos":[{"a":1}]}"#),
        call("Grep", r#"{"pattern":"X"}"#),
    ]);
    assert_eq!(alerts.len(), 1);
    assert_eq!(alerts[0].run, 3);
    assert_eq!(alerts[0].tool.as_deref(), Some("Grep"));
}

#[test]
fn a_bookkeeping_call_never_starts_a_run_of_its_own() {
    let mut chain = RepeatChain::new();
    for _ in 0..8 {
        assert!(chain
            .on_event(&call("TodoWrite", r#"{"todos":[]}"#))
            .is_none());
    }
    assert_eq!(chain.run(), 0, "a todo write is not a chain");
    assert_eq!(chain.tool(), None);
}

#[test]
fn denied_calls_count_toward_the_run() {
    // The result between two calls is an error every time, which is exactly the loop
    // worth breaking; the chain must not read the verdict.
    let alerts = advisories(&[
        call("Bash", r#"{"command":"rm -rf /"}"#),
        result(false),
        call("Bash", r#"{"command":"rm -rf /"}"#),
        result(false),
        call("Bash", r#"{"command":"rm -rf /"}"#),
        result(false),
    ]);
    assert_eq!(alerts.len(), 1);
    assert_eq!(alerts[0].run, 3);
}

#[test]
fn a_user_prompt_resets_the_chain() {
    let mut chain = RepeatChain::new();
    let c = call("Grep", r#"{"pattern":"X"}"#);
    chain.on_event(&c);
    chain.on_event(&c);
    assert_eq!(chain.run(), 2);
    chain.on_event(&prompt("try something else"));
    assert_eq!(chain.run(), 0);
    assert!(chain.on_event(&c).is_none());
    assert!(
        chain.on_event(&c).is_none(),
        "the run restarts from this turn"
    );
    assert_eq!(chain.run(), 2);
}

#[test]
fn prose_thinking_steps_and_usage_neither_extend_nor_break_a_run() {
    let alerts = advisories(&[
        call("Read", r#"{"file":"a"}"#),
        TranscriptEvent::Assistant {
            step: None,
            text: "let me look again".into(),
        },
        TranscriptEvent::Thinking {
            step: None,
            text: "hm".into(),
        },
        TranscriptEvent::Step {
            step: "req_2".into(),
            model: None,
        },
        TranscriptEvent::Usage {
            step: None,
            usage: Default::default(),
        },
        TranscriptEvent::TurnEnd { reason: None },
        call("Read", r#"{"file":"a"}"#),
        call("Read", r#"{"file":"a"}"#),
    ]);
    assert_eq!(
        alerts.len(),
        1,
        "the run is three despite everything between"
    );
    assert_eq!(alerts[0].run, 3);
}

#[test]
fn chains_are_per_session_and_do_not_pool() {
    let watch = watch_over(&[]);
    let c = call("Grep", r#"{"pattern":"X"}"#);
    // Interleaved, the way two dispatched agents actually run.
    for _ in 0..2 {
        watch.on_transcript("a", [&c]);
        watch.on_transcript("b", [&c]);
    }
    assert_eq!(watch.run_of("a"), 2);
    assert_eq!(watch.run_of("b"), 2);
    assert!(watch.alerts().is_empty(), "neither session reached three");
    watch.on_transcript("a", [&c]);
    assert_eq!(watch.run_of("a"), 3);
    assert_eq!(watch.run_of("b"), 2, "b's chain did not move");
    let alerts = watch.alerts();
    assert_eq!(alerts.len(), 1);
    assert_eq!(alerts[0].0, "a");
}

// MARK: - truncation

#[test]
fn truncation_is_in_the_message_and_never_in_the_comparison() {
    // Two calls whose canonical arguments are identical for the first ARG_HEAD bytes
    // and differ only past it. They are different calls.
    let shared = "z".repeat(ARG_HEAD + 40);
    let one = format!(r#"{{"q":"{shared}A"}}"#);
    let two = format!(r#"{{"q":"{shared}B"}}"#);
    let mut chain = RepeatChain::new();
    chain.on_event(&call("Grep", &one));
    chain.on_event(&call("Grep", &two));
    assert_eq!(
        chain.run(),
        1,
        "a difference past the head is still a difference"
    );

    // And the message a long run does produce quotes only the head.
    let mut chain = RepeatChain::new();
    let mut last = None;
    for _ in 0..5 {
        last = chain.on_event(&call("Grep", &one)).or(last);
    }
    let alert = last.expect("five identical calls advise");
    assert_eq!(alert.run, 5);
    assert!(
        alert.advice.contains('…'),
        "the quoted arguments are cut: {}",
        alert.advice
    );
    let full = canonical_args(&one);
    assert!(
        !alert.advice.contains(&full),
        "the message quotes the head, never the whole argument string"
    );
    assert!(
        alert.advice.contains(&full[..ARG_HEAD]),
        "and it does quote the head"
    );
}

#[test]
fn the_first_threshold_is_generic_and_the_later_ones_name_the_call() {
    let events: Vec<TranscriptEvent> = (0..8)
        .map(|_| call("Bash", r#"{"command":"pnpm test"}"#))
        .collect();
    let alerts = advisories(&events);
    assert_eq!(alerts.len(), 3);
    assert!(
        !alerts[0].advice.contains("Bash") && !alerts[0].advice.contains("pnpm test"),
        "the first nudge names nothing: {}",
        alerts[0].advice
    );
    for alert in &alerts[1..] {
        assert!(alert.advice.contains("Bash"), "{}", alert.advice);
        assert!(alert.advice.contains("pnpm test"), "{}", alert.advice);
        assert!(
            alert.advice.contains(&alert.run.to_string()),
            "{}",
            alert.advice
        );
    }
}

#[test]
fn head_cuts_on_a_character_boundary() {
    let text = "é".repeat(ARG_HEAD);
    let cut = head(&text, ARG_HEAD);
    assert!(cut.ends_with('…'));
    assert!(cut.len() <= ARG_HEAD + '…'.len_utf8());
}

// MARK: - the stall half

fn busy_probe(id: &str) -> ReapProbe {
    ReapProbe {
        id: id.into(),
        cwd: "/tmp".into(),
        cli_session_id: Some(id.into()),
        running: true,
        child_pid: Some(4242),
        activity: SessionActivity::Busy,
        open_tool_call: true,
        last_input_ms: 0,
        last_output_ms: 0,
        output_bytes: 1_000,
        last_busy_ms: 0,
        updated_at: 0,
    }
}

fn sample(probe: &ReapProbe, size: u64) -> StallSample {
    sample_of(probe, Some(size))
}

const MIN: i64 = 60_000;

#[test]
fn a_session_that_is_not_claiming_to_work_is_never_a_stall() {
    let mut probe = busy_probe("s");
    probe.activity = SessionActivity::Idle;
    probe.open_tool_call = false;
    let policy = StallPolicy::default();
    let s = sample(&probe, 10);
    let streak = stall_anchor(&s, 0);
    assert_eq!(
        evaluate_stall(&s, Some(&streak), 60 * MIN, &policy),
        StallVerdict::Moving
    );
}

#[test]
fn waiting_input_is_not_a_stall_because_the_activity_ping_already_said_so() {
    let mut probe = busy_probe("s");
    probe.activity = SessionActivity::WaitingInput;
    probe.open_tool_call = false;
    assert!(!sample(&probe, 10).claims_working());
}

#[test]
fn dormancy_must_be_observed_across_several_sweeps_not_merely_elapsed() {
    let probe = busy_probe("s");
    let s = sample(&probe, 10);
    let policy = StallPolicy::default();
    // One anchor and one follow-up, an hour apart but inside the gap allowance is not
    // possible — so use two sweeps a minute apart and then jump the clock. The point:
    // elapsed time alone must not produce a verdict.
    let mut streak = stall_anchor(&s, 0);
    let mut fired = false;
    // Two observations only, spread across the whole window.
    for now in [5 * MIN] {
        match evaluate_stall(&s, Some(&streak), now, &policy) {
            StallVerdict::Holding(next) => streak = next,
            StallVerdict::Stalled { .. } => fired = true,
            StallVerdict::Moving => panic!("nothing moved"),
        }
    }
    assert!(!fired);
    assert_eq!(streak.quiet_samples, 2);
    // The window is served now, but two observations are still one short.
    match evaluate_stall(&s, Some(&streak), 11 * MIN, &policy) {
        StallVerdict::Stalled { quiet_ms, .. } => {
            assert!(quiet_ms >= policy.quiet_ms);
        }
        other => panic!("the third observation should fire: {other:?}"),
    }
}

#[test]
fn a_sample_gap_re_anchors_rather_than_counting_unwatched_time() {
    let probe = busy_probe("s");
    let s = sample(&probe, 10);
    let policy = StallPolicy::default();
    let streak = StallStreak {
        since_ms: 0,
        output_bytes: s.output_bytes,
        transcript_size_bytes: s.transcript_size_bytes,
        last_sample_ms: 0,
        quiet_samples: 9,
    };
    // A sweep an hour later: nobody was watching, so the nine observations are worth
    // nothing and the streak restarts from now with one.
    match evaluate_stall(&s, Some(&streak), 60 * MIN, &policy) {
        StallVerdict::Holding(next) => {
            assert_eq!(next.quiet_samples, 1);
            assert_eq!(next.since_ms, 60 * MIN);
        }
        other => panic!("a gap must re-anchor, got {other:?}"),
    }
}

#[test]
fn a_growing_transcript_is_work_however_still_the_screen_is() {
    let probe = busy_probe("s");
    let policy = StallPolicy::default();
    let streak = stall_anchor(&sample(&probe, 10), 0);
    let grown = sample(&probe, 11);
    assert_eq!(
        evaluate_stall(&grown, Some(&streak), 5 * MIN, &policy),
        StallVerdict::Moving
    );
}

#[test]
fn output_below_the_floor_is_not_progress() {
    let mut probe = busy_probe("s");
    let policy = StallPolicy::default();
    let streak = stall_anchor(&sample(&probe, 10), 0);
    // A repainting TUI: bytes, but not many. Still dormant.
    probe.output_bytes += policy.output_floor_bytes;
    assert!(matches!(
        evaluate_stall(&sample(&probe, 10), Some(&streak), 5 * MIN, &policy),
        StallVerdict::Holding(_)
    ));
    // A build log: past the floor, and the session is working.
    probe.output_bytes += 1;
    assert_eq!(
        evaluate_stall(&sample(&probe, 10), Some(&streak), 5 * MIN, &policy),
        StallVerdict::Moving
    );
}

#[test]
fn the_stall_verdict_never_reads_input() {
    // juancode-qb5: an idle reaper keyed on pty input killed busy sessions, because a
    // dispatched agent is typed at once and then works for hours. Moving the input
    // clock must change nothing here.
    let mut probe = busy_probe("s");
    let policy = StallPolicy::default();
    let streak = stall_anchor(&sample(&probe, 10), 0);
    let without = evaluate_stall(&sample(&probe, 10), Some(&streak), 11 * MIN, &policy);
    probe.last_input_ms = 11 * MIN;
    let with = evaluate_stall(&sample(&probe, 10), Some(&streak), 11 * MIN, &policy);
    assert_eq!(without, with);
}

#[test]
fn a_sweep_names_a_wedged_session_once_and_then_stays_quiet() {
    let fake = Arc::new(Fake::new(vec![busy_probe("s")]));
    let watch = TestWatch::over(fake.clone());
    // Three sweeps inside the window: holding, holding, then the window is served.
    fake.set_now(0);
    assert!(watch.inner.sweep_once().is_empty());
    fake.set_now(5 * MIN);
    assert!(watch.inner.sweep_once().is_empty());
    fake.set_now(11 * MIN);
    assert_eq!(watch.inner.sweep_once(), vec!["s".to_string()]);
    // Still wedged on the next sweep, but the cooldown holds.
    fake.set_now(14 * MIN);
    assert!(watch.inner.sweep_once().is_empty(), "renotify_ms must hold");
    let alerts = watch.alerts();
    assert_eq!(alerts.len(), 1);
    assert_eq!(alerts[0].1.kind, StuckKind::Stall);
    assert!(alerts[0].1.quiet_ms >= 10 * MIN);
    assert!(
        alerts[0].1.advice.contains("11 min"),
        "{}",
        alerts[0].1.advice
    );
}

#[test]
fn one_sweep_names_at_most_the_cap_and_the_oldest_stall_first() {
    let probes: Vec<ReapProbe> = (0..5).map(|i| busy_probe(&format!("s{i}"))).collect();
    let fake = Arc::new(Fake::new(probes));
    let watch = TestWatch::over(fake.clone());
    for now in [0, 5 * MIN] {
        fake.set_now(now);
        assert!(watch.inner.sweep_once().is_empty());
    }
    fake.set_now(11 * MIN);
    let named = watch.inner.sweep_once();
    assert_eq!(
        named.len(),
        StallPolicy::default().max_alerts_per_sweep,
        "five wedged sessions must not page five times in one second"
    );
}

#[test]
fn a_session_that_goes_away_is_forgotten() {
    let fake = Arc::new(Fake::new(vec![busy_probe("s")]));
    let watch = TestWatch::over(fake.clone());
    let c = call("Grep", r#"{"pattern":"X"}"#);
    watch.inner.on_transcript("s", [&c, &c]);
    assert_eq!(watch.inner.run_of("s"), 2);
    fake.remove("s");
    watch.inner.sweep_once();
    assert_eq!(watch.inner.run_of("s"), 0, "a dead session keeps no chain");
}

// MARK: - test doubles

/// A watch whose alerts are collected instead of sent.
struct TestWatch {
    inner: StuckWatch,
    seen: Arc<StdMutex<Vec<(String, StuckAlert)>>>,
}

impl TestWatch {
    fn over(fake: Arc<Fake>) -> Self {
        let seen: Arc<StdMutex<Vec<(String, StuckAlert)>>> = Arc::new(StdMutex::new(Vec::new()));
        let sink_seen = Arc::clone(&seen);
        let now = Arc::clone(&fake.now);
        let probes = ReaperProbes {
            now_ms: Arc::new(move || now.load(Ordering::Relaxed)),
            descendant_count: Arc::new(|_| 0),
            tree_cpu_time_ms: Arc::new(|_| 0),
            // A transcript that never grows: the sessions under test are wedged.
            transcript_sizes: Arc::new(HashMap::new),
        };
        let inner = StuckWatch::new(
            fake as Arc<dyn SessionsApi>,
            probes,
            StallPolicy::default(),
            Arc::new(move |id: &str, alert: StuckAlert| {
                sink_seen.lock().unwrap().push((id.to_string(), alert));
            }),
        );
        Self { inner, seen }
    }

    fn alerts(&self) -> Vec<(String, StuckAlert)> {
        self.seen.lock().unwrap().clone()
    }

    fn on_transcript<'a>(&self, id: &str, events: impl IntoIterator<Item = &'a TranscriptEvent>) {
        self.inner.on_transcript(id, events);
    }

    fn run_of(&self, id: &str) -> u32 {
        self.inner.run_of(id)
    }
}

/// The same shape for the repeat tests, which need no sessions at all.
fn watch_over(probes: &[ReapProbe]) -> TestWatch {
    TestWatch::over(Arc::new(Fake::new(probes.to_vec())))
}

struct Fake {
    probes: StdMutex<Vec<ReapProbe>>,
    now: Arc<AtomicI64>,
    events: broadcast::Sender<crate::registry::SessionEvent>,
}

impl Fake {
    fn new(probes: Vec<ReapProbe>) -> Self {
        Self {
            probes: StdMutex::new(probes),
            now: Arc::new(AtomicI64::new(0)),
            events: broadcast::channel(16).0,
        }
    }

    fn set_now(&self, ms: i64) {
        self.now.store(ms, Ordering::Relaxed);
    }

    fn remove(&self, id: &str) {
        self.probes.lock().unwrap().retain(|p| p.id != id);
    }
}

impl SessionsApi for Fake {
    fn ids(&self) -> Vec<String> {
        self.probes
            .lock()
            .unwrap()
            .iter()
            .map(|p| p.id.clone())
            .collect()
    }

    fn reap_probe(&self, id: &str) -> Option<ReapProbe> {
        self.probes
            .lock()
            .unwrap()
            .iter()
            .find(|p| p.id == id)
            .cloned()
    }

    fn is_running(&self, id: &str) -> bool {
        self.reap_probe(id).is_some_and(|p| p.running)
    }

    fn subscribe(&self) -> broadcast::Receiver<crate::registry::SessionEvent> {
        self.events.subscribe()
    }

    // Nothing below is on the stuck detector's path. It reads `ids` and `reap_probe`,
    // and it writes nothing at all.
    fn meta(&self, _id: &str) -> Option<SessionMeta> {
        unimplemented!("the stuck watch reads `reap_probe`, not `meta`")
    }
    fn activity(&self, _id: &str) -> Option<SessionActivity> {
        unimplemented!()
    }
    fn snapshot(&self, _id: &str) -> Option<Snapshot> {
        unimplemented!()
    }
    fn grid(&self, _id: &str) -> Option<(u16, u16)> {
        unimplemented!()
    }
    fn grid_owner(&self, _id: &str) -> Option<crate::grid::ClientId> {
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
    fn attach(
        &self,
        _id: &str,
        _owner: crate::grid::ClientId,
        _cols: u16,
        _rows: u16,
    ) -> Result<Attached, StateError> {
        unimplemented!()
    }
    fn reactivate(
        &self,
        _id: &str,
        _owner: crate::grid::ClientId,
        _cols: u16,
        _rows: u16,
    ) -> Result<Option<Attached>, StateError> {
        unimplemented!()
    }
    fn set_skip_permissions(
        &self,
        _id: &str,
        _skip: bool,
        _owner: crate::grid::ClientId,
        _cols: u16,
        _rows: u16,
    ) -> Result<Attached, StateError> {
        unimplemented!()
    }
    fn input(&self, _id: &str, _data: &[u8]) -> Result<(), StateError> {
        unimplemented!()
    }
    fn queue(&self, _id: &str) -> Vec<QueuedMessage> {
        Vec::new()
    }
    fn queue_message(&self, _id: &str, _text: &str) -> Result<Option<QueuedMessage>, StateError> {
        unimplemented!()
    }
    fn dequeue_message(&self, _id: &str, _message_id: &str) -> Result<bool, StateError> {
        unimplemented!()
    }
    fn resize(
        &self,
        _id: &str,
        _owner: crate::grid::ClientId,
        _cols: u16,
        _rows: u16,
    ) -> ResizeOutcome {
        unimplemented!()
    }
    fn release_client(&self, _owner: crate::grid::ClientId) {}
    fn kill(&self, _id: &str) -> Result<(), StateError> {
        unreachable!("the stuck detector notifies; it never kills")
    }
    fn on_transcript(&self, _id: &str, _records: &[TranscriptRecord]) {}
    fn flush_all(&self) -> usize {
        0
    }
    fn mark_dormant(&self, _id: &str) -> bool {
        unreachable!("the stuck detector notifies; it never sleeps a session")
    }
    fn publish_stuck(&self, _id: &str, _alert: StuckAlert) {
        // The tests read the sink directly; the bus is the daemon's business.
    }
}

/// Keeps `Source` used: the fake's `on_transcript` takes records, and a reader of this
/// file should see the shape one has.
#[test]
fn a_record_is_what_the_pump_hands_the_registry() {
    let record = TranscriptRecord {
        session: "s".into(),
        source: Source::ClaudeJsonl,
        seq: 1,
        at_ms: None,
        turn: None,
        event: call("Grep", r#"{"pattern":"X"}"#),
    };
    let mut chain = RepeatChain::new();
    assert!(chain.on_event(&record.event).is_none());
    assert_eq!(chain.run(), 1);
}
