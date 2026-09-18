//! A red CI build, read the way the Actions web UI reads it.
//!
//! A port of `JuancodeServices/ActionsLog.swift`. The input is exactly what
//! [`crate::gh::failed_check_logs`] produces: `gh run view --log-failed` output under
//! a per-run banner. The output is steps → folds → attributed lines, so a failure is
//! one error line at the top of a panel instead of twenty thousand characters somebody
//! has to scroll to the site to escape.
//!
//! Two grammars are layered in that text and both are parsed here. `gh` prefixes every
//! line with `<job>\t<step>\t`, and the raw line it wraps starts with an RFC-3339
//! timestamp and then carries GitHub Actions' own log commands (`##[group]`,
//! `##[error]`, the `::error file=…::` workflow form) and ANSI SGR escapes. The same
//! two layers GitHub Desktop parses in `app/src/lib/actions-log-parser` (MIT).
//!
//! Tolerant by construction, because a log is not a protocol: a line that does not
//! match gh's prefix is kept as text in whatever step is open, an unterminated
//! `##[group]` is closed at the step boundary, and a command this core has never heard
//! of degrades to a line that reads as noise rather than being dropped.

use serde::{Deserialize, Serialize};

use crate::gh::iso8601_ms;

/// A run of text sharing one set of ANSI attributes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionsLogSpan {
    pub text: String,
    /// The raw SGR foreground code (30–37 / 90–97), or absent for the default colour.
    /// Kept raw rather than resolved: which red a client draws is the client's business
    /// and depends on its theme.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fg: Option<u8>,
    #[serde(default)]
    pub bold: bool,
}

/// What an Actions log command said about a line, when it said anything.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ActionsLogSeverity {
    Plain,
    Command,
    Debug,
    Notice,
    Warning,
    Error,
}

/// One log line: how loud it is, when it happened, and its text already split into
/// attributed spans with the marker and the timestamp stripped.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionsLogLine {
    pub id: usize,
    pub severity: ActionsLogSeverity,
    /// Milliseconds since the epoch, or absent when the line had no stamp or it would
    /// not parse.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<i64>,
    pub spans: Vec<ActionsLogSpan>,
}

impl ActionsLogLine {
    /// The line as plain text — for search, for copying, and for the collapsed summary.
    pub fn text(&self) -> String {
        self.spans.iter().map(|s| s.text.as_str()).collect()
    }
}

/// A `##[group]` … `##[endgroup]` fold, or the implicit group holding the lines that
/// sat outside any fold (empty title, not foldable).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionsLogGroup {
    pub id: usize,
    pub title: String,
    pub foldable: bool,
    pub lines: Vec<ActionsLogLine>,
    /// Whether anything in the fold is an error — what decides if it starts open.
    /// Serialised rather than left to the client, so the desktop and the phone open the
    /// same folds.
    pub has_error: bool,
}

/// All the log for one job step, in the order gh emitted it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionsLogSection {
    pub id: usize,
    /// The workflow run this step belongs to, when the text carried a banner for it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run_id: Option<String>,
    pub job: String,
    pub step: String,
    pub groups: Vec<ActionsLogGroup>,
    pub has_error: bool,
    /// Every error line in the step — the "why is CI red" answer, with no fold to open
    /// first.
    pub error_lines: Vec<ActionsLogLine>,
}

/// A parsed failing-CI log.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionsLog {
    pub sections: Vec<ActionsLogSection>,
    /// True when the text carried the truncation marker, i.e. the head was dropped to
    /// fit the cap and what is here is the tail.
    pub truncated: bool,
}

impl ActionsLog {
    pub fn is_empty(&self) -> bool {
        self.sections.is_empty()
    }
}

/// The per-run banner `failed_check_logs` writes between runs.
const RUN_BANNER_PREFIX: &str = "===== run ";

/// Parse the failing-step text into steps → folds → lines.
pub fn parse_actions_log(text: &str) -> ActionsLog {
    if text.is_empty() {
        return ActionsLog::default();
    }
    let mut parser = Parser::default();
    for raw in text.split('\n') {
        parser.feed(raw);
    }
    parser.finish()
}

