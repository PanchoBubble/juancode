//! One WebSocket connection: the whole protocol loop for a single client.
//!
//! Structured as one task selecting over three sources — the socket, the session
//! event bus, and the screen tick — so every piece of per-connection state
//! (attachments, screen streamers, UTF-8 carries) is plain local data. No locks, no
//! shared mutable state, and therefore no ordering question about whether an
//! `inputAck` can overtake the `output` it caused.
//!
//! The connection has an id, and that id is its grid claim. A secondary viewer's
//! attach or resize is arbitrated by the registry rather than silently overwriting
//! the size the CLI is drawing at; when the socket closes, the claim is released so
//! the next client can take over.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use axum::extract::ws::{Message, WebSocket};
use futures::{SinkExt, StreamExt};
use tokio::sync::broadcast::error::{RecvError, TryRecvError};
use tracing::{debug, warn};

use juancoded_cordis::contribution::ContributionRegistry;
use juancoded_cordis::plugins::QueueChanged;
use juancoded_cordis::services::queue::{Content, QueueApi, QueueError, QueueSnapshot};
use juancoded_cordis::services::transcripts::{TranscriptAppended, TranscriptBatch};
use juancoded_core::model::ProviderId;
use juancoded_state::registry::{AdoptRequest, Attached, CreateRequest, SessionEvent, StateError};
use juancoded_state::{ClientId, SessionReaper, SessionsApi};

use crate::screen::ScreenStreamer;
use crate::seed::{deliver_seed, log_outcome, SeedTiming};
use crate::serve::CoreHandles;
use crate::transcript_pump::TranscriptPlane;
use crate::utf8::Utf8Stream;
use crate::wire::{ClientMessage, ServerMessage};

/// Per-connection state the event fan-out reads: which sessions this client is
/// attached to, whose steering queue it is watching, and the UTF-8 carry per session
/// so a split code point is never cut in half across two frames.
struct Fanout {
    attached: HashSet<String>,
    /// Sessions whose queue snapshots this connection asked for. A watch is
    /// per-connection, so unsubscribing stops the frames for this client and nobody
    /// else's, and closing the socket drops the watch with the rest of this state.
    queue_watchers: HashSet<String>,
    /// Sessions whose transcript records this connection asked for. Per-connection
    /// like the queue watch, and dropped with the socket.
    transcript_watchers: HashSet<String>,
    /// The contribution revision this connection last saw, once it asked to watch.
    /// `None` means it is not watching, which is every client that does not know the
    /// surface exists.
    contribution_revision: Option<u64>,
    carries: HashMap<String, Utf8Stream>,
    /// Frames a background task owes this client, out of band from the request that
    /// started it. Seeded delivery is the only one today: it outlives the create it
    /// belongs to by the whole of a CLI's boot window, and a delivery that failed has
    /// to say so on the wire rather than in a log nobody dispatching is reading.
    oob: tokio::sync::mpsc::UnboundedSender<ServerMessage>,
}

/// Screen-diff cadence: at most one frame per tick, matching the Swift streamer.
const SCREEN_TICK: Duration = Duration::from_millis(80);
/// The grid a client with no viewport of its own gets. Whatever the CLI prints in
/// its first turn is wrapped at the spawn width forever, so a nominal 80x24 would
/// leave a permanently narrow transcript that resizing the pane cannot widen.
const DEFAULT_GRID: (u16, u16) = (120, 40);

static NEXT_CLIENT_ID: AtomicU64 = AtomicU64::new(1);

/// Everything a closing connection has to hand back: the grids it claimed, so the next
/// viewer's resize is applied rather than denied by a connection nobody is holding, and
/// the sessions it declared off-limits, so a pane nobody is looking at any more stops
/// being un-reapable forever.
fn release(
    sessions: &Arc<dyn SessionsApi>,
    reaper: Option<&Arc<SessionReaper>>,
    client: ClientId,
) {
    sessions.release_client(client);
    if let Some(reaper) = reaper {
        reaper.release_client(client);
    }
}

