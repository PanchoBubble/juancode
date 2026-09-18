//! The harness events the core surfaces mount onto, one per dispatch mode.
//!
//! Each event's mode is its trait, so the dispatch call site is checked against the
//! declaration by the compiler. These four are the real ones the daemon needs, not
//! demonstrations: output fan-in, input policy, exit side effects, binary resolution.

use std::sync::Arc;

use crate::bus::{AroundEvent, FanOutEvent, ObserveEvent, SerialEvent};

/// Bytes a session's pty produced.
#[derive(Debug, Clone)]
pub struct OutputFrame {
    pub session: String,
    pub bytes: Arc<Vec<u8>>,
}

/// Observed, never intercepted: the grid feed, activity detection and transcript
/// tailing all want the same bytes and none of them may alter them.
pub struct SessionOutput;

impl ObserveEvent for SessionOutput {
    const NAME: &'static str = "session.output";
    type Payload = OutputFrame;
}

/// Input on its way to a session's pty. Listeners may annotate `notes` and delegate,
/// or refuse the write and own the decision.
#[derive(Debug, Clone)]
pub struct InputRequest {
    pub session: String,
    pub data: Vec<u8>,
    pub notes: Vec<String>,
}

impl InputRequest {
    pub fn new(session: impl Into<String>, data: impl Into<Vec<u8>>) -> Self {
        Self {
            session: session.into(),
            data: data.into(),
            notes: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InputDecision {
    Delivered(usize),
    Refused(String),
}

/// Around-middleware, because input is where policy lives: the steering queue's claim
/// boundary and the "is this session even alive" check both wrap the same write.
pub struct SessionInput;

impl AroundEvent for SessionInput {
    const NAME: &'static str = "session.input";
    type Request = InputRequest;
    type Output = InputDecision;
}

#[derive(Debug, Clone)]
pub struct ExitInfo {
    pub session: String,
    pub code: Option<i32>,
}

/// Fan-out, because the reactions to an exit are independent of each other: persist
/// the transcript, notify Telegram, release the grid. Nobody should wait in line.
pub struct SessionExit;

impl FanOutEvent for SessionExit {
    const NAME: &'static str = "session.exit";
    type Payload = ExitInfo;
}

#[derive(Debug, Clone)]
pub struct BinQuery {
    pub provider: String,
}

/// Ordered with a return value: the first listener that can name the binary wins, so
/// an env override beats PATH lookup by being registered ahead of it.
pub struct ResolveBinary;

impl SerialEvent for ResolveBinary {
    const NAME: &'static str = "provider.resolveBin";
    type Payload = BinQuery;
    type Output = String;
}

/// What kind of PR activity a candidate notification came out of.
///
/// Carried rather than inferred from the message, because every rule a filter applies
/// is about the kind: "only the most recent review" is only about reviews, and a
/// sentence is not a thing you can apply a rule to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrNotifyKind {
    /// A review verdict — approved, changes requested, a review comment.
    Review,
    /// An issue-level comment on the PR.
    Comment,
    /// CI went red, or would not run.
    Ci,
    /// The PR merged or closed.
    Closed,
    /// The engine itself has something to say: it could not reach the agent, could not
    /// revive a session, could not hand the work over. Never GitHub's doing.
    Engine,
}

/// One thing the tracked-PR poller is about to tell somebody about.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrNotifyCandidate {
    pub kind: PrNotifyKind,
    /// The message as a client would read it.
    pub message: String,
    /// Who caused it, lower-cased; empty when this core cannot say.
    pub actor: String,
    /// For a review: GitHub's node id, which is what "the most recent one" is decided
    /// by, and what makes two passes over the same review the same event.
    pub review_id: Option<String>,
}

/// One poll pass's worth of candidates, with the context every rule needs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrNotifyPass {
    pub tracked_id: String,
    pub pr_number: i64,
    /// The login `gh` is authenticated as, lower-cased. Empty when it could not be
    /// determined, which every rule reads as "no viewer to filter for".
    pub viewer: String,
    /// The PR author's login, lower-cased. Empty when GitHub reported none.
    pub author: String,
    /// The messages already open on this watch, so a repeat can be recognised.
    pub already_open: Vec<String>,
    pub candidates: Vec<PrNotifyCandidate>,
    /// What each listener decided and why, for `dump-config` and for a bug report that
    /// has to explain a notification that never arrived.
    pub notes: Vec<String>,
}

/// Around-middleware over the poller's notifications: a listener may drop candidates
/// and say why, or delegate.
///
/// Around rather than observe because the whole point is to REMOVE notifications, and
/// around rather than a branch inside the poller because these are somebody's rules
/// about their own inbox — turning them off should be an entry in the tree, not a
/// rebuild. With no listener mounted the terminal returns every candidate, which is the
/// behaviour the poller had before any of this existed.
pub struct PrNotify;

impl AroundEvent for PrNotify {
    const NAME: &'static str = "pr.notify";
    type Request = PrNotifyPass;
    type Output = Vec<PrNotifyCandidate>;
}
