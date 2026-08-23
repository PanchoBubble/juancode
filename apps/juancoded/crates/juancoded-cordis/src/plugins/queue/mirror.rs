//! The client half of the queue contract, written as a type so the discipline is
//! enforced rather than described.
//!
//! Three rules, and each one is a shape here rather than a comment:
//!
//! - **No optimistic mutation.** [`QueueMirror::edit`] and [`QueueMirror::remove`]
//!   return a [`QueueRequest`] to send and change nothing locally. There is no method
//!   that edits a held row, so a client cannot show an edit the host has not accepted.
//! - **No inference.** [`QueueMirror::observe_activity`] exists and does nothing. A
//!   client that retires a row when the session goes idle is guessing that the row it
//!   is holding is the one that was just delivered, and a queue with two copies of the
//!   same text is exactly where that guess is wrong.
//! - **Reconnect replaces.** [`QueueMirror::apply_baseline`] overwrites a session's
//!   rows wholesale, including dropping rows the baseline does not mention. It never
//!   merges, and it does not compare revisions: a core that restarted counts from 1
//!   again, and a mirror that treated its own higher number as newer would render a
//!   queue that no longer exists.
//!
//! This lives next to the plugin rather than in the client, because the rule belongs
//! to the contract. A Swift or TypeScript client mirrors this type; the tests below
//! are what it has to keep true.

use std::collections::BTreeMap;

use crate::services::queue::{Occurrence, QueueSnapshot};

/// Something for the client to send. Holding one changes nothing on screen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QueueRequest {
    Edit {
        session: String,
        id: String,
        text: String,
    },
    Remove {
        session: String,
        id: String,
    },
}

/// A client's view of every queue it is watching.
#[derive(Debug, Default, Clone)]
pub struct QueueMirror {
    sessions: BTreeMap<String, QueueSnapshot>,
    stale: bool,
}

impl QueueMirror {
    pub fn new() -> Self {
        Self::default()
    }

    /// The subscribe reply, and the only thing a reconnect acts on. Replaces.
    pub fn apply_baseline(&mut self, snapshot: QueueSnapshot) {
        self.stale = false;
        self.sessions.insert(snapshot.session.clone(), snapshot);
    }

    /// A pushed snapshot. Replaces too; the revision only decides whether this one is
    /// news, because two snapshots can cross on the wire.
    pub fn apply_broadcast(&mut self, snapshot: QueueSnapshot) -> bool {
        if let Some(held) = self.sessions.get(&snapshot.session) {
            if !self.stale && snapshot.revision <= held.revision {
                return false;
            }
        }
        self.sessions.insert(snapshot.session.clone(), snapshot);
        true
    }

    /// The socket dropped. What is on screen is now history: it stays visible so the
    /// dock does not flicker, but nothing here is treated as current again until a
    /// baseline arrives.
    pub fn disconnected(&mut self) {
        self.stale = true;
    }

    pub fn is_stale(&self) -> bool {
        self.stale
    }

    pub fn rows(&self, session: &str) -> &[Occurrence] {
        self.sessions
            .get(session)
            .map(|snapshot| snapshot.items.as_slice())
            .unwrap_or(&[])
    }

    pub fn revision(&self, session: &str) -> u64 {
        self.sessions.get(session).map(|s| s.revision).unwrap_or(0)
    }

    /// What the dock renders: nothing at zero rows, one row at one, a count above.
    pub fn dock(&self, session: &str) -> Dock {
        match self.rows(session) {
            [] => Dock::Hidden,
            [one] => Dock::One(one.clone()),
            many => Dock::Collapsed(many.len()),
        }
    }

    /// Ask the host to edit. Returns what to send; the row changes when the host says
    /// so and not before.
    pub fn edit(&self, session: &str, id: &str, text: &str) -> QueueRequest {
        QueueRequest::Edit {
            session: session.to_string(),
            id: id.to_string(),
            text: text.to_string(),
        }
    }

    /// Ask the host to remove. Same rule.
    pub fn remove(&self, session: &str, id: &str) -> QueueRequest {
        QueueRequest::Remove {
            session: session.to_string(),
            id: id.to_string(),
        }
    }

    /// A turn, status or activity edge arrived. Deliberately not a queue event.
    #[allow(unused_variables)]
    pub fn observe_activity(&mut self, session: &str, activity: &str) {}
}