pub async fn handle(socket: WebSocket, handles: CoreHandles) {
    let CoreHandles {
        sessions,
        contributions,
        queue,
        transcripts,
        reaper,
        bus,
        identity,
    } = handles;
    let client: ClientId = NEXT_CLIENT_ID.fetch_add(1, Ordering::Relaxed);
    let (mut tx, mut rx) = socket.split();
    let mut events = sessions.subscribe();

    // Queue snapshots come off the cordis bus rather than the registry's event stream,
    // because the queue that publishes them is a mounted service and the snapshot it
    // publishes is already complete. Listening for it means this connection never has
    // to read a queue back out and never has to decide what "now" was: what goes on the
    // wire is the exact value the mutation produced.
    //
    // The listener is an effect held for the length of the connection. Dropping it on
    // the way out is what unregisters it, so a closed socket leaves nothing on the bus.
    let (queue_tx, mut queue_rx) = tokio::sync::mpsc::unbounded_channel::<QueueSnapshot>();
    let _queue_listener = bus.on::<QueueChanged, _>(&format!("wire.queue.{client}"), move |s| {
        // A closed channel is a connection already on its way out; the frame it would
        // have carried is nobody's any more.
        let _ = queue_tx.send(s.clone());
    });

    // The transcript seam announces every batch it reads on the same bus, for the same
    // reason: the pump that read it is not this connection, and what goes on the wire
    // has to be the exact batch the poll produced rather than a re-read of a table
    // whose newest rows may already have moved on.
    let (transcript_tx, mut transcript_rx) =
        tokio::sync::mpsc::unbounded_channel::<TranscriptBatch>();
    let _transcript_listener =
        bus.on::<TranscriptAppended, _>(&format!("wire.transcript.{client}"), move |batch| {
            let _ = transcript_tx.send(batch.clone());
        });

    // Always first on the wire, before anything else can be sent.
    if tx
        .send(Message::Text(
            ServerMessage::ServerInfo {
                client_id: client,
                identity,
            }
            .to_json()
            .into(),
        ))
        .await
        .is_err()
    {
        release(&sessions, reaper.as_ref(), client);
        return;
    }
    // Then who already drives which grid, so a client that arrives mid-flight starts
    // from the truth rather than assuming every grid is free.
    for frame in grid_snapshot(&sessions) {
        if tx
            .send(Message::Text(frame.to_json().into()))
            .await
            .is_err()
        {
            release(&sessions, reaper.as_ref(), client);
            return;
        }
    }

    let (oob_tx, mut oob_rx) = tokio::sync::mpsc::unbounded_channel::<ServerMessage>();
    let mut fanout = Fanout {
        attached: HashSet::new(),
        queue_watchers: HashSet::new(),
        transcript_watchers: HashSet::new(),
        contribution_revision: None,
        carries: HashMap::new(),
        oob: oob_tx,
    };
    let mut screens: HashMap<String, ScreenStreamer> = HashMap::new();
    let mut ticker = tokio::time::interval(SCREEN_TICK);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        let mut outbound: Vec<ServerMessage> = Vec::new();

        tokio::select! {
            Some(snapshot) = queue_rx.recv() => {
                // Gated on a watch, like output: a queue is something a client opted
                // into, not a fact about a session everyone is owed.
                if fanout.queue_watchers.contains(&snapshot.session) {
                    outbound.push(ServerMessage::Queue { snapshot });
                }
            }

            Some(batch) = transcript_rx.recv() => {
                // Gated on a watch, like output and like the queue: a transcript is a
                // stream a client opted into.
                if fanout.transcript_watchers.contains(&batch.session) {
                    outbound.push(transcript_frame(&batch.session, false, batch.records.iter()));
                }
            }

            incoming = rx.next() => {
                let Some(Ok(frame)) = incoming else { break };
                match frame {
                    Message::Text(text) => {
                        let mut reply: Vec<ServerMessage> = Vec::new();
                        match ClientMessage::decode(&text) {
                            Ok(msg) => handle_client_message(
                                msg,
                                &Tree {
                                    sessions: &sessions,
                                    contributions: &contributions,
                                    queue: queue.as_ref(),
                                    transcripts: transcripts.as_ref(),
                                    reaper: reaper.as_ref(),
                                },
                                client,
                                &mut fanout,
                                &mut screens,
                                &mut reply,
                            ),
                            Err(e) => {
                                // One sessionless error, and the connection lives: a
                                // client that can be killed by one bad frame cannot
                                // be upgraded independently of the core.
                                warn!(error = %e, "undecodable frame");
                                reply.push(ServerMessage::Error {
                                    session_id: None,
                                    message: "Invalid JSON".into(),
                                });
                            }
                        }
                        // A handler that moved the arbitrated grid has already put the
                        // broadcast on the bus. Fold that in ahead of the handler's own
                        // reply, so the grant is public before the `created` or the
                        // `resizeAck` it belongs to — the order the Swift core gets for
                        // free by emitting from inside the state change. Bytes and
                        // lifecycle keep their place behind the reply, so `attached`
                        // stays the replay baseline it promises to be.
                        let mut behind: Vec<ServerMessage> = Vec::new();
                        drain_bus(&mut events, &mut fanout, &mut outbound, &mut behind);
                        outbound.extend(reply);
                        outbound.extend(behind);
                    }
                    Message::Close(_) => break,
                    // A client that speaks binary is not a thing today; ignore
                    // rather than tearing the connection down.
                    _ => {}
                }
            }
            frame = oob_rx.recv() => {
                // The sender lives with this connection, so `None` cannot happen
                // while this loop is alive.
                if let Some(frame) = frame {
                    outbound.push(frame);
                }
            }
            event = events.recv() => {
                match event {
                    Ok(event) => push_event(event, &mut fanout, &mut outbound),
                    Err(RecvError::Lagged(n)) => {
                        debug!(dropped = n, "connection lagged behind the session bus");
                    }
                    Err(RecvError::Closed) => break,
                }
            }
            _ = ticker.tick() => {
                for (session_id, streamer) in screens.iter_mut() {
                    if let Some(snapshot) = sessions.snapshot(session_id) {
                        if let Some(frame) = streamer.frame(snapshot) {
                            outbound.push(frame);
                        }
                    }
                }
                // A contribution appears or disappears when a plugin mounts or
                // unmounts, which is not a session event and so has no bus to ride.
                // Comparing one integer on the tick a watcher is already paying for
                // is cheaper than a second broadcast channel for something that
                // changes a handful of times in a daemon's life.
                if let Some(seen) = fanout.contribution_revision {
                    let current = contributions.revision();
                    if current != seen {
                        fanout.contribution_revision = Some(current);
                        outbound.push(ServerMessage::Contributions {
                            snapshot: contributions.snapshot(),
                        });
                    }
                }
            }
        }

        for msg in outbound {
            if tx.send(Message::Text(msg.to_json().into())).await.is_err() {
                release(&sessions, reaper.as_ref(), client);
                return;
            }
        }
    }
    // The socket is gone: drop this client's grid claims so the next viewer's resize
    // is applied rather than denied by a connection nobody is holding.
    release(&sessions, reaper.as_ref(), client);
}

/// Turn one bus event into the frames this connection owes for it. Output is gated on
/// an attachment because it is a byte stream a client opted into; the session-level
/// broadcasts are not, because a sidebar row and a grid owner are facts about a
/// session a client may never have attached to.
fn push_event(event: SessionEvent, fanout: &mut Fanout, outbound: &mut Vec<ServerMessage>) {
    match event {
        SessionEvent::Output { session_id, bytes } => {
            if fanout.attached.contains(&session_id) {
                let carry = fanout.carries.entry(session_id.clone()).or_default();
                let data = carry.push(&bytes);
                if !data.is_empty() {
                    outbound.push(ServerMessage::Output { session_id, data });
                }
            }
        }
        SessionEvent::Activity {
            session_id,
            state,
            notify,
            changes,
            dispatch_id,
        } => outbound.push(ServerMessage::Activity {
            session_id,
            state,
            notify,
            changes,
            dispatch_id,
        }),
        SessionEvent::Exit {
            session_id,
            exit_code,
        } => outbound.push(ServerMessage::Exit {
            session_id,
            exit_code,
        }),
        SessionEvent::Meta { session_id, meta } => outbound.push(ServerMessage::SessionMeta {
            session_id,
            session: meta,
        }),
        // Deliberately no frame. This announces the registry's own store-backed queue,
        // and the wire's queue is the addressable one mounted as the `queue` service:
        // sending both would put two different lists under one frame type, and the one
        // a client could address by id would be whichever arrived last.
        SessionEvent::QueueChanged { session_id } => {
            debug!(session = %session_id, "ignoring the store queue's change event");
        }
        SessionEvent::GridChange {
            session_id,
            owner,
            cols,
            rows,
        } => outbound.push(ServerMessage::GridChange {
            session_id,
            owner,
            cols,
            rows,
        }),
    }
}

