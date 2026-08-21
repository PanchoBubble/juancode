//! The entry list: composition as data.
//!
//! An ordered list of rows, each naming a plugin and carrying a stable `id`. The
//! loader diffs by `id`, so editing one row does not disturb its neighbours, and
//! `disabled = true` unmounts a plugin without deleting the row that describes it.
//!
//! An entry built without an explicit id gets a generated one that is fresh on every
//! read. That is deliberate, and it is cordis's documented behaviour: with no stable
//! identity the loader cannot tell an edit from a removal plus an addition, so the
//! row remounts on every config read. Give every row you care about an id.

use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};

static GENERATED: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub id: String,
    /// The plugin's registered name, which is how the loader finds it.
    pub name: String,
    #[serde(default)]
    pub disabled: bool,
    #[serde(default)]
    pub config: serde_json::Value,
    /// True when `id` was generated rather than written down.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub anonymous: bool,
}

impl Entry {
    /// A row with a stable identity. This is the form to use.
    pub fn new(id: impl Into<String>, name: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            disabled: false,
            config: serde_json::Value::Null,
            anonymous: false,
        }
    }

    /// A row with no written-down identity, which therefore remounts on every read.
    pub fn anonymous(name: impl Into<String>) -> Self {
        let name = name.into();
        let n = GENERATED.fetch_add(1, Ordering::Relaxed);
        Self {
            id: format!("{name}#{n}"),
            name,
            disabled: false,
            config: serde_json::Value::Null,
            anonymous: true,
        }
    }

    pub fn disabled(mut self, disabled: bool) -> Self {
        self.disabled = disabled;
        self
    }

    pub fn config(mut self, config: serde_json::Value) -> Self {
        self.config = config;
        self
    }
}

/// An ordered list of entries, unique by id.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct EntryList {
    entries: Vec<Entry>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DuplicateId(pub String);

impl std::fmt::Display for DuplicateId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "two entries claim the id `{}`", self.0)
    }
}

impl std::error::Error for DuplicateId {}

impl EntryList {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(mut self, entry: Entry) -> Self {
        self.entries.push(entry);
        self
    }

    pub fn entries(&self) -> &[Entry] {
        &self.entries
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn get(&self, id: &str) -> Option<&Entry> {
        self.entries.iter().find(|e| e.id == id)
    }

    /// Flip one row's `disabled`, addressed by id. Returns false if no such row.
    pub fn set_disabled(&mut self, id: &str, disabled: bool) -> bool {
        match self.entries.iter_mut().find(|e| e.id == id) {
            Some(entry) => {
                entry.disabled = disabled;
                true
            }
            None => false,
        }
    }

    /// Replace one row's config, addressed by id.
    pub fn set_config(&mut self, id: &str, config: serde_json::Value) -> bool {
        match self.entries.iter_mut().find(|e| e.id == id) {
            Some(entry) => {
                entry.config = config;
                true
            }
            None => false,
        }
    }

    pub fn remove(&mut self, id: &str) -> Option<Entry> {
        let pos = self.entries.iter().position(|e| e.id == id)?;
        Some(self.entries.remove(pos))
    }

    /// Ids are the addressing scheme for everything else, so a collision has to be an
    /// error at read time rather than a last-writer-wins surprise at mount time.
    pub fn validate(&self) -> Result<(), DuplicateId> {
        let mut seen = std::collections::BTreeSet::new();
        for entry in &self.entries {
            if !seen.insert(entry.id.as_str()) {
                return Err(DuplicateId(entry.id.clone()));
            }
        }
        Ok(())
    }
}

impl FromIterator<Entry> for EntryList {
    fn from_iter<I: IntoIterator<Item = Entry>>(iter: I) -> Self {
        Self {
            entries: iter.into_iter().collect(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_anonymous_entry_gets_a_different_id_on_every_read() {
        let first = Entry::anonymous("greeter");
        let second = Entry::anonymous("greeter");
        assert_ne!(first.id, second.id);
        assert!(first.anonymous);
    }

    #[test]
    fn a_named_entry_keeps_its_id() {
        assert_eq!(Entry::new("greeter", "greeter").id, "greeter");
        assert!(!Entry::new("greeter", "greeter").anonymous);
    }

    #[test]
    fn duplicate_ids_are_rejected_at_read_time() {
        let list = EntryList::new()
            .push(Entry::new("a", "one"))
            .push(Entry::new("a", "two"));
        assert_eq!(list.validate().unwrap_err(), DuplicateId("a".into()));
    }

    #[test]
    fn rows_are_addressable_by_id() {
        let mut list = EntryList::new()
            .push(Entry::new("a", "one"))
            .push(Entry::new("b", "two"));
        assert!(list.set_disabled("b", true));
        assert!(!list.set_disabled("nope", true));
        assert!(list.get("b").unwrap().disabled);
        assert!(!list.get("a").unwrap().disabled);
    }

    #[test]
    fn an_entry_list_round_trips_through_json() {
        let list = EntryList::new()
            .push(Entry::new("terminal", "vt-terminal"))
            .push(Entry::new("guard", "input-guard").disabled(true));
        let json = serde_json::to_string(&list).unwrap();
        assert_eq!(serde_json::from_str::<EntryList>(&json).unwrap(), list);
    }
}
