//! The VT model: one `alacritty_terminal` grid per session, one owner, and a
//! value-type projection of it.
//!
//! This is the Rust half of `SessionTerminalModel.swift` + `ScreenWire.swift`. The
//! shapes here are deliberately a mirror of those Swift types — `Snapshot` is
//! `TerminalSnapshot`, `Row` is `TerminalRow`, and `wire::segments` reproduces the
//! same run-length compression — because the `screen` frames both cores emit have
//! to be byte-identical for a client to be core-agnostic.
//!
//! The point of moving here: alacritty owns the grid outright behind `&mut`, so the
//! "two things parse the same stream on different threads" bug class (juancode-9goj,
//! grnu, 1th) is not expressible.

use std::sync::{Arc, Mutex};

use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line, Point};
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::{Config, TermMode};
use alacritty_terminal::vte::ansi::{Color as VteColor, NamedColor, Processor};
use alacritty_terminal::Term;

pub mod wire;

/// A cell's colour, mirroring Swift's `TerminalColor`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Color {
    Default,
    DefaultInverted,
    Ansi(u8),
    TrueColor(u8, u8, u8),
}

/// Text attributes, mirroring Swift's `TerminalCellStyle` bitmask **exactly** —
/// the raw value crosses the wire as `st`, so these bit positions are protocol.
pub mod style {
    pub const BOLD: u8 = 1 << 0;
    pub const UNDERLINE: u8 = 1 << 1;
    pub const BLINK: u8 = 1 << 2;
    pub const INVERSE: u8 = 1 << 3;
    pub const INVISIBLE: u8 = 1 << 4;
    pub const DIM: u8 = 1 << 5;
    pub const ITALIC: u8 = 1 << 6;
    pub const CROSSED_OUT: u8 = 1 << 7;
}

/// One rendered grid cell. `width` is 2 for the lead cell of a wide glyph; the
/// trailing spacer alacritty keeps in the grid is dropped from `Row::cells`, as
/// the Swift model does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cell {
    pub ch: char,
    pub width: u8,
    pub fg: Color,
    pub bg: Color,
    pub style: u8,
}

/// One rendered line: styled cells plus the plain text with trailing blanks
/// trimmed, so text-only consumers (search, activity detection) don't rebuild it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Row {
    pub cells: Vec<Cell>,
    pub text: String,
}

/// A point-in-time projection of the visible screen. Pure values, so a client or
/// a diff can hold it without touching the live grid.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Snapshot {
    pub cols: usize,
    pub rows: usize,
    pub lines: Vec<Row>,
    pub cursor_x: usize,
    pub cursor_y: usize,
    pub cursor_visible: bool,
    pub alt: bool,
}

impl Snapshot {
    /// The bottom `rows` rows as text, blanks and all. The footer / input / dialog
    /// region: prompt markers are only trusted here, so the same words scrolled up
    /// in conversation history cannot masquerade as a live prompt.
    pub fn bottom_text(&self, rows: usize) -> String {
        let start = self.lines.len().saturating_sub(rows);
        self.lines[start..]
            .iter()
            .map(|r| r.text.as_str())
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// The visible screen as text: rows joined by newlines, trailing blank rows
    /// dropped. Mirrors `TerminalSnapshot.text`.
    pub fn text(&self) -> String {
        let mut end = self.lines.len();
        while end > 0 && self.lines[end - 1].text.is_empty() {
            end -= 1;
        }
        self.lines[..end]
            .iter()
            .map(|r| r.text.as_str())
            .collect::<Vec<_>>()
            .join("\n")
    }
}

/// Grid geometry handed to `Term::resize`. alacritty's own `TermSize` lives behind
/// its `test` module, so we carry our own.
#[derive(Debug, Clone, Copy)]
pub struct Size {
    pub cols: usize,
    pub rows: usize,
    pub history: usize,
}

impl Dimensions for Size {
    fn total_lines(&self) -> usize {
        self.rows + self.history
    }
    fn screen_lines(&self) -> usize {
        self.rows
    }
    fn columns(&self) -> usize {
        self.cols
    }
}

/// Catches the OSC 0/2 window titles the parser reports, so a session can adopt the
/// name a CLI gives itself instead of keeping the directory basename it started with.
///
/// The parser hands a title to the listener from inside `advance`, and a listener only
/// ever sees `&self`, so the slot is a mutex even though exactly one thread feeds a
/// model. `ResetTitle` is dropped: a reset is the absence of a name, and there is
/// nothing there to adopt.
///
/// Two slots, not one. `pending` is what the registry TAKES, because adopting a name
/// is a one-time act and a TUI repaints its title many times a turn. `last` is what a
/// reader READS, because a one-shot screen read has to be able to report the title the
/// program is currently flying without stealing the registry's adoption — and after the
/// first take, `pending` is empty while the window is still named.
#[derive(Default)]
struct TitleState {
    pending: Option<String>,
    last: Option<String>,
}

#[derive(Clone, Default)]
struct TitleSink(Arc<Mutex<TitleState>>);

impl TitleSink {
    fn take(&self) -> Option<String> {
        self.0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .pending
            .take()
    }

