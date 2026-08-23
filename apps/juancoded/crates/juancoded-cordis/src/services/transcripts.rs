//! The `transcripts` service: structured turn, thinking and tool events per session.
//!
//! The second data plane. Everything else in this daemon knows a session as pty bytes
//! and a VT grid, which is the right shape for a terminal and the wrong shape for
//! every question about what the agent is actually doing. A consumer resolves this key
//! and gets typed records instead: turn boundaries, model steps, reasoning blocks,
//! tool calls with their results, and what each step cost.
//!
//! The hub owns three things and nothing else.
//!
//! - **Sources**, registered by the provider plugins as ordinary reversible effects.
//!   A source knows one CLI's own store; the hub knows none of them. Adding codex is
//!   registering a third source.
//! - **Bindings**, from a juancode session to the locator its source found for it.
//!   Binding is retried on every poll until it succeeds, because two of the three
//!   providers only learn their conversation id minutes after the spawn.
//! - **Cursors**, so a poll reads what appeared since the last one and a restart
//!   resumes rather than re-parsing.
//!
//! The hub is pull-based. It starts no task and holds no timer: something else decides
//! when to poll, and gets the batch as a return value as well as on the bus. That
//! keeps the seam testable without a runtime and keeps a transcript reader from
//! becoming a second thing that wakes a sleeping session up.
//!
//! It is also strictly read-only. Nothing here writes into a CLI's own store, and
//! anything that would need to is a different ticket.

use std::collections::BTreeMap;
use std::fmt;
use std::sync::{Arc, Mutex};

use juancoded_transcripts::{
    BindRequest, Binding, CursorStore, MemoryCursors, Source, SqliteCursors, StoredCursor,
    TranscriptRecord, TranscriptSource,
};

use crate::bus::{Bus, ObserveEvent};
use crate::effect::Effect;
use crate::plugin::{Context, Plugin};
use crate::service::Service;

/// One poll's worth of records for one session, never empty when emitted.
#[derive(Debug, Clone)]
pub struct TranscriptBatch {
    pub session: String,
    pub source: Source,
    pub records: Vec<TranscriptRecord>,
}

/// Observed, never intercepted. The reasoning tab, the stuck detector and a Telegram
/// summary all want the same records and none of them may alter what the others see.
pub struct TranscriptAppended;

impl ObserveEvent for TranscriptAppended {
    const NAME: &'static str = "session.transcript";
    type Payload = TranscriptBatch;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceTaken(pub &'static str);

impl fmt::Display for SourceTaken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "a transcript source already claims the name `{}`",
            self.0
        )
    }
}

impl std::error::Error for SourceTaken {}

/// What consumers of the `transcripts` key may do.
pub trait TranscriptsApi: Send + Sync {
    /// Add a provider for as long as the returned guard lives.
    fn register_source(&self, source: Arc<dyn TranscriptSource>) -> Result<Effect, SourceTaken>;

    /// The sources currently registered, in registration order.
    fn sources(&self) -> Vec<&'static str>;

    /// Ask every source whether it can find this session's transcript, and remember
    /// the first answer. Returns the source that bound it.
    ///
    /// Idempotent, and cheap to call again: a session already bound is left alone, and
    /// one that could not be bound costs one lookup per source.
    fn attach(&self, req: &BindRequest) -> Option<&'static str>;

    /// Forget a session's binding and its durable cursor.
    fn detach(&self, session: &str);

    fn bindings(&self) -> Vec<(String, Binding)>;

    /// Read whatever has appeared since the last poll, advancing the durable cursor.
    fn poll(&self, session: &str) -> anyhow::Result<Vec<TranscriptRecord>>;

    /// The whole transcript from the beginning, leaving the durable cursor alone.
    ///
    /// This is what makes the stream replayable: a client that connects late, or a
    /// panel opened for the first time, reads the history without disturbing whoever
    /// is tailing it.
    fn replay(&self, session: &str) -> anyhow::Result<Vec<TranscriptRecord>>;
}

/// The contract marker: `ctx.resolve::<TranscriptsService>()` yields `Arc<dyn TranscriptsApi>`.
pub struct TranscriptsService;

impl Service for TranscriptsService {
    const KEY: &'static str = "transcripts";
    type Api = dyn TranscriptsApi;
}

struct Bound {
    binding: Binding,
    source: Arc<dyn TranscriptSource>,
}

#[derive(Default)]
struct Inner {
    sources: Vec<Arc<dyn TranscriptSource>>,
    bound: BTreeMap<String, Bound>,
}

