//! What drives the transcript seam: the one thing that decides when to poll it.
//!
//! `juancoded-transcripts` reads a CLI's own store, and the `transcripts` hub owns the
//! bindings and the durable cursors — but both are deliberately pull-based. The hub's
//! own words: "It starts no task and holds no timer: something else decides when to
//! poll." Until this module existed nothing did, so the crate was mounted in the tree,
//! the cursor table was migrated, and not one record was ever produced. This is the
//! something.
//!
//! One task for the daemon, not one per connection or per session, for the same reason
//! the queue has one pump: a record is read because a session wrote one, not because
//! somebody happens to be watching the pane.
//!
//! # When it polls
//!
//! * **Once at boot, for every session the store remembers.** This is the restore
//!   path, and it is the whole reason the plane survives a restart: while the daemon
//!   was down the CLI kept writing, so the first thing to do on the way up is read the
//!   gap and put it in the store, before any client opens a pane and asks for history.
//! * **On output**, coalesced onto a tick. A session produces bytes in bursts and its
//!   transcript grows with them; polling per chunk would put a file read on the pty's
//!   hot path for records that are not there yet.
//! * **On meta**, because two of the three providers only learn their conversation id
//!   minutes after the spawn, and a session cannot be bound before it has one.
//! * **On exit**, once more, so the last turn's records are not lost to the fact that
//!   nothing will ever be dirty again.
//!
//! # What it persists
//!
//! Everything a poll returns, bounded by `keep` records per session
//! (`JUANCODE_TRANSCRIPT_RECORDS`). The hub already announced the batch on the cordis
//! bus by the time we get it, so a live watcher has seen it; the store is for the
//! client that is not connected yet, which is every client after a restart.
//!
//! It never writes into a CLI's own store, and it never creates a binding by hand: a
//! session the sources cannot find is retried later and costs one lookup per source
//! until it can be.
//!
//! # Why an unbound session is throttled
//!
//! Binding is not free the way polling is. Once bound, a poll is a read from a known
//! offset in a known file. Before that, the claude source tries the cwd slug, then the
//! canonicalised cwd, and then **walks every project directory** looking for the file —
//! hundreds of them on a machine that has been used for a while. A session that cannot
//! be bound is the normal state for a codex or opencode session for its first minutes,
//! and the permanent state for a dead session whose CLI file is gone, so retrying it on
//! every tick would spend that walk twice a second forever. [`BIND_RETRY`] is the
//! answer, and it is why the pump keeps state instead of being a free function.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::sync::broadcast::error::RecvError;
use tracing::{debug, warn};

use juancoded_cordis::services::transcripts::TranscriptsApi;
use juancoded_persistence::{SessionStore, TranscriptRow};
use juancoded_state::registry::SessionEvent;
use juancoded_state::SessionsApi;
use juancoded_transcripts::BindRequest;

/// How long output is allowed to pile up before the transcript is read.
///
/// Slower than the screen tick on purpose. A transcript record is written by the CLI
/// when a turn, a tool call or a step completes, so polling faster than that buys
/// nothing but file reads; the number that matters to a human is how long after a tool
/// call finishes its row appears, and half a second is under the threshold where that
/// reads as lag.
pub const PUMP_TICK: Duration = Duration::from_millis(500);

/// How long to leave a session that no source could bind before trying again.
///
/// The two providers that mint their own conversation id take minutes to write it
/// down, so the retry has to keep going; the directory walk behind a failed bind is why
/// it must not keep going at tick rate.
pub const BIND_RETRY: Duration = Duration::from_secs(5);

/// The handles one pump needs. Grouped for the same reason [`crate::serve::CoreHandles`]
/// is: the hub, the store and the sessions all have to come out of one booted tree, and
/// a pump reading one tree's sessions into another tree's store would persist history
/// under session ids that store has never heard of.
#[derive(Clone)]
pub struct TranscriptPlane {
    pub hub: Arc<dyn TranscriptsApi>,
    pub store: Arc<dyn SessionStore>,
    /// Records kept per session. 0 = unlimited. See
    /// [`juancoded_persistence::transcript_records_kept`].
    pub keep: usize,
    /// How many records a client is handed when it subscribes. The tail, not the whole
    /// history: a pane draws the recent end first, and `keep` is the bound on what
    /// exists at all.
    pub replay_limit: usize,
}

/// How much history one `subscribeTranscript` replays. Smaller than `keep`, because
/// the two answer different questions: `keep` is what the daemon is willing to store,
/// this is what a pane is willing to draw before the user has scrolled anywhere.
pub const DEFAULT_REPLAY_LIMIT: usize = 500;