    fn last(&self) -> Option<String> {
        self.0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .last
            .clone()
    }
}

impl EventListener for TitleSink {
    fn send_event(&self, event: Event) {
        if let Event::Title(title) = event {
            let mut state = self.0.lock().unwrap_or_else(|e| e.into_inner());
            state.pending = Some(title.clone());
            state.last = Some(title);
        }
    }
}

/// The headless terminal model for one session: the parser plus the grid it owns.
///
/// Single-threaded by construction — hold it behind the session's own lock and
/// there is exactly one writer, which is the whole point.
pub struct TerminalModel {
    term: Term<TitleSink>,
    parser: Processor,
    titles: TitleSink,
    cols: usize,
    rows: usize,
    history: usize,
}

impl TerminalModel {
    pub fn new(cols: usize, rows: usize, history: usize) -> Self {
        let size = Size {
            cols,
            rows,
            history,
        };
        let config = Config {
            scrolling_history: history,
            ..Default::default()
        };
        let titles = TitleSink::default();
        Self {
            term: Term::new(config, &size, titles.clone()),
            parser: Processor::new(),
            titles,
            cols,
            rows,
            history,
        }
    }

    /// Feed pty bytes. The only mutation path into the grid.
    pub fn feed(&mut self, bytes: &[u8]) {
        self.parser.advance(&mut self.term, bytes);
    }

    /// The newest OSC 0/2 window title the program set since the last take, if any.
    /// Taking rather than reading, because the caller adopts a title once: a TUI
    /// repaints its window title many times per turn and every repaint would
    /// otherwise read as a fresh fact.
    pub fn take_title(&mut self) -> Option<String> {
        self.titles.take()
    }

    pub fn resize(&mut self, cols: usize, rows: usize) {
        if cols == self.cols && rows == self.rows {
            return;
        }
        self.cols = cols;
        self.rows = rows;
        self.term.resize(Size {
            cols,
            rows,
            history: self.history,
        });
    }

    pub fn cols(&self) -> usize {
        self.cols
    }

    pub fn rows(&self) -> usize {
        self.rows
    }

    /// Project the visible screen. Cheap relative to parsing, but not free — take
    /// one per render tick, not per byte.
    pub fn snapshot(&self) -> Snapshot {
        let grid = self.term.grid();
        let display_offset = grid.display_offset();
        let mode = self.term.mode();
        let mut lines = Vec::with_capacity(self.rows);

        for row in 0..self.rows {
            lines.push(self.row_at(Line(row as i32 - display_offset as i32)));
        }

        let cursor = grid.cursor.point;
        Snapshot {
            cols: self.cols,
            rows: self.rows,
            lines,
            cursor_x: cursor.column.0.min(self.cols.saturating_sub(1)),
            cursor_y: (cursor.line.0 + display_offset as i32).max(0) as usize,
            cursor_visible: mode.contains(TermMode::SHOW_CURSOR),
            alt: mode.contains(TermMode::ALT_SCREEN),
        }
    }