/// The parse's running state. A struct rather than a pile of locals because the two
/// flushes — close the fold, close the step — are called from four places each and both
/// have to leave every counter consistent.
#[derive(Default)]
struct Parser {
    sections: Vec<ActionsLogSection>,
    truncated: bool,
    next_line_id: usize,
    next_group_id: usize,
    /// The open step.
    run_id: Option<String>,
    job: String,
    step: String,
    groups: Vec<ActionsLogGroup>,
    /// The open fold within it, and the loose lines before or after one.
    group_title: Option<String>,
    group_lines: Vec<ActionsLogLine>,
    loose_lines: Vec<ActionsLogLine>,
    /// Whether the open step has had anything at all put in it. A step that never did
    /// is not a step, which is what keeps a stray banner from becoming an empty card.
    started: bool,
}

impl Parser {
    fn feed(&mut self, raw: &str) {
        if raw.starts_with(RUN_BANNER_PREFIX) {
            self.flush_section();
            self.run_id = run_id_from_banner(raw);
            self.job.clear();
            self.step.clear();
            return;
        }
        // Both spellings, because the marker is written with a real ellipsis and read
        // back from text that may have been through something that flattened it.
        if raw.starts_with("…(truncated)") || raw.starts_with("...(truncated)") {
            self.truncated = true;
            return;
        }
        if raw.is_empty() {
            return;
        }

        let (line_job, line_step, rest) = split_gh_log_line(raw);
        // gh restates the job and step on every single line, so a change in either is
        // the only signal that a new step began.
        if let (Some(lj), Some(ls)) = (line_job, line_step) {
            if lj != self.job || ls != self.step {
                let (job, step) = (lj.to_string(), ls.to_string());
                self.flush_section();
                self.job = job;
                self.step = step;
            }
        }

        let (timestamp, after_stamp) = split_timestamp(rest);
        let (command, payload) = split_log_command(after_stamp);

        match command.as_str() {
            "group" => {
                self.flush_group();
                self.group_title = Some(strip_ansi(payload));
                self.started = true;
            }
            "endgroup" => self.flush_group(),
            _ => {
                self.started = true;
                let line = ActionsLogLine {
                    id: self.next_line_id,
                    severity: severity_for(&command),
                    timestamp,
                    spans: ansi_spans(payload),
                };
                self.next_line_id += 1;
                if self.group_title.is_some() {
                    self.group_lines.push(line);
                } else {
                    self.loose_lines.push(line);
                }
            }
        }
    }

    fn flush_group(&mut self) {
        if let Some(title) = self.group_title.take() {
            let lines = std::mem::take(&mut self.group_lines);
            self.groups
                .push(finish_group(self.next_group_id, title, true, lines));
            self.next_group_id += 1;
        } else if !self.loose_lines.is_empty() {
            let lines = std::mem::take(&mut self.loose_lines);
            self.groups.push(finish_group(
                self.next_group_id,
                String::new(),
                false,
                lines,
            ));
            self.next_group_id += 1;
        }
    }

    fn flush_section(&mut self) {
        self.flush_group();
        let groups = std::mem::take(&mut self.groups);
        if self.started && !groups.is_empty() {
            self.sections.push(finish_section(
                self.sections.len(),
                self.run_id.clone(),
                self.job.clone(),
                self.step.clone(),
                groups,
            ));
        }
        self.started = false;
    }

    fn finish(mut self) -> ActionsLog {
        self.flush_section();
        ActionsLog {
            sections: self.sections,
            truncated: self.truncated,
        }
    }
}

fn finish_group(
    id: usize,
    title: String,
    foldable: bool,
    lines: Vec<ActionsLogLine>,
) -> ActionsLogGroup {
    let has_error = lines
        .iter()
        .any(|l| l.severity == ActionsLogSeverity::Error);
    ActionsLogGroup {
        id,
        title,
        foldable,
        lines,
        has_error,
    }
}

