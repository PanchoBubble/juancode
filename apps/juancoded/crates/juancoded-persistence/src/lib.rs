//! Session persistence. Spike-level on purpose: the shape of the seam, with an
//! in-memory implementation behind it.
//!
//! The real store (SQLite, per-core DB file, retention cap) is juancode-52e8.6. The
//! constraint that makes the two-core switch safe lives here: one DB file per core,
//! so a session started under one core is simply not visible under the other. That
//! is why `db_path` takes the core name.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

use juancoded_core::model::SessionMeta;

/// Where a core's session DB lives. Separate file per core — no shared SQLite, no
/// live-session migration, no way for one core to half-read the other's rows.
pub fn db_path(core: &str) -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(format!("{home}/.juancode/data/juancode-{core}.db"))
}

pub trait SessionStore: Send + Sync {
    fn upsert(&self, meta: &SessionMeta);
    fn get(&self, id: &str) -> Option<SessionMeta>;
    fn all(&self) -> Vec<SessionMeta>;
}

#[derive(Default)]
pub struct MemoryStore {
    rows: Mutex<HashMap<String, SessionMeta>>,
}

impl SessionStore for MemoryStore {
    fn upsert(&self, meta: &SessionMeta) {
        if let Ok(mut rows) = self.rows.lock() {
            rows.insert(meta.id.clone(), meta.clone());
        }
    }

    fn get(&self, id: &str) -> Option<SessionMeta> {
        self.rows.lock().ok()?.get(id).cloned()
    }

    fn all(&self) -> Vec<SessionMeta> {
        let Ok(rows) = self.rows.lock() else {
            return Vec::new();
        };
        let mut all: Vec<_> = rows.values().cloned().collect();
        all.sort_by_key(|m| m.created_at);
        all
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use juancoded_core::model::{now_ms, ProviderId};

    fn meta(id: &str, at: i64) -> SessionMeta {
        let mut m = SessionMeta::new(
            id.into(),
            ProviderId::Claude,
            "/tmp".into(),
            "tmp".into(),
            now_ms(),
            false,
        );
        m.created_at = at;
        m
    }

    #[test]
    fn each_core_gets_its_own_db_file() {
        let swift = db_path("swift");
        let rust = db_path("rust");
        assert_ne!(swift, rust);
        assert!(swift.to_string_lossy().ends_with("juancode-swift.db"));
    }

    #[test]
    fn upsert_replaces_and_all_is_ordered_by_creation() {
        let store = MemoryStore::default();
        store.upsert(&meta("b", 2));
        store.upsert(&meta("a", 1));
        assert_eq!(
            store.all().iter().map(|m| m.id.clone()).collect::<Vec<_>>(),
            ["a", "b"]
        );

        let mut updated = meta("a", 1);
        updated.title = "renamed".into();
        store.upsert(&updated);
        assert_eq!(store.get("a").unwrap().title, "renamed");
        assert_eq!(store.all().len(), 2);
    }
}