    /// The newest OSC 0/2 window title, WITHOUT consuming it — the title the program
    /// is currently flying. [`Self::take_title`] is the registry's adoption path and
    /// empties its slot on the first call; a reader that used it would both steal that
    /// adoption and report `None` for every window whose name was already taken.
    pub fn title(&self) -> Option<String> {
        self.titles.last()
    }

    /// How many scrollback rows the model retains ABOVE the visible screen. Zero on
    /// the alternate buffer, which keeps no history by construction.
    pub fn scrollback_rows(&self) -> usize {
        let grid = self.term.grid();
        grid.history_size().saturating_sub(grid.display_offset())
    }

    /// The last `count` scrollback rows, oldest first, styled — the Rust half of
    /// `SessionTerminalModel.styledScrollbackTail`. Fewer than asked for when that is
    /// all the history there is; empty when `count` is 0.
    pub fn styled_scrollback_tail(&self, count: usize) -> Vec<Row> {
        let available = self.scrollback_rows();
        let n = count.min(available);
        if n == 0 {
            return Vec::new();
        }
        let display_offset = self.term.grid().display_offset() as i32;
        // The row just above the visible top is `-display_offset - 1`, so the last `n`
        // history rows run from `-n - display_offset` up to `-1 - display_offset`.
        (0..n)
            .map(|i| self.row_at(Line(i as i32 - n as i32 - display_offset)))
            .collect()
    }

    /// A one-shot read of everything `GET /api/sessions/:id/screen` answers with,
    /// taken under ONE borrow of the model: the visible grid, the history rows above
    /// it, and the retained window title.
    ///
    /// One call rather than three, because the three are a picture: a feed landing
    /// between a history read and a grid read scrolls one row across the seam, and the
    /// seam is exactly the row a reader would misplace.
    pub fn peek(&self, scrollback_rows: usize) -> ScreenPeek {
        ScreenPeek {
            history: self.styled_scrollback_tail(scrollback_rows),
            snapshot: self.snapshot(),
            title: self.title(),
        }
    }