fn finish_section(
    id: usize,
    run_id: Option<String>,
    job: String,
    step: String,
    groups: Vec<ActionsLogGroup>,
) -> ActionsLogSection {
    let has_error = groups.iter().any(|g| g.has_error);
    let error_lines: Vec<ActionsLogLine> = groups
        .iter()
        .flat_map(|g| g.lines.iter())
        .filter(|l| l.severity == ActionsLogSeverity::Error)
        .cloned()
        .collect();
    ActionsLogSection {
        id,
        run_id,
        job,
        step,
        groups,
        has_error,
        error_lines,
    }
}

/// `===== run 123 (failed steps) =====` → `123`.
fn run_id_from_banner(line: &str) -> Option<String> {
    let rest = &line[RUN_BANNER_PREFIX.len()..];
    let id: String = rest.chars().take_while(char::is_ascii_digit).collect();
    (!id.is_empty()).then_some(id)
}

/// Split gh's `<job>\t<step>\t<raw line>` prefix off a line. Both are `None` when the
/// line does not carry them — a wrapped line, or plain `gh run view --log` text piped
/// in — in which case the whole line is content.
fn split_gh_log_line(raw: &str) -> (Option<&str>, Option<&str>, &str) {
    let mut parts = raw.splitn(3, '\t');
    match (parts.next(), parts.next(), parts.next()) {
        (Some(job), Some(step), Some(rest)) => (Some(job), Some(step), rest),
        _ => (None, None, raw),
    }
}

/// Peel a leading RFC-3339 timestamp off a log line and hand back both halves.
///
/// The first line of a downloaded log carries a UTF-8 BOM ahead of the stamp — verified
/// against a live `gh run view --log-failed`, not assumed — so it is dropped rather
/// than left to poison the parse and cost the line its timestamp.
fn split_timestamp(untrimmed: &str) -> (Option<i64>, &str) {
    let line = untrimmed.strip_prefix('\u{FEFF}').unwrap_or(untrimmed);
    let Some(space) = line.find(' ') else {
        return (None, line);
    };
    let head = &line[..space];
    if head.len() < 20
        || !head.ends_with('Z')
        || !head.contains('T')
        || !head.starts_with(|c: char| c.is_ascii_digit())
    {
        return (None, line);
    }
    (iso8601_ms(head), &line[space + 1..])
}

/// Peel an Actions log command off a line. Two forms show up: the `##[group]title` the
/// log stream itself uses, and the `::error file=a.swift,line=2::message` workflow
/// command an action can print. Returns the lower-cased name (empty for a plain line)
/// and whatever followed it.
fn split_log_command(line: &str) -> (String, &str) {
    if let Some(rest) = line.strip_prefix("##[") {
        if let Some(close) = rest.find(']') {
            return (rest[..close].to_lowercase(), &rest[close + 1..]);
        }
    }
    if let Some(after) = line.strip_prefix("::") {
        let Some(close) = after.find("::") else {
            return (String::new(), line);
        };
        let head = &after[..close];
        // The name runs to the first space; parameters follow it.
        let name = head.split(' ').next().unwrap_or_default();
        if name.is_empty() || !name.chars().all(|c| c.is_alphabetic() || c == '-') {
            return (String::new(), line);
        }
        return (name.to_lowercase(), &after[close + 2..]);
    }
    (String::new(), line)
}

/// How loudly a line reads. A command this core does not know (`set-output`,
/// `add-mask`, …) is noise rather than content, which is what `Command` means — the
/// payload is kept, it just does not read as something that happened.
fn severity_for(command: &str) -> ActionsLogSeverity {
    match command {
        "" => ActionsLogSeverity::Plain,
        "error" => ActionsLogSeverity::Error,
        "warning" => ActionsLogSeverity::Warning,
        "notice" | "section" => ActionsLogSeverity::Notice,
        "debug" => ActionsLogSeverity::Debug,
        _ => ActionsLogSeverity::Command,
    }
}

// ── ANSI ─────────────────────────────────────────────────────────────────────

/// Strip every ANSI escape from a string.
pub fn strip_ansi(s: &str) -> String {
    ansi_spans(s).iter().map(|sp| sp.text.as_str()).collect()
}

