//! Activity inference: is the agent working, done, or waiting on a human?
//!
//! A port of `JuancodeCore/ActivityDetector.swift`, fusing the same two signals it
//! does. Both ports are written around `notify`, because `notify` is the one field a
//! phone acts on:
//!
//! * **busy** is only ever *entered* on the working-footer phrase or on a transcript
//!   record the agent itself produced, so a startup banner or a keystroke echo can
//!   never open a turn. Entering busy never notifies.
//! * **idle** on the settle after a busy turn is a turn boundary, and notifies.
//! * **waiting_input** is a prompt marker in the bottom region, and notifies —
//!   whether it follows a turn or appears on its own (a trust dialog at startup).
//! * a prompt that was *answered away* demotes back to idle and does **not** notify.
//!
//! # The screen
//!
//! The fallback signal, and the only one that can see a permission prompt: a prompt is
//! not written to any transcript until it has been answered. Classification always
//! re-reads the rendered screen rather than the chunk that armed it: a footer arrives
//! in pieces and a prompt is drawn with absolute cursor moves, so the bytes of one
//! read are not a picture of anything. The chunk is used only as a cheap gate on
//! whether re-reading is worth it.
//!
//! # The transcript
//!
//! The preferred signal, and preferred because it is wording independent: a CLI that
//! renames its footer stops being readable off the screen and goes on writing records
//! either way. [`TranscriptEvent`] is what the seam every CLI's own store is read
//! through carries, and [`ActivityDetector::on_transcript`] is where it lands. It adds
//! exactly two things, both of them in the direction of *more* busy:
//!
//! 1. An agent-produced record enters or keeps busy, exactly as footer output does.
//! 2. An unresolved [`TranscriptEvent::ToolCall`] *holds* the turn busy past the
//!    stuck-footer watchdog. This is the signal's whole point: a slow tool or a
//!    delegated subagent goes screen- and transcript-quiet for minutes, and whatever
//!    reaps dormant sessions off this state must never see real work as dormant.
//!
//! Two pieces of the Swift detector are deliberately **not** ported, both for the same
//! reason: they are the only ways this signal could make a session read idle *sooner*
//! than the screen alone would have said, and nothing about a transcript is worth
//! that. Swift's `structuredTurn` lets a settle skip the "is the footer still there"
//! check once a record has arrived; here the footer stays a veto until the watchdog.
//! And [`TranscriptEvent::TurnEnd`] — which Swift has no equivalent of at all — is
//! inert: the screen owns the end of a turn.
//!
//! Timing lives with the caller. `on_output`, `on_transcript` and `settle` return the
//! generation to settle at, and a settle only acts if that generation is still current
//! — a debounce without a timer per byte, and a state machine a test can drive with no
//! sleeps at all. The one duration the detector measures for itself is how long an
//! unresolved tool call has been holding a turn, and that is read off an injectable
//! [`ActivityClock`] so a test can drive that too.

/// Rows of the bottom screen region treated as footer / input / dialog area.
pub const PROMPT_REGION_ROWS: usize = 20;
/// Quiet period after output stops before the screen is re-classified.
pub const SETTLE_MS: u64 = 250;
/// Longer silence after which a still-"busy" footer is treated as stale. The spinner
/// repaints while a turn really runs, so this much quiet means the turn ended.
pub const WATCHDOG_MS: u64 = 8_000;
/// Ceiling on how long an unresolved tool call may hold a turn busy, measured from the
/// record that last showed the agent alive. A tool whose process died never writes its
/// result, and without a cap that one missing record would pin a session busy for as
/// long as the daemon runs.
pub const TOOL_HOLD_CAP_MS: u64 = 30 * 60 * 1_000;

use std::collections::HashSet;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use juancoded_transcripts::TranscriptEvent;

use crate::model::SessionActivity;

/// Where the one duration the detector measures itself comes from.
///
/// Injectable for the same reason the Swift core's `ActivityClock` is: the tool-hold
/// cap is half an hour, and a test that could only reach it by waiting could not
/// assert it at all.
pub trait ActivityClock: Send + Sync + std::fmt::Debug {
    /// Milliseconds on some monotonic scale of this clock's choosing. Only differences
    /// are ever read, so the origin does not matter.
    fn now_ms(&self) -> u64;
}

/// The production clock: milliseconds since the first time anything asked.
///
/// Monotonic rather than wall clock on purpose. A wall clock that steps backwards
/// (an NTP correction, a laptop waking) would make an in-flight tool call look newer
/// than it is and hold busy longer, or older and release a session that is working.
#[derive(Debug, Default)]
pub struct MonotonicClock;

