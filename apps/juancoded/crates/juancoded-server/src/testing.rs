//! Fixtures shared by the tests in this crate.
//!
//! Two of them, and they answer different questions. [`handles`] is the real state
//! layer over an in-memory store with `/bin/cat` in place of a provider CLI, for
//! anything about the tree or the wire. [`FakeChild`] is a session whose whole
//! observable behaviour is scripted, for anything about delivery: both the seed engine
//! and the queue's claim boundary need to assert which bytes a child received in which
//! order, and that answer must not depend on when a real process happened to be
//! scheduled.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use juancoded_core::model::{ProviderId, SessionActivity, SessionMeta, SessionStatus};
use juancoded_state::registry::{AdoptRequest, Attached, CreateRequest, SessionEvent, StateError};
use juancoded_state::{ClientId, QueuedMessage, ReapProbe, ResizeOutcome, SessionsApi};
use juancoded_vt::{Snapshot, TerminalModel};
use tokio::sync::broadcast;

use crate::serve::CoreHandles;

pub fn handles() -> CoreHandles {
    let (loader, _, sessions) =
        juancoded_state::boot_with(&juancoded_state::test_entries("/bin/cat", &[]))
            .expect("the test tree mounts");
    let handles = CoreHandles::from_loader(&loader, sessions);
    // The loader owns every mounted plugin's effects, so it has to outlive the handles
    // it vended; leaking it for the length of a test is cheaper than threading it
    // through every call site.
    std::mem::forget(loader);
    handles
}

pub fn sessions() -> Arc<dyn SessionsApi> {
    handles().sessions
}

/// A session whose whole observable behaviour is scripted: what it echoes, when
/// it exits, and every byte it was written.
///
/// A real pty is in the end-to-end case below and in the conformance suite. It is
/// the wrong instrument for "exactly once", where the question is which bytes the
/// child received in which order, and the answer must not depend on when a child
/// process happened to be scheduled.
pub struct FakeChild {
    writes: Mutex<Vec<Vec<u8>>>,
    model: Mutex<TerminalModel>,
    /// Whether the child paints what it is sent, the way a TUI's input box does.
    echoes: bool,
    /// A child that takes the paste and does nothing at all with the Enter, which
    /// is the shape of the bug this engine exists for: the prompt sits typed and
    /// unsent, and the delivery has to say so rather than report a submission.
    pub swallows_enter: AtomicBool,
    pub running: AtomicBool,
    pub busy: AtomicBool,
    pub dormant: AtomicBool,
    events: broadcast::Sender<SessionEvent>,
}

impl FakeChild {
    pub fn new(echoes: bool) -> Arc<Self> {
        // A settled banner, so the readiness wait has something stable to see.
        Self::painting(echoes, b"fake-agent ready\r\n")
    }

    /// A child showing nothing at all: on the way up that is a CLI that has not painted
    /// yet, and on a live session it is one that just cleared for the next turn.
    pub fn blank(echoes: bool) -> Arc<Self> {
        Self::painting(echoes, b"")
    }

    fn painting(echoes: bool, banner: &[u8]) -> Arc<Self> {
        let mut model = TerminalModel::new(80, 24, 100);
        model.feed(banner);
        let (events, _) = broadcast::channel(16);
        Arc::new(Self {
            writes: Mutex::new(Vec::new()),
            model: Mutex::new(model),
            echoes,
            swallows_enter: AtomicBool::new(false),
            running: AtomicBool::new(true),
            busy: AtomicBool::new(false),
            dormant: AtomicBool::new(false),
            events,
        })
    }

    pub fn written(&self) -> Vec<Vec<u8>> {
        self.writes.lock().unwrap().clone()
    }

    /// Every byte the child was sent, in order, as one string.
    pub fn stream(&self) -> String {
        String::from_utf8_lossy(&self.written().concat()).into_owned()
    }

    pub fn api(self: &Arc<Self>) -> Arc<dyn SessionsApi> {
        self.clone()
    }
}

impl SessionsApi for FakeChild {
    /// Unlimited: a fixture that pruned would delete the session a scenario is
    /// halfway through addressing.
    fn retention(&self) -> usize {
        0
    }

    /// Nothing to persist: this fake holds no scrollback.
    fn flush_all(&self) -> usize {
        0
    }

    /// This fake has no activity detector, and the queue engine it stands in for
    /// classifies busy off `busy` below rather than off any transcript.
    fn on_transcript(&self, _id: &str, _records: &[juancoded_transcripts::TranscriptRecord]) {}