/// Fold every event already queued on the bus into frames, splitting them by whether
/// they may overtake the reply the handler is about to send: a grid change describes
/// the state the reply is about, so it goes ahead of it; everything else follows.
///
/// A closed bus is not handled here — the `recv` arm of the loop sees it on the next
/// pass and ends the connection there, so there is one place that decides to stop.
fn drain_bus(
    events: &mut tokio::sync::broadcast::Receiver<SessionEvent>,
    fanout: &mut Fanout,
    ahead: &mut Vec<ServerMessage>,
    behind: &mut Vec<ServerMessage>,
) {
    loop {
        match events.try_recv() {
            Ok(event) => {
                let bucket = if matches!(event, SessionEvent::GridChange { .. }) {
                    &mut *ahead
                } else {
                    &mut *behind
                };
                push_event(event, fanout, bucket);
            }
            Err(TryRecvError::Lagged(n)) => {
                debug!(dropped = n, "connection lagged behind the session bus");
            }
            Err(TryRecvError::Empty | TryRecvError::Closed) => return,
        }
    }
}

/// Who already drives which session's grid, for a connection that just arrived.
///
/// Only a claimed grid on a live session: a client starts out assuming the grid is
/// free, so silence already says the right thing for an unclaimed one, and a dead pty
/// has no honest grid to report.
fn grid_snapshot(sessions: &Arc<dyn SessionsApi>) -> Vec<ServerMessage> {
    let mut frames = Vec::new();
    for session_id in sessions.ids() {
        if !sessions.is_running(&session_id) {
            continue;
        }
        let Some(owner) = sessions.grid_owner(&session_id) else {
            continue;
        };
        let Some((cols, rows)) = sessions.grid(&session_id) else {
            continue;
        };
        frames.push(ServerMessage::GridChange {
            session_id,
            owner: Some(owner),
            cols,
            rows,
        });
    }
    frames
}

/// `created` then `attached`, in that order: a client learns the identity first and
/// the replay baseline second, and it is attached from the moment it hears about the
/// session rather than after a round trip.
fn push_attached(
    session_id: &str,
    attached_payload: Attached,
    attached: &mut HashSet<String>,
    outbound: &mut Vec<ServerMessage>,
) {
    attached.insert(session_id.to_string());
    let replay_exit = attached_payload.replay_exit;
    outbound.push(ServerMessage::Attached {
        session_id: session_id.to_string(),
        scrollback: attached_payload.scrollback,
        session: attached_payload.meta,
    });
    // A session that is already over re-states its exit, so a client that missed the
    // live event is not left waiting for one that will never come again.
    if let Some(exit_code) = replay_exit {
        outbound.push(ServerMessage::Exit {
            session_id: session_id.to_string(),
            exit_code,
        });
    }
}

/// Run one seeded delivery in the background and report a failure to the client that
/// asked for the create.
///
/// Background because the delivery spans the CLI's whole boot window: a create reply
/// that waited for it would look like a hung daemon. The failure frame matters as
/// much as the delivery — the old behaviour was a prompt sitting typed and unsent
/// with nothing anywhere saying so, which is indistinguishable from an agent that
/// simply had nothing to say.
fn spawn_seed(
    sessions: Arc<dyn SessionsApi>,
    id: String,
    text: String,
    oob: tokio::sync::mpsc::UnboundedSender<ServerMessage>,
) {
    tokio::spawn(async move {
        let outcome = deliver_seed(sessions, &id, &text, SeedTiming::default()).await;
        log_outcome(&id, &outcome);
        // Either failure is a prompt the agent never saw, and the client asked for a
        // create that was supposed to carry one. Which of the two it was matters to the
        // queue's claim boundary and to nobody here.
        if let Some(reason) = outcome.reason() {
            // A closed channel is a client that already left; the log above is then
            // the whole record, which is the best there is to do for it.
            let _ = oob.send(ServerMessage::Error {
                session_id: Some(id),
                message: format!("the initial prompt was not delivered: {reason}"),
            });
        }
    });
}

/// Why a queue mutation did not happen, in the words the queue itself defines.
///
/// The code goes out verbatim, and there are only ever two of them. A missing session,
/// an id that was never real, and an occurrence the delivery engine has already claimed
/// all answer `queue-item-not-found`, because a client holding a stale row cannot tell
/// those apart and must not try: the correct reaction to all three is to stop showing
/// the row and take the next snapshot as the truth.
fn queue_refusal(session: &str, error: QueueError) -> ServerMessage {
    ServerMessage::Error {
        session_id: Some(session.to_string()),
        message: error.code().to_string(),
    }
}

/// A daemon whose tree mounted no `queue` row.
///
/// Its own code, and not one of the two above, because it is not a stale row: retrying
/// will never help and the client should put the dock away rather than resynchronise.
fn queue_unavailable(session: &str, outbound: &mut Vec<ServerMessage>) {
    outbound.push(ServerMessage::Error {
        session_id: Some(session.to_string()),
        message: "queue-unavailable".into(),
    });
}

/// One batch of transcript records as a frame.
///
/// A record whose JSON cannot be built is dropped rather than allowed to fail the
/// batch: `seq` is what a client orders and de-duplicates by, so a hole is a record it
/// never learns about, while a refused batch is every record after it too.
fn transcript_frame<'a>(
    session: &str,
    replay: bool,
    records: impl Iterator<Item = &'a juancoded_transcripts::TranscriptRecord>,
) -> ServerMessage {
    ServerMessage::Transcript {
        session_id: session.to_string(),
        replay,
        records: records
            .filter_map(|record| serde_json::to_value(record).ok())
            .collect(),
    }
}

