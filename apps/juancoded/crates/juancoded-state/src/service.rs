//! The two keys the state layer claims, and the contracts behind them.
//!
//! The state layer **mounts into** cordis rather than sitting beside it: `sessions`
//! and `store` are ordinary keyed services, the registry resolves `pty`, `terminal`
//! and `store` by key like any other consumer, and the wire layer holds an
//! `Arc<dyn SessionsApi>` without knowing that a registry, a SQLite file or an
//! `alacritty_terminal` grid exist. There is exactly one composition mechanism in
//! this daemon, and it is the one juancode-52e8.4 built.

use std::sync::Arc;

use juancoded_cordis::Service;
use juancoded_persistence::{QueuedMessage, SessionStore};
use juancoded_transcripts::TranscriptRecord;
use juancoded_vt::Snapshot;

use juancoded_core::model::{SessionActivity, SessionMeta};
use tokio::sync::broadcast;

use crate::grid::{ClientId, ResizeOutcome};
use crate::reaper::ReapProbe;
use crate::registry::{
    AdoptRequest, Attached, CreateRequest, SessionEvent, SessionRegistry, StateError,
};
use crate::stuck::StuckAlert;

/// What consumers of the `sessions` key may do. Everything the wire protocol needs
/// and nothing more: no pty handle, no grid, no store.
pub trait SessionsApi: Send + Sync {
    fn subscribe(&self) -> broadcast::Receiver<SessionEvent>;
    fn ids(&self) -> Vec<String>;
    fn meta(&self, id: &str) -> Option<SessionMeta>;
    fn is_running(&self, id: &str) -> bool;
    fn activity(&self, id: &str) -> Option<SessionActivity>;
    fn snapshot(&self, id: &str) -> Option<Snapshot>;
    fn grid(&self, id: &str) -> Option<(u16, u16)>;
    /// Which client drives the session's grid, or `None` when it is unclaimed. The
    /// wire layer needs it to tell an arriving connection what it missed.
    fn grid_owner(&self, id: &str) -> Option<ClientId>;
    /// The per-project session cap this registry enforces. On the trait rather than
    /// read back out of the environment by whoever wants it, because the two answers
    /// diverge for any tree built with a config of its own — and the number is only
    /// worth reporting if it is the one that actually prunes.
    fn retention(&self) -> usize;

    fn create(&self, req: CreateRequest) -> Result<SessionMeta, StateError>;
    fn adopt_external(&self, req: AdoptRequest) -> Result<Option<SessionMeta>, StateError>;
    fn attach(
        &self,
        id: &str,
        owner: ClientId,
        cols: u16,
        rows: u16,
    ) -> Result<Attached, StateError>;
    fn reactivate(
        &self,
        id: &str,
        owner: ClientId,
        cols: u16,
        rows: u16,
    ) -> Result<Option<Attached>, StateError>;
    fn set_skip_permissions(
        &self,
        id: &str,
        skip: bool,
        owner: ClientId,
        cols: u16,
        rows: u16,
    ) -> Result<Attached, StateError>;
    fn input(&self, id: &str, data: &[u8]) -> Result<(), StateError>;
    /// A session's pending steering messages, in delivery order. The whole list, so
    /// a consumer replaces what it holds instead of patching it.
    fn queue(&self, id: &str) -> Vec<QueuedMessage>;
    /// Queue one message. `Ok(None)` is the whitespace-only text that was not a
    /// message at all.
    fn queue_message(&self, id: &str, text: &str) -> Result<Option<QueuedMessage>, StateError>;
    /// Cancel a still-pending message; `false` when it was not in that queue.
    fn dequeue_message(&self, id: &str, message_id: &str) -> Result<bool, StateError>;
    fn resize(&self, id: &str, owner: ClientId, cols: u16, rows: u16) -> ResizeOutcome;
    fn release_client(&self, owner: ClientId);
    fn kill(&self, id: &str) -> Result<(), StateError>;

    /// Records one session's CLI has newly appended to its own transcript.
    ///
    /// On the trait for the same reason `flush_all` is: the only thing that polls a
    /// transcript holds an `Arc<dyn SessionsApi>` and nothing else, and a signal it
    /// cannot reach is a signal that does not arrive. It is the preferred half of
    /// activity detection — wording independent, and the only way a session whose tool
    /// call has gone quiet for minutes stays visibly busy.
    ///
    /// The caller owns the decision of what is newly appended: a backlog read out of a
    /// file written before anyone was watching is history, and must not be passed here.
    fn on_transcript(&self, id: &str, records: &[TranscriptRecord]);

    /// Persist every live session's newest bytes before the process goes away.
    ///
    /// On the trait because the daemon's shutdown path only ever holds a
    /// `dyn SessionsApi`, and a flush it cannot reach is a flush that does not
    /// happen. Scrollback is written on a throttle while a session runs, so without
    /// this the last couple of seconds of every live session is lost on every exit —
    /// which stopped being acceptable the moment quitting the app started ending the
    /// daemon.
    fn flush_all(&self) -> usize;

    /// Everything the idle reaper reads about one session, in one call.
    ///
    /// On the trait for the same reason `on_transcript` and `flush_all` are: the sweep
    /// holds an `Arc<dyn SessionsApi>` and nothing else, and a signal it cannot reach
    /// is a signal that does not arrive. One call rather than a getter per signal
    /// because the reaper asks twice — once to decide, once immediately before the
    /// kill — and two assemblies that could drift apart is the bug the second ask
    /// exists to catch.
    fn reap_probe(&self, id: &str) -> Option<ReapProbe>;

