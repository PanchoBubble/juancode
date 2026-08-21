//! Per-connection rendered-screen streaming — the cheap, phone-friendly
//! alternative to the raw byte stream, and a port of `ScreenStreamer.swift`.
//!
//! Read-only by construction: it only ever reads snapshots, so a screen viewer can
//! never resize or otherwise disturb the grid. Diffs are computed against the last
//! snapshot actually SENT, so a skipped tick loses nothing — the next one emits one
//! coalesced diff covering everything since.

use juancoded_vt::wire::{changed_lines, full_lines};
use juancoded_vt::Snapshot;

use crate::wire::ServerMessage;

pub struct ScreenStreamer {
    session_id: String,
    last_sent: Option<Snapshot>,
}

impl ScreenStreamer {
    pub fn new(session_id: String) -> Self {
        Self {
            session_id,
            last_sent: None,
        }
    }

    /// The next frame to send, or `None` when nothing changed. A geometry or
    /// screen-buffer flip forces a full repaint (`reset: true`).
    pub fn frame(&mut self, snapshot: Snapshot) -> Option<ServerMessage> {
        let reset = match &self.last_sent {
            None => true,
            Some(prev) => {
                prev.cols != snapshot.cols || prev.rows != snapshot.rows || prev.alt != snapshot.alt
            }
        };
        let lines = if reset {
            full_lines(&snapshot)
        } else {
            let prev = self.last_sent.as_ref().expect("checked above");
            let changed = changed_lines(prev, &snapshot);
            // Cursor moves alone are worth a frame; a byte-identical grid is not.
            if changed.is_empty()
                && prev.cursor_x == snapshot.cursor_x
                && prev.cursor_y == snapshot.cursor_y
                && prev.cursor_visible == snapshot.cursor_visible
            {
                return None;
            }
            changed
        };
        let msg = ServerMessage::Screen {
            session_id: self.session_id.clone(),
            reset,
            cols: snapshot.cols,
            rows: snapshot.rows,
            cursor_x: snapshot.cursor_x,
            cursor_y: snapshot.cursor_y,
            cursor_visible: snapshot.cursor_visible,
            alt: snapshot.alt,
            lines,
        };
        self.last_sent = Some(snapshot);
        Some(msg)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use juancoded_vt::TerminalModel;

    #[test]
    fn the_first_frame_is_a_full_reset_and_a_quiet_grid_sends_nothing() {
        let mut model = TerminalModel::new(20, 4, 100);
        model.feed(b"hello");
        let mut streamer = ScreenStreamer::new("s".into());

        let first = streamer.frame(model.snapshot()).expect("first frame");
        match &first {
            ServerMessage::Screen { reset, lines, .. } => {
                assert!(*reset);
                assert_eq!(lines.len(), 4); // every visible row
            }
            _ => panic!("expected a screen frame"),
        }
        assert!(
            streamer.frame(model.snapshot()).is_none(),
            "unchanged grid re-sent"
        );
    }

    #[test]
    fn a_later_frame_carries_only_the_changed_rows() {
        let mut model = TerminalModel::new(20, 4, 100);
        model.feed(b"row one\r\n");
        let mut streamer = ScreenStreamer::new("s".into());
        streamer.frame(model.snapshot());

        model.feed(b"row two");
        match streamer.frame(model.snapshot()).expect("diff frame") {
            ServerMessage::Screen { reset, lines, .. } => {
                assert!(!reset);
                assert_eq!(lines.len(), 1);
                assert_eq!(lines[0].row, 1);
            }
            _ => panic!("expected a screen frame"),
        }
    }

    #[test]
    fn a_geometry_change_forces_a_full_repaint() {
        let mut model = TerminalModel::new(20, 4, 100);
        model.feed(b"x");
        let mut streamer = ScreenStreamer::new("s".into());
        streamer.frame(model.snapshot());

        model.resize(30, 6);
        match streamer.frame(model.snapshot()).expect("repaint") {
            ServerMessage::Screen {
                reset,
                cols,
                rows,
                lines,
                ..
            } => {
                assert!(reset);
                assert_eq!((cols, rows), (30, 6));
                assert_eq!(lines.len(), 6);
            }
            _ => panic!("expected a screen frame"),
        }
    }

    #[test]
    fn an_alt_screen_flip_forces_a_full_repaint() {
        let mut model = TerminalModel::new(20, 4, 100);
        let mut streamer = ScreenStreamer::new("s".into());
        streamer.frame(model.snapshot());
        model.feed(b"\x1b[?1049h");
        match streamer.frame(model.snapshot()).expect("repaint") {
            ServerMessage::Screen { reset, alt, .. } => {
                assert!(reset);
                assert!(alt);
            }
            _ => panic!("expected a screen frame"),
        }
    }

    #[test]
    fn a_cursor_move_alone_still_produces_a_frame() {
        let mut model = TerminalModel::new(20, 4, 100);
        model.feed(b"abc");
        let mut streamer = ScreenStreamer::new("s".into());
        streamer.frame(model.snapshot());
        model.feed(b"\x1b[3;1H"); // move the cursor, touch no cell
        let frame = streamer.frame(model.snapshot()).expect("cursor frame");
        match frame {
            ServerMessage::Screen {
                reset, cursor_y, ..
            } => {
                assert!(!reset);
                assert_eq!(cursor_y, 2);
            }
            _ => panic!("expected a screen frame"),
        }
    }
}