/// What one frame handler reads from the booted tree.
///
/// Grouped rather than passed one by one, because the three of them always travel
/// together and always come from the same loader: a handler holding this cannot be
/// looking at one tree's sessions and another tree's queue.
struct Tree<'a> {
    sessions: &'a Arc<dyn SessionsApi>,
    contributions: &'a ContributionRegistry,
    queue: Option<&'a Arc<dyn QueueApi>>,
    transcripts: Option<&'a TranscriptPlane>,
    /// `None` when this core runs no reaper. The two reaper frames then answer with an
    /// error rather than silently doing nothing, which is the failure the no-op
    /// `setReaperIdleWindow` on the Swift client was.
    reaper: Option<&'a Arc<SessionReaper>>,
}

fn handle_client_message(
    msg: ClientMessage,
    tree: &Tree<'_>,
    client: ClientId,
    fanout: &mut Fanout,
    screens: &mut HashMap<String, ScreenStreamer>,
    outbound: &mut Vec<ServerMessage>,
) {
    let Tree {
        sessions,
        contributions,
        queue,
        transcripts,
        reaper,
    } = *tree;
    let attached = &mut fanout.attached;
    match msg {
        ClientMessage::Create {
            provider,
            cwd,
            cols,
            rows,
            initial_input,
            skip_permissions,
            dispatch_id,
        } => {
            let Some(provider_id) = ProviderId::parse(&provider) else {
                outbound.push(ServerMessage::Error {
                    session_id: None,
                    message: format!("Unknown provider: {provider}"),
                });
                return;
            };
            let (cols, rows) = grid_or_default(cols, rows);
            let req = CreateRequest {
                provider: provider_id,
                cwd,
                cols,
                rows,
                skip_permissions: skip_permissions.unwrap_or(false),
                model: None,
                dispatch_id,
                owner: client,
            };
            match sessions.create(req) {
                Ok(meta) => {
                    let id = meta.id.clone();
                    attached.insert(id.clone());
                    outbound.push(ServerMessage::Created {
                        session: meta.clone(),
                    });
                    if let Some(text) = initial_input {
                        spawn_seed(sessions.clone(), id.clone(), text, fanout.oob.clone());
                    }
                    // Nothing to replay yet, and saying so is the client's baseline
                    // for everything that arrives after.
                    outbound.push(ServerMessage::Attached {
                        session_id: id,
                        scrollback: String::new(),
                        session: meta,
                    });
                }
                Err(e) => outbound.push(ServerMessage::Error {
                    session_id: None,
                    message: e.to_string(),
                }),
            }
        }

        ClientMessage::AdoptExternal {
            provider,
            cli_session_id,
            cwd,
            start_ms,
            cols,
            rows,
        } => {
            let Some(provider_id) = ProviderId::parse(&provider) else {
                outbound.push(ServerMessage::Error {
                    session_id: None,
                    message: format!("Unknown provider: {provider}"),
                });
                return;
            };
            let (cols, rows) =
                grid_or_default(Some(cols).filter(|c| *c > 0), Some(rows).filter(|r| *r > 0));
            let req = AdoptRequest {
                provider: provider_id,
                cli_session_id,
                cwd,
                start_ms,
                cols,
                rows,
                owner: client,
            };
            match sessions.adopt_external(req) {
                // Already ours: silence is the answer, not a duplicate session.
                Ok(None) => {}
                Ok(Some(meta)) => {
                    let id = meta.id.clone();
                    outbound.push(ServerMessage::Created { session: meta });
                    match sessions.attach(&id, client, cols, rows) {
                        Ok(payload) => push_attached(&id, payload, attached, outbound),
                        Err(e) => outbound.push(ServerMessage::Error {
                            session_id: Some(id),
                            message: e.to_string(),
                        }),
                    }
                }
                Err(e) => outbound.push(ServerMessage::Error {
                    session_id: None,
                    message: e.to_string(),
                }),
            }
        }

        ClientMessage::Attach {
            session_id,
            cols,
            rows,
        } => match sessions.attach(&session_id, client, cols, rows) {
            Ok(payload) => push_attached(&session_id, payload, attached, outbound),
            Err(e) => outbound.push(ServerMessage::Error {
                session_id: Some(session_id),
                message: e.to_string(),
            }),
        },

        ClientMessage::Reactivate {
            session_id,
            cols,
            rows,
        } => match sessions.reactivate(&session_id, client, cols, rows) {
            // Already live: the client is welcome to it, and there is nothing to say.
            Ok(None) => {
                attached.insert(session_id);
            }
            Ok(Some(payload)) => push_attached(&session_id, payload, attached, outbound),
            Err(StateError::Unresumable(reason)) => {
                outbound.push(ServerMessage::Unresumable { session_id, reason })
            }
            Err(e) => outbound.push(ServerMessage::Error {
                session_id: Some(session_id),
                message: e.to_string(),
            }),
        },

        ClientMessage::SetSkipPermissions {
            session_id,
            skip_permissions,
            cols,
            rows,
        } => {
            let (cols, rows) =
                grid_or_default(Some(cols).filter(|c| *c > 0), Some(rows).filter(|r| *r > 0));
            match sessions.set_skip_permissions(&session_id, skip_permissions, client, cols, rows) {
                Ok(payload) => push_attached(&session_id, payload, attached, outbound),
                Err(e) => outbound.push(ServerMessage::Error {
                    session_id: Some(session_id),
                    message: e.to_string(),
                }),
            }
        }

        ClientMessage::Input {
            session_id,
            data,
            seq,
        } => {
            if let Err(e) = sessions.input(&session_id, data.as_bytes()) {
                debug!(session = session_id, error = %e, "input went nowhere");
            }
            // Acked after the write attempt either way: the ack means the frame was
            // received and processed, and a dead pty surfaces through its own `exit`.
            if let Some(seq) = seq {
                outbound.push(ServerMessage::InputAck { session_id, seq });
            }
        }

        ClientMessage::Resize {
            session_id,
            cols,
            rows,
            seq,
        } => {
            let outcome = sessions.resize(&session_id, client, cols, rows);
            if let Some(seq) = seq {
                outbound.push(ServerMessage::ResizeAck {
                    session_id,
                    seq,
                    cols,
                    rows,
                    applied: outcome.applied,
                    denied: outcome.denied,
                    owner: outcome.owner,
                });
            }
        }

        ClientMessage::Kill { session_id } => {
            if let Err(e) = sessions.kill(&session_id) {
                outbound.push(ServerMessage::Error {
                    session_id: Some(session_id),
                    message: e.to_string(),
                });
            }
        }

        ClientMessage::SubscribeScreen { session_id } => {
            // The grid dies with the pty, so a screen viewer on a dead session is
            // told to fall back to `attach` rather than handed a frozen picture.
            if !sessions.is_running(&session_id) {
                outbound.push(ServerMessage::Error {
                    session_id: Some(session_id),
                    message: StateError::NotRunning.to_string(),
                });
                return;
            }
            screens.insert(session_id.clone(), ScreenStreamer::new(session_id));
        }

        ClientMessage::UnsubscribeScreen { session_id } => {
            screens.remove(&session_id);
        }

        // Every one of these answers from the mounted `queue` service. A baseline goes
        // out on subscribe and a complete snapshot on every change, so a client's whole
        // job is to replace what it holds; there is no delta frame to miss.
        ClientMessage::SubscribeQueue { session_id } => {
            // Idempotent per session: a second subscribe from the same connection is
            // not a second snapshot.
            if !fanout.queue_watchers.insert(session_id.clone()) {
                return;
            }
            let Some(queue) = queue else {
                return queue_unavailable(&session_id, outbound);
            };
            // A session nobody has queued to gets an empty queue at revision 0 rather
            // than silence, which is what a client subscribing before the first message
            // needs in order to draw an empty dock instead of guessing.
            outbound.push(ServerMessage::Queue {
                snapshot: queue.snapshot(&session_id),
            });
        }

        ClientMessage::UnsubscribeQueue { session_id } => {
            fanout.queue_watchers.remove(&session_id);
        }

        // The transcript plane's baseline, and the same contract as the queue's: what
        // is answered here is complete for the history the daemon kept, and everything
        // after it arrives on the bus.
        //
        // The history is read out of the store rather than out of the CLI's own file.
        // Two reasons, both about this being the connection loop: replaying from the
        // source means re-parsing a jsonl that routinely runs to tens of megabytes,
        // and a session whose file has since been pruned would answer with nothing at
        // all. What the pump read is already ours.
        ClientMessage::SubscribeTranscript { session_id } => {
            if !fanout.transcript_watchers.insert(session_id.clone()) {
                return;
            }
            // A session with no transcript gets an empty replay rather than silence,
            // which is what a client needs in order to draw an empty panel instead of
            // waiting for a frame that is not coming. Same for a core with no plane
            // mounted: it does not advertise the capability, and a client that asked
            // anyway is answered honestly.
            let records = transcripts
                .map(|plane| plane.history(&session_id))
                .unwrap_or_default();
            outbound.push(ServerMessage::Transcript {
                session_id,
                replay: true,
                records,
            });
        }

        ClientMessage::UnsubscribeTranscript { session_id } => {
            fanout.transcript_watchers.remove(&session_id);
        }

        ClientMessage::QueueMessage { session_id, text } => {
            let Some(queue) = queue else {
                return queue_unavailable(&session_id, outbound);
            };
            // The queue keeps no session table of its own, so nothing below would
            // refuse a message addressed to a session that never existed: it would open
            // a lane for it and the client would watch its message sit there forever.
            // `queue-item-not-found` and not a code of its own, on the same grounds the
            // mutations share it: the session or the row you named is not there.
            if sessions.meta(&session_id).is_none() {
                return outbound.push(queue_refusal(&session_id, QueueError::NotFound));
            }
            // A whitespace-only text is not a message: it is dropped, and no snapshot
            // goes out for a queue that did not move. The snapshot for a real one rides
            // the bus like every other change, so every watcher sees it and not only
            // the client that sent this frame.
            if text.trim().is_empty() {
                return;
            }
            queue.enqueue(&session_id, Content::text(text), "wire");
        }

        ClientMessage::EditQueued {
            session_id,
            message_id,
            text,
        } => {
            let Some(queue) = queue else {
                return queue_unavailable(&session_id, outbound);
            };
            if let Err(e) = queue.edit(&session_id, &message_id, &text) {
                outbound.push(queue_refusal(&session_id, e));
            }
        }

        ClientMessage::DequeueMessage {
            session_id,
            message_id,
        } => {
            let Some(queue) = queue else {
                return queue_unavailable(&session_id, outbound);
            };
            if let Err(e) = queue.remove(&session_id, &message_id) {
                outbound.push(queue_refusal(&session_id, e));
            }
        }

        // The contribution surface is complete daemon-side and the `contributions`
        // capability is still withheld: nothing renders a descriptor yet, so a client
        // that switched its chrome on off the capability would draw nothing.
        ClientMessage::SubscribeContributions => {
            let snapshot = contributions.snapshot();
            // Idempotent: a second subscribe from the same connection is not a second
            // snapshot, exactly as for the queue.
            if fanout.contribution_revision == Some(snapshot.revision) {
                return;
            }
            fanout.contribution_revision = Some(snapshot.revision);
            outbound.push(ServerMessage::Contributions { snapshot });
        }

        ClientMessage::UnsubscribeContributions => {
            fanout.contribution_revision = None;
        }

        ClientMessage::ActivateContribution {
            contribution,
            target,
            payload,
        } => {
            // The daemon runs the owning plugin's handler and answers. An id nobody
            // claims is `unhandled`, not an error: the client's snapshot is simply
            // older than the tree.
            let activation = juancoded_cordis::Activation {
                contribution: contribution.clone(),
                target,
                payload,
            };
            outbound.push(ServerMessage::ContributionResult {
                outcome: contributions.activate(&activation),
                contribution,
            });
        }

        // Feature-detected away by well-behaved clients; ignored either way, so an
        // older core can never kill a newer client.
        ClientMessage::SetReaperPolicy {
            minutes,
            window_ms,
            max_live,
        } => {
            let Some(reaper) = reaper else {
                outbound.push(ServerMessage::Error {
                    session_id: None,
                    message: "This core runs no session reaper".into(),
                });
                return;
            };
            // `windowMs` wins over `minutes`: it is the precise spelling, and a client
            // that sends both meant the exact one.
            if let Some(ms) = window_ms.or_else(|| minutes.map(|m| m * 60_000)) {
                reaper.set_window_ms(ms);
            }
            if let Some(max) = max_live {
                reaper.set_max_live(max);
            }
            debug!(
                window_ms = reaper.window_ms(),
                max_live = reaper.max_live(),
                "reaper policy set by a client"
            );
        }

        ClientMessage::SetReaperProtectedIds { session_ids } => {
            let Some(reaper) = reaper else {
                outbound.push(ServerMessage::Error {
                    session_id: None,
                    message: "This core runs no session reaper".into(),
                });
                return;
            };
            reaper.set_protected(client, session_ids.into_iter().collect());
        }

        ClientMessage::Unknown { r#type } => debug!(r#type, "ignoring unimplemented message"),
    }
}

fn grid_or_default(cols: Option<u16>, rows: Option<u16>) -> (u16, u16) {
    (
        cols.unwrap_or(DEFAULT_GRID.0),
        rows.unwrap_or(DEFAULT_GRID.1),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use juancoded_state::registry::CreateRequest;

    fn fanout() -> Fanout {
        Fanout {
            attached: HashSet::new(),
            queue_watchers: HashSet::new(),
            transcript_watchers: HashSet::new(),
            contribution_revision: None,
            carries: HashMap::new(),
            // Nothing in these tests reads the side channel; the receiver is dropped
            // and a send on it is the no-op a departed client already gets.
            oob: tokio::sync::mpsc::unbounded_channel().0,
        }
    }

    /// The same, against a real booted tree's contributions rather than an empty
    /// registry, for the frames that only mean something with chrome mounted.
    fn contribution_step(
        msg: ClientMessage,
        handles: &CoreHandles,
        fanout: &mut Fanout,
    ) -> Vec<ServerMessage> {
        let mut reply = Vec::new();
        let mut screens = HashMap::new();
        handle_client_message(
            msg,
            &Tree {
                sessions: &handles.sessions,
                contributions: &handles.contributions,
                queue: handles.queue.as_ref(),
                transcripts: handles.transcripts.as_ref(),
                reaper: handles.reaper.as_ref(),
            },
            1,
            fanout,
            &mut screens,
            &mut reply,
        );
        reply
    }

    #[test]
    fn subscribing_to_contributions_answers_with_the_whole_list_once() {
        let handles = crate::testing::handles();
        let mut fanout = fanout();

        let first = contribution_step(ClientMessage::SubscribeContributions, &handles, &mut fanout);
        let [ServerMessage::Contributions { snapshot }] = &first[..] else {
            panic!("expected one snapshot, got {first:?}");
        };
        assert_eq!(snapshot.schema_version, 1);
        let ids: Vec<&str> = snapshot.items.iter().map(|c| c.id.as_str()).collect();
        assert!(ids.contains(&"session.badge.waiting"), "{ids:?}");

        // A second subscribe on an unchanged tree is not a second snapshot.
        assert!(
            contribution_step(ClientMessage::SubscribeContributions, &handles, &mut fanout,)
                .is_empty()
        );

        // And unsubscribing stops the watch for this connection only.
        contribution_step(
            ClientMessage::UnsubscribeContributions,
            &handles,
            &mut fanout,
        );
        assert_eq!(fanout.contribution_revision, None);
    }

    #[test]
    fn activating_a_contribution_answers_with_what_the_plugin_decided() {
        let handles = crate::testing::handles();
        let mut fanout = fanout();

        let out = contribution_step(
            ClientMessage::ActivateContribution {
                contribution: juancoded_cordis::plugins::INTERRUPT_ID.into(),
                target: Some("s-1".into()),
                payload: serde_json::Value::Null,
            },
            &handles,
            &mut fanout,
        );
        let [ServerMessage::ContributionResult {
            contribution,
            outcome,
        }] = &out[..]
        else {
            panic!("expected one result, got {out:?}");
        };
        assert_eq!(contribution, juancoded_cordis::plugins::INTERRUPT_ID);
        assert_eq!(
            outcome,
            &juancoded_cordis::ActivationOutcome::Handled {
                result: serde_json::json!({ "interrupted": "s-1" })
            }
        );
    }

    #[test]
    fn activating_an_id_the_tree_does_not_have_is_answered_not_an_error() {
        let handles = crate::testing::handles();
        let mut fanout = fanout();
        let out = contribution_step(
            ClientMessage::ActivateContribution {
                contribution: "nobody.here".into(),
                target: None,
                payload: serde_json::Value::Null,
            },
            &handles,
            &mut fanout,
        );
        assert!(matches!(
            out.as_slice(),
            [ServerMessage::ContributionResult {
                outcome: juancoded_cordis::ActivationOutcome::Unhandled,
                ..
            }]
        ));
    }

    #[tokio::test]
    async fn subscribing_to_a_transcript_answers_with_a_baseline_and_only_once() {
        let handles = crate::testing::handles();
        let id = handles
            .sessions
            .create(CreateRequest {
                provider: ProviderId::Claude,
                cwd: "/tmp".into(),
                cols: 80,
                rows: 24,
                skip_permissions: false,
                model: None,
                dispatch_id: None,
                owner: 1,
            })
            .expect("create")
            .id;
        let mut fanout = fanout();

        // A session with no transcript yet is an empty replay, not silence: a client
        // needs to know the panel is empty rather than that its frame is still coming.
        let first = contribution_step(
            ClientMessage::SubscribeTranscript {
                session_id: id.clone(),
            },
            &handles,
            &mut fanout,
        );
        match first.as_slice() {
            [ServerMessage::Transcript {
                session_id,
                replay,
                records,
            }] => {
                assert_eq!(session_id, &id);
                assert!(*replay, "the baseline is a replay");
                assert!(records.is_empty());
            }
            other => panic!("expected one transcript frame, got {other:?}"),
        }
        assert!(fanout.transcript_watchers.contains(&id));

        // Idempotent per session, like the queue's: a second subscribe is not a second
        // baseline, because a client that re-sent one would redraw a history it holds.
        let again = contribution_step(
            ClientMessage::SubscribeTranscript {
                session_id: id.clone(),
            },
            &handles,
            &mut fanout,
        );
        assert!(again.is_empty());

        // Unsubscribing drops the watch, and with it every live batch the bus carries.
        contribution_step(
            ClientMessage::UnsubscribeTranscript {
                session_id: id.clone(),
            },
            &handles,
            &mut fanout,
        );
        assert!(!fanout.transcript_watchers.contains(&id));
    }

    /// One connection's worth of the loop, minus the socket.
    ///
    /// It exists because the queue's frames no longer come from the registry's event
    /// stream: a mutation publishes a complete snapshot on the cordis bus, and the loop
    /// forwards it to whichever of its watchers it belongs to. A test that read the
    /// queue back out instead would be asserting its own read rather than the frame the
    /// client would have received, and would pass just as happily if nothing were
    /// published at all.
    struct Wire {
        handles: CoreHandles,
        events: tokio::sync::broadcast::Receiver<SessionEvent>,
        published: Arc<std::sync::Mutex<Vec<QueueSnapshot>>>,
        _listener: juancoded_cordis::Effect,
    }

    impl Wire {
        fn new() -> Self {
            let handles = crate::testing::handles();
            let events = handles.sessions.subscribe();
            let published: Arc<std::sync::Mutex<Vec<QueueSnapshot>>> = Arc::default();
            let sink = Arc::clone(&published);
            let listener = handles.bus.on::<QueueChanged, _>("test.queue", move |s| {
                sink.lock().unwrap().push(s.clone());
            });
            Self {
                handles,
                events,
                published,
                _listener: listener,
            }
        }

        fn sessions(&self) -> &Arc<dyn SessionsApi> {
            &self.handles.sessions
        }

        fn queue(&self) -> &Arc<dyn QueueApi> {
            self.handles
                .queue
                .as_ref()
                .expect("the test tree mounts a queue")
        }

        fn session(&self) -> String {
            self.sessions()
                .create(CreateRequest {
                    provider: ProviderId::Claude,
                    cwd: "/tmp".into(),
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

        /// Feed one frame through the handler and fold in everything the loop would have
        /// sent for it, in the loop's own order: the registry's events, the handler's
        /// own reply, and then each published snapshot, gated on this connection's
        /// watches exactly as the loop gates them.
        fn step(&mut self, msg: ClientMessage, fanout: &mut Fanout) -> Vec<ServerMessage> {
            self.published.lock().unwrap().clear();
            let mut reply = Vec::new();
            let mut screens = HashMap::new();
            handle_client_message(
                msg,
                &Tree {
                    sessions: &self.handles.sessions,
                    contributions: &self.handles.contributions,
                    queue: self.handles.queue.as_ref(),
                    transcripts: self.handles.transcripts.as_ref(),
                    reaper: self.handles.reaper.as_ref(),
                },
                1,
                fanout,
                &mut screens,
                &mut reply,
            );
            let mut ahead = Vec::new();
            let mut behind = Vec::new();
            drain_bus(&mut self.events, fanout, &mut ahead, &mut behind);
            ahead.extend(reply);
            ahead.extend(behind);
            ahead.extend(self.forwarded(fanout));
            ahead
        }

        /// The queue frames the loop's own select arm would have produced.
        fn forwarded(&self, fanout: &Fanout) -> Vec<ServerMessage> {
            self.published
                .lock()
                .unwrap()
                .iter()
                .filter(|s| fanout.queue_watchers.contains(&s.session))
                .cloned()
                .map(|snapshot| ServerMessage::Queue { snapshot })
                .collect()
        }
    }

    /// The queue snapshots in a batch of frames, as their item texts. Everything else a
    /// session emits while this runs (output, activity, a grid grant) is somebody else's
    /// assertion.
    fn snapshots(frames: &[ServerMessage]) -> Vec<Vec<String>> {
        frames
            .iter()
            .filter_map(|f| match f {
                ServerMessage::Queue { snapshot } => Some(
                    snapshot
                        .items
                        .iter()
                        .map(|i| i.content.as_text().unwrap_or("<keys>").to_string())
                        .collect(),
                ),
                _ => None,
            })
            .collect()
    }

    /// Every error code in a batch of frames.
    fn codes(frames: &[ServerMessage]) -> Vec<&str> {
        frames
            .iter()
            .filter_map(|f| match f {
                ServerMessage::Error { message, .. } => Some(message.as_str()),
                _ => None,
            })
            .collect()
    }

    /// The wire half of scenario 10: a watcher gets the complete ordered list on
    /// subscribe and after every change, gets nothing for a change that did not happen,
    /// and stops hearing about the queue once it unsubscribes.
    #[tokio::test]
    async fn a_watcher_gets_the_whole_queue_on_subscribe_and_after_every_change() {
        let mut wire = Wire::new();
        let mut fanout = fanout();
        let id = wire.session();

        let subscribed = wire.step(
            ClientMessage::SubscribeQueue {
                session_id: id.clone(),
            },
            &mut fanout,
        );
        assert_eq!(
            snapshots(&subscribed),
            vec![Vec::<String>::new()],
            "an empty queue is still a snapshot: silence would leave a client guessing"
        );

        // A second subscribe is not a second snapshot.
        let again = wire.step(
            ClientMessage::SubscribeQueue {
                session_id: id.clone(),
            },
            &mut fanout,
        );
        assert!(snapshots(&again).is_empty());

        let first = wire.step(
            ClientMessage::QueueMessage {
                session_id: id.clone(),
                text: "first".into(),
            },
            &mut fanout,
        );
        assert_eq!(snapshots(&first), vec![vec!["first".to_string()]]);

        let second = wire.step(
            ClientMessage::QueueMessage {
                session_id: id.clone(),
                text: "second".into(),
            },
            &mut fanout,
        );
        assert_eq!(
            snapshots(&second),
            vec![vec!["first".to_string(), "second".to_string()]],
            "the frame is the whole list, in insertion order, not a delta"
        );

        let blank = wire.step(
            ClientMessage::QueueMessage {
                session_id: id.clone(),
                text: "   ".into(),
            },
            &mut fanout,
        );
        assert!(
            snapshots(&blank).is_empty(),
            "a whitespace-only message is not queued, so no snapshot goes out"
        );

        // An edit keeps the occurrence's id and its place, so the snapshot that follows
        // is the same two rows in the same order with one of them rewritten.
        let head = wire.queue().snapshot(&id).items[0].id.clone();
        let edited = wire.step(
            ClientMessage::EditQueued {
                session_id: id.clone(),
                message_id: head.clone(),
                text: "first, revised".into(),
            },
            &mut fanout,
        );
        assert_eq!(
            snapshots(&edited),
            vec![vec!["first, revised".to_string(), "second".to_string()]]
        );
        assert_eq!(
            wire.queue().snapshot(&id).items[0].id,
            head,
            "an edit is not a requeue: a new id would send the message to the back"
        );

        let dequeued = wire.step(
            ClientMessage::DequeueMessage {
                session_id: id.clone(),
                message_id: head,
            },
            &mut fanout,
        );
        assert_eq!(snapshots(&dequeued), vec![vec!["second".to_string()]]);

        let missing = wire.step(
            ClientMessage::DequeueMessage {
                session_id: id.clone(),
                message_id: "never-queued".into(),
            },
            &mut fanout,
        );
        assert!(
            snapshots(&missing).is_empty(),
            "removing nothing changes nothing, so no snapshot goes out"
        );
        assert_eq!(codes(&missing), ["queue-item-not-found"]);

        let _ = wire.step(
            ClientMessage::UnsubscribeQueue {
                session_id: id.clone(),
            },
            &mut fanout,
        );
        let after = wire.step(
            ClientMessage::QueueMessage {
                session_id: id.clone(),
                text: "third".into(),
            },
            &mut fanout,
        );
        assert!(
            snapshots(&after).is_empty(),
            "the watch is gone, so the queue is no longer this client's business"
        );
        // The message itself was still queued: unsubscribing is a client's choice about
        // frames, not a mute button on the queue.
        assert_eq!(wire.queue().snapshot(&id).items.len(), 2);
    }

    /// The claim is where a client's addressing rights end. Once the delivery engine
    /// holds an occurrence, editing it would rewrite text that is already in the agent's
    /// box, so both mutations answer the same code a stale id gets.
    #[tokio::test]
    async fn an_occurrence_the_engine_has_claimed_is_no_longer_the_clients_to_change() {
        let mut wire = Wire::new();
        let mut fanout = fanout();
        let id = wire.session();
        let _ = wire.step(
            ClientMessage::SubscribeQueue {
                session_id: id.clone(),
            },
            &mut fanout,
        );
        let _ = wire.step(
            ClientMessage::QueueMessage {
                session_id: id.clone(),
                text: "ship it".into(),
            },
            &mut fanout,
        );
        let item = wire.queue().snapshot(&id).items[0].id.clone();

        // The engine takes the row. Held, not settled: this is the state a delivery is
        // in while its paste sits in the box waiting for the Enter.
        let claim = wire.queue().claim_next(&id).expect("the head is claimable");
        assert_eq!(claim.id, item);

        let edit = wire.step(
            ClientMessage::EditQueued {
                session_id: id.clone(),
                message_id: item.clone(),
                text: "actually, do not".into(),
            },
            &mut fanout,
        );
        assert_eq!(codes(&edit), ["queue-item-not-found"]);
        let remove = wire.step(
            ClientMessage::DequeueMessage {
                session_id: id.clone(),
                message_id: item.clone(),
            },
            &mut fanout,
        );
        assert_eq!(codes(&remove), ["queue-item-not-found"]);
        assert_eq!(
            wire.queue()
                .snapshot(&id)
                .get(&item)
                .unwrap()
                .content
                .as_text(),
            Some("ship it"),
            "a refused edit must not have changed anything"
        );

        // A missing session answers with the very same code, and that is deliberate: a
        // client holding a stale row cannot tell the two apart and must not try.
        let ghost = wire.step(
            ClientMessage::DequeueMessage {
                session_id: "no-such-session".into(),
                message_id: item,
            },
            &mut fanout,
        );
        assert_eq!(codes(&ghost), ["queue-item-not-found"]);
    }

    /// A queue watch is per-connection: one client's unsubscribe cannot silence
    /// another's, and a change made by anyone reaches every watcher.
    #[tokio::test]
    async fn one_connections_watch_says_nothing_about_anothers() {
        let mut wire = Wire::new();
        let mut watcher = fanout();
        let mut bystander = fanout();
        let id = wire.session();
        let _ = wire.step(
            ClientMessage::SubscribeQueue {
                session_id: id.clone(),
            },
            &mut watcher,
        );

        // The bystander sends the message and hears nothing back: it never asked to
        // watch. The watcher hears about it because the snapshot is published to the
        // bus, not returned to whoever caused it.
        let sent = wire.step(
            ClientMessage::QueueMessage {
                session_id: id.clone(),
                text: "steer".into(),
            },
            &mut bystander,
        );
        assert!(snapshots(&sent).is_empty(), "it never asked to watch");

        let heard = wire.forwarded(&watcher);
        assert_eq!(snapshots(&heard), vec![vec!["steer".to_string()]]);
    }

    #[tokio::test]
    async fn queueing_to_a_session_that_does_not_exist_answers_with_an_error() {
        let mut wire = Wire::new();
        let mut fanout = fanout();
        let frames = wire.step(
            ClientMessage::QueueMessage {
                session_id: "no-such-session".into(),
                text: "hello".into(),
            },
            &mut fanout,
        );
        assert_eq!(codes(&frames), ["queue-item-not-found"]);
        assert!(
            snapshots(&frames).is_empty(),
            "nothing was queued, so there is no snapshot to send"
        );
    }
}