/// Split a line on its ANSI SGR escapes into attributed spans.
///
/// Only foreground colour and bold are carried — the two things Actions logs use to
/// mean something. Other attributes, and non-SGR sequences like the cursor moves a
/// progress bar emits, are dropped along with their escape rather than leaking control
/// bytes into the text. A code this core does not understand resets to the default
/// instead of bleeding into the rest of the line.
pub fn ansi_spans(s: &str) -> Vec<ActionsLogSpan> {
    if !s.contains('\u{1B}') {
        return if s.is_empty() {
            Vec::new()
        } else {
            vec![ActionsLogSpan {
                text: s.to_string(),
                fg: None,
                bold: false,
            }]
        };
    }

    let mut spans: Vec<ActionsLogSpan> = Vec::new();
    let mut buffer = String::new();
    let mut fg: Option<u8> = None;
    let mut bold = false;

    let chars: Vec<char> = s.chars().collect();
    let mut i = 0usize;
    while i < chars.len() {
        if chars[i] != '\u{1B}' || i + 1 >= chars.len() || chars[i + 1] != '[' {
            buffer.push(chars[i]);
            i += 1;
            continue;
        }
        // CSI … final-byte: scan to the first byte in @–~, which ends the sequence.
        let mut j = i + 2;
        let mut params = String::new();
        while j < chars.len() && !('\u{40}'..='\u{7E}').contains(&chars[j]) {
            params.push(chars[j]);
            j += 1;
        }
        if j >= chars.len() {
            // A truncated escape at the end of the line: drop the tail rather than
            // print it.
            break;
        }
        if chars[j] == 'm' {
            if !buffer.is_empty() {
                spans.push(ActionsLogSpan {
                    text: std::mem::take(&mut buffer),
                    fg,
                    bold,
                });
            }
            apply_sgr(&params, &mut fg, &mut bold);
        }
        i = j + 1;
    }
    if !buffer.is_empty() {
        spans.push(ActionsLogSpan {
            text: buffer,
            fg,
            bold,
        });
    }
    spans
}