/// How the queue dock renders. There is no send-now, and no reorder: the only two
/// affordances a row carries are edit and delete.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Dock {
    Hidden,
    One(Occurrence),
    Collapsed(usize),
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::queue::{Content, ItemState};

    fn snapshot(session: &str, revision: u64, texts: &[(&str, &str)]) -> QueueSnapshot {
        QueueSnapshot {
            session: session.to_string(),
            revision,
            items: texts
                .iter()
                .map(|(id, text)| Occurrence {
                    id: (*id).to_string(),
                    content: Content::text(*text),
                    source: "telegram".into(),
                    created_at: 0,
                    state: ItemState::Pending,
                })
                .collect(),
        }
    }

    #[test]
    fn asking_for_an_edit_changes_nothing_until_the_host_says_so() {
        let mut mirror = QueueMirror::new();
        mirror.apply_baseline(snapshot("s1", 4, &[("q1", "typo")]));

        let request = mirror.edit("s1", "q1", "fixed");
        assert_eq!(
            request,
            QueueRequest::Edit {
                session: "s1".into(),
                id: "q1".into(),
                text: "fixed".into()
            }
        );
        assert_eq!(
            mirror.rows("s1")[0].content.as_text(),
            Some("typo"),
            "the row must not move ahead of the host"
        );

        mirror.apply_broadcast(snapshot("s1", 5, &[("q1", "fixed")]));
        assert_eq!(mirror.rows("s1")[0].content.as_text(), Some("fixed"));
    }

    #[test]
    fn asking_for_a_remove_leaves_the_row_on_screen_until_the_snapshot_drops_it() {
        let mut mirror = QueueMirror::new();
        mirror.apply_baseline(snapshot("s1", 1, &[("q1", "one"), ("q2", "two")]));
        let _ = mirror.remove("s1", "q1");
        assert_eq!(mirror.rows("s1").len(), 2);
        mirror.apply_broadcast(snapshot("s1", 2, &[("q2", "two")]));
        assert_eq!(mirror.rows("s1").len(), 1);
    }

    #[test]
    fn a_reconnect_replaces_the_whole_snapshot_rather_than_patching_it() {
        let mut mirror = QueueMirror::new();
        mirror.apply_baseline(snapshot("s1", 9, &[("q1", "one"), ("q2", "two")]));
        mirror.disconnected();
        assert!(mirror.is_stale());

        // A restarted core counts from 1 again and knows about one different row. The
        // mirror takes the baseline whole: the two rows it was holding are gone, not
        // merged with the new one, and the lower revision does not make it stale news.
        mirror.apply_baseline(snapshot("s1", 1, &[("q7", "something else")]));
        assert!(!mirror.is_stale());
        assert_eq!(mirror.revision("s1"), 1);
        assert_eq!(
            mirror
                .rows("s1")
                .iter()
                .map(|row| row.id.as_str())
                .collect::<Vec<_>>(),
            ["q7"]
        );
    }

    #[test]
    fn no_row_is_retired_by_reading_an_activity_edge() {
        let mut mirror = QueueMirror::new();
        mirror.apply_baseline(snapshot("s1", 1, &[("q1", "same"), ("q2", "same")]));
        // The exact shape of the bug: two occurrences of one text, and a turn that
        // finished. Which row did it deliver? The client does not get to guess.
        for edge in ["busy", "idle", "waitingInput", "idle"] {
            mirror.observe_activity("s1", edge);
        }
        assert_eq!(mirror.rows("s1").len(), 2);
        assert_eq!(mirror.revision("s1"), 1);
    }

    #[test]
    fn a_snapshot_that_crossed_a_newer_one_on_the_wire_is_ignored() {
        let mut mirror = QueueMirror::new();
        mirror.apply_baseline(snapshot("s1", 5, &[("q1", "current")]));
        assert!(!mirror.apply_broadcast(snapshot("s1", 4, &[("q1", "stale"), ("q2", "stale")])));
        assert_eq!(mirror.rows("s1").len(), 1);
        assert_eq!(mirror.rows("s1")[0].content.as_text(), Some("current"));
    }

    #[test]
    fn the_dock_hides_at_zero_shows_one_row_at_one_and_collapses_above() {
        let mut mirror = QueueMirror::new();
        assert_eq!(mirror.dock("s1"), Dock::Hidden);
        mirror.apply_baseline(snapshot("s1", 1, &[("q1", "one")]));
        assert!(matches!(mirror.dock("s1"), Dock::One(row) if row.id == "q1"));
        mirror.apply_broadcast(snapshot("s1", 2, &[("q1", "one"), ("q2", "two")]));
        assert_eq!(mirror.dock("s1"), Dock::Collapsed(2));
        mirror.apply_broadcast(snapshot("s1", 3, &[]));
        assert_eq!(mirror.dock("s1"), Dock::Hidden);
    }
}
