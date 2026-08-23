//! The transcript seam: a second data plane per session, beside the pty bytes.
//!
//! juancode has exactly one plane today, pty bytes into a VT grid, so everything
//! structured a session produces (turn boundaries, reasoning, tool calls, token
//! counts) survives only as styled text somebody has to scrape back out. It does not
//! have to: every CLI we drive already writes that structure to disk for its own
//! resume, and this crate reads it.
//!
//! Three properties shape the whole crate.
//!
//! 1. **Read-only, always.** We are a reader of somebody else's store. Nothing here
//!    opens a CLI's file for writing, creates one that was missing, or takes a lock a
//!    live CLI would notice. The opencode reader opens its database `READ_ONLY` for
//!    exactly that reason, and the claude reader only ever `read_at`s.
//! 2. **Incremental.** A session's transcript grows for hours and is read on every
//!    poll, so a reader that re-parsed the file would cost more than the feature is
//!    worth. Every source carries an opaque durable cursor ([`Cursor`]) and reads
//!    only what appeared after it; see [`tail`] for the ways a file can move under a
//!    cursor and what each one does.
//! 3. **Typed, not transcribed.** Only the eight events in [`TranscriptEvent`] cross
//!    the seam. A field in a CLI's own format that does not map onto one of them is
//!    skipped, not modelled, because the seam's job is to be the same shape whichever
//!    CLI is behind it.
//!
//! The provider trait is [`TranscriptSource`]: bind a session to a locator, then read
//! forward from a cursor. Two implement it, [`claude::ClaudeJsonl`] and
//! [`opencode::OpencodeSqlite`]. A third for codex fits without changing anything
//! here, which is the point of the trait, but codex is not installed on the machine
//! this was written on and none of it is invented.

pub mod claude;
pub mod cursors;
pub mod opencode;
pub mod tail;
pub mod time;

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

pub use cursors::{CursorStore, MemoryCursors, SqliteCursors, StoredCursor};

/// How much of any one string crosses the seam.
///
/// A tool result can be a whole file and a prompt can be a whole ticket. The bytes are
/// still on disk either way, so a reader that held megabytes in memory per session
/// would be paying for something a consumer can go and fetch.
pub const MAX_TEXT: usize = 16 * 1024;

/// Which CLI's own store a record came out of.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Source {
    ClaudeJsonl,
    OpencodeSqlite,
}

impl Source {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::ClaudeJsonl => "claude-jsonl",
            Self::OpencodeSqlite => "opencode-sqlite",
        }
    }
}

/// Tokens one step spent. Every field is "as the CLI reported it"; a CLI that does not
/// break a number out leaves it zero rather than having one guessed for it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TokenUsage {
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    pub reasoning: u64,
}

impl TokenUsage {
    pub fn is_zero(&self) -> bool {
        *self == Self::default()
    }
}

/// The eight things the seam carries.
///
/// This list is the contract, and it is short on purpose: a consumer written against
/// it must not have to know which CLI produced the record. `step` is the CLI's own
/// name for one model request, so a consumer can group a turn's work without inventing
/// its own boundaries.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum TranscriptEvent {
    /// A human prompt opened a turn.
    TurnStart { prompt: String },
    /// The turn closed. `reason` is the CLI's word for it when it had one.
    TurnEnd { reason: Option<String> },
    /// One model request began.
    Step { step: String, model: Option<String> },
    /// Prose the assistant wrote.
    Assistant { step: Option<String>, text: String },
    /// A reasoning block. Empty ones are dropped at the source: a redacted thinking
    /// block is a signature and no text, and that is not a thought anyone can read.
    Thinking { step: Option<String>, text: String },
    /// A tool was called. `input` is the arguments as compact JSON, which is what a
    /// repeat-tool detector needs in order to canonicalise them.
    ToolCall {
        call: String,
        name: String,
        input: String,
    },
    /// That call came back. `call` matches the [`TranscriptEvent::ToolCall`] before it.
    ToolResult {
        call: String,
        ok: bool,
        output: String,
    },
    /// What a step cost.
    Usage {
        step: Option<String>,
        usage: TokenUsage,
    },
}

impl TranscriptEvent {
    /// A short label, for logs and the dump.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::TurnStart { .. } => "turnStart",
            Self::TurnEnd { .. } => "turnEnd",
            Self::Step { .. } => "step",
            Self::Assistant { .. } => "assistant",
            Self::Thinking { .. } => "thinking",
            Self::ToolCall { .. } => "toolCall",
            Self::ToolResult { .. } => "toolResult",
            Self::Usage { .. } => "usage",
        }
    }
}

