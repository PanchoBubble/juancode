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

use alacritty_terminal::event::VoidListener;
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

/// The headless terminal model for one session: the parser plus the grid it owns.
///
/// Single-threaded by construction — hold it behind the session's own lock and
/// there is exactly one writer, which is the whole point.
pub struct TerminalModel {
    term: Term<VoidListener>,
    parser: Processor,
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
        Self {
            term: Term::new(config, &size, VoidListener),
            parser: Processor::new(),
            cols,
            rows,
            history,
        }
    }

    /// Feed pty bytes. The only mutation path into the grid.
    pub fn feed(&mut self, bytes: &[u8]) {
        self.parser.advance(&mut self.term, bytes);
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
            let line = Line(row as i32 - display_offset as i32);
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
            lines.push(Row { cells, text });
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
}