impl TranscriptPlane {
    pub fn new(hub: Arc<dyn TranscriptsApi>, store: Arc<dyn SessionStore>) -> Self {
        Self {
            hub,
            store,
            keep: juancoded_persistence::transcript_records_kept(),
            replay_limit: DEFAULT_REPLAY_LIMIT,
        }
    }

    /// One session's stored history, oldest first, ready to go on the wire.
    ///
    /// A read failure is empty history and a warning, never an error to the client: a
    /// pane that cannot draw its transcript is worse off than one that draws none, and
    /// the pty scrollback it repaints from is a different plane and unaffected.
    pub fn history(&self, session: &str) -> Vec<serde_json::Value> {
        match self.store.transcript(session, self.replay_limit) {
            Ok(rows) => rows
                .iter()
                .filter_map(|row| serde_json::from_str(&row.json).ok())
                .collect(),
            Err(error) => {
                warn!(%error, session, "could not read a stored transcript");
                Vec::new()
            }
        }
    }
}

/// The pump's state: which sessions are bound, and when an unbound one was last tried.
///
/// Small on purpose — one entry per session the daemon knows — and owned by the task
/// rather than shared, so nothing about the binding cadence needs a lock.
#[derive(Default)]
pub struct Pump {
    bound: HashSet<String>,
    tried: HashMap<String, Instant>,
}

impl Pump {
    pub fn new() -> Self {
        Self::default()
    }

    /// Read whatever one session's transcript has grown by, and store it.
    ///
    /// Returns how many records were appended, which is what a test asserts on. Zero
    /// covers four ordinary cases and none of them is an error: no source owns the
    /// session, no source can find its file yet, its bind is still in back-off, or
    /// nothing new was written since the last poll.
    pub fn poll_session(
        &mut self,
        sessions: &Arc<dyn SessionsApi>,
        plane: &TranscriptPlane,
        session: &str,
        now: Instant,
    ) -> usize {
        let Some(meta) = sessions.meta(session) else {
            // The session was pruned between the event and this tick. Its records went
            // with it through the foreign key.
            self.bound.remove(session);
            self.tried.remove(session);
            return 0;
        };
        if !self.bound.contains(session) {
            if let Some(last) = self.tried.get(session) {
                if now.duration_since(*last) < BIND_RETRY {
                    return 0;
                }
            }
            self.tried.insert(session.to_string(), now);
            let req = BindRequest {
                session: session.to_string(),
                provider: meta.provider.as_str().to_string(),
                cwd: meta.cwd.clone(),
                cli_session_id: meta.cli_session_id.clone(),
            };
            let Some(source) = plane.hub.attach(&req) else {
                return 0;
            };
            debug!(session, source, "transcript bound");
            self.bound.insert(session.to_string());
        }
        let records = match plane.hub.poll(session) {
            Ok(records) => records,
            Err(error) => {
                warn!(%error, session, "transcript poll failed");
                return 0;
            }
        };
        if records.is_empty() {
            return 0;
        }
        let rows: Vec<TranscriptRow> = records
            .iter()
            .filter_map(|record| {
                serde_json::to_string(record)
                    .map(|json| TranscriptRow {
                        seq: record.seq,
                        json,
                    })
                    .ok()
            })
            .collect();
        let appended = rows.len();
        if let Err(error) = plane.store.append_transcript(session, &rows, plane.keep) {
            // The batch is already on the bus, so a live watcher has it; what is lost is
            // the history a later client would have read. Worth a warning and not a
            // retry: the cursor has moved past these records, and re-reading them is not
            // something this seam can do without re-parsing from the top.
            warn!(%error, session, "could not persist a transcript batch");
        }
        appended
    }

    /// Poll every session the store remembers, once, on the way up.
    ///
    /// The restore path, and the whole reason this plane survives a restart. A daemon
    /// that was down for an hour comes up with an hour of the CLI's own writing to
    /// catch up on — and even a daemon that was only killed mid-batch comes up with
    /// records that reached the file but never reached the store. Reading here means
    /// the history is complete before the first client can ask for it.
    ///
    /// **Every** session, including the exited ones, because whether our copy is short
    /// of the file is not something we can know without looking. The cost of looking is
    /// the reason that is affordable: a session already read to the end costs an open
    /// and a seek to its durable offset, and the worst case — an exited session whose
    /// CLI file is gone, which is the only case that walks the projects directory — was
    /// measured at 0.9ms across 387 project directories on the machine this was written
    /// on. Forty of those is a boot 36ms slower for a history that is right.
    pub fn backfill(&mut self, sessions: &Arc<dyn SessionsApi>, plane: &TranscriptPlane) -> usize {
        let now = Instant::now();
        let ids = sessions.ids();
        let mut total = 0;
        for id in &ids {
            total += self.poll_session(sessions, plane, id, now);
        }
        debug!(
            sessions = ids.len(),
            records = total,
            "backfilled transcripts at boot"
        );
        total
    }
}