/// What a source emits: an event, when it happened, and the turn it belongs to.
///
/// The session id and the sequence number are not here because a source does not know
/// them; whoever drives the source stamps them on the way out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Emitted {
    pub at_ms: Option<i64>,
    pub turn: Option<String>,
    pub event: TranscriptEvent,
}

impl Emitted {
    pub fn new(at_ms: Option<i64>, turn: Option<String>, event: TranscriptEvent) -> Self {
        Self { at_ms, turn, event }
    }
}

/// One record as a consumer sees it. Append-only within a session: `seq` never
/// repeats and never goes backwards, across restarts included.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptRecord {
    pub session: String,
    pub source: Source,
    pub seq: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub at_ms: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn: Option<String>,
    #[serde(flatten)]
    pub event: TranscriptEvent,
}

/// Where a session's transcript actually is.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "source", rename_all = "kebab-case")]
pub enum Binding {
    ClaudeJsonl { path: PathBuf },
    OpencodeSqlite { db: PathBuf, conversation: String },
}

impl Binding {
    pub fn source(&self) -> Source {
        match self {
            Self::ClaudeJsonl { .. } => Source::ClaudeJsonl,
            Self::OpencodeSqlite { .. } => Source::OpencodeSqlite,
        }
    }

    /// The stable string that names this binding in the cursor store.
    pub fn locator(&self) -> String {
        match self {
            Self::ClaudeJsonl { path } => path.to_string_lossy().into_owned(),
            Self::OpencodeSqlite { db, conversation } => {
                format!("{}#{conversation}", db.to_string_lossy())
            }
        }
    }
}

/// Everything known about a session at the moment we go looking for its transcript.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BindRequest {
    pub session: String,
    pub provider: String,
    pub cwd: String,
    /// The CLI's own conversation id, when the session has one yet. For claude this is
    /// the id we pinned at spawn; for opencode it is discovered minutes later, so
    /// `None` is an ordinary state and means "ask again".
    pub cli_session_id: Option<String>,
}

/// An opaque, provider-owned resume point. Empty means "from the beginning".
///
/// Opaque on purpose: the claude cursor is a byte offset plus a file identity, the
/// opencode one is a row key plus the tool calls still in flight, and a codex one will
/// be something else again. Whoever stores it only has to keep the bytes.
pub type Cursor = String;

/// A provider of structured transcript events for one CLI.
pub trait TranscriptSource: Send + Sync {
    /// The name an entry list and `dump-config` address this source by.
    fn name(&self) -> &'static str;

    fn source(&self) -> Source;

    /// Where this session's transcript is, if this source owns the session at all and
    /// the transcript exists yet. `None` is normal and retryable.
    fn bind(&self, req: &BindRequest) -> Option<Binding>;

    /// Read forward from `cursor`, returning what appeared and where to resume.
    ///
    /// Must be cheap when nothing changed, and must never re-read what the cursor has
    /// already passed.
    fn read(&self, binding: &Binding, cursor: &Cursor) -> anyhow::Result<(Vec<Emitted>, Cursor)>;
}

/// Trim to [`MAX_TEXT`], marking the cut so a consumer never renders a silent half.
pub fn clamp(text: &str) -> String {
    if text.len() <= MAX_TEXT {
        return text.to_string();
    }
    let mut end = MAX_TEXT;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…[truncated]", &text[..end])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clamping_cuts_on_a_character_boundary_and_says_it_cut() {
        let short = "héllo";
        assert_eq!(clamp(short), short);
        // A multi-byte character straddling the cap must not be split in half.
        let long = "é".repeat(MAX_TEXT);
        let cut = clamp(&long);
        assert!(cut.ends_with("…[truncated]"));
        assert!(cut.len() < long.len());
    }

    #[test]
    fn a_record_serialises_with_its_event_inline() {
        let record = TranscriptRecord {
            session: "s1".into(),
            source: Source::ClaudeJsonl,
            seq: 3,
            at_ms: Some(17),
            turn: Some("t1".into()),
            event: TranscriptEvent::Thinking {
                step: Some("req_1".into()),
                text: "hm".into(),
            },
        };
        let json = serde_json::to_value(&record).unwrap();
        assert_eq!(json["kind"], "thinking");
        assert_eq!(json["source"], "claude-jsonl");
        assert_eq!(json["seq"], 3);
        assert_eq!(
            serde_json::from_value::<TranscriptRecord>(json).unwrap(),
            record
        );
    }
}