    /// One grid line as a value row. `line` is alacritty's own index: `0` is the top
    /// of the viewport when nothing is scrolled, and history runs negative.
    fn row_at(&self, line: Line) -> Row {
        let grid = self.term.grid();
        let mut cells: Vec<Cell> = Vec::with_capacity(self.cols);
        for col in 0..self.cols {
            let cell = &grid[Point::new(line, Column(col))];
            let flags = cell.flags;
            // alacritty keeps a spacer cell after a wide glyph; the Swift model
            // drops it and widens the lead cell instead.
            if flags.contains(Flags::WIDE_CHAR_SPACER)
                || flags.contains(Flags::LEADING_WIDE_CHAR_SPACER)
            {
                continue;
            }
            cells.push(Cell {
                ch: cell.c,
                width: if flags.contains(Flags::WIDE_CHAR) {
                    2
                } else {
                    1
                },
                fg: map_color(cell.fg, ColorRole::Fg),
                bg: map_color(cell.bg, ColorRole::Bg),
                style: map_style(flags),
            });
        }
        let mut text: String = cells.iter().map(|c| c.ch).collect();
        while text.ends_with(' ') {
            text.pop();
        }
        Row { cells, text }
    }
}

/// A one-shot rendered read of a session: the visible grid, the scrollback history
/// asked for above it, and the window title the program set.
///
/// The Rust half of `ScreenPeek.swift`. Its whole reason for existing is that the
/// alternative — replaying a stored byte log — has no record of the width those bytes
/// were parsed at, so every hard wrap in the replay lands in the wrong cell. These
/// rows were laid out by the parser that wrote them, at the width it wrote them at.
#[derive(Debug, Clone, Default)]
pub struct ScreenPeek {
    pub snapshot: Snapshot,
    /// Scrollback above the visible grid, oldest first. Empty unless asked for.
    pub history: Vec<Row>,
    /// The last OSC 0/2 title the program set, if any.
    pub title: Option<String>,
}

impl ScreenPeek {
    /// History (when asked for) above the visible screen, rows joined by "\n" with the
    /// screen's trailing blank rows dropped — the `text/plain` body.
    pub fn text(&self) -> String {
        let visible = self.snapshot.text();
        if self.history.is_empty() {
            return visible;
        }
        let past = self
            .history
            .iter()
            .map(|r| r.text.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        if visible.is_empty() {
            past
        } else {
            format!("{past}\n{visible}")
        }
    }

    /// Styled rows in the `screen` frame's own encoding: history at -n … -1, the
    /// visible grid at 0 … rows-1. Negative indices rather than a second array,
    /// so one decoder reads a peek and a stream frame alike.
    pub fn lines(&self) -> Vec<wire::PeekRow> {
        let n = self.history.len() as i64;
        let mut out = Vec::with_capacity(self.history.len() + self.snapshot.lines.len());
        for (i, row) in self.history.iter().enumerate() {
            out.push(wire::PeekRow {
                row: i as i64 - n,
                segs: wire::segments(row),
            });
        }
        for row in wire::full_lines(&self.snapshot) {
            out.push(wire::PeekRow {
                row: row.row as i64,
                segs: row.segs,
            });
        }
        out
    }
}

enum ColorRole {
    Fg,
    Bg,
}

/// alacritty's colour union → the wire colour. The default fg/bg collapse to
/// `Default` so they are omitted from the frame entirely, as in `ScreenWire`.
fn map_color(color: VteColor, role: ColorRole) -> Color {
    match color {
        VteColor::Named(NamedColor::Foreground) => match role {
            ColorRole::Fg => Color::Default,
            ColorRole::Bg => Color::DefaultInverted,
        },
        VteColor::Named(NamedColor::Background) => match role {
            ColorRole::Fg => Color::DefaultInverted,
            ColorRole::Bg => Color::Default,
        },
        VteColor::Named(named) => {
            let idx = named as usize;
            if idx < 16 {
                Color::Ansi(idx as u8)
            } else {
                // Cursor / dim / bright aliases have no ANSI index; fold them onto
                // the nearest base colour rather than inventing one.
                match named {
                    NamedColor::BrightForeground | NamedColor::DimForeground => match role {
                        ColorRole::Fg => Color::Default,
                        ColorRole::Bg => Color::DefaultInverted,
                    },
                    _ => Color::Default,
                }
            }
        }
        VteColor::Indexed(i) => Color::Ansi(i),
        VteColor::Spec(rgb) => Color::TrueColor(rgb.r, rgb.g, rgb.b),
    }
}

fn map_style(flags: Flags) -> u8 {
    let mut st = 0u8;
    if flags.contains(Flags::BOLD) {
        st |= style::BOLD;
    }
    if flags.intersects(Flags::ALL_UNDERLINES) {
        st |= style::UNDERLINE;
    }
    if flags.contains(Flags::INVERSE) {
        st |= style::INVERSE;
    }
    if flags.contains(Flags::HIDDEN) {
        st |= style::INVISIBLE;
    }
    if flags.contains(Flags::DIM) {
        st |= style::DIM;
    }
    if flags.contains(Flags::ITALIC) {
        st |= style::ITALIC;
    }
    if flags.contains(Flags::STRIKEOUT) {
        st |= style::CROSSED_OUT;
    }
    st
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bottom_text_keeps_the_blank_rows_the_footer_region_needs() {
        let mut m = TerminalModel::new(20, 5, 100);
        m.feed(b"top\r\n\x1b[5;1Hfooter");
        let snap = m.snapshot();
        // Trailing blanks are trimmed from `text` but the footer band is positional:
        // taking the last two rows must still land on the last two rows.
        assert_eq!(snap.bottom_text(2), "\nfooter");
        assert_eq!(snap.bottom_text(99).lines().count(), 5);
        assert_eq!(snap.text(), "top\n\n\n\nfooter");
    }

    #[test]
    fn an_osc_window_title_is_taken_once_and_leaves_the_grid_alone() {
        let mut m = TerminalModel::new(20, 3, 100);
        assert_eq!(m.take_title(), None, "nothing was set yet");
        m.feed(b"\x1b]2;named by the cli\x07visible text");
        assert_eq!(m.take_title().as_deref(), Some("named by the cli"));
        assert_eq!(m.take_title(), None, "a title is a fact to adopt once");
        // The escape sequence is consumed by the parser, not painted.
        assert_eq!(m.snapshot().lines[0].text, "visible text");
    }

    #[test]
    fn the_newest_title_wins_within_one_feed() {
        let mut m = TerminalModel::new(20, 3, 100);
        m.feed(b"\x1b]0;first\x07\x1b]2;second\x07");
        assert_eq!(m.take_title().as_deref(), Some("second"));
    }

    #[test]
    fn reading_a_title_survives_the_adoption_that_takes_it() {
        // The registry adopts a name once; a screen read has to be able to report it
        // afterwards, or every peek at a long-running session says the window is
        // nameless.
        let mut m = TerminalModel::new(20, 3, 100);
        assert_eq!(m.title(), None);
        m.feed(b"\x1b]2;the cli named itself\x07");
        assert_eq!(m.take_title().as_deref(), Some("the cli named itself"));
        assert_eq!(m.take_title(), None, "the adoption slot is still one-shot");
        assert_eq!(m.title().as_deref(), Some("the cli named itself"));
    }

    #[test]
    fn the_scrollback_tail_is_the_rows_just_above_the_screen_oldest_first() {
        let mut m = TerminalModel::new(20, 3, 100);
        for i in 0..8 {
            m.feed(format!("line {i}\r\n").as_bytes());
        }
        // 8 lines written plus the cursor's own row into a 3-row screen: rows 0..5
        // scrolled off, 6 and 7 are visible with the cursor parked below them.
        assert_eq!(m.scrollback_rows(), 6);
        assert_eq!(m.snapshot().lines[0].text, "line 6");

        let tail: Vec<String> = m
            .styled_scrollback_tail(3)
            .into_iter()
            .map(|r| r.text)
            .collect();
        assert_eq!(tail, vec!["line 3", "line 4", "line 5"]);

        // Asking for more than there is takes everything, and zero takes nothing.
        assert_eq!(m.styled_scrollback_tail(99).len(), 6);
        assert!(m.styled_scrollback_tail(0).is_empty());
    }

    #[test]
    fn the_alternate_buffer_has_no_history_to_read() {
        let mut m = TerminalModel::new(20, 3, 100);
        for i in 0..8 {
            m.feed(format!("line {i}\r\n").as_bytes());
        }
        assert_eq!(m.scrollback_rows(), 6);
        m.feed(b"\x1b[?1049h");
        assert_eq!(m.scrollback_rows(), 0, "the alt screen keeps none");
        assert!(m.peek(200).history.is_empty());
    }

    #[test]
    fn a_peek_puts_history_at_negative_rows_and_the_screen_at_zero_up() {
        let mut m = TerminalModel::new(20, 3, 100);
        m.feed(b"\x1b]2;peeked\x07");
        for i in 0..6 {
            m.feed(format!("line {i}\r\n").as_bytes());
        }
        let peek = m.peek(2);
        assert_eq!(peek.title.as_deref(), Some("peeked"));
        assert_eq!(peek.history.len(), 2);

        let rows: Vec<i64> = peek.lines().iter().map(|l| l.row).collect();
        assert_eq!(
            rows,
            vec![-2, -1, 0, 1, 2],
            "history below zero, screen at 0.."
        );

        // The text body is the same rows in the same order, history first.
        assert_eq!(peek.text(), "line 2\nline 3\nline 4\nline 5");
        // A peek with no history asked for is exactly the visible screen.
        assert_eq!(m.peek(0).text(), m.snapshot().text());
    }

    #[test]
    fn a_peek_row_encodes_exactly_as_a_stream_row_does() {
        let mut m = TerminalModel::new(20, 2, 100);
        m.feed(b"\x1b[31mred\r\n");
        m.feed(b"plain\r\n");
        let peek = m.peek(1);
        let history = &peek.lines()[0];
        assert_eq!(history.row, -1);
        assert_eq!(
            serde_json::to_string(history).unwrap(),
            r#"{"row":-1,"segs":[{"text":"red","fg":1}]}"#
        );
    }
}
