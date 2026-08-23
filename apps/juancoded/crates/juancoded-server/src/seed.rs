//! Verified delivery of a create's `initialInput` — the paste, then the Enter.
//!
//! A dispatch arrives as one `create` frame carrying the prompt, and the session it
//! creates is spawned before its CLI has painted anything. Writing the prompt into
//! that pty is not delivering it: without a submitting Enter the agent sits with the
//! prompt typed and unsent, so nothing runs, no activity edge fires, and a mirror
//! that only learns of a session on its first activity never learns of it at all.
//!
//! Appending a newline is the tempting fix and it is the wrong one. A CR that arrives
//! inside a still-open bracketed paste is read as a literal newline rather than
//! submit, and a CR that arrives before the input box is interactive is read by
//! nobody. So this is the same three-step engine `Session.autoSubmit` runs on the
//! Swift side: wait for the screen to settle, paste (bracketed, when the CLI reads
//! those markers), confirm the paste is actually on screen, and only then send a lone
//! Enter and confirm the submission.
//!
//! It differs from the Swift engine in one place, and deliberately. Swift's land
//! check is "the prompt is visible in the grid", which is true of every real TUI and
//! false of a child that does not echo — a line-oriented stand-in, `cat`, anything
//! not painting an input box. Swift gives up there and never sends the Enter. Here a
//! screen that has not moved at all since the paste is read as "this child echoes
//! nothing", and the Enter goes anyway with the submission confirmed against the
//! child's own output instead. What is never done is the thing the Swift bugs
//! (juancode-8sta, juancode-g4id) were about: a re-paste without positive evidence
//! that the first one was lost.

use std::sync::Arc;
use std::time::Duration;

use juancoded_core::model::SessionActivity;
use juancoded_state::SessionsApi;
use tracing::{debug, warn};

/// Where a delivery ended up. `verified_land` is whether the prompt was actually
/// *seen* in the grid before the Enter, so a caller can tell a fully verified
/// delivery from one that trusted the child's output instead.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SeedOutcome {
    Submitted { verified_land: bool },
    Failed { reason: String },
}

impl SeedOutcome {
    pub fn is_submitted(&self) -> bool {
        matches!(self, Self::Submitted { .. })
    }

    fn failed(reason: impl Into<String>) -> Self {
        Self::Failed {
            reason: reason.into(),
        }
    }
}

/// Timing budgets for one delivery. Mirrors the `Seed` block in
/// `apps/native/Sources/JuancodeCore/Session.swift`; a test overrides them so a case
/// about the state machine does not cost the CLI boot window.
#[derive(Debug, Clone, Copy)]
pub struct SeedTiming {
    /// Cap on waiting for the TUI to settle before pasting (MCP startup can be slow);
    /// we paste anyway once it elapses.
    pub ready_max_ms: u64,
    pub ready_poll_ms: u64,
    /// Per-round budget for the paste to show up on screen.
    pub land_ms: u64,
    /// Total budget for the paste to land, across re-pastes.
    pub land_deadline_ms: u64,
    /// Gap between the paste's end marker and the submitting Enter, so the CR is not
    /// swallowed as a literal newline by a still-open paste.
    pub submit_settle_ms: u64,
    /// Per-attempt budget to confirm the Enter submitted.
    pub submit_ms: u64,
    pub poll_ms: u64,
    /// Enter attempts before the delivery is called failed.
    pub max_enter_attempts: usize,
    /// Hard cap on pastes for one delivery, re-pastes included. Every one of them
    /// needs evidence the previous one was lost; this is the backstop for the case
    /// where that evidence is wrong.
    pub max_pastes: usize,
    /// Rows of the bottom of the screen treated as the input box.
    pub input_rows: usize,
}

impl Default for SeedTiming {
    fn default() -> Self {
        Self {
            ready_max_ms: 45_000,
            ready_poll_ms: 200,
            land_ms: 2_000,
            land_deadline_ms: 24_000,
            submit_settle_ms: 200,
            submit_ms: 4_000,
            poll_ms: 150,
            max_enter_attempts: 3,
            max_pastes: 3,
            input_rows: 16,
        }
    }
}