impl ActivityClock for MonotonicClock {
    fn now_ms(&self) -> u64 {
        static BASE: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
        BASE.get_or_init(std::time::Instant::now)
            .elapsed()
            .as_millis() as u64
    }
}

/// A clock a test moves by hand. Public rather than `cfg(test)` so the crates that
/// wire this detector up can drive the same cap from their own tests.
#[derive(Debug, Default)]
pub struct ManualClock(AtomicU64);

impl ManualClock {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn advance(&self, ms: u64) {
        self.0.fetch_add(ms, Ordering::Relaxed);
    }
}

impl ActivityClock for ManualClock {
    fn now_ms(&self) -> u64 {
        self.0.load(Ordering::Relaxed)
    }
}

/// The screen the classifier reads: the whole visible grid and its bottom band.
#[derive(Debug, Clone, Default)]
pub struct ScreenText {
    pub full: String,
    pub bottom: String,
}

impl ScreenText {
    pub fn new(full: impl Into<String>, bottom: impl Into<String>) -> Self {
        Self {
            full: full.into(),
            bottom: bottom.into(),
        }
    }
}

/// A state change worth broadcasting. `notify` is the edge a human is pinged on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Transition {
    pub state: SessionActivity,
    pub notify: bool,
    /// Whether this transition ended a busy turn, which is the only edge that is
    /// worth the cost of a whole-tree change rollup.
    pub ended_turn: bool,
}

/// What `on_output` wants the caller to schedule.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Armed {
    pub generation: u64,
    /// Whether the long stuck-busy watchdog is worth arming too. Only a busy turn
    /// can hang; an idle screen has nothing to demote.
    pub watchdog: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Step {
    pub transition: Option<Transition>,
    pub armed: Option<Armed>,
}

impl Step {
    /// Nothing to broadcast and nothing to schedule.
    fn nothing() -> Self {
        Self {
            transition: None,
            armed: None,
        }
    }

    fn changed(transition: Option<Transition>) -> Self {
        Self {
            transition,
            armed: None,
        }
    }
}

pub struct ActivityDetector {
    state: SessionActivity,
    generation: u64,
    /// Tail of the previous chunk, re-scanned with the next one, so a gate token split
    /// across a pty read boundary is still seen.
    carry: Vec<u8>,
    last_prompt: Option<&'static str>,
    clock: Arc<dyn ActivityClock>,
    /// Tool calls the transcript has opened and not resolved, as the *state machine*
    /// reads them: cleared whenever the turn ends for any reason, and bounded by
    /// [`TOOL_HOLD_CAP_MS`], so one missing result cannot pin busy forever.
    pending_tool_calls: HashSet<String>,
    /// The same opened-but-unresolved calls without the cap and without the
    /// clear-on-leave-busy — the raw "a call is still out there" fact, which is what a
    /// dormancy reaper has to read instead. A false busy there costs a session's RAM
    /// for longer; a false idle kills the run. Released only by the result, by the next
    /// human prompt (which supersedes anything the previous turn left open), and by
    /// [`ActivityDetector::reset`].
    open_tool_calls: HashSet<String>,
    /// When a record last showed the agent alive; the anchor the hold cap is measured
    /// from.
    last_transcript_ms: Option<u64>,
}

impl Default for ActivityDetector {
    fn default() -> Self {
        Self::new()
    }
}

impl ActivityDetector {
    pub fn new() -> Self {
        Self::with_clock(Arc::new(MonotonicClock))
    }

    pub fn with_clock(clock: Arc<dyn ActivityClock>) -> Self {
        Self {
            state: SessionActivity::Idle,
            generation: 0,
            carry: Vec::new(),
            last_prompt: None,
            clock,
            pending_tool_calls: HashSet::new(),
            open_tool_calls: HashSet::new(),
            last_transcript_ms: None,
        }
    }

    pub fn state(&self) -> SessionActivity {
        self.state
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// Which prompt shape last classified a screen as waiting, for diagnosis.
    pub fn last_prompt(&self) -> Option<&'static str> {
        self.last_prompt
    }

    /// Whether the transcript has opened a tool call it has not resolved.
    ///
    /// Deliberately the uncapped fact rather than the state machine's view of it: the
    /// cap exists so a crashed tool cannot pin the *activity state* busy, and a
    /// consumer deciding whether a session is dormant needs the truth instead. A
    /// delegated subagent legitimately runs past the cap. (The Swift core's session
    /// reaper reads its counterpart, `hasPendingToolUse`; the Rust daemon has no reaper
    /// yet, and this is the input the one it grows will need.)
    pub fn has_open_tool_call(&self) -> bool {
        !self.open_tool_calls.is_empty()
    }

