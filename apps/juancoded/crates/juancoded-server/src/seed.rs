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
///
/// The two failures are separate because one caller cannot treat them alike. A queued
/// message is returned to its queue only when the engine can prove it typed nothing,
/// and re-queueing a payload that may already be sitting in the agent's box is how
/// this area has shipped duplicate pastes before. So the split is by evidence, not by
/// severity: [`Self::Refused`] is exactly the case where no write ever succeeded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SeedOutcome {
    Submitted {
        verified_land: bool,
    },
    /// Stopped before any byte reached the pty. Nothing is on screen that was not
    /// there before, so a caller may safely act as though the delivery never started.
    Refused {
        reason: String,
    },
    /// Bytes went out and the delivery still did not finish. Whatever they put on
    /// screen is still there, so a caller must not assume a clean slate.
    Failed {
        reason: String,
    },
}

impl SeedOutcome {
    pub fn is_submitted(&self) -> bool {
        matches!(self, Self::Submitted { .. })
    }

    /// The reason a delivery did not submit, whichever way it failed.
    pub fn reason(&self) -> Option<&str> {
        match self {
            Self::Submitted { .. } => None,
            Self::Refused { reason } | Self::Failed { reason } => Some(reason),
        }
    }

    /// Classify a stop by the one thing that decides it: whether a write has already
    /// succeeded for this delivery.
    fn stopped(wrote: bool, reason: impl Into<String>) -> Self {
        let reason = reason.into();
        if wrote {
            Self::Failed { reason }
        } else {
            Self::Refused { reason }
        }
    }
}

/// What the engine may assume about the session before it pastes.
///
/// The difference is entirely about how to read a session that is already busy, and
/// getting it backwards is silent: it reports a delivery that never typed anything.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Precondition {
    /// A session that was just spawned. Wait out the CLI's boot window, and read an
    /// already-busy session as one something else has already seeded.
    Booting,
    /// A session that has been up for a while and is between turns. It settled long
    /// ago, so a busy session here is not evidence of a delivery that already
    /// happened, it is a turn in progress: pasting into it would interleave this text
    /// with whatever the agent is doing, so the delivery is refused instead.
    LiveIdle,
}

/// Timing budgets for one delivery. Mirrors the `Seed` block in
/// `apps/native/Sources/JuancodeCore/Session.swift`; a test overrides them so a case
/// about the state machine does not cost the CLI boot window.
#[derive(Debug, Clone, Copy)]
pub struct SeedTiming {
    /// Cap on waiting for the TUI to settle before pasting (MCP startup can be slow);
    /// we paste anyway once it elapses.
    pub ready_max_ms: u64,
    /// The same wait for a session that is already up, and much shorter because it is
    /// waiting for something else. There is no boot to sit through: the only thing that
    /// could still be moving is the tail of the last turn.
    pub live_settle_ms: u64,
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
            live_settle_ms: 2_000,
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
    deliver_text(sessions, id, text, timing, Precondition::Booting).await
}

