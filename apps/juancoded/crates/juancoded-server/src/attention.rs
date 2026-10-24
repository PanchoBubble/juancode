//! Shared attention state. Only lifecycle evidence creates items; terminal text is
//! never interpreted as an approval contract. Full snapshots are replacement values.
use juancoded_core::model::{now_ms, SessionActivity};
use juancoded_persistence::SessionStore;
use juancoded_state::{registry::SessionEvent, SessionsApi};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::sync::broadcast::{error::TryRecvError, Receiver};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AttentionItem {
    pub id: String,
    pub session_id: String,
    pub kind: AttentionKind,
    pub created_at: i64,
    pub updated_at: i64,
    pub acknowledged: bool,
    pub resolved: bool,
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum AttentionKind {
    Waiting,
    Error,
    Completion,
}

struct Book {
    dirty: bool,
    items: Vec<AttentionItem>,
    states: HashMap<String, SessionActivity>,
    events: Receiver<SessionEvent>,
}
pub struct Attention {
    sessions: Arc<dyn SessionsApi>,
    store: Arc<dyn SessionStore>,
    book: Mutex<Book>,
}
impl Attention {
    pub fn new(
        sessions: Arc<dyn SessionsApi>,
        store: Arc<dyn SessionStore>,
    ) -> anyhow::Result<Arc<Self>> {
        let events = sessions.subscribe();
        let items = serde_json::from_str(&store.attention()?)?;
        let mut book = Book {
            dirty: false,
            items,
            states: HashMap::new(),
            events,
        };
        book.reconcile(sessions.as_ref());
        store.save_attention(&serde_json::to_string(&book.items)?)?;
        Ok(Arc::new(Self {
            sessions,
            store,
            book: Mutex::new(book),
        }))
    }
    // Drain while holding the same lock as acknowledgements. A delayed activity
    // cannot restore an item behind a successful acknowledgement.
    fn refresh(&self, book: &mut Book) -> anyhow::Result<()> {
        let before = book.items.clone();
        loop {
            match book.events.try_recv() {
                Ok(event) => book.apply(event),
                Err(TryRecvError::Lagged(_)) => book.reconcile(self.sessions.as_ref()),
                Err(_) => break,
            }
        }
        book.dirty |= book.items != before;
        if book.dirty {
            self.store
                .save_attention(&serde_json::to_string(&book.items)?)?;
        }
        book.dirty = false;
        Ok(())
    }
    pub fn list(&self) -> anyhow::Result<Vec<AttentionItem>> {
        let mut book = self.book.lock().unwrap_or_else(|e| e.into_inner());
        self.refresh(&mut book)?;
        let mut items = book.items.clone();
        items.sort_by(|a, b| (a.created_at, &a.id).cmp(&(b.created_at, &b.id)));
        Ok(items)
    }
    pub fn acknowledge(&self, id: &str) -> anyhow::Result<()> {
        let mut book = self.book.lock().unwrap_or_else(|e| e.into_inner());
        self.refresh(&mut book)?;
        let mut next = book.items.clone();
        let item = next
            .iter_mut()
            .find(|i| i.id == id)
            .ok_or_else(|| anyhow::anyhow!("attention-not-found"))?;
        if item.acknowledged {
            return Ok(());
        }
        item.acknowledged = true;
        item.updated_at = now_ms();
        self.store.save_attention(&serde_json::to_string(&next)?)?;
        book.items = next;
        Ok(())
    }
    pub fn spawn(self: &Arc<Self>) -> AttentionTask {
        let weak = Arc::downgrade(self);
        AttentionTask(tokio::spawn(async move {
            let mut tick = tokio::time::interval(std::time::Duration::from_millis(40));
            loop {
                tick.tick().await;
                let Some(engine) = weak.upgrade() else { break };
                if let Err(e) = engine.list() {
                    tracing::warn!("attention update failed: {e:#}");
                }
            }
        }))
    }
}
pub struct AttentionTask(tokio::task::JoinHandle<()>);
impl Drop for AttentionTask {
    fn drop(&mut self) {
        self.0.abort();
    }
}
impl Book {
    fn open(&mut self, session: &str, kind: AttentionKind) {
        if self
            .items
            .iter()
            .any(|i| i.session_id == session && i.kind == kind && !i.resolved)
        {
            return;
        }
        // Keep the latest occurrence of each kind per session, not an unbounded log.
        self.items
            .retain(|i| i.session_id != session || i.kind != kind);
        let now = now_ms();
        self.items.push(AttentionItem {
            id: uuid::Uuid::new_v4().to_string(),
            session_id: session.into(),
            kind,
            created_at: now,
            updated_at: now,
            acknowledged: false,
            resolved: false,
        });
    }
    fn resolve(&mut self, session: &str, kind: AttentionKind) {
        for item in &mut self.items {
            if item.session_id == session && item.kind == kind && !item.resolved {
                item.resolved = true;
                item.updated_at = now_ms();
            }
        }
    }
    fn reconcile(&mut self, sessions: &dyn SessionsApi) {
        self.items
            .retain(|i| sessions.meta(&i.session_id).is_some_and(|m| !m.archived));
        for id in sessions.ids() {
            if sessions.meta(&id).is_some_and(|m| m.archived || m.dormant) {
                self.resolve(&id, AttentionKind::Waiting);
                continue;
            }
            let state = sessions.activity(&id).unwrap_or(SessionActivity::Idle);
            self.states.insert(id.clone(), state);
            if sessions.is_running(&id) && state == SessionActivity::WaitingInput {
                self.open(&id, AttentionKind::Waiting);
            } else {
                self.resolve(&id, AttentionKind::Waiting);
            }
        }
    }
    fn apply(&mut self, event: SessionEvent) {
        match event {
            SessionEvent::Activity {
                session_id,
                state,
                notify,
                ..
            } => {
                let previous = self.states.insert(session_id.clone(), state);
                if state == SessionActivity::WaitingInput {
                    self.open(&session_id, AttentionKind::Waiting);
                } else {
                    self.resolve(&session_id, AttentionKind::Waiting);
                }
                if state == SessionActivity::Busy {
                    self.resolve(&session_id, AttentionKind::Error);
                }
                if state == SessionActivity::Idle
                    && notify
                    && previous != Some(SessionActivity::Idle)
                {
                    self.resolve(&session_id, AttentionKind::Completion);
                    self.open(&session_id, AttentionKind::Completion);
                }
            }
            SessionEvent::Exit {
                session_id,
                exit_code,
            } => {
                self.resolve(&session_id, AttentionKind::Waiting);
                self.states
                    .insert(session_id.clone(), SessionActivity::Idle);
                if exit_code.is_some_and(|c| c != 0) {
                    self.open(&session_id, AttentionKind::Error);
                }
            }
            SessionEvent::Deleted { session_id, .. } => {
                self.items.retain(|i| i.session_id != session_id);
                self.states.remove(&session_id);
            }
            SessionEvent::Meta { session_id, meta } if meta.archived || meta.dormant => {
                if meta.archived {
                    self.items.retain(|i| i.session_id != session_id);
                } else {
                    self.resolve(&session_id, AttentionKind::Waiting);
                }
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::FakeChild;
    use juancoded_persistence::SqliteStore;
    fn activity(child: &FakeChild, state: SessionActivity, notify: bool) {
        child.publish(SessionEvent::Activity {
            session_id: "fake".into(),
            state,
            notify,
            changes: None,
            dispatch_id: None,
        });
    }
    #[test]
    fn lifecycle_dedupes_and_preserves_acknowledged_completion() {
        let child = FakeChild::new(false);
        let store = Arc::new(SqliteStore::open(":memory:").unwrap());
        let engine = Attention::new(child.api(), store.clone()).unwrap();
        activity(&child, SessionActivity::WaitingInput, true);
        let waiting = engine.list().unwrap()[0].clone();
        activity(&child, SessionActivity::WaitingInput, true);
        assert_eq!(engine.list().unwrap(), vec![waiting.clone()]);
        engine.acknowledge(&waiting.id).unwrap();
        activity(&child, SessionActivity::Busy, false);
        activity(&child, SessionActivity::Idle, true);
        let items = engine.list().unwrap();
        assert!(
            items
                .iter()
                .find(|i| i.kind == AttentionKind::Waiting)
                .unwrap()
                .resolved
        );
        let completion = items
            .iter()
            .find(|i| i.kind == AttentionKind::Completion)
            .unwrap();
        let id = completion.id.clone();
        engine.acknowledge(&id).unwrap();
        activity(&child, SessionActivity::Idle, true);
        assert!(
            engine
                .list()
                .unwrap()
                .iter()
                .find(|i| i.id == id)
                .unwrap()
                .acknowledged
        );
        drop(engine);
        let engine = Attention::new(child.api(), store).unwrap();
        assert!(
            engine
                .list()
                .unwrap()
                .iter()
                .find(|i| i.id == id)
                .unwrap()
                .acknowledged
        );
        activity(&child, SessionActivity::Busy, false);
        activity(&child, SessionActivity::Idle, true);
        let items = engine.list().unwrap();
        let next = items
            .iter()
            .find(|i| i.kind == AttentionKind::Completion)
            .unwrap();
        assert_ne!(next.id, id);
        assert!(!next.acknowledged);
        assert!(engine.acknowledge("unknown").is_err());
        assert!(
            child.written().is_empty(),
            "acknowledgement must never type into the PTY"
        );
    }
    #[test]
    fn exit_error_resume_delete_and_restart_waiting() {
        let child = FakeChild::new(false);
        let store = Arc::new(SqliteStore::open(":memory:").unwrap());
        let engine = Attention::new(child.api(), store.clone()).unwrap();
        activity(&child, SessionActivity::WaitingInput, true);
        engine.list().unwrap();
        child.publish(SessionEvent::Exit {
            session_id: "fake".into(),
            exit_code: Some(1),
        });
        let items = engine.list().unwrap();
        assert!(
            items
                .iter()
                .find(|i| i.kind == AttentionKind::Waiting)
                .unwrap()
                .resolved
        );
        assert_eq!(items.iter().filter(|i| !i.resolved).count(), 1);
        child.publish(SessionEvent::Exit {
            session_id: "fake".into(),
            exit_code: Some(1),
        });
        assert_eq!(engine.list().unwrap(), items);
        activity(&child, SessionActivity::Busy, false);
        assert!(engine.list().unwrap().iter().all(|i| i.resolved));
        activity(&child, SessionActivity::WaitingInput, true);
        engine.list().unwrap();
        drop(engine);
        let engine = Attention::new(child.api(), store).unwrap();
        assert!(
            engine.list().unwrap().iter().all(|i| i.resolved),
            "restart cannot preserve stale waiting"
        );
        child.publish(SessionEvent::Deleted {
            session_id: "fake".into(),
            worktree_path: None,
            worktree_removed: None,
        });
        assert!(engine.list().unwrap().is_empty());
    }
    #[test]
    fn snapshot_order_and_disk_reopen() {
        let path = std::env::temp_dir().join(format!("attention-{}.db", uuid::Uuid::new_v4()));
        let child = FakeChild::new(false);
        let id;
        {
            let store = Arc::new(SqliteStore::open(&path).unwrap());
            let engine = Attention::new(child.api(), store).unwrap();
            activity(&child, SessionActivity::Busy, false);
            activity(&child, SessionActivity::Idle, true);
            id = engine.list().unwrap()[0].id.clone();
            engine.acknowledge(&id).unwrap();
        }
        {
            let store = Arc::new(SqliteStore::open(&path).unwrap());
            let engine = Attention::new(child.api(), store).unwrap();
            let snapshot = engine.list().unwrap();
            assert_eq!(snapshot[0].id, id);
            assert!(snapshot[0].acknowledged);
            assert_eq!(
                engine.list().unwrap(),
                snapshot,
                "reconnect is a replacement snapshot"
            );
            activity(&child, SessionActivity::WaitingInput, true);
            let snapshot = engine.list().unwrap();
            assert!(snapshot
                .windows(2)
                .all(|w| (w[0].created_at, &w[0].id) <= (w[1].created_at, &w[1].id)));
        }
        std::fs::remove_file(path).unwrap();
    }
}