/// Deliver `text` into a freshly created session and confirm it was submitted.
///
/// Runs as its own task: the create reply must not wait on a CLI's boot window.
pub async fn deliver_seed(
    sessions: Arc<dyn SessionsApi>,
    id: &str,
    text: &str,
    timing: SeedTiming,
) -> SeedOutcome {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return SeedOutcome::Submitted {
            verified_land: true,
        };
    }
    let bracketed = sessions
        .meta(id)
        .map(|m| juancoded_core::provider::Providers::spec(m.provider).bracketed_paste)
        .unwrap_or(true);
    let signature = signature(trimmed);
    let payload = paste_bytes(trimmed, bracketed);

    // 1) Wait for the screen to stop changing, so the input box exists before we
    // paste. Trusting the first output byte instead is what the Swift engine used to
    // do: that byte is the startup banner, seconds before the box is interactive.
    let settled = wait_for_stable_screen(&sessions, id, timing).await;
    debug!(session = id, settled, "seed: screen settle");
    if !sessions.is_running(id) {
        return SeedOutcome::failed("the session exited during startup");
    }
    // A session that is already working was seeded by something else (or started
    // itself). Checked once and only here: our own paste can flip the detector to
    // busy, and treating that as submitted is what used to skip the Enter.
    if sessions.activity(id) == Some(SessionActivity::Busy) {
        return SeedOutcome::Submitted {
            verified_land: false,
        };
    }

    // 2) Paste, then confirm it landed. A round that ends with the screen exactly as
    // it was before the paste is a child that echoes nothing, not a lost paste, and
    // re-pasting into it would deliver the prompt twice with nothing to show for it.
    let mut pastes = 0usize;
    let mut elapsed = 0u64;
    let mut landed = None;
    while elapsed < timing.land_deadline_ms && pastes < timing.max_pastes {
        if !sessions.is_running(id) {
            return SeedOutcome::failed("the session exited before the prompt was typed");
        }
        if seed_landed(&sessions, id, &signature) {
            landed = Some(true);
            break;
        }
        let before = screen(&sessions, id);
        pastes += 1;
        debug!(session = id, attempt = pastes, "seed: paste");
        if let Err(e) = sessions.input(id, &payload) {
            return SeedOutcome::failed(format!("the pty refused the paste: {e}"));
        }
        if wait_until(timing.land_ms, timing.poll_ms, || {
            seed_landed(&sessions, id, &signature)
        })
        .await
        {
            landed = Some(true);
            break;
        }
        elapsed += timing.land_ms;
        if screen(&sessions, id) == before {
            debug!(session = id, "seed: nothing echoes, submitting unverified");
            landed = Some(false);
            break;
        }
    }
    let verified_land = match landed {
        Some(v) => v,
        None => {
            return SeedOutcome::failed(format!(
                "the prompt never appeared on screen after {}s",
                timing.land_deadline_ms / 1_000
            ))
        }
    };

    // 3) Submit, separately and only now, then confirm it went through. The settle
    // gap is what keeps the CR out of the paste it would otherwise be part of.
    sleep_ms(timing.submit_settle_ms).await;
    for attempt in 1..=timing.max_enter_attempts {
        if !sessions.is_running(id) {
            return SeedOutcome::failed("the session exited before the prompt was submitted");
        }
        let at_enter = screen(&sessions, id);
        debug!(session = id, attempt, "seed: enter");
        if let Err(e) = sessions.input(id, b"\r") {
            return SeedOutcome::failed(format!("the pty refused the Enter: {e}"));
        }
        let submitted = wait_until(timing.submit_ms, timing.poll_ms, || {
            if sessions.activity(id) == Some(SessionActivity::Busy) {
                return true;
            }
            if verified_land {
                // The prompt leaving the box is the submission, and only the box
                // counts: a transcript above it keeps the text on screen forever.
                let footer = bottom(&sessions, id, timing.input_rows);
                !region_contains(&footer, &signature) && !shows_collapsed_paste(&footer)
            } else {
                // Nothing echoed the paste, so the only honest signal is the child
                // reacting at all.
                screen(&sessions, id) != at_enter
            }
        })
        .await;
        if submitted {
            return SeedOutcome::Submitted { verified_land };
        }
    }
    SeedOutcome::failed("the prompt stayed in the input box; it was never submitted")
}

