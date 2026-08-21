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