/// The real implementation: sources, bindings, and a cursor store.
///
/// `inner` is behind an `Arc` because a source's teardown guard has to reach it after
/// the plugin that registered the source is gone, and must find nothing rather than a
/// dangling pointer when the hub itself has gone too.
pub struct TranscriptHub {
    inner: Arc<Mutex<Inner>>,
    cursors: Arc<dyn CursorStore>,
    bus: Option<Bus>,
}

impl TranscriptHub {
    pub fn new(cursors: Arc<dyn CursorStore>) -> Self {
        Self {
            inner: Arc::new(Mutex::new(Inner::default())),
            cursors,
            bus: None,
        }
    }

    /// The same, wired to a bus so a poll also announces itself.
    pub fn with_bus(cursors: Arc<dyn CursorStore>, bus: Bus) -> Self {
        Self {
            inner: Arc::new(Mutex::new(Inner::default())),
            cursors,
            bus: Some(bus),
        }
    }

    fn inner(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn bound(&self, session: &str) -> Option<(Binding, Arc<dyn TranscriptSource>)> {
        self.inner()
            .bound
            .get(session)
            .map(|b| (b.binding.clone(), Arc::clone(&b.source)))
    }

    /// Read forward from the durable cursor and store the new one.
    fn advance(
        &self,
        session: &str,
        binding: &Binding,
        source: &Arc<dyn TranscriptSource>,
    ) -> anyhow::Result<Vec<TranscriptRecord>> {
        let locator = binding.locator();
        // A cursor recorded against a different file is not this session's place in
        // this one. That happens when a session's transcript is found somewhere else
        // than it was last time, and resuming from the old offset would skip whatever
        // the new file already holds.
        let mut stored = match self.cursors.load(session) {
            Some(stored) if stored.locator == locator && stored.source == binding.source() => {
                stored
            }
            _ => StoredCursor::fresh(binding.source(), locator),
        };

        let (emitted, next) = source.read(binding, &stored.cursor)?;
        let records = self.stamp(session, binding.source(), &mut stored.next_seq, emitted);
        stored.cursor = next;
        self.cursors.save(session, &stored)?;
        self.announce(session, binding.source(), &records);
        Ok(records)
    }

    fn stamp(
        &self,
        session: &str,
        source: Source,
        next_seq: &mut u64,
        emitted: Vec<juancoded_transcripts::Emitted>,
    ) -> Vec<TranscriptRecord> {
        emitted
            .into_iter()
            .map(|e| {
                let seq = *next_seq;
                *next_seq += 1;
                TranscriptRecord {
                    session: session.to_string(),
                    source,
                    seq,
                    at_ms: e.at_ms,
                    turn: e.turn,
                    event: e.event,
                }
            })
            .collect()
    }

    fn announce(&self, session: &str, source: Source, records: &[TranscriptRecord]) {
        if records.is_empty() {
            return;
        }
        if let Some(bus) = &self.bus {
            bus.emit::<TranscriptAppended>(&TranscriptBatch {
                session: session.to_string(),
                source,
                records: records.to_vec(),
            });
        }
    }
}

impl TranscriptsApi for TranscriptHub {
    fn register_source(&self, source: Arc<dyn TranscriptSource>) -> Result<Effect, SourceTaken> {
        let name = source.name();
        {
            let mut inner = self.inner();
            if inner.sources.iter().any(|s| s.name() == name) {
                return Err(SourceTaken(name));
            }
            inner.sources.push(source);
        }
        tracing::debug!(source = name, "transcript source registered");
        // Bindings made by this source go with it: leaving them would hand later polls
        // a session bound to a reader nobody can reach.
        let handle = SourceHandle {
            inner: Arc::downgrade(&self.inner),
            name,
        };
        Ok(Effect::new(format!("transcripts:{name}"), move || {
            handle.withdraw();
        }))
    }

    fn sources(&self) -> Vec<&'static str> {
        self.inner().sources.iter().map(|s| s.name()).collect()
    }