/// The engine itself: one paste, one verified Enter, into a session in the state
/// `precondition` describes.
pub async fn deliver_text(
    sessions: Arc<dyn SessionsApi>,
    id: &str,
    text: &str,
    timing: SeedTiming,
    precondition: Precondition,
) -> SeedOutcome {
    // Nothing has been written yet, and every stop from here reads this to say whether
    // it may be treated as "the delivery never started".
    let mut wrote = false;
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
    let settled = wait_for_stable_screen(&sessions, id, timing, precondition).await;
    debug!(session = id, settled, "seed: screen settle");
    if !sessions.is_running(id) {
        return SeedOutcome::stopped(wrote, "the session exited during startup");
    }
    // Checked once and only here: our own paste can flip the detector to busy, and
    // treating that as submitted is what used to skip the Enter.
    if sessions.activity(id) == Some(SessionActivity::Busy) {
        match precondition {
            // A session that is already working was seeded by something else (or
            // started itself).
            Precondition::Booting => {
                return SeedOutcome::Submitted {
                    verified_land: false,
                }
            }
            // A session that has been up and is now busy is mid-turn. Refusing hands
            // the text back to whoever queued it, which is the only answer that does
            // not either interleave it or lose it.
            Precondition::LiveIdle => {
                return SeedOutcome::stopped(wrote, "the session is in the middle of a turn")
            }
        }
    }

    // 2) Paste, then confirm it landed. A round that ends with the screen exactly as
    // it was before the paste is a child that echoes nothing, not a lost paste, and
    // re-pasting into it would deliver the prompt twice with nothing to show for it.
    let mut pastes = 0usize;
    let mut elapsed = 0u64;
    let mut landed = None;
    while elapsed < timing.land_deadline_ms && pastes < timing.max_pastes {
        if !sessions.is_running(id) {
            return SeedOutcome::stopped(wrote, "the session exited before the prompt was typed");
        }
        if seed_landed(&sessions, id, &signature) {
            landed = Some(true);
            break;
        }
        let before = screen(&sessions, id);
        pastes += 1;
        debug!(session = id, attempt = pastes, "seed: paste");
        if let Err(e) = sessions.input(id, &payload) {
            return SeedOutcome::stopped(wrote, format!("the pty refused the paste: {e}"));
        }
        wrote = true;
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
            return SeedOutcome::stopped(
                wrote,
                format!(
                    "the prompt never appeared on screen after {}s",
                    timing.land_deadline_ms / 1_000
                ),
            )
        }
    };

    // 3) Submit, separately and only now, then confirm it went through. The settle
    // gap is what keeps the CR out of the paste it would otherwise be part of.
    sleep_ms(timing.submit_settle_ms).await;
    for attempt in 1..=timing.max_enter_attempts {
        if !sessions.is_running(id) {
            return SeedOutcome::stopped(
                wrote,
                "the session exited before the prompt was submitted",
            );
        }
        let at_enter = screen(&sessions, id);
        debug!(session = id, attempt, "seed: enter");
        if let Err(e) = sessions.input(id, b"\r") {
            return SeedOutcome::stopped(wrote, format!("the pty refused the Enter: {e}"));
        }
        wrote = true;
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
    SeedOutcome::stopped(
        wrote,
        "the prompt stayed in the input box; it was never submitted",
    )
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

/// Poll until the rendered screen stops changing, or the budget elapses. The return
/// says whether it settled, so a caller can tell ready from still-streaming.
///
/// A blank screen counts as settled for a live session and does not for a booting one,
/// and that difference is the whole reason the precondition is a parameter here. On the
/// way up, blank means the CLI has not painted its banner yet, so waiting is right. On a
/// session that has been up for an hour, blank is an ordinary resting state — a CLI that
/// just cleared for the next turn — and treating it as "not ready yet" is how a queued
/// message came to sit unsent for the length of a boot window that had already happened.
async fn wait_for_stable_screen(
    sessions: &Arc<dyn SessionsApi>,
    id: &str,
    timing: SeedTiming,
    precondition: Precondition,
) -> bool {
    let (budget, needs_paint) = match precondition {
        Precondition::Booting => (timing.ready_max_ms, true),
        Precondition::LiveIdle => (timing.live_settle_ms, false),
    };
    let mut elapsed = 0;
    let mut prev = screen(sessions, id);
    while elapsed < budget {
        sleep_ms(timing.ready_poll_ms).await;
        elapsed += timing.ready_poll_ms;
        // A session that died on the way up is not a slow one: waiting out the whole
        // window would delay the report of a failure that is already decided.
        if !sessions.is_running(id) {
            return false;
        }
        let cur = screen(sessions, id);
        if (!needs_paint || !cur.trim().is_empty()) && cur == prev {
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
        SeedOutcome::Refused { reason } => {
            warn!(session = id, reason = %reason, "seed: nothing typed")
        }
        SeedOutcome::Failed { reason } => {
            warn!(session = id, reason = %reason, "seed: never submitted")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::FakeChild;
    use juancoded_core::model::ProviderId;
    use juancoded_state::registry::CreateRequest;
    use std::sync::atomic::Ordering;

    fn fast() -> SeedTiming {
        SeedTiming {
            ready_max_ms: 1_000,
            ready_poll_ms: 20,
            land_ms: 300,
            land_deadline_ms: 900,
            submit_settle_ms: 10,
            submit_ms: 600,
            poll_ms: 10,
            live_settle_ms: 300,
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
    async fn a_session_that_died_before_the_paste_is_refused_rather_than_failed() {
        let child = FakeChild::new(true);
        child.running.store(false, Ordering::Relaxed);
        let outcome = deliver_seed(child.api(), "fake", "never arrives", fast()).await;
        // Refused and not Failed, and the write log is why the distinction is provable
        // rather than a judgement: nothing was typed, so a caller holding a claim may
        // put the message back where it came from.
        match &outcome {
            SeedOutcome::Refused { reason } => assert!(reason.contains("exited"), "{reason}"),
            other => panic!("a dead session must not report a delivery: {other:?}"),
        }
        assert!(
            child.written().is_empty(),
            "nothing is written to a dead pty"
        );
    }

    /// The precondition is the whole difference between the two callers, and reading it
    /// the wrong way is silent: a busy live session read as "already seeded" would
    /// report a delivery that never typed a byte, and a queued message settled on that
    /// report would retire unsent.
    #[tokio::test]
    async fn a_busy_session_is_a_finished_seed_but_a_refused_queued_message() {
        let child = FakeChild::new(true);
        child.busy.store(true, Ordering::Relaxed);

        let seeded = deliver_text(
            child.api(),
            "fake",
            "run the suite",
            fast(),
            Precondition::Booting,
        )
        .await;
        assert_eq!(
            seeded,
            SeedOutcome::Submitted {
                verified_land: false
            },
            "a session already working when its create's prompt arrives was seeded by \
             something else"
        );

        let queued = deliver_text(
            child.api(),
            "fake",
            "run the suite",
            fast(),
            Precondition::LiveIdle,
        )
        .await;
        match &queued {
            SeedOutcome::Refused { reason } => assert!(reason.contains("turn"), "{reason}"),
            other => panic!("a mid-turn session must not consume a queued message: {other:?}"),
        }
        assert!(
            child.written().is_empty(),
            "neither call may write to a busy session"
        );
    }

    /// A blank screen means opposite things in the two cases, and reading it the boot
    /// way on a live session is what left a queued message unsent for the length of a
    /// boot window that had already happened.
    #[tokio::test]
    async fn a_blank_screen_is_settled_for_a_live_session_and_not_for_a_booting_one() {
        let child = FakeChild::blank(true);
        let sessions = child.api();
        assert!(
            wait_for_stable_screen(&sessions, "fake", fast(), Precondition::LiveIdle).await,
            "an idle CLI that cleared its screen is resting, not still starting"
        );
        assert!(
            !wait_for_stable_screen(&sessions, "fake", fast(), Precondition::Booting).await,
            "a CLI that has painted nothing has not brought its input box up yet"
        );
    }

    /// Once a paste is out, a failure is no longer "nothing happened". The bytes are in
    /// the box, so a caller holding a claim must retire the occurrence rather than put
    /// it back: re-queueing it is how this area has shipped a duplicate paste.
    #[tokio::test]
    async fn a_paste_that_is_never_submitted_fails_rather_than_refusing() {
        let child = FakeChild::new(true);
        child.swallows_enter.store(true, Ordering::Relaxed);
        let outcome = deliver_text(
            child.api(),
            "fake",
            "ship it",
            fast(),
            Precondition::LiveIdle,
        )
        .await;
        match &outcome {
            SeedOutcome::Failed { reason } => {
                assert!(reason.contains("never submitted"), "{reason}")
            }
            other => panic!("a paste that went out cannot be refused: {other:?}"),
        }
        let writes = child.written();
        // One paste, then the Enter attempts. The paste is never repeated: the screen
        // moved when it landed, so there is no evidence it was lost.
        assert_eq!(writes[0], paste_bytes("ship it", true));
        assert!(
            writes[1..].iter().all(|w| w == b"\r"),
            "{:?}",
            child.stream()
        );
        assert_eq!(
            writes.len(),
            1 + fast().max_enter_attempts,
            "{:?}",
            child.stream()
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