    /// A chunk of pty output. `screen` is called at most once, and only when the
    /// cheap byte gate says a re-read could change anything.
    pub fn on_output(&mut self, bytes: &[u8], screen: impl FnOnce() -> ScreenText) -> Step {
        let scan = if self.carry.is_empty() {
            bytes.to_vec()
        } else {
            let mut s = std::mem::take(&mut self.carry);
            s.extend_from_slice(bytes);
            s
        };
        self.carry = scan.iter().rev().take(CARRY_BYTES).rev().copied().collect();

        if self.state == SessionActivity::Busy {
            // Already working: any output re-arms the clocks and nothing else.
            return Step {
                transition: None,
                armed: Some(self.arm(true)),
            };
        }

        let could_be_footer = contains(&scan, INTERRUPT_GATE);
        let could_be_prompt = self.state == SessionActivity::WaitingInput
            || PROMPT_GATE.iter().any(|t| contains(&scan, t.as_bytes()));
        if !could_be_footer && !could_be_prompt {
            return Step {
                transition: None,
                armed: None,
            };
        }

        let screen = screen();
        if could_be_footer && working_footer(&collapse(&screen.full)) {
            let transition = self.transition(SessionActivity::Busy, false);
            return Step {
                transition,
                armed: Some(self.arm(true)),
            };
        }
        // A prompt can appear with no preceding turn (a startup trust dialog, an auth
        // prompt, a resumed session repainting its pending menu), so the idle screen
        // gets a settle of its own rather than waiting for a turn that never comes.
        Step {
            transition: None,
            armed: Some(self.arm(false)),
        }
    }