/// Start the daemon's one transcript pump. Aborting the handle stops it.
pub fn spawn_pump(
    sessions: Arc<dyn SessionsApi>,
    plane: TranscriptPlane,
    tick: Duration,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut events = sessions.subscribe();
        let mut pump = Pump::new();
        pump.backfill(&sessions, &plane);
        let mut dirty: HashSet<String> = HashSet::new();
        let mut ticker = tokio::time::interval(tick);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                event = events.recv() => match event {
                    Ok(event) => mark(event, &mut dirty),
                    // Lagging is survivable and does not lose a record: the cursor is
                    // where the reading resumes from, not the event stream, so the
                    // next output on any session catches up whatever this missed.
                    Err(RecvError::Lagged(n)) => debug!(dropped = n, "transcript pump lagged"),
                    Err(RecvError::Closed) => return,
                },
                _ = ticker.tick() => {
                    let now = Instant::now();
                    for session in dirty.drain() {
                        pump.poll_session(&sessions, &plane, &session, now);
                    }
                }
            }
        }
    })
}

/// Which sessions one bus event makes worth re-reading.
fn mark(event: SessionEvent, dirty: &mut HashSet<String>) {
    match event {
        // Output means the CLI is working, and a working CLI is writing its transcript.
        SessionEvent::Output { session_id, .. } => {
            dirty.insert(session_id);
        }
        // A discovered conversation id is the moment an unbindable session becomes
        // bindable, and it arrives as a meta change and nothing else.
        SessionEvent::Meta { session_id, .. } => {
            dirty.insert(session_id);
        }
        // The last read there will ever be. Without it the final turn's records sit in
        // the CLI's file with nothing left to make anyone look.
        SessionEvent::Exit { session_id, .. } => {
            dirty.insert(session_id);
        }
        // Activity is derived from the same bytes that already marked the session, a
        // grid change moves no transcript, and the store queue's notification is not
        // about this plane at all.
        SessionEvent::Activity { .. }
        | SessionEvent::GridChange { .. }
        | SessionEvent::QueueChanged { .. } => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::io::Write;
    use std::path::{Path, PathBuf};

    use juancoded_core::model::ProviderId;
    use juancoded_state::registry::CreateRequest;

    use crate::serve::CoreHandles;

    /// Four lines of a real claude transcript: a prompt, a tool call, its result and
    /// the answer. Copied from the transcripts crate's own fixture rather than invented,
    /// so what this exercises is the parser that runs in production.
    const PROMPT: &str = r#"{"type":"user","promptId":"p1","timestamp":"2026-08-23T10:00:00.000Z","message":{"role":"user","content":"land the ticket"}}"#;
    const CALL: &str = r#"{"type":"assistant","requestId":"req_1","timestamp":"2026-08-23T10:00:01.000Z","message":{"model":"claude-opus-5","usage":{"input_tokens":4,"output_tokens":9},"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"cargo test"}}],"stop_reason":"tool_use"}}"#;
    const RESULT: &str = r#"{"type":"user","timestamp":"2026-08-23T10:00:30.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"34 passed"}]}}"#;
    const DONE: &str = r#"{"type":"assistant","requestId":"req_2","timestamp":"2026-08-23T10:00:31.000Z","message":{"model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":2},"content":[{"type":"text","text":"green"}],"stop_reason":"end_turn"}}"#;

    struct Scratch {
        dir: PathBuf,
    }

    impl Scratch {
        fn new(label: &str) -> Self {
            let dir = std::env::temp_dir().join(format!(
                "juancoded-pump-{label}-{}-{:?}",
                std::process::id(),
                std::thread::current().id()
            ));
            std::fs::remove_dir_all(&dir).ok();
            std::fs::create_dir_all(dir.join("projects")).expect("scratch");
            std::fs::create_dir_all(dir.join("cwd")).expect("scratch cwd");
            Self { dir }
        }

        fn db(&self) -> String {
            self.dir.join("store.db").to_string_lossy().into_owned()
        }

        fn projects(&self) -> PathBuf {
            self.dir.join("projects")
        }

        fn cwd(&self) -> String {
            self.dir.join("cwd").to_string_lossy().into_owned()
        }

        /// The file claude would have written for this session, at the path claude
        /// would have written it to.
        fn transcript_for(&self, session: &str) -> PathBuf {
            let dir = self
                .projects()
                .join(juancoded_transcripts::claude::project_slug(&self.cwd()));
            std::fs::create_dir_all(&dir).expect("project dir");
            dir.join(format!("{session}.jsonl"))
        }

        /// A tree over this scratch's store, with the claude source pointed at its
        /// fixture projects directory rather than the developer's own.
        fn boot(&self) -> (juancoded_cordis::Loader, CoreHandles) {
            let mut entries = juancoded_state::test_entries_at(&self.db(), "/bin/cat", &[]);
            entries.set_config(
                "transcript-claude",
                serde_json::json!({ "root": self.projects().to_string_lossy() }),
            );
            let (loader, _, sessions) = juancoded_state::boot_with(&entries).expect("tree mounts");
            let handles = CoreHandles::from_loader(&loader, sessions);
            (loader, handles)
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            std::fs::remove_dir_all(&self.dir).ok();
        }
    }

    fn append(path: &Path, lines: &[&str]) {
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .expect("append");
        for line in lines {
            writeln!(file, "{line}").expect("write");
        }
    }

    fn create(handles: &CoreHandles, cwd: &str) -> String {
        handles
            .sessions
            .create(CreateRequest {
                provider: ProviderId::Claude,
                cwd: cwd.to_string(),
                cols: 80,
                rows: 24,
                skip_permissions: false,
                model: None,
                dispatch_id: None,
                owner: 1,
            })
            .expect("create")
            .id
    }

    fn kinds(records: &[serde_json::Value]) -> Vec<String> {
        records
            .iter()
            .map(|r| r["kind"].as_str().unwrap_or("?").to_string())
            .collect()
    }

    #[tokio::test]
    async fn a_session_records_its_transcript_and_a_second_daemon_serves_it_back() {
        let scratch = Scratch::new("restart");
        let cwd = scratch.cwd();

        // --- first daemon -------------------------------------------------------
        let (loader, handles) = scratch.boot();
        let plane = handles.transcripts.clone().expect("the plane mounted");
        let session = create(&handles, &cwd);
        // Nothing to read yet: the CLI has not written its file, and an unbindable
        // session is an ordinary state rather than an error.
        assert_eq!(
            Pump::new().poll_session(&handles.sessions, &plane, &session, Instant::now()),
            0
        );
        assert!(plane.history(&session).is_empty());

        let path = scratch.transcript_for(&session);
        append(&path, &[PROMPT, CALL]);
        assert!(Pump::new().poll_session(&handles.sessions, &plane, &session, Instant::now()) > 0);
        let first = plane.history(&session);
        assert_eq!(
            kinds(&first),
            vec!["turnStart", "step", "usage", "toolCall"],
            "the seam's own events, in the order the file wrote them"
        );

        // The daemon goes away. Its loader is what owns every mounted effect, so
        // dropping it IS the shutdown, and the store file is all that is left.
        drop(plane);
        drop(handles);
        drop(loader);

        // --- second daemon over the same file -----------------------------------
        let (loader2, handles2) = scratch.boot();
        let plane2 = handles2.transcripts.clone().expect("the plane mounted");
        let restored = plane2.history(&session);
        assert_eq!(
            kinds(&restored),
            kinds(&first),
            "a pane opened after a restart draws the history the first daemon read"
        );

        // While the daemon was down the CLI kept working. The boot backfill is what
        // reads the gap, and the durable cursor is what stops it re-reading the part
        // already stored.
        append(&path, &[RESULT, DONE]);
        assert_eq!(Pump::new().backfill(&handles2.sessions, &plane2), 5);
        let caught_up = plane2.history(&session);
        assert_eq!(
            kinds(&caught_up),
            vec![
                "turnStart",
                "step",
                "usage",
                "toolCall",
                "toolResult",
                "step",
                "usage",
                "assistant",
                "turnEnd"
            ]
        );
        // Append-only across the restart: no seq repeats and none goes backwards.
        let seqs: Vec<u64> = caught_up
            .iter()
            .map(|r| r["seq"].as_u64().expect("seq"))
            .collect();
        assert_eq!(seqs, (0..9).collect::<Vec<_>>());

        // And a second poll with nothing new appended is not a second copy.
        assert_eq!(
            Pump::new().poll_session(&handles2.sessions, &plane2, &session, Instant::now()),
            0
        );
        assert_eq!(plane2.history(&session).len(), 9);
        drop(loader2);
    }

    #[tokio::test]
    async fn history_is_bounded_per_session_and_the_bound_is_the_newest_records() {
        let scratch = Scratch::new("bound");
        let cwd = scratch.cwd();
        let (loader, handles) = scratch.boot();
        let mut plane = handles.transcripts.clone().expect("the plane mounted");
        // A deliberately tiny bound: what matters is that the cap is enforced on the
        // write and that what survives is the recent end.
        plane.keep = 3;
        let session = create(&handles, &cwd);
        let path = scratch.transcript_for(&session);
        append(&path, &[PROMPT, CALL, RESULT, DONE]);
        assert_eq!(
            Pump::new().poll_session(&handles.sessions, &plane, &session, Instant::now()),
            9
        );

        let kept = plane.history(&session);
        assert_eq!(kept.len(), 3, "the bound is per session and it is enforced");
        assert_eq!(kinds(&kept), vec!["usage", "assistant", "turnEnd"]);
        drop(loader);
    }

    #[tokio::test]
    async fn a_session_no_source_can_find_is_not_looked_for_again_until_the_backoff_is_up() {
        let scratch = Scratch::new("backoff");
        let cwd = scratch.cwd();
        let (loader, handles) = scratch.boot();
        let plane = handles.transcripts.clone().expect("the plane mounted");
        let session = create(&handles, &cwd);
        let mut pump = Pump::new();

        // No file yet. This is the ordinary state of a just-spawned session, and it is
        // the one that costs a walk of every project directory.
        let t0 = Instant::now();
        assert_eq!(
            pump.poll_session(&handles.sessions, &plane, &session, t0),
            0
        );

        // The file appears, but the pump is in back-off and does not look. A tick is
        // 500ms and the back-off is seconds, so this is the common case, not a corner.
        append(&scratch.transcript_for(&session), &[PROMPT]);
        assert_eq!(
            pump.poll_session(&handles.sessions, &plane, &session, t0),
            0,
            "a failed bind must not be retried on every tick"
        );

        // Once the back-off is up it binds, and from then on every tick polls: a bound
        // session is a read from a known offset, which is what the throttle was
        // protecting.
        let later = t0 + BIND_RETRY;
        assert_eq!(
            pump.poll_session(&handles.sessions, &plane, &session, later),
            1
        );
        append(&scratch.transcript_for(&session), &[CALL]);
        assert_eq!(
            pump.poll_session(&handles.sessions, &plane, &session, later),
            3,
            "no back-off once bound"
        );
        drop(loader);
    }

    #[tokio::test]
    async fn a_pruned_session_takes_its_transcript_with_it() {
        let scratch = Scratch::new("prune");
        let cwd = scratch.cwd();
        let (loader, handles) = scratch.boot();
        let plane = handles.transcripts.clone().expect("the plane mounted");
        let session = create(&handles, &cwd);
        append(&scratch.transcript_for(&session), &[PROMPT]);
        assert!(Pump::new().poll_session(&handles.sessions, &plane, &session, Instant::now()) > 0);
        assert!(!plane.history(&session).is_empty());

        // There is no second retention knob: the per-project cap prunes sessions and
        // the foreign key takes their transcripts.
        plane.store.delete(&session).expect("delete");
        assert!(plane.history(&session).is_empty());
        drop(loader);
    }

    #[test]
    fn only_the_events_that_can_move_a_transcript_mark_a_session() {
        let mut dirty = HashSet::new();
        mark(
            SessionEvent::Output {
                session_id: "s1".into(),
                bytes: Arc::new(b"hi".to_vec()),
            },
            &mut dirty,
        );
        mark(
            SessionEvent::GridChange {
                session_id: "s2".into(),
                owner: None,
                cols: 80,
                rows: 24,
            },
            &mut dirty,
        );
        mark(
            SessionEvent::Exit {
                session_id: "s3".into(),
                exit_code: Some(0),
            },
            &mut dirty,
        );
        let mut marked: Vec<String> = dirty.into_iter().collect();
        marked.sort();
        assert_eq!(marked, vec!["s1".to_string(), "s3".to_string()]);
    }
}