    /// Flag a session dormant and broadcast the row. `false` when it already was.
    /// Called before `kill`, so the exited row carries the flag and a client can tell
    /// "slept, wake me on demand" from a crash.
    fn mark_dormant(&self, id: &str) -> bool;

    /// Broadcast a stuck-session advisory (see [`crate::stuck`]).
    ///
    /// On the trait for the same reason `reap_probe` is: the watch holds an
    /// `Arc<dyn SessionsApi>` and nothing else, and the registry owns the only bus a
    /// client is listening to. It is a *write* on a read-shaped trait and that is
    /// deliberate — it is the one thing the detector does, and everything it does is
    /// advisory: no implementation of this may kill, sleep, resize or type.
    fn publish_stuck(&self, id: &str, alert: StuckAlert);
}

/// `ctx.resolve::<SessionsService>()` yields `Arc<dyn SessionsApi>`.
pub struct SessionsService;

impl Service for SessionsService {
    const KEY: &'static str = "sessions";
    type Api = dyn SessionsApi;
}

/// `ctx.resolve::<StoreService>()` yields `Arc<dyn SessionStore>`. The key is what
/// the registry declares in `inject`, so swapping SQLite for anything else is a
/// change at one mount site.
pub struct StoreService;

impl Service for StoreService {
    const KEY: &'static str = "store";
    type Api = dyn SessionStore;
}

impl SessionsApi for SessionRegistry {
    fn subscribe(&self) -> broadcast::Receiver<SessionEvent> {
        SessionRegistry::subscribe(self)
    }

    fn ids(&self) -> Vec<String> {
        SessionRegistry::ids(self)
    }

    fn meta(&self, id: &str) -> Option<SessionMeta> {
        SessionRegistry::meta(self, id)
    }

    fn is_running(&self, id: &str) -> bool {
        SessionRegistry::is_running(self, id)
    }

    fn activity(&self, id: &str) -> Option<SessionActivity> {
        SessionRegistry::activity(self, id)
    }

    fn snapshot(&self, id: &str) -> Option<Snapshot> {
        SessionRegistry::snapshot(self, id)
    }

    fn grid(&self, id: &str) -> Option<(u16, u16)> {
        SessionRegistry::grid(self, id)
    }

    fn grid_owner(&self, id: &str) -> Option<ClientId> {
        SessionRegistry::grid_owner(self, id)
    }

    fn retention(&self) -> usize {
        SessionRegistry::retention(self)
    }

    fn create(&self, req: CreateRequest) -> Result<SessionMeta, StateError> {
        SessionRegistry::create(self, req)
    }

    fn adopt_external(&self, req: AdoptRequest) -> Result<Option<SessionMeta>, StateError> {
        SessionRegistry::adopt_external(self, req)
    }

    fn attach(
        &self,
        id: &str,
        owner: ClientId,
        cols: u16,
        rows: u16,
    ) -> Result<Attached, StateError> {
        SessionRegistry::attach(self, id, owner, cols, rows)
    }

    fn reactivate(
        &self,
        id: &str,
        owner: ClientId,
        cols: u16,
        rows: u16,
    ) -> Result<Option<Attached>, StateError> {
        SessionRegistry::reactivate(self, id, owner, cols, rows)
    }

    fn set_skip_permissions(
        &self,
        id: &str,
        skip: bool,
        owner: ClientId,
        cols: u16,
        rows: u16,
    ) -> Result<Attached, StateError> {
        SessionRegistry::set_skip_permissions(self, id, skip, owner, cols, rows)
    }

    fn input(&self, id: &str, data: &[u8]) -> Result<(), StateError> {
        SessionRegistry::input(self, id, data)
    }

    fn queue(&self, id: &str) -> Vec<QueuedMessage> {
        SessionRegistry::queue(self, id)
    }

    fn queue_message(&self, id: &str, text: &str) -> Result<Option<QueuedMessage>, StateError> {
        SessionRegistry::queue_message(self, id, text)
    }

    fn dequeue_message(&self, id: &str, message_id: &str) -> Result<bool, StateError> {
        SessionRegistry::dequeue_message(self, id, message_id)
    }

    fn resize(&self, id: &str, owner: ClientId, cols: u16, rows: u16) -> ResizeOutcome {
        SessionRegistry::resize(self, id, owner, cols, rows)
    }

    fn release_client(&self, owner: ClientId) {
        SessionRegistry::release_client(self, owner)
    }

    fn on_transcript(&self, id: &str, records: &[TranscriptRecord]) {
        SessionRegistry::on_transcript(self, id, records)
    }

    fn flush_all(&self) -> usize {
        SessionRegistry::flush_all(self)
    }

    fn kill(&self, id: &str) -> Result<(), StateError> {
        SessionRegistry::kill(self, id)
    }

    fn reap_probe(&self, id: &str) -> Option<ReapProbe> {
        SessionRegistry::reap_probe(self, id)
    }

    fn mark_dormant(&self, id: &str) -> bool {
        SessionRegistry::mark_dormant(self, id)
    }

    fn publish_stuck(&self, id: &str, alert: StuckAlert) {
        SessionRegistry::publish_stuck(self, id, alert)
    }
}

/// Hand a store to the registry as an `Arc<dyn SessionStore>` without the mount site
/// naming the concrete type.
pub fn as_store(store: Arc<dyn SessionStore>) -> Arc<dyn SessionStore> {
    store
}