    /// Records the CLI has *newly appended* to its own transcript, oldest first.
    ///
    /// Returns the same [`Step`] the byte path does, because there is one state machine
    /// and one notion of busy: a caller broadcasts and arms a transcript-driven turn
    /// exactly the way it does a footer-driven one.
    ///
    /// The caller must never hand over a session's backlog — the part of a file that
    /// was written before anyone was reading it, which a fresh bind or a restarted
    /// daemon reads in one go. Those records are history, and history must not pulse a
    /// session busy.
    pub fn on_transcript<'a>(
        &mut self,
        events: impl IntoIterator<Item = &'a TranscriptEvent>,
    ) -> Step {
        let mut agent_worked = false;
        for event in events {
            match event {
                // The human's own prompt, which is a turn boundary but not the agent
                // working. It also supersedes the previous turn: anything that turn
                // left open is not in flight any more, and this is the one release
                // path for a call whose result never came.
                TranscriptEvent::TurnStart { .. } => self.open_tool_calls.clear(),
                TranscriptEvent::ToolCall { call, .. } => {
                    self.pending_tool_calls.insert(call.clone());
                    self.open_tool_calls.insert(call.clone());
                    agent_worked = true;
                }
                TranscriptEvent::ToolResult { call, .. } => {
                    self.pending_tool_calls.remove(call);
                    self.open_tool_calls.remove(call);
                    agent_worked = true;
                }
                // A step and its cost are the CLI announcing a model request, which is
                // the agent working as much as the prose that comes out of it.
                TranscriptEvent::Assistant { .. }
                | TranscriptEvent::Thinking { .. }
                | TranscriptEvent::Step { .. }
                | TranscriptEvent::Usage { .. } => agent_worked = true,
                // Inert on purpose: see the module docs. Ending a turn here is the one
                // thing this signal could do that would make a session read idle
                // earlier than the screen would have said, and the screen (its prompt,
                // its quiet, its watchdog) already owns that decision.
                TranscriptEvent::TurnEnd { .. } => {}
            }
        }
        if !agent_worked {
            return Step::nothing();
        }
        self.last_transcript_ms = Some(self.clock.now_ms());
        let transition = self.transition(SessionActivity::Busy, false);
        Step {
            transition,
            armed: Some(self.arm(true)),
        }
    }

    /// Re-classify a settled screen.
    ///
    /// `generation` is the token `on_output` / `on_transcript` handed out: a settle
    /// whose token is stale lost the race to newer output and must do nothing.
    /// `demote_stale_footer` is the watchdog path, which ends a busy turn even while
    /// the footer is still painted.
    ///
    /// It returns a [`Step`] rather than a transition alone because a turn held busy by
    /// an unresolved tool call has to be looked at again, and on a session that has
    /// gone quiet nothing else will make anyone look.
    pub fn settle(
        &mut self,
        generation: u64,
        demote_stale_footer: bool,
        screen: &ScreenText,
    ) -> Step {
        if generation != self.generation {
            return Step::nothing();
        }
        let prompt = self.match_prompt(screen);
        if self.state == SessionActivity::Busy {
            if !demote_stale_footer && working_footer(&collapse(&screen.full)) {
                return Step::nothing(); // still working
            }
            if prompt.is_some() {
                // A visible prompt beats the open-call hold: a tool call is written to
                // the transcript *before* its permission menu is answered, and that is
                // the edge a human has to be pinged on. Leaving busy drops the hold.
                return Step::changed(self.transition(SessionActivity::WaitingInput, true));
            }
            if self.holds_open_tool_call() {
                // A call is still in flight, so the turn is not over however quiet the
                // screen has gone. Re-arm from the watchdog pass only: a held turn is
                // then re-read every `WATCHDOG_MS` until the result, a late prompt or
                // the cap ends the hold, rather than four times a second for as long
                // as a subagent runs.
                return Step {
                    transition: None,
                    armed: demote_stale_footer.then(|| self.arm(true)),
                };
            }
            return Step::changed(self.transition(SessionActivity::Idle, true));
        }
        // Idle or waiting: a visible prompt enters waiting (and pings), a prompt that
        // has since been answered demotes back to idle without one.
        Step::changed(match prompt {
            Some(_) if self.state != SessionActivity::WaitingInput => {
                self.transition(SessionActivity::WaitingInput, true)
            }
            None if self.state == SessionActivity::WaitingInput => {
                self.transition(SessionActivity::Idle, false)
            }
            _ => None,
        })
    }

    /// The session ended: cancel any pending settle and fall back to idle quietly.
    pub fn reset(&mut self) -> Option<Transition> {
        self.generation += 1;
        self.carry.clear();
        self.open_tool_calls.clear();
        self.last_transcript_ms = None;
        self.transition(SessionActivity::Idle, false)
    }

    /// Whether an unresolved tool call should keep this turn busy. Past the cap the
    /// hold is dropped — a tool that died never writes its result — so classification
    /// goes back to reading the screen.
    fn holds_open_tool_call(&mut self) -> bool {
        if self.pending_tool_calls.is_empty() {
            return false;
        }
        let anchor = self.last_transcript_ms.unwrap_or(0);
        if self.clock.now_ms().saturating_sub(anchor) >= TOOL_HOLD_CAP_MS {
            self.pending_tool_calls.clear();
            return false;
        }
        true
    }

    fn arm(&mut self, watchdog: bool) -> Armed {
        self.generation += 1;
        Armed {
            generation: self.generation,
            watchdog,
        }
    }

    fn transition(&mut self, next: SessionActivity, notify: bool) -> Option<Transition> {
        if next == self.state {
            return None;
        }
        let ended_turn = self.state == SessionActivity::Busy && next != SessionActivity::Busy;
        if ended_turn {
            // Any legitimate exit from busy abandons the hold; a tool that is really
            // still running re-enters busy through its own records or its own output.
            self.pending_tool_calls.clear();
        }
        self.state = next;
        Some(Transition {
            state: next,
            notify,
            ended_turn,
        })
    }

    fn match_prompt(&mut self, screen: &ScreenText) -> Option<&'static str> {
        let full = collapse(&screen.full);
        let bottom = collapse(&screen.bottom);
        for pattern in PROMPT_PATTERNS {
            let haystack = if pattern.bottom_only { &bottom } else { &full };
            if (pattern.matches)(haystack) {
                self.last_prompt = Some(pattern.label);
                return Some(pattern.label);
            }
        }
        self.last_prompt = None;
        None
    }
}

/// Cheap lowercase substrings that gate an idle screen re-read. A false positive
/// costs one wasted scan; it never changes state on its own.
const PROMPT_GATE: &[&str] = &["?", "❯", "y/n", "trust", "continue", "esc to cancel"];
/// The working footer's one stable word, gating entry into busy.
const INTERRUPT_GATE: &[u8] = b"interrupt";
/// One byte short of the longest gate token, which is all it takes to catch a token
/// split across two pty reads.
const CARRY_BYTES: usize = 14;

struct PromptPattern {
    label: &'static str,
    /// Prose markers are trusted only in the footer band; the CLI's own menu cursor
    /// is never prose, so it is matched anywhere on screen.
    bottom_only: bool,
    matches: fn(&str) -> bool,
}