/// The bytes one paste is made of: bracketed for a CLI that reads the markers, plain
/// for one that does not. Never a trailing CR — the Enter is its own write, after the
/// landing is confirmed, which is the whole point of the engine.
pub fn paste_bytes(text: &str, bracketed: bool) -> Vec<u8> {
    let mut out = Vec::with_capacity(text.len() + 12);
    if bracketed {
        out.extend_from_slice(b"\x1b[200~");
    }
    out.extend_from_slice(text.as_bytes());
    if bracketed {
        out.extend_from_slice(b"\x1b[201~");
    }
    out
}

/// A distinctive, normalized token from the start of `prompt`, used to find it in —
/// or confirm it has left — the input box. Port of
/// `InitialPromptDelivery.signature`: the first non-empty line, because the box
/// reflows anything longer, and a short prefix so it stays inside one wrapped row.
pub fn signature(prompt: &str) -> String {
    signature_with_len(prompt, 24)
}

fn signature_with_len(prompt: &str, max_len: usize) -> String {
    let Some(line) = prompt.split(['\n', '\r']).find(|l| !l.trim().is_empty()) else {
        return String::new();
    };
    normalize(line).chars().take(max_len).collect()
}

/// True if `signature` appears in `region`. Both sides are whitespace-collapsed and
/// lowercased first, so box borders and padding do not defeat the match. An empty
/// signature never matches: there is nothing distinctive to look for.
pub fn region_contains(region: &str, signature: &str) -> bool {
    let sig = normalize(signature);
    if sig.is_empty() {
        return false;
    }
    normalize(region).contains(&sig)
}

/// Claude collapses a large or multi-line bracketed paste into a chip
/// (`[Pasted text #1 +29 lines]`) instead of echoing the text, so the signature never
/// appears even though the paste is sitting in the box. That chip is a landing.
pub fn shows_collapsed_paste(region: &str) -> bool {
    normalize(region).contains("pasted text")
}