    fn attach(&self, req: &BindRequest) -> Option<&'static str> {
        if let Some(bound) = self.inner().bound.get(&req.session) {
            return Some(bound.source.name());
        }
        let sources: Vec<Arc<dyn TranscriptSource>> = self.inner().sources.clone();
        for source in sources {
            let Some(binding) = source.bind(req) else {
                continue;
            };
            let name = source.name();
            tracing::debug!(
                session = req.session,
                source = name,
                locator = binding.locator(),
                "transcript bound"
            );
            self.inner()
                .bound
                .insert(req.session.clone(), Bound { binding, source });
            return Some(name);
        }
        None
    }

    fn detach(&self, session: &str) {
        self.inner().bound.remove(session);
        if let Err(error) = self.cursors.clear(session) {
            tracing::warn!(%error, session, "transcript cursor not cleared");
        }
    }

    fn bindings(&self) -> Vec<(String, Binding)> {
        self.inner()
            .bound
            .iter()
            .map(|(session, bound)| (session.clone(), bound.binding.clone()))
            .collect()
    }

    fn poll(&self, session: &str) -> anyhow::Result<Vec<TranscriptRecord>> {
        let Some((binding, source)) = self.bound(session) else {
            return Ok(Vec::new());
        };
        self.advance(session, &binding, &source)
    }

    fn replay(&self, session: &str) -> anyhow::Result<Vec<TranscriptRecord>> {
        let Some((binding, source)) = self.bound(session) else {
            return Ok(Vec::new());
        };
        let (emitted, _) = source.read(&binding, &String::new())?;
        let mut seq = 0;
        Ok(self.stamp(session, binding.source(), &mut seq, emitted))
    }
}

/// Claims the `transcripts` key with the hub the source plugins register into.
///
/// It lives beside the service rather than in a file of its own because there is
/// nothing to it: the hub is the service, and mounting it is picking a cursor store.
/// The sources are separate rows on purpose, so `dump-config` shows which CLIs this
/// daemon can actually read and either one can be disabled by id.
pub struct Transcripts;

impl Plugin for Transcripts {
    fn name(&self) -> &'static str {
        "transcripts"
    }

    fn apply(&self, ctx: &Context) -> anyhow::Result<()> {
        // With no database configured the cursors live for as long as the process,
        // which is the right answer for a test and the wrong one for the daemon: a
        // restart would re-read every transcript from the top.
        let cursors: Arc<dyn CursorStore> = match ctx.config().get("db").and_then(|v| v.as_str()) {
            Some(db) if !db.is_empty() => Arc::new(SqliteCursors::open(db)?),
            _ => Arc::new(MemoryCursors::new()),
        };
        ctx.provide::<TranscriptsService>(Arc::new(TranscriptHub::with_bus(
            cursors,
            ctx.bus().clone(),
        )))?;
        Ok(())
    }
}

/// The half of the hub a source's teardown guard needs, without keeping the hub alive.
struct SourceHandle {
    inner: std::sync::Weak<Mutex<Inner>>,
    name: &'static str,
}

impl SourceHandle {
    fn withdraw(&self) {
        let Some(inner) = self.inner.upgrade() else {
            return;
        };
        let mut inner = inner.lock().unwrap_or_else(|e| e.into_inner());
        inner.sources.retain(|s| s.name() != self.name);
        inner
            .bound
            .retain(|_, bound| bound.source.name() != self.name);
        tracing::debug!(source = self.name, "transcript source withdrawn");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use juancoded_transcripts::{Cursor, Emitted, MemoryCursors, TranscriptEvent};

    struct Fake {
        name: &'static str,
        provider: &'static str,
        lines: Mutex<Vec<String>>,
    }

    impl Fake {
        fn new(name: &'static str, provider: &'static str) -> Arc<Self> {
            Arc::new(Self {
                name,
                provider,
                lines: Mutex::new(Vec::new()),
            })
        }

        fn push(&self, text: &str) {
            self.lines
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(text.to_string());
        }
    }

    impl TranscriptSource for Fake {
        fn name(&self) -> &'static str {
            self.name
        }

        fn source(&self) -> Source {
            Source::ClaudeJsonl
        }

        fn bind(&self, req: &BindRequest) -> Option<Binding> {
            (req.provider == self.provider).then(|| Binding::ClaudeJsonl {
                path: format!("/fake/{}.jsonl", req.session).into(),
            })
        }

        fn read(&self, _: &Binding, cursor: &Cursor) -> anyhow::Result<(Vec<Emitted>, Cursor)> {
            let read: usize = cursor.parse().unwrap_or(0);
            let lines = self.lines.lock().unwrap_or_else(|e| e.into_inner());
            let fresh: Vec<Emitted> = lines[read.min(lines.len())..]
                .iter()
                .map(|text| {
                    Emitted::new(
                        None,
                        None,
                        TranscriptEvent::Assistant {
                            step: None,
                            text: text.clone(),
                        },
                    )
                })
                .collect();
            Ok((fresh, lines.len().to_string()))
        }
    }