const PROMPT_PATTERNS: &[PromptPattern] = &[
    PromptPattern {
        label: "select-cursor",
        bottom_only: false,
        matches: select_cursor,
    },
    PromptPattern {
        label: "do-you-want",
        bottom_only: true,
        matches: |s| lower_contains(s, "do you want to"),
    },
    PromptPattern {
        label: "do-you-trust",
        bottom_only: true,
        matches: |s| lower_contains(s, "do you trust"),
    },
    PromptPattern {
        label: "proceed",
        bottom_only: true,
        matches: |s| lower_contains(s, "proceed?"),
    },
    PromptPattern {
        label: "allow",
        bottom_only: true,
        matches: |s| near_question(s, "allow", 40),
    },
    PromptPattern {
        label: "yn-paren",
        bottom_only: true,
        matches: |s| lower_contains(s, "(y/n)"),
    },
    PromptPattern {
        label: "yn-bracket",
        bottom_only: true,
        matches: |s| lower_contains(s, "[y/n]"),
    },
    PromptPattern {
        label: "press-enter",
        bottom_only: true,
        matches: |s| lower_contains(s, "press enter to continue"),
    },
    PromptPattern {
        label: "esc-cancel",
        bottom_only: true,
        matches: |s| lower_contains(s, "(esc to cancel)"),
    },
];

fn lower_contains(haystack: &str, needle: &str) -> bool {
    haystack.to_lowercase().contains(needle)
}

/// `❯` followed by a number, a dot and a space: the CLI's own selection menu.
fn select_cursor(s: &str) -> bool {
    let bytes: Vec<char> = s.chars().collect();
    for (i, c) in bytes.iter().enumerate() {
        if *c != '❯' {
            continue;
        }
        let mut j = i + 1;
        while bytes.get(j).is_some_and(|c| c.is_whitespace()) {
            j += 1;
        }
        let digits = bytes[j..].iter().take_while(|c| c.is_ascii_digit()).count();
        if digits == 0 {
            continue;
        }
        j += digits;
        if bytes.get(j) == Some(&'.') && bytes.get(j + 1).is_some_and(|c| c.is_whitespace()) {
            return true;
        }
    }
    false
}

/// `word` followed by a `?` within `window` characters, on the same line. The
/// distance bound is what stops an unrelated question mark further down the screen
/// from turning any mention of the word into a prompt.
fn near_question(s: &str, word: &str, window: usize) -> bool {
    let lower = s.to_lowercase();
    for line in lower.lines() {
        let mut from = 0;
        while let Some(at) = line[from..].find(word) {
            let start = from + at + word.len();
            let end = (start + window).min(line.len());
            if line[start..end].contains('?') {
                return true;
            }
            from = start;
        }
    }
    false
}

/// `esc`/`escape` followed by `interrupt` within 40 characters on one line — the
/// working footer both real CLIs paint while a turn runs, tolerant of wording.
fn working_footer(screen: &str) -> bool {
    let lower = screen.to_lowercase();
    for line in lower.lines() {
        let mut from = 0;
        while let Some(at) = line[from..].find("esc") {
            let start = from + at + 3;
            let end = (start + 40).min(line.len());
            if line[start..end].contains("interrupt") {
                return true;
            }
            from = start;
        }
    }
    false
}

