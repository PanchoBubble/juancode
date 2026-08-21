//! `screen` frame encoding — a line-for-line port of `ScreenWire.swift`.
//!
//! The compression contract (kept identical so both cores emit the same bytes):
//! consecutive cells sharing fg/bg/style collapse into one segment; trailing
//! blanks with nothing visible are dropped; a default colour is omitted from the
//! JSON, `defaultInverted` is the string "inv", an ANSI index is a number, a
//! truecolor is "#rrggbb"; `st` is omitted when the style is plain.

use serde::ser::{SerializeStruct, Serializer};
use serde::Serialize;

use crate::{Color, Row, Snapshot};

/// One styled run of a row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Segment {
    pub text: String,
    pub fg: Color,
    pub bg: Color,
    pub style: u8,
}

impl Serialize for Segment {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let fields = 1
            + usize::from(self.fg != Color::Default)
            + usize::from(self.bg != Color::Default)
            + usize::from(self.style != 0);
        let mut st = s.serialize_struct("Segment", fields)?;
        st.serialize_field("text", &self.text)?;
        serialize_color(&mut st, "fg", self.fg)?;
        serialize_color(&mut st, "bg", self.bg)?;
        if self.style != 0 {
            st.serialize_field("st", &self.style)?;
        }
        st.end()
    }
}

fn serialize_color<S: SerializeStruct>(
    st: &mut S,
    key: &'static str,
    color: Color,
) -> Result<(), S::Error> {
    match color {
        Color::Default => Ok(()),
        Color::DefaultInverted => st.serialize_field(key, "inv"),
        Color::Ansi(i) => st.serialize_field(key, &i),
        Color::TrueColor(r, g, b) => st.serialize_field(key, &format!("#{r:02x}{g:02x}{b:02x}")),
    }
}

/// One row of a `screen` frame. Empty `segs` means a blank row.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RowUpdate {
    pub row: usize,
    pub segs: Vec<Segment>,
}

/// Run-length compress a row into wire segments.
pub fn segments(row: &Row) -> Vec<Segment> {
    let mut cells = &row.cells[..];
    while let Some(last) = cells.last() {
        if last.ch == ' ' && last.bg == Color::Default && last.style == 0 {
            cells = &cells[..cells.len() - 1];
        } else {
            break;
        }
    }
    let mut segs: Vec<Segment> = Vec::new();
    for cell in cells {
        match segs.last_mut() {
            Some(last) if last.fg == cell.fg && last.bg == cell.bg && last.style == cell.style => {
                last.text.push(cell.ch);
            }
            _ => segs.push(Segment {
                text: cell.ch.to_string(),
                fg: cell.fg,
                bg: cell.bg,
                style: cell.style,
            }),
        }
    }
    segs
}

/// Every visible row — the `reset: true` payload.
pub fn full_lines(snapshot: &Snapshot) -> Vec<RowUpdate> {
    snapshot
        .lines
        .iter()
        .enumerate()
        .map(|(row, r)| RowUpdate {
            row,
            segs: segments(r),
        })
        .collect()
}

/// Only the rows that differ — the `reset: false` payload. A row present in one
/// snapshot but not the other counts as changed; callers repaint wholesale on a
/// geometry change anyway.
pub fn changed_lines(prev: &Snapshot, next: &Snapshot) -> Vec<RowUpdate> {
    let mut out = Vec::new();
    for row in 0..prev.lines.len().max(next.lines.len()) {
        let old = prev.lines.get(row);
        let new = next.lines.get(row);
        if old == new {
            continue;
        }
        out.push(RowUpdate {
            row,
            segs: new.map(segments).unwrap_or_default(),
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TerminalModel;

    fn model_with(bytes: &[u8]) -> TerminalModel {
        let mut m = TerminalModel::new(20, 5, 100);
        m.feed(bytes);
        m
    }

    #[test]
    fn plain_text_lands_in_one_segment_with_no_colour_keys() {
        let m = model_with(b"hello");
        let snap = m.snapshot();
        let segs = segments(&snap.lines[0]);
        assert_eq!(segs.len(), 1);
        assert_eq!(segs[0].text, "hello");
        let json = serde_json::to_string(&segs[0]).unwrap();
        assert_eq!(json, r#"{"text":"hello"}"#);
    }

    #[test]
    fn sgr_colour_splits_the_run_and_encodes_as_an_ansi_index() {
        let m = model_with(b"ab\x1b[31mcd");
        let snap = m.snapshot();
        let segs = segments(&snap.lines[0]);
        assert_eq!(segs.len(), 2);
        assert_eq!(segs[1].text, "cd");
        assert_eq!(segs[1].fg, Color::Ansi(1));
        let json = serde_json::to_string(&segs[1]).unwrap();
        assert_eq!(json, r#"{"text":"cd","fg":1}"#);
    }

    #[test]
    fn truecolor_and_style_use_the_swift_bitmask_and_hex_form() {
        let m = model_with(b"\x1b[1;38;2;18;52;86mx");
        let snap = m.snapshot();
        let segs = segments(&snap.lines[0]);
        assert_eq!(segs[0].fg, Color::TrueColor(0x12, 0x34, 0x56));
        assert_eq!(segs[0].style, crate::style::BOLD);
        let json = serde_json::to_string(&segs[0]).unwrap();
        assert_eq!(json, r##"{"text":"x","fg":"#123456","st":1}"##);
    }

    #[test]
    fn trailing_blanks_are_dropped_but_a_coloured_blank_survives() {
        let m = model_with(b"hi");
        let snap = m.snapshot();
        // 20 columns wide, but only "hi" ships.
        assert_eq!(segments(&snap.lines[0])[0].text, "hi");
        assert_eq!(segments(&snap.lines[0]).len(), 1);

        let m = model_with(b"hi\x1b[41m  ");
        let snap = m.snapshot();
        let segs = segments(&snap.lines[0]);
        assert_eq!(segs.len(), 2);
        assert_eq!(segs[1].bg, Color::Ansi(1));
        assert_eq!(segs[1].text, "  ");
    }

    #[test]
    fn changed_lines_reports_only_the_touched_row() {
        let mut m = TerminalModel::new(20, 5, 100);
        m.feed(b"line one\r\n");
        let prev = m.snapshot();
        m.feed(b"line two");
        let next = m.snapshot();
        let changed = changed_lines(&prev, &next);
        assert_eq!(changed.len(), 1);
        assert_eq!(changed[0].row, 1);
        assert_eq!(changed[0].segs[0].text, "line two");
    }

    #[test]
    fn alt_screen_and_cursor_visibility_are_reported() {
        let mut m = TerminalModel::new(20, 5, 100);
        let snap = m.snapshot();
        assert!(!snap.alt);
        assert!(snap.cursor_visible);
        m.feed(b"\x1b[?1049h\x1b[?25l");
        let snap = m.snapshot();
        assert!(snap.alt);
        assert!(!snap.cursor_visible);
    }

    #[test]
    fn snapshot_text_trims_trailing_blank_rows() {
        let mut m = TerminalModel::new(20, 5, 100);
        m.feed(b"a\r\nb");
        assert_eq!(m.snapshot().text(), "a\nb");
    }
}