    fn hub() -> TranscriptHub {
        TranscriptHub::new(Arc::new(MemoryCursors::new()))
    }

    fn req(session: &str, provider: &str) -> BindRequest {
        BindRequest {
            session: session.into(),
            provider: provider.into(),
            cwd: "/tmp".into(),
            cli_session_id: Some("cli-1".into()),
        }
    }

    #[test]
    fn the_first_source_that_can_bind_a_session_owns_it() {
        let hub = hub();
        let claude = Fake::new("claude-jsonl", "claude");
        let opencode = Fake::new("opencode-sqlite", "opencode");
        let _a = hub.register_source(claude).unwrap();
        let _b = hub.register_source(opencode).unwrap();

        assert_eq!(hub.sources(), ["claude-jsonl", "opencode-sqlite"]);
        assert_eq!(hub.attach(&req("s1", "claude")), Some("claude-jsonl"));
        assert_eq!(hub.attach(&req("s2", "opencode")), Some("opencode-sqlite"));
        assert_eq!(
            hub.attach(&req("s3", "codex")),
            None,
            "nothing owns codex yet"
        );
        assert_eq!(hub.bindings().len(), 2);
    }

    #[test]
    fn a_poll_reads_only_what_appeared_since_the_last_one_and_seq_never_repeats() {
        let hub = hub();
        let source = Fake::new("claude-jsonl", "claude");
        let _guard = hub
            .register_source(Arc::clone(&source) as Arc<dyn TranscriptSource>)
            .unwrap();
        hub.attach(&req("s1", "claude"));

        source.push("one");
        let first = hub.poll("s1").unwrap();
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].seq, 0);

        assert!(hub.poll("s1").unwrap().is_empty(), "nothing new");

        source.push("two");
        source.push("three");
        let second = hub.poll("s1").unwrap();
        assert_eq!(
            second.iter().map(|r| r.seq).collect::<Vec<_>>(),
            [1, 2],
            "sequence numbers continue across polls"
        );
    }

    #[test]
    fn replay_reads_the_whole_transcript_without_moving_the_tail() {
        let hub = hub();
        let source = Fake::new("claude-jsonl", "claude");
        let _guard = hub
            .register_source(Arc::clone(&source) as Arc<dyn TranscriptSource>)
            .unwrap();
        hub.attach(&req("s1", "claude"));
        source.push("one");
        source.push("two");
        assert_eq!(hub.poll("s1").unwrap().len(), 2);

        let replayed = hub.replay("s1").unwrap();
        assert_eq!(replayed.len(), 2);
        assert_eq!(replayed[0].seq, 0);
        // The tail is where it was: replay is a read, not a rewind.
        source.push("three");
        let tailed = hub.poll("s1").unwrap();
        assert_eq!(tailed.len(), 1);
        assert_eq!(tailed[0].seq, 2);
    }

    #[test]
    fn polling_or_replaying_a_session_nobody_bound_is_empty_rather_than_an_error() {
        let hub = hub();
        assert!(hub.poll("ghost").unwrap().is_empty());
        assert!(hub.replay("ghost").unwrap().is_empty());
    }

    #[test]
    fn two_sources_cannot_share_a_name() {
        let hub = hub();
        let _first = hub
            .register_source(Fake::new("claude-jsonl", "claude"))
            .unwrap();
        let err = hub
            .register_source(Fake::new("claude-jsonl", "opencode"))
            .unwrap_err();
        assert_eq!(err, SourceTaken("claude-jsonl"));
    }

    #[test]
    fn detaching_forgets_the_binding_and_the_cursor() {
        let cursors = Arc::new(MemoryCursors::new());
        let hub = TranscriptHub::new(cursors.clone());
        let source = Fake::new("claude-jsonl", "claude");
        let _guard = hub
            .register_source(Arc::clone(&source) as Arc<dyn TranscriptSource>)
            .unwrap();
        hub.attach(&req("s1", "claude"));
        source.push("one");
        hub.poll("s1").unwrap();
        assert!(cursors.load("s1").is_some());

        hub.detach("s1");
        assert!(hub.bindings().is_empty());
        assert!(cursors.load("s1").is_none());
        assert!(hub.poll("s1").unwrap().is_empty());
    }

    #[test]
    fn the_three_rows_mount_and_the_row_that_was_waiting_on_this_key_stops_waiting() {
        // `activity-log` ships in the default tree PENDING on `transcripts`, as the
        // standing proof that a waiting plugin is visible. This is the other half of
        // that proof: the key exists, and the row that wanted it runs.
        let entries = crate::plugins::default_entries()
            .push(crate::Entry::new("transcripts", "transcripts"))
            .push(crate::Entry::new("transcript-claude", "transcript-claude"))
            .push(crate::Entry::new(
                "transcript-opencode",
                "transcript-opencode",
            ));
        let (loader, report) = crate::boot_with(&entries).unwrap();

        assert!(report.is_clean(), "{:?}", report.diagnostics());
        assert!(loader.state("activity-log").unwrap().is_active());
        let api = loader.services().resolve::<TranscriptsService>().unwrap();
        assert_eq!(api.sources(), ["claude-jsonl", "opencode-sqlite"]);

        // Disabling one source by id leaves the hub and the other source alone.
        let mut entries = entries;
        entries.set_disabled("transcript-opencode", true);
        let mut loader = loader;
        loader.apply(&entries).unwrap();
        let api = loader.services().resolve::<TranscriptsService>().unwrap();
        assert_eq!(api.sources(), ["claude-jsonl"]);
    }

    #[test]
    fn a_batch_reaches_a_listener_on_the_bus_as_well_as_the_caller() {
        let bus = Bus::new();
        let hub = TranscriptHub::with_bus(Arc::new(MemoryCursors::new()), bus.clone());
        let seen = Arc::new(Mutex::new(Vec::<u64>::new()));
        let sink = Arc::clone(&seen);
        let _listener = bus.on::<TranscriptAppended, _>("test.sink", move |batch| {
            sink.lock()
                .unwrap_or_else(|e| e.into_inner())
                .extend(batch.records.iter().map(|r| r.seq));
        });

        let source = Fake::new("claude-jsonl", "claude");
        let _guard = hub
            .register_source(Arc::clone(&source) as Arc<dyn TranscriptSource>)
            .unwrap();
        hub.attach(&req("s1", "claude"));
        source.push("one");
        source.push("two");
        hub.poll("s1").unwrap();
        assert_eq!(*seen.lock().unwrap(), [0, 1]);

        // An empty poll is not an event: a listener that woke on nothing would be a
        // second reason for a sleeping session to be looked at.
        hub.poll("s1").unwrap();
        assert_eq!(*seen.lock().unwrap(), [0, 1]);
    }

    #[test]
    fn dropping_a_sources_guard_takes_its_bindings_with_it() {
        let hub = hub();
        let source = Fake::new("claude-jsonl", "claude");
        let guard = hub
            .register_source(Arc::clone(&source) as Arc<dyn TranscriptSource>)
            .unwrap();
        hub.attach(&req("s1", "claude"));
        source.push("one");
        assert_eq!(hub.poll("s1").unwrap().len(), 1);

        drop(guard);
        assert!(hub.sources().is_empty());
        assert!(
            hub.bindings().is_empty(),
            "a binding to a withdrawn reader is a session nothing can read"
        );
        assert!(hub.poll("s1").unwrap().is_empty());
    }

    #[test]
    fn a_guard_outliving_the_hub_finds_nothing_rather_than_a_dangling_map() {
        let hub = hub();
        let guard = hub
            .register_source(Fake::new("claude-jsonl", "claude"))
            .unwrap();
        drop(hub);
        drop(guard);
    }

    #[test]
    fn a_cursor_recorded_against_a_different_file_is_not_resumed_from() {
        let cursors = Arc::new(MemoryCursors::new());
        let hub = TranscriptHub::new(cursors.clone());
        let source = Fake::new("claude-jsonl", "claude");
        let _guard = hub
            .register_source(Arc::clone(&source) as Arc<dyn TranscriptSource>)
            .unwrap();
        hub.attach(&req("s1", "claude"));
        source.push("one");
        source.push("two");

        // A cursor left by an earlier binding to some other file, restored on top.
        let mut stale = StoredCursor::fresh(Source::ClaudeJsonl, "/fake/somewhere-else.jsonl");
        stale.cursor = "2".into();
        stale.next_seq = 99;
        cursors.save("s1", &stale).unwrap();

        let records = hub.poll("s1").unwrap();
        assert_eq!(records.len(), 2, "the stale offset must not skip this file");
        assert_eq!(records[0].seq, 0);
    }
}