/// Collapse runs of intra-line whitespace. The grid renders a cursor-positioned
/// footer segment as the real column gap (many spaces); collapsing restores a
/// compact line so the distance-bounded matches above land as intended.
fn collapse(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut pending_space = false;
    for c in s.chars() {
        match c {
            '\n' => {
                pending_space = false;
                out.push('\n');
            }
            c if c.is_whitespace() => pending_space = true,
            c => {
                if pending_space && !out.is_empty() && !out.ends_with('\n') {
                    out.push(' ');
                }
                pending_space = false;
                out.push(c);
            }
        }
    }
    if pending_space && !out.is_empty() && !out.ends_with('\n') {
        out.push(' ');
    }
    out
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() || haystack.len() < needle.len() {
        return false;
    }
    haystack.windows(needle.len()).any(|w| w == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn quiet() -> ScreenText {
        ScreenText::new("nothing to see", "nothing to see")
    }

    fn footer() -> ScreenText {
        ScreenText::new(
            "some output\nworking... esc to interrupt",
            "working... esc to interrupt",
        )
    }

    fn prompt() -> ScreenText {
        ScreenText::new(
            "some output\nDo you want to proceed? (y/n)",
            "Do you want to proceed? (y/n)",
        )
    }

    #[test]
    fn a_banner_never_opens_a_turn() {
        let mut det = ActivityDetector::new();
        let step = det.on_output(b"fake-agent ready\r\n", quiet);
        assert_eq!(step.transition, None);
        assert_eq!(det.state(), SessionActivity::Idle);
        // No gate token matched at all, so no settle was even scheduled.
        assert_eq!(step.armed, None);
    }

    #[test]
    fn the_footer_enters_busy_without_notifying_and_the_settle_ends_the_turn() {
        let mut det = ActivityDetector::new();
        let step = det.on_output(b"working... esc to interrupt\r\n", footer);
        assert_eq!(
            step.transition,
            Some(Transition {
                state: SessionActivity::Busy,
                notify: false,
                ended_turn: false
            }),
            "entering a turn must never ping a human"
        );
        let armed = step.armed.expect("busy must arm a settle");
        assert!(armed.watchdog);

        // The footer is still up: the settle must leave the turn alone.
        assert_eq!(
            det.settle(armed.generation, false, &footer()).transition,
            None
        );
        // Screen cleared: a real turn boundary, which notifies.
        assert_eq!(
            det.settle(armed.generation, false, &quiet()).transition,
            Some(Transition {
                state: SessionActivity::Idle,
                notify: true,
                ended_turn: true
            })
        );
    }

    #[test]
    fn a_prompt_at_the_end_of_a_turn_waits_and_notifies() {
        let mut det = ActivityDetector::new();
        let armed = det
            .on_output(b"esc to interrupt", footer)
            .armed
            .expect("armed");
        assert_eq!(
            det.settle(armed.generation, false, &prompt()).transition,
            Some(Transition {
                state: SessionActivity::WaitingInput,
                notify: true,
                ended_turn: true
            })
        );
        assert_eq!(det.last_prompt(), Some("do-you-want"));
    }

    #[test]
    fn a_prompt_with_no_preceding_turn_still_waits_and_notifies() {
        let mut det = ActivityDetector::new();
        let armed = det
            .on_output("Do you trust this folder?".as_bytes(), || {
                ScreenText::new("Do you trust this folder?", "Do you trust this folder?")
            })
            .armed
            .expect("a prompt gate must arm a settle even from idle");
        assert!(!armed.watchdog, "an idle screen has no turn to demote");
        let transition = det
            .settle(
                armed.generation,
                false,
                &ScreenText::new("Do you trust this folder?", "Do you trust this folder?"),
            )
            .transition
            .expect("transition");
        assert_eq!(transition.state, SessionActivity::WaitingInput);
        assert!(transition.notify);
    }

    #[test]
    fn a_prompt_answered_away_goes_quiet_rather_than_pinging_again() {
        let mut det = ActivityDetector::new();
        let armed = det.on_output(b"(y/n)", prompt).armed.expect("armed");
        det.settle(armed.generation, false, &prompt());
        assert_eq!(det.state(), SessionActivity::WaitingInput);

        // The keystroke that answers it carries no marker of its own, so while
        // waiting every chunk re-arms the re-read.
        let armed = det.on_output(b"y", quiet).armed.expect("re-armed");
        assert_eq!(
            det.settle(armed.generation, false, &quiet()).transition,
            Some(Transition {
                state: SessionActivity::Idle,
                notify: false,
                ended_turn: false
            }),
            "a cleared prompt is not a new notification"
        );
    }

    #[test]
    fn a_stale_settle_loses_to_newer_output() {
        let mut det = ActivityDetector::new();
        let first = det.on_output(b"esc to interrupt", footer).armed.unwrap();
        let second = det.on_output(b"more", footer).armed.unwrap();
        assert_ne!(first.generation, second.generation);
        assert_eq!(
            det.settle(first.generation, false, &quiet()).transition,
            None,
            "the settle that newer output outran must do nothing"
        );
        assert_eq!(det.state(), SessionActivity::Busy);
        assert!(det
            .settle(second.generation, false, &quiet())
            .transition
            .is_some());
    }

    #[test]
    fn the_watchdog_ends_a_turn_whose_footer_never_got_erased() {
        let mut det = ActivityDetector::new();
        let armed = det.on_output(b"esc to interrupt", footer).armed.unwrap();
        assert_eq!(
            det.settle(armed.generation, false, &footer()).transition,
            None
        );
        let ended = det
            .settle(armed.generation, true, &footer())
            .transition
            .expect("the watchdog must not hang on a stale footer");
        assert_eq!(ended.state, SessionActivity::Idle);
        assert!(ended.notify);
    }

    #[test]
    fn a_gate_token_split_across_two_reads_is_still_seen() {
        let mut det = ActivityDetector::new();
        assert_eq!(
            det.on_output(b"working... esc to inte", footer).transition,
            None
        );
        let step = det.on_output(b"rrupt\r\n", footer);
        assert_eq!(
            step.transition.map(|t| t.state),
            Some(SessionActivity::Busy),
            "the gate must survive a chunk boundary"
        );
    }

    #[test]
    fn the_footer_distance_bound_rejects_two_unrelated_words() {
        let far = "press esc".to_string() + &" ".repeat(60) + "interrupt handler";
        assert!(!working_footer(&far));
        assert!(working_footer("esc to interrupt"));
        assert!(working_footer("ESCAPE to interrupt"));
    }

    #[test]
    fn a_menu_cursor_counts_anywhere_but_prose_only_in_the_footer() {
        assert!(select_cursor("❯ 1. Yes"));
        assert!(select_cursor("❯ 2. No, and tell me more"));
        assert!(!select_cursor("❯ nope"));

        let mut det = ActivityDetector::new();
        // The words scrolled up in history, with a clean footer: not a live prompt.
        let screen = ScreenText::new("Do you want to run this? (earlier)\n\nready", "ready");
        let armed = det.on_output(b"?", || screen.clone()).armed.unwrap();
        assert_eq!(
            det.settle(armed.generation, false, &screen).transition,
            None
        );
    }

    #[test]
    fn collapsing_restores_a_footer_the_grid_spread_across_columns() {
        let spread = format!("esc{}to interrupt", " ".repeat(30));
        assert!(!working_footer(&spread), "40 chars is the raw bound");
        assert!(working_footer(&collapse(&spread)));
        assert_eq!(collapse("a  \t b\n  c  "), "a b\nc ");
    }

    fn transcript_det() -> (ActivityDetector, Arc<ManualClock>) {
        let clock = Arc::new(ManualClock::new());
        (
            ActivityDetector::with_clock(clock.clone() as Arc<dyn ActivityClock>),
            clock,
        )
    }

    fn turn_start() -> TranscriptEvent {
        TranscriptEvent::TurnStart {
            prompt: "land the ticket".into(),
        }
    }

    fn turn_end() -> TranscriptEvent {
        TranscriptEvent::TurnEnd {
            reason: Some("end_turn".into()),
        }
    }

    fn assistant() -> TranscriptEvent {
        TranscriptEvent::Assistant {
            step: Some("req_1".into()),
            text: "on it".into(),
        }
    }

    fn tool_call(call: &str) -> TranscriptEvent {
        TranscriptEvent::ToolCall {
            call: call.into(),
            name: "Task".into(),
            input: "{}".into(),
        }
    }

    fn tool_result(call: &str) -> TranscriptEvent {
        TranscriptEvent::ToolResult {
            call: call.into(),
            ok: true,
            output: "done".into(),
        }
    }

    #[test]
    fn a_session_writing_records_with_no_pty_output_at_all_reads_busy() {
        let (mut det, _clock) = transcript_det();
        // Not one byte has come out of the pty: no footer, nothing on the screen. The
        // CLI writing its own transcript is the whole evidence there is.
        let step = det.on_transcript(&[turn_start(), assistant()]);
        assert_eq!(
            step.transition,
            Some(Transition {
                state: SessionActivity::Busy,
                notify: false,
                ended_turn: false
            }),
            "a record the agent produced opens a turn, and opening one never pings"
        );
        assert_eq!(det.state(), SessionActivity::Busy);
        let armed = step.armed.expect("a transcript turn arms its own settle");
        assert!(armed.watchdog);

        // Records stop, the screen is empty: the turn ended and a human is told.
        assert_eq!(
            det.settle(armed.generation, false, &quiet()).transition,
            Some(Transition {
                state: SessionActivity::Idle,
                notify: true,
                ended_turn: true
            })
        );
    }

    #[test]
    fn a_genuinely_quiet_session_reads_idle_and_stays_there() {
        let (mut det, _clock) = transcript_det();
        // No records at all, and a screen with nothing on it.
        assert_eq!(det.state(), SessionActivity::Idle);
        let step = det.on_output(b"fake-agent ready\r\n", quiet);
        assert_eq!(step.transition, None);
        assert_eq!(step.armed, None);

        // A settle on a quiet screen from idle changes nothing and asks for nothing.
        let settled = det.settle(det.generation(), false, &quiet());
        assert_eq!(settled.transition, None);
        assert_eq!(settled.armed, None);
        assert_eq!(det.state(), SessionActivity::Idle);
        assert!(!det.has_open_tool_call());
    }

    #[test]
    fn a_human_prompt_on_its_own_is_a_turn_boundary_and_not_the_agent_working() {
        let (mut det, _clock) = transcript_det();
        let step = det.on_transcript(&[turn_start()]);
        assert_eq!(step.transition, None, "somebody typing is not the agent");
        assert_eq!(step.armed, None);
        assert_eq!(det.state(), SessionActivity::Idle);
    }

    #[test]
    fn an_unresolved_tool_call_holds_the_turn_through_the_stuck_footer_watchdog() {
        let (mut det, clock) = transcript_det();
        let armed = det
            .on_transcript(&[turn_start(), tool_call("toolu_1")])
            .armed
            .expect("armed");
        assert_eq!(det.state(), SessionActivity::Busy);
        assert!(det.has_open_tool_call());

        // A delegated subagent: screen-quiet and transcript-quiet for minutes. The
        // ordinary settle leaves it alone and does not re-arm...
        clock.advance(SETTLE_MS);
        let settled = det.settle(armed.generation, false, &quiet());
        assert_eq!(settled.transition, None);
        assert_eq!(settled.armed, None);

        // ...and the watchdog, which exists to end a turn whose footer went stale,
        // must not end this one. It re-arms instead, so the hold is re-read.
        clock.advance(WATCHDOG_MS);
        let held = det.settle(armed.generation, true, &quiet());
        assert_eq!(
            held.transition, None,
            "a session running a tool is not dormant, whatever the screen says"
        );
        let again = held.armed.expect("a held turn must be looked at again");
        assert_eq!(det.state(), SessionActivity::Busy);

        // The result arrives: the hold is gone and the next settle ends the turn.
        let armed = det
            .on_transcript(&[tool_result("toolu_1")])
            .armed
            .expect("armed");
        assert_ne!(armed.generation, again.generation);
        assert!(!det.has_open_tool_call());
        assert_eq!(
            det.settle(armed.generation, false, &quiet())
                .transition
                .map(|t| t.state),
            Some(SessionActivity::Idle)
        );
    }

    #[test]
    fn a_tool_that_never_answers_stops_holding_at_the_cap() {
        let (mut det, clock) = transcript_det();
        let armed = det.on_transcript(&[tool_call("toolu_1")]).armed.unwrap();

        clock.advance(TOOL_HOLD_CAP_MS);
        let ended = det
            .settle(armed.generation, true, &quiet())
            .transition
            .expect("past the cap a hold cannot pin busy forever");
        assert_eq!(ended.state, SessionActivity::Idle);
        assert!(ended.notify);
        // The uncapped mirror is untouched: the call really is still out there, and a
        // reaper is entitled to the fact rather than to the state machine's view of it.
        assert!(det.has_open_tool_call());
    }

    #[test]
    fn a_visible_prompt_beats_an_open_tool_call() {
        let (mut det, _clock) = transcript_det();
        // The tool_use record is written before its permission menu is answered, so
        // this is the ordinary shape of a session asking to run something.
        let armed = det.on_transcript(&[tool_call("toolu_1")]).armed.unwrap();
        let asked = det
            .settle(armed.generation, false, &prompt())
            .transition
            .expect("a prompt must not be swallowed by the hold");
        assert_eq!(asked.state, SessionActivity::WaitingInput);
        assert!(asked.notify, "this is exactly the edge a phone rings on");
    }

    #[test]
    fn a_turn_end_record_never_ends_a_turn_and_the_footer_stays_a_veto() {
        let (mut det, _clock) = transcript_det();
        let armed = det.on_transcript(&[assistant()]).armed.unwrap();

        // The CLI says the turn closed. The screen still says it is working, and the
        // screen wins: this signal is only ever allowed to add busy.
        let step = det.on_transcript(&[turn_end()]);
        assert_eq!(step.transition, None);
        assert_eq!(step.armed, None, "an inert record schedules nothing");
        assert_eq!(det.state(), SessionActivity::Busy);
        assert_eq!(
            det.settle(armed.generation, false, &footer()).transition,
            None,
            "unlike the Swift detector, a record does not let a settle skip the footer"
        );
        assert_eq!(det.state(), SessionActivity::Busy);
    }

    #[test]
    fn the_next_human_prompt_releases_whatever_the_last_turn_left_open() {
        let (mut det, _clock) = transcript_det();
        det.on_transcript(&[tool_call("toolu_1")]);
        assert!(det.has_open_tool_call());

        // A tool whose result never came, and then somebody typed. Whatever was in
        // flight belonged to a turn that is over.
        det.on_transcript(&[turn_start()]);
        assert!(!det.has_open_tool_call());

        det.on_transcript(&[tool_call("toolu_2")]);
        assert!(det.has_open_tool_call());
        det.reset();
        assert!(
            !det.has_open_tool_call(),
            "a teardown owes nothing to a call"
        );
    }

    #[test]
    fn reset_returns_to_idle_and_invalidates_any_pending_settle() {
        let mut det = ActivityDetector::new();
        let armed = det.on_output(b"esc to interrupt", footer).armed.unwrap();
        let back = det.reset().expect("busy to idle");
        assert_eq!(back.state, SessionActivity::Idle);
        assert!(!back.notify, "a teardown is not a turn boundary");
        assert_eq!(
            det.settle(armed.generation, false, &footer()).transition,
            None
        );
    }
}
