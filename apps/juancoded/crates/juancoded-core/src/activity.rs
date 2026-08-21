//! Activity inference: is the agent working, done, or waiting on a human?
//!
//! A port of `JuancodeCore/ActivityDetector.swift`, minus the structured-transcript
//! signal (that arrives with the transcript seam). What is kept is the part that
//! decides `notify`, because `notify` is the one field a phone acts on:
//!
//! * **busy** is only ever *entered* on the working-footer phrase, so a startup
//!   banner or a keystroke echo can never open a turn. Entering busy never notifies.
//! * **idle** on the settle after a busy turn is a turn boundary, and notifies.
//! * **waiting_input** is a prompt marker in the bottom region, and notifies —
//!   whether it follows a turn or appears on its own (a trust dialog at startup).
//! * a prompt that was *answered away* demotes back to idle and does **not** notify.
//!
//! Classification always re-reads the rendered screen rather than the chunk that
//! armed it: a footer arrives in pieces and a prompt is drawn with absolute cursor
//! moves, so the bytes of one read are not a picture of anything. The chunk is used
//! only as a cheap gate on whether re-reading is worth it.
//!
//! Timing lives with the caller. `on_output` returns the generation to settle at, and
//! `settle` only acts if that generation is still current — a debounce without a
//! timer per byte, and a state machine a test can drive with no sleeps at all.

/// Rows of the bottom screen region treated as footer / input / dialog area.
pub const PROMPT_REGION_ROWS: usize = 20;
/// Quiet period after output stops before the screen is re-classified.
pub const SETTLE_MS: u64 = 250;
/// Longer silence after which a still-"busy" footer is treated as stale. The spinner
/// repaints while a turn really runs, so this much quiet means the turn ended.
pub const WATCHDOG_MS: u64 = 8_000;

use crate::model::SessionActivity;

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

pub struct ActivityDetector {
    state: SessionActivity,
    generation: u64,
    /// Tail of the previous chunk, re-scanned with the next one, so a gate token split
    /// across a pty read boundary is still seen.
    carry: Vec<u8>,
    last_prompt: Option<&'static str>,
}

impl Default for ActivityDetector {
    fn default() -> Self {
        Self::new()
    }
}

impl ActivityDetector {
    pub fn new() -> Self {
        Self {
            state: SessionActivity::Idle,
            generation: 0,
            carry: Vec::new(),
            last_prompt: None,
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

    /// Re-classify a settled screen.
    ///
    /// `generation` is the token `on_output` handed out: a settle whose token is stale
    /// lost the race to newer output and must do nothing. `demote_stale_footer` is the
    /// watchdog path, which ends a busy turn even while the footer is still painted.
    pub fn settle(
        &mut self,
        generation: u64,
        demote_stale_footer: bool,
        screen: &ScreenText,
    ) -> Option<Transition> {
        if generation != self.generation {
            return None;
        }
        let prompt = self.match_prompt(screen);
        if self.state == SessionActivity::Busy {
            if !demote_stale_footer && working_footer(&collapse(&screen.full)) {
                return None; // still working
            }
            return match prompt {
                Some(_) => self.transition(SessionActivity::WaitingInput, true),
                None => self.transition(SessionActivity::Idle, true),
            };
        }
        // Idle or waiting: a visible prompt enters waiting (and pings), a prompt that
        // has since been answered demotes back to idle without one.
        match prompt {
            Some(_) if self.state != SessionActivity::WaitingInput => {
                self.transition(SessionActivity::WaitingInput, true)
            }
            None if self.state == SessionActivity::WaitingInput => {
                self.transition(SessionActivity::Idle, false)
            }
            _ => None,
        }
    }

    /// The session ended: cancel any pending settle and fall back to idle quietly.
    pub fn reset(&mut self) -> Option<Transition> {
        self.generation += 1;
        self.carry.clear();
        self.transition(SessionActivity::Idle, false)
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
        assert_eq!(det.settle(armed.generation, false, &footer()), None);
        // Screen cleared: a real turn boundary, which notifies.
        assert_eq!(
            det.settle(armed.generation, false, &quiet()),
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
            det.settle(armed.generation, false, &prompt()),
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
            det.settle(armed.generation, false, &quiet()),
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
            det.settle(first.generation, false, &quiet()),
            None,
            "the settle that newer output outran must do nothing"
        );
        assert_eq!(det.state(), SessionActivity::Busy);
        assert!(det.settle(second.generation, false, &quiet()).is_some());
    }

    #[test]
    fn the_watchdog_ends_a_turn_whose_footer_never_got_erased() {
        let mut det = ActivityDetector::new();
        let armed = det.on_output(b"esc to interrupt", footer).armed.unwrap();
        assert_eq!(det.settle(armed.generation, false, &footer()), None);
        let ended = det
            .settle(armed.generation, true, &footer())
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
        assert_eq!(det.settle(armed.generation, false, &screen), None);
    }

    #[test]
    fn collapsing_restores_a_footer_the_grid_spread_across_columns() {
        let spread = format!("esc{}to interrupt", " ".repeat(30));
        assert!(!working_footer(&spread), "40 chars is the raw bound");
        assert!(working_footer(&collapse(&spread)));
        assert_eq!(collapse("a  \t b\n  c  "), "a b\nc ");
    }

    #[test]
    fn reset_returns_to_idle_and_invalidates_any_pending_settle() {
        let mut det = ActivityDetector::new();
        let armed = det.on_output(b"esc to interrupt", footer).armed.unwrap();
        let back = det.reset().expect("busy to idle");
        assert_eq!(back.state, SessionActivity::Idle);
        assert!(!back.notify, "a teardown is not a turn boundary");
        assert_eq!(det.settle(armed.generation, false, &footer()), None);
    }
}