    fn input(&self, _id: &str, data: &[u8]) -> Result<(), StateError> {
        self.writes.lock().unwrap().push(data.to_vec());
        let mut model = self.model.lock().unwrap();
        if data == b"\r" && self.swallows_enter.load(Ordering::Relaxed) {
            // Nothing moves: the box keeps the text and the child never answers.
        } else if data == b"\r" {
            // Submitting clears the box and the child answers, which is what both
            // of the engine's submission signals are looking at.
            model.feed(b"\x1b[2J\x1b[Hthe child ran its turn\r\n");
        } else if self.echoes {
            // Painted at the bottom of the grid, because that is where a TUI's
            // input box is and the submission check only looks there. Echoing at
            // the top would make every delivery read as submitted the instant it
            // was pasted, which is the bug being tested for rather than a fixture
            // detail.
            model.feed(b"\x1b[24;1H");
            model.feed(data);
            model.feed(b"\r\n");
        }
        Ok(())
    }

    fn snapshot(&self, _id: &str) -> Option<Snapshot> {
        Some(self.model.lock().unwrap().snapshot())
    }

    fn is_running(&self, _id: &str) -> bool {
        self.running.load(Ordering::Relaxed)
    }

    fn activity(&self, _id: &str) -> Option<SessionActivity> {
        Some(if self.busy.load(Ordering::Relaxed) {
            SessionActivity::Busy
        } else {
            SessionActivity::Idle
        })
    }

    fn meta(&self, id: &str) -> Option<SessionMeta> {
        let mut meta = SessionMeta::new(
            id.into(),
            ProviderId::Claude,
            "/tmp".into(),
            "fake".into(),
            0,
            false,
        );
        meta.status = SessionStatus::Running;
        Some(meta)
    }

    // Nothing below is on the delivery path; a fake that pretended otherwise
    // would be lying about what this test covers.
    fn subscribe(&self) -> broadcast::Receiver<SessionEvent> {
        self.events.subscribe()
    }
    fn ids(&self) -> Vec<String> {
        vec!["fake".into()]
    }
    fn grid(&self, _id: &str) -> Option<(u16, u16)> {
        Some((80, 24))
    }
    fn grid_owner(&self, _id: &str) -> Option<ClientId> {
        None
    }
    fn create(&self, _req: CreateRequest) -> Result<SessionMeta, StateError> {
        unimplemented!("the fake is handed an already-created session")
    }
    fn adopt_external(&self, _req: AdoptRequest) -> Result<Option<SessionMeta>, StateError> {
        unimplemented!()
    }
    fn attach(&self, _id: &str, _o: ClientId, _c: u16, _r: u16) -> Result<Attached, StateError> {
        unimplemented!()
    }
    fn reactivate(
        &self,
        _id: &str,
        _o: ClientId,
        _c: u16,
        _r: u16,
    ) -> Result<Option<Attached>, StateError> {
        unimplemented!()
    }
    fn set_skip_permissions(
        &self,
        _id: &str,
        _skip: bool,
        _o: ClientId,
        _c: u16,
        _r: u16,
    ) -> Result<Attached, StateError> {
        unimplemented!()
    }
    fn queue(&self, _id: &str) -> Vec<QueuedMessage> {
        Vec::new()
    }
    fn queue_message(&self, _id: &str, _text: &str) -> Result<Option<QueuedMessage>, StateError> {
        unimplemented!()
    }
    fn dequeue_message(&self, _id: &str, _message_id: &str) -> Result<bool, StateError> {
        unimplemented!()
    }
    fn resize(&self, _id: &str, _o: ClientId, _c: u16, _r: u16) -> ResizeOutcome {
        unimplemented!()
    }
    fn release_client(&self, _owner: ClientId) {}
    fn kill(&self, _id: &str) -> Result<(), StateError> {
        self.running.store(false, Ordering::Relaxed);
        Ok(())
    }
    /// No pty, so no child pid — which is exactly what a reaper sweep over this fake
    /// should see. The reaper's own behaviour is measured against a fake that does
    /// have one, in `juancoded_state::reaper::tests`.
    fn reap_probe(&self, id: &str) -> Option<ReapProbe> {
        Some(ReapProbe {
            id: id.into(),
            cwd: "/tmp".into(),
            cli_session_id: Some("fake-cli-id".into()),
            running: self.running.load(Ordering::Relaxed),
            child_pid: None,
            activity: self.activity(id).unwrap_or(SessionActivity::Idle),
            open_tool_call: false,
            last_input_ms: 0,
            last_output_ms: 0,
            output_bytes: 0,
            last_busy_ms: 0,
            updated_at: 0,
        })
    }
    fn mark_dormant(&self, _id: &str) -> bool {
        !self.dormant.swap(true, Ordering::Relaxed)
    }
}
