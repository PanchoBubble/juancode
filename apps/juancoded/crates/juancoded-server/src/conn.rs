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

use juancoded_core::model::ProviderId;
use juancoded_state::registry::{AdoptRequest, Attached, CreateRequest, SessionEvent, StateError};
use juancoded_state::{ClientId, SessionsApi};

use crate::screen::ScreenStreamer;
use crate::utf8::Utf8Stream;
use crate::wire::{ClientMessage, ServerMessage};

/// Per-connection state the event fan-out reads: which sessions this client is
/// attached to, and the UTF-8 carry per session so a split code point is never cut in
/// half across two frames.
struct Fanout {
    attached: HashSet<String>,
    carries: HashMap<String, Utf8Stream>,
}

/// Screen-diff cadence: at most one frame per tick, matching the Swift streamer.
const SCREEN_TICK: Duration = Duration::from_millis(80);
/// The grid a client with no viewport of its own gets. Whatever the CLI prints in
/// its first turn is wrapped at the spawn width forever, so a nominal 80x24 would
/// leave a permanently narrow transcript that resizing the pane cannot widen.
const DEFAULT_GRID: (u16, u16) = (120, 40);

static NEXT_CLIENT_ID: AtomicU64 = AtomicU64::new(1);

pub async fn handle(socket: WebSocket, sessions: Arc<dyn SessionsApi>) {
    let client: ClientId = NEXT_CLIENT_ID.fetch_add(1, Ordering::Relaxed);
    let (mut tx, mut rx) = socket.split();
    let mut events = sessions.subscribe();

    // Always first on the wire, before anything else can be sent.
    if tx
        .send(Message::Text(
            ServerMessage::ServerInfo { client_id: client }
                .to_json()
                .into(),
        ))
        .await
        .is_err()
    {
        sessions.release_client(client);
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
            sessions.release_client(client);
            return;
        }
    }

    let mut fanout = Fanout {
        attached: HashSet::new(),
        carries: HashMap::new(),
    };
    let mut screens: HashMap<String, ScreenStreamer> = HashMap::new();
    let mut ticker = tokio::time::interval(SCREEN_TICK);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        let mut outbound: Vec<ServerMessage> = Vec::new();

        tokio::select! {
            incoming = rx.next() => {
                let Some(Ok(frame)) = incoming else { break };
                match frame {
                    Message::Text(text) => {
                        let mut reply: Vec<ServerMessage> = Vec::new();
                        match ClientMessage::decode(&text) {
                            Ok(msg) => handle_client_message(
                                msg, &sessions, client, &mut fanout.attached, &mut screens,
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
            }
        }

        for msg in outbound {
            if tx.send(Message::Text(msg.to_json().into())).await.is_err() {
                sessions.release_client(client);
                return;
            }
        }
    }
    // The socket is gone: drop this client's grid claims so the next viewer's resize
    // is applied rather than denied by a connection nobody is holding.
    sessions.release_client(client);
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

fn handle_client_message(
    msg: ClientMessage,
    sessions: &Arc<dyn SessionsApi>,
    client: ClientId,
    attached: &mut HashSet<String>,
    screens: &mut HashMap<String, ScreenStreamer>,
    outbound: &mut Vec<ServerMessage>,
) {
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
                        // Seeded input goes in as-is; the paste-then-verified-Enter
                        // delivery engine is a later ticket, not this one.
                        let _ = sessions.input(&id, text.as_bytes());
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

        // Feature-detected away by well-behaved clients; ignored either way, so an
        // older core can never kill a newer client.
        ClientMessage::Unknown { r#type } => debug!(r#type, "ignoring unimplemented message"),
    }
}

fn grid_or_default(cols: Option<u16>, rows: Option<u16>) -> (u16, u16) {
    (
        cols.unwrap_or(DEFAULT_GRID.0),
        rows.unwrap_or(DEFAULT_GRID.1),
    )
}
