//! The service contracts the rest of the core resolves by key, plus the adapters that
//! mount the existing crates behind them.
//!
//! The contract is a trait and the key is a string; neither mentions
//! `alacritty_terminal` or `portable-pty`. That is the point: a consumer holds
//! `Arc<dyn TerminalApi>`, so replacing the implementation is a change at one mount
//! site, and a test can stand in a fake without touching a pty.

pub mod goal;
pub mod pty;
pub mod queue;
pub mod terminal;
pub mod transcripts;

pub use goal::{
    Armed, BlockCode, Blocked, Goal, GoalApi, GoalBook, GoalError, GoalJournal, GoalPhase, GoalRef,
    GoalService, GoalSnapshot, MemoryJournal, RoundOutcome, RoundRefusal, ROUND_CAP_REACHED,
};
pub use pty::{PtyHost, PtySpawnApi, PtySpawnService};
pub use queue::{
    Claim, ClaimRefused, ClaimSink, Content, Delivery, ItemState, Occurrence, QueueApi, QueueError,
    QueueService, QueueSnapshot, SessionQueues,
};
pub use terminal::{TerminalApi, TerminalService, VtTerminals};
pub use transcripts::{
    SourceTaken, TranscriptAppended, TranscriptBatch, TranscriptHub, Transcripts, TranscriptsApi,
    TranscriptsService,
};