/// Lowercase, collapse every run of whitespace to one space, trim the ends.
pub fn normalize(s: &str) -> String {
    s.to_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Whether the seed is detectably on screen. Searched across the whole grid rather
/// than the footer: a tall multi-line prompt renders taller than the input box, so
/// its first line scrolls above the bottom rows, and a footer-scoped check missed it
/// and never sent the Enter. Safe here because a freshly settled session shows only
/// its banner and an empty box.
fn seed_landed(sessions: &Arc<dyn SessionsApi>, id: &str, signature: &str) -> bool {
    let screen = screen(sessions, id);
    region_contains(&screen, signature) || shows_collapsed_paste(&screen)
}

fn screen(sessions: &Arc<dyn SessionsApi>, id: &str) -> String {
    sessions.snapshot(id).map(|s| s.text()).unwrap_or_default()
}

fn bottom(sessions: &Arc<dyn SessionsApi>, id: &str, rows: usize) -> String {
    sessions
        .snapshot(id)
        .map(|s| s.bottom_text(rows))
        .unwrap_or_default()
}

/// Poll until the rendered screen stops changing (two identical non-empty frames) or
/// the budget elapses. A CLI-agnostic "the TUI is up" signal; the return says whether
/// it settled, so a caller can tell ready from still-streaming.
async fn wait_for_stable_screen(
    sessions: &Arc<dyn SessionsApi>,
    id: &str,
    timing: SeedTiming,
) -> bool {
    let mut elapsed = 0;
    let mut prev = screen(sessions, id);
    while elapsed < timing.ready_max_ms {
        sleep_ms(timing.ready_poll_ms).await;
        elapsed += timing.ready_poll_ms;
        // A session that died on the way up is not a slow one: waiting out the whole
        // window would delay the report of a failure that is already decided.
        if !sessions.is_running(id) {
            return false;
        }
        let cur = screen(sessions, id);
        if !cur.trim().is_empty() && cur == prev {
            return true;
        }
        prev = cur;
    }
    false
}

async fn wait_until(max_ms: u64, poll_ms: u64, cond: impl Fn() -> bool) -> bool {
    if cond() {
        return true;
    }
    let mut elapsed = 0;
    while elapsed < max_ms {
        sleep_ms(poll_ms).await;
        elapsed += poll_ms;
        if cond() {
            return true;
        }
    }
    false
}

async fn sleep_ms(ms: u64) {
    if ms > 0 {
        tokio::time::sleep(Duration::from_millis(ms)).await;
    }
}

/// Log a finished delivery. A failure is never silent: it says which session, and
/// why, on the way to the client that asked for the create.
pub fn log_outcome(id: &str, outcome: &SeedOutcome) {
    match outcome {
        SeedOutcome::Submitted { verified_land } => {
            debug!(session = id, verified_land, "seed: submitted")
        }
        SeedOutcome::Failed { reason } => {
            warn!(session = id, reason = %reason, "seed: never submitted")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use juancoded_core::model::{ProviderId, SessionMeta, SessionStatus};
    use juancoded_state::registry::{
        AdoptRequest, Attached, CreateRequest, SessionEvent, StateError,
    };
    use juancoded_state::{ClientId, QueuedMessage, ResizeOutcome};
    use juancoded_vt::{Snapshot, TerminalModel};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Mutex;
    use tokio::sync::broadcast;

    fn fast() -> SeedTiming {
        SeedTiming {
            ready_max_ms: 1_000,
            ready_poll_ms: 20,
            land_ms: 300,
            land_deadline_ms: 900,
            submit_settle_ms: 10,
            submit_ms: 600,
            poll_ms: 10,
            ..SeedTiming::default()
        }
    }

    #[test]
    fn a_signature_is_the_first_non_empty_line_normalized() {
        assert_eq!(signature("  \n\n Fix The Bug \n more"), "fix the bug");
        assert_eq!(signature_with_len("abcdefghij", 4), "abcd");
        assert_eq!(signature("   \n  "), "");
        // An empty signature matches nothing, so a caller never reads it as landed.
        assert!(!region_contains("anything at all", ""));
    }

    #[test]
    fn a_landing_survives_the_box_reflowing_and_padding() {
        assert!(region_contains("│  fix   the\n bug  │", "fix the bug"));
        assert!(shows_collapsed_paste("> [Pasted text #1 +29 lines]"));
        assert!(!shows_collapsed_paste("> nothing pasted here"));
    }

    #[test]
    fn a_paste_carries_no_enter_of_its_own() {
        let bytes = paste_bytes("one\ntwo", true);
        assert_eq!(bytes, b"\x1b[200~one\ntwo\x1b[201~".to_vec());
        // The embedded newline stays inside the paste and no CR is appended, so a
        // multi-line prompt cannot submit itself line by line.
        assert!(!bytes.contains(&b'\r'));
        assert_eq!(paste_bytes("plain", false), b"plain".to_vec());
    }

    /// A session whose whole observable behaviour is scripted: what it echoes, when
    /// it exits, and every byte it was written.
    ///
    /// A real pty is in the end-to-end case below and in the conformance suite. It is
    /// the wrong instrument for "exactly once", where the question is which bytes the
    /// child received in which order, and the answer must not depend on when a child
    /// process happened to be scheduled.
    struct FakeChild {
        writes: Mutex<Vec<Vec<u8>>>,
        model: Mutex<TerminalModel>,
        /// Whether the child paints what it is sent, the way a TUI's input box does.
        echoes: bool,
        running: AtomicBool,
        busy: AtomicBool,
        events: broadcast::Sender<SessionEvent>,
    }

    impl FakeChild {
        fn new(echoes: bool) -> Arc<Self> {
            let mut model = TerminalModel::new(80, 24, 100);
            // A settled banner, so the readiness wait has something stable to see.
            model.feed(b"fake-agent ready\r\n");
            let (events, _) = broadcast::channel(16);
            Arc::new(Self {
                writes: Mutex::new(Vec::new()),
                model: Mutex::new(model),
                echoes,
                running: AtomicBool::new(true),
                busy: AtomicBool::new(false),
                events,
            })
        }

        fn written(&self) -> Vec<Vec<u8>> {
            self.writes.lock().unwrap().clone()
        }

        /// Every byte the child was sent, in order, as one string.
        fn stream(&self) -> String {
            String::from_utf8_lossy(&self.written().concat()).into_owned()
        }

        fn api(self: &Arc<Self>) -> Arc<dyn SessionsApi> {
            self.clone()
        }
    }

    impl SessionsApi for FakeChild {
        fn input(&self, _id: &str, data: &[u8]) -> Result<(), StateError> {
            self.writes.lock().unwrap().push(data.to_vec());
            let mut model = self.model.lock().unwrap();
            if data == b"\r" {
                // Submitting clears the box and the child answers, which is what both
                // of the engine's submission signals are looking at.
                model.feed(b"\x1b[2J\x1b[Hthe child ran its turn\r\n");
            } else if self.echoes {
                model.feed(data);
                model.feed(b"\r\n");
            }
            Ok(())
        }

        fn snapshot(&self, _id: &str) -> Option<Snapshot> {
            Some(self.model.lock().unwrap().snapshot())
        }

        fn is_running(&self, _id: &str) -> bool {
            self.running.load(Ordering::Relaxed)
        }

        fn activity(&self, _id: &str) -> Option<SessionActivity> {
            Some(if self.busy.load(Ordering::Relaxed) {
                SessionActivity::Busy
            } else {
                SessionActivity::Idle
            })
        }

        fn meta(&self, id: &str) -> Option<SessionMeta> {
            let mut meta = SessionMeta::new(
                id.into(),
                ProviderId::Claude,
                "/tmp".into(),
                "fake".into(),
                0,
                false,
            );
            meta.status = SessionStatus::Running;
            Some(meta)
        }

        // Nothing below is on the delivery path; a fake that pretended otherwise
        // would be lying about what this test covers.
        fn subscribe(&self) -> broadcast::Receiver<SessionEvent> {
            self.events.subscribe()
        }
        fn ids(&self) -> Vec<String> {
            vec!["fake".into()]
        }
        fn grid(&self, _id: &str) -> Option<(u16, u16)> {
            Some((80, 24))
        }
        fn grid_owner(&self, _id: &str) -> Option<ClientId> {
            None
        }
        fn create(&self, _req: CreateRequest) -> Result<SessionMeta, StateError> {
            unimplemented!("the fake is handed an already-created session")
        }
        fn adopt_external(&self, _req: AdoptRequest) -> Result<Option<SessionMeta>, StateError> {
            unimplemented!()
        }
        fn attach(
            &self,
            _id: &str,
            _o: ClientId,
            _c: u16,
            _r: u16,
        ) -> Result<Attached, StateError> {
            unimplemented!()
        }
        fn reactivate(
            &self,
            _id: &str,
            _o: ClientId,
            _c: u16,
            _r: u16,
        ) -> Result<Option<Attached>, StateError> {
            unimplemented!()
        }
        fn set_skip_permissions(
            &self,
            _id: &str,
            _skip: bool,
            _o: ClientId,
            _c: u16,
            _r: u16,
        ) -> Result<Attached, StateError> {
            unimplemented!()
        }
        fn queue(&self, _id: &str) -> Vec<QueuedMessage> {
            Vec::new()
        }
        fn queue_message(
            &self,
            _id: &str,
            _text: &str,
        ) -> Result<Option<QueuedMessage>, StateError> {
            unimplemented!()
        }
        fn dequeue_message(&self, _id: &str, _message_id: &str) -> Result<bool, StateError> {
            unimplemented!()
        }
        fn resize(&self, _id: &str, _o: ClientId, _c: u16, _r: u16) -> ResizeOutcome {
            unimplemented!()
        }
        fn release_client(&self, _owner: ClientId) {}
        fn kill(&self, _id: &str) -> Result<(), StateError> {
            self.running.store(false, Ordering::Relaxed);
            Ok(())
        }
    }

    #[tokio::test]
    async fn a_prompt_with_no_trailing_newline_is_pasted_then_submitted_once() {
        let child = FakeChild::new(true);
        let outcome = deliver_seed(child.api(), "fake", "fix the failing test", fast()).await;
        assert_eq!(
            outcome,
            SeedOutcome::Submitted {
                verified_land: true
            }
        );

        // The shape of the delivery is the guarantee: one paste, one Enter, in that
        // order, and the Enter is not part of the paste.
        let writes = child.written();
        assert_eq!(writes.len(), 2, "{:?}", child.stream());
        assert_eq!(writes[0], paste_bytes("fix the failing test", true));
        assert_eq!(writes[1], b"\r".to_vec());
        assert_eq!(child.stream().matches("fix the failing test").count(), 1);
    }

    #[tokio::test]
    async fn a_multi_line_prompt_goes_in_as_one_paste_with_the_enter_last() {
        let child = FakeChild::new(true);
        let prompt = "first line\nsecond line\nthird line";
        let outcome = deliver_seed(child.api(), "fake", prompt, fast()).await;
        assert!(outcome.is_submitted(), "{outcome:?}");

        let writes = child.written();
        assert_eq!(writes.len(), 2, "{:?}", child.stream());
        // One paste holding all three lines: nothing submitted line by line, because
        // the only CR in the stream is the last byte of the last write.
        assert_eq!(writes[0], paste_bytes(prompt, true));
        assert_eq!(writes[1], b"\r".to_vec());
        assert_eq!(child.stream().matches('\r').count(), 1);
    }

    #[tokio::test]
    async fn a_child_that_echoes_nothing_is_still_submitted_exactly_once() {
        // The dispatch case that used to stall: nothing paints the paste back, so a
        // land check alone would wait out its deadline and never send the Enter.
        let child = FakeChild::new(false);
        let outcome = deliver_seed(child.api(), "fake", "run the suite", fast()).await;
        assert_eq!(
            outcome,
            SeedOutcome::Submitted {
                verified_land: false
            }
        );
        let writes = child.written();
        assert_eq!(writes.len(), 2, "{:?}", child.stream());
        // Still one paste: a silent screen is not evidence the paste was lost, so it
        // is never re-sent.
        assert_eq!(writes[0], paste_bytes("run the suite", true));
        assert_eq!(writes[1], b"\r".to_vec());
    }

    #[tokio::test]
    async fn a_session_that_died_before_the_paste_fails_loudly() {
        let child = FakeChild::new(true);
        child.running.store(false, Ordering::Relaxed);
        let outcome = deliver_seed(child.api(), "fake", "never arrives", fast()).await;
        match outcome {
            SeedOutcome::Failed { reason } => assert!(reason.contains("exited"), "{reason}"),
            other => panic!("a dead session must not report a delivery: {other:?}"),
        }
        assert!(
            child.written().is_empty(),
            "nothing is written to a dead pty"
        );
    }

    #[tokio::test]
    async fn whitespace_is_not_a_prompt_and_writes_nothing() {
        let child = FakeChild::new(true);
        let outcome = deliver_seed(child.api(), "fake", "   \n  ", fast()).await;
        assert_eq!(
            outcome,
            SeedOutcome::Submitted {
                verified_land: true
            }
        );
        assert!(child.written().is_empty());
    }

    #[tokio::test]
    async fn a_session_already_working_is_left_alone() {
        let child = FakeChild::new(true);
        child.busy.store(true, Ordering::Relaxed);
        let outcome = deliver_seed(child.api(), "fake", "would be a second turn", fast()).await;
        assert!(outcome.is_submitted(), "{outcome:?}");
        assert!(
            child.written().is_empty(),
            "a busy session is not pasted into"
        );
    }

    /// The same delivery against a real pty and a real state tree. `/bin/cat` stands
    /// in for the CLI: the line discipline echoes the paste, so the land check has
    /// something to see, and the CR makes `cat` answer.
    #[tokio::test]
    async fn a_real_pty_receives_the_prompt_and_the_enter() {
        let sessions = crate::testing::sessions();
        let id = sessions
            .create(CreateRequest {
                provider: ProviderId::Claude,
                cwd: std::env::temp_dir().to_string_lossy().into(),
                cols: 80,
                rows: 24,
                skip_permissions: false,
                model: None,
                dispatch_id: None,
                owner: 1,
            })
            .expect("the test tree spawns")
            .id;
        let timing = SeedTiming {
            ready_max_ms: 1_500,
            ready_poll_ms: 50,
            land_ms: 1_000,
            land_deadline_ms: 3_000,
            submit_settle_ms: 50,
            submit_ms: 2_000,
            poll_ms: 50,
            ..SeedTiming::default()
        };
        let outcome = deliver_seed(sessions.clone(), &id, "a seeded prompt", timing).await;
        assert!(outcome.is_submitted(), "{outcome:?}");
        // `cat` only writes a line back once it has been submitted, so its copy under
        // the echoed one is the Enter's receipt. It arrives after the delivery reports
        // done, hence the wait rather than a bare read.
        let echoed_back = wait_until(3_000, 50, || {
            screen(&sessions, &id).matches("a seeded prompt").count() >= 2
        })
        .await;
        assert!(
            echoed_back,
            "the Enter never reached cat: {:?}",
            screen(&sessions, &id)
        );
        let _ = sessions.kill(&id);
    }
}