/// Apply one SGR parameter list to the running attributes.
fn apply_sgr(params: &str, fg: &mut Option<u8>, bold: &mut bool) {
    if params.is_empty() {
        // A bare `ESC[m` is a reset.
        *fg = None;
        *bold = false;
        return;
    }
    let codes: Vec<i64> = params.split(';').map(|c| c.parse().unwrap_or(0)).collect();
    let mut idx = 0usize;
    while idx < codes.len() {
        match codes[idx] {
            0 => {
                *fg = None;
                *bold = false;
            }
            1 => *bold = true,
            22 => *bold = false,
            c @ (30..=37 | 90..=97) => *fg = Some(c as u8),
            39 => *fg = None,
            code @ (38 | 48) => {
                // Extended colour: `38;5;n` and `38;2;r;g;b`, plus the 48 background
                // equivalents. Fall back to the default and step over the arguments, so
                // a `5` or a `31` inside them is not read as an attribute of its own.
                if code == 38 {
                    *fg = None;
                }
                let mode = codes.get(idx + 1).copied().unwrap_or(0);
                let consumed = match mode {
                    2 => 5,
                    5 => 3,
                    _ => 1,
                };
                idx += consumed;
                continue;
            }
            _ => {} // background, italics, underline… nothing to carry
        }
        idx += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// gh's shape, wrapped in the banner `failed_check_logs` adds: a fold, an error, a
    /// warning, a noise command and a second step. Lifted from `ActionsLogTests.swift`.
    const SAMPLE: &str = "===== run 1234 (failed steps) =====\n\
build\tRun tests\t2026-07-29T09:41:02.1234567Z ##[group]Run pnpm test\n\
build\tRun tests\t2026-07-29T09:41:02.2000000Z pnpm test\n\
build\tRun tests\t2026-07-29T09:41:02.3000000Z ##[endgroup]\n\
build\tRun tests\t2026-07-29T09:41:09.0000000Z FAIL src/queue.test.ts\n\
build\tRun tests\t2026-07-29T09:41:09.5000000Z ##[error]Process completed with exit code 1.\n\
build\tLint\t2026-07-29T09:42:00.0000000Z ##[warning]2 warnings\n\
build\tLint\t2026-07-29T09:42:01.0000000Z ##[set-output]name=foo";

    fn texts(g: &ActionsLogGroup) -> Vec<String> {
        g.lines.iter().map(ActionsLogLine::text).collect()
    }

    #[test]
    fn a_red_build_comes_out_as_steps_folds_and_lines() {
        let log = parse_actions_log(SAMPLE);
        assert!(!log.truncated);
        assert_eq!(log.sections.len(), 2);

        let tests = &log.sections[0];
        assert_eq!(tests.run_id.as_deref(), Some("1234"));
        assert_eq!(
            (tests.job.as_str(), tests.step.as_str()),
            ("build", "Run tests")
        );
        assert!(tests.has_error);
        assert_eq!(tests.groups.len(), 2, "the fold, then what followed it");
        assert_eq!(tests.groups[0].title, "Run pnpm test");
        assert!(tests.groups[0].foldable);
        assert_eq!(texts(&tests.groups[0]), vec!["pnpm test"]);
        assert!(!tests.groups[0].has_error);
        assert!(!tests.groups[1].foldable);
        assert_eq!(
            texts(&tests.groups[1]),
            vec![
                "FAIL src/queue.test.ts",
                "Process completed with exit code 1."
            ]
        );
        assert_eq!(
            tests.groups[1]
                .lines
                .iter()
                .map(|l| l.severity)
                .collect::<Vec<_>>(),
            vec![ActionsLogSeverity::Plain, ActionsLogSeverity::Error]
        );
        assert_eq!(
            tests
                .error_lines
                .iter()
                .map(ActionsLogLine::text)
                .collect::<Vec<_>>(),
            vec!["Process completed with exit code 1."],
            "the one line that matters is reachable without opening a fold"
        );

        let lint = &log.sections[1];
        assert_eq!(lint.step, "Lint");
        assert!(!lint.has_error);
        assert_eq!(
            lint.groups[0]
                .lines
                .iter()
                .map(|l| l.severity)
                .collect::<Vec<_>>(),
            vec![ActionsLogSeverity::Warning, ActionsLogSeverity::Command]
        );
        assert_eq!(
            lint.groups[0].lines[1].text(),
            "name=foo",
            "a command this core does not know keeps its payload and reads as noise"
        );
    }

    /// Actions writes seven fractional digits, which most RFC-3339 parsers reject. A
    /// dropped timestamp here is a log with no clock in it.
    #[test]
    fn a_seven_digit_fraction_parses_and_leaves_the_text_clean() {
        let log = parse_actions_log(SAMPLE);
        let line = &log.sections[0].groups[0].lines[0];
        assert_eq!(line.timestamp, iso8601_ms("2026-07-29T09:41:02.200Z"));
        assert_eq!(line.text(), "pnpm test");
    }

    #[test]
    fn the_truncation_marker_becomes_a_flag_rather_than_a_line() {
        let log = parse_actions_log("…(truncated)\nbuild\tRun tests\t2026-07-29T09:41:02Z oops");
        assert!(log.truncated);
        assert_eq!(log.sections.len(), 1);
        assert_eq!(texts(&log.sections[0].groups[0]), vec!["oops"]);
    }

    #[test]
    fn a_group_nobody_closed_ends_where_its_step_does() {
        let log = parse_actions_log(
            "a\tstep one\t2026-07-29T09:41:02Z ##[group]Never closed\n\
             a\tstep one\t2026-07-29T09:41:03Z inside\n\
             a\tstep two\t2026-07-29T09:41:04Z after",
        );
        assert_eq!(log.sections.len(), 2);
        assert_eq!(log.sections[0].groups.len(), 1);
        assert_eq!(log.sections[0].groups[0].title, "Never closed");
        assert_eq!(texts(&log.sections[0].groups[0]), vec!["inside"]);
        assert_eq!(texts(&log.sections[1].groups[0]), vec!["after"]);
    }

    /// `gh run view --log` piped straight in, or a line long enough that gh wrapped it:
    /// no job, no step, no stamp, and still worth showing.
    #[test]
    fn a_line_with_no_prefix_and_no_stamp_survives_as_text() {
        let log = parse_actions_log("just some output\nand more");
        assert_eq!(log.sections.len(), 1);
        assert_eq!(log.sections[0].job, "");
        assert_eq!(log.sections[0].groups[0].lines[0].timestamp, None);
        assert_eq!(
            texts(&log.sections[0].groups[0]),
            vec!["just some output", "and more"]
        );
    }

    #[test]
    fn the_workflow_command_form_is_read_too() {
        let log =
            parse_actions_log("a\tb\t2026-07-29T09:41:02Z ::error file=a.swift,line=2::bad thing");
        let line = &log.sections[0].groups[0].lines[0];
        assert_eq!(line.severity, ActionsLogSeverity::Error);
        assert_eq!(line.text(), "bad thing");
        // And something that merely starts with `::` is not a command.
        let plain = parse_actions_log("a\tb\t2026-07-29T09:41:02Z ::just text");
        assert_eq!(
            plain.sections[0].groups[0].lines[0].severity,
            ActionsLogSeverity::Plain
        );
    }

    /// The first line of a downloaded log really does start with a BOM, ahead of the
    /// timestamp. Verified against a live `gh run view --log-failed`.
    #[test]
    fn a_utf8_bom_does_not_cost_the_first_line_its_timestamp() {
        let log = parse_actions_log(
            "Dependabot\tUNKNOWN STEP\t\u{FEFF}2026-07-28T13:37:35.7637778Z Current runner version",
        );
        let line = &log.sections[0].groups[0].lines[0];
        assert_eq!(line.text(), "Current runner version");
        assert!(line.timestamp.is_some());
    }

    #[test]
    fn no_text_is_an_empty_log_rather_than_an_empty_step() {
        let log = parse_actions_log("");
        assert!(log.is_empty());
        assert!(!log.truncated);
    }

    #[test]
    fn spans_carry_the_two_attributes_a_ci_log_uses() {
        let spans = ansi_spans("plain \u{1B}[1;31mFAIL\u{1B}[0m done");
        assert_eq!(
            spans.iter().map(|s| s.text.as_str()).collect::<Vec<_>>(),
            vec!["plain ", "FAIL", " done"]
        );
        assert_eq!(
            spans.iter().map(|s| s.fg).collect::<Vec<_>>(),
            vec![None, Some(31), None]
        );
        assert_eq!(
            spans.iter().map(|s| s.bold).collect::<Vec<_>>(),
            vec![false, true, false]
        );
    }

    /// `38;5;31` is a 256-colour index. Read one parameter at a time it looks like
    /// "bright", then "blink", then red — three attributes nobody asked for.
    #[test]
    fn extended_colour_arguments_are_stepped_over_not_read_as_attributes() {
        let spans = ansi_spans("\u{1B}[38;5;31mx\u{1B}[0m");
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].text, "x");
        assert_eq!(spans[0].fg, None);
        assert!(!spans[0].bold);
    }

    #[test]
    fn a_progress_bars_cursor_moves_vanish_without_eating_the_text() {
        let spans = ansi_spans("\u{1B}[2K\u{1B}[1Gprogress");
        assert_eq!(
            spans.iter().map(|s| s.text.as_str()).collect::<Vec<_>>(),
            vec!["progress"]
        );
    }

    #[test]
    fn stripping_leaves_the_words_and_none_of_the_control_bytes() {
        assert_eq!(strip_ansi("\u{1B}[32mok\u{1B}[0m"), "ok");
        assert_eq!(strip_ansi("nothing to strip"), "nothing to strip");
        assert_eq!(
            strip_ansi("tail\u{1B}[3"),
            "tail",
            "a truncated escape drops rather than leaking an ESC into a panel"
        );
    }
}
