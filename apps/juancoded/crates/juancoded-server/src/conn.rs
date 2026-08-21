//! One WebSocket connection: the whole protocol loop for a single client.
//!
//! Structured as one task selecting over three sources — the socket, the registry
//! event bus, and the screen tick — so every piece of per-connection state
//! (attachments, screen streamers, UTF-8 carries) is plain local data. No locks, no
//! shared mutable state, and therefore no ordering question about whether an
//! `inputAck` can overtake the `output` it caused.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use axum::extract::ws::{Message, WebSocket};
use futures::{SinkExt, StreamExt};
use tokio::sync::broadcast::error::RecvError;
use tracing::{debug, warn};

use juancoded_core::model::{ProviderId, SessionActivity};
use juancoded_core::registry::{CreateRequest, Registry, SessionEvent};

use crate::screen::ScreenStreamer;
use crate::utf8::Utf8Stream;
use crate::wire::{ClientMessage, ServerMessage};

/// Screen-diff cadence: at most one frame per tick, matching the Swift streamer.
const SCREEN_TICK: Duration = Duration::from_millis(80);
/// The grid a client with no viewport of its own gets. The Swift core reads the
/// desktop's last real grid from UserDefaults; a headless daemon has no such
/// memory, so it uses the same roomy fallback that code falls back to.
const DEFAULT_GRID: (u16, u16) = (120, 40);

pub async fn handle(socket: WebSocket, registry: Arc<Registry>) {
    let (mut tx, mut rx) = socket.split();
    let mut events = registry.subscribe();

    // Always first on the wire, before anything else can be sent.
    if tx
        .send(Message::Text(ServerMessage::ServerInfo.to_json().into()))
        .await
        .is_err()
    {
        return;
    }

    let mut attached: HashSet<String> = HashSet::new();
    let mut screens: HashMap<String, ScreenStreamer> = HashMap::new();
    let mut carries: HashMap<String, Utf8Stream> = HashMap::new();
    let mut ticker = tokio::time::interval(SCREEN_TICK);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        let mut outbound: Vec<ServerMessage> = Vec::new();

        tokio::select! {
            incoming = rx.next() => {
                let Some(Ok(frame)) = incoming else { break };
                match frame {
                    Message::Text(text) => {
                        match ClientMessage::decode(&text) {
                            Ok(msg) => handle_client_message(
                                msg, &registry, &mut attached, &mut screens, &mut outbound,
                            ),
                            Err(e) => {
                                warn!(error = %e, "undecodable frame");
                                outbound.push(ServerMessage::Error {
                                    session_id: None,
                                    message: format!("Invalid JSON: {e}"),
                                });
                            }
                        }
                    }
                    Message::Close(_) => break,
                    // A client that speaks binary is not a thing today; ignore
                    // rather than tearing the connection down.
                    _ => {}
                }
            }
            event = events.recv() => {
                match event {
                    Ok(SessionEvent::Output { session_id, bytes }) => {
                        if attached.contains(&session_id) {
                            let carry = carries.entry(session_id.clone()).or_default();
                            let data = carry.push(&bytes);
                            if !data.is_empty() {
                                outbound.push(ServerMessage::Output { session_id, data });
                            }
                        }
                    }
                    Ok(SessionEvent::Activity { session_id, state }) => {
                        // `notify` is the desktop's "this deserves a ping" edge; the
                        // spike only knows the transition itself.
                        let notify = state == SessionActivity::Idle;
                        outbound.push(ServerMessage::Activity {
                            session_id, state, notify, dispatch_id: None,
                        });
                    }
                    Ok(SessionEvent::Exit { session_id, exit_code }) => {
                        outbound.push(ServerMessage::Exit { session_id, exit_code });
                    }
                    Err(RecvError::Lagged(n)) => {
                        debug!(dropped = n, "connection lagged behind the session bus");
                    }
                    Err(RecvError::Closed) => break,
                }
            }
            _ = ticker.tick() => {
                for (session_id, streamer) in screens.iter_mut() {
                    if let Some(snapshot) = registry.snapshot(session_id) {
                        if let Some(frame) = streamer.frame(snapshot) {
                            outbound.push(frame);
                        }
                    }
                }
            }
        }

        for msg in outbound {
            if tx.send(Message::Text(msg.to_json().into())).await.is_err() {
                return;
            }
        }
    }
}

fn handle_client_message(
    msg: ClientMessage,
    registry: &Arc<Registry>,
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
                    message: format!("unknown provider: {provider}"),
                });
                return;
            };
            let (cols, rows) = (
                cols.unwrap_or(DEFAULT_GRID.0),
                rows.unwrap_or(DEFAULT_GRID.1),
            );
            let req = CreateRequest {
                provider: provider_id,
                cwd,
                cols,
                rows,
                skip_permissions: skip_permissions.unwrap_or(false),
                model: None,
                dispatch_id,
            };
            match registry.create(req, None) {
                Ok(meta) => {
                    attached.insert(meta.id.clone());
                    if let Some(text) = initial_input {
                        // Seeded input goes in as-is; the paste/land-check engine is
                        // a later ticket, not spike surface.
                        let _ = registry.input(&meta.id, text.as_bytes());
                    }
                    outbound.push(ServerMessage::Created { session: meta });
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
        } => {
            let Some(meta) = registry.meta(&session_id) else {
                outbound.push(ServerMessage::Unresumable {
                    session_id,
                    reason: "no such session in this core".into(),
                });
                return;
            };
            attached.insert(session_id.clone());
            let _ = registry.resize(&session_id, cols, rows);
            let scrollback = registry.scrollback(&session_id).unwrap_or_default();
            outbound.push(ServerMessage::Attached {
                session_id,
                scrollback,
                session: meta,
            });
        }
        ClientMessage::Input {
            session_id,
            data,
            seq,
        } => match registry.input(&session_id, data.as_bytes()) {
            Ok(()) => {
                if let Some(seq) = seq {
                    outbound.push(ServerMessage::InputAck { session_id, seq });
                }
            }
            Err(e) => outbound.push(ServerMessage::Error {
                session_id: Some(session_id),
                message: e.to_string(),
            }),
        },
        ClientMessage::Resize {
            session_id,
            cols,
            rows,
            seq,
        } => {
            let applied = registry.resize(&session_id, cols, rows).unwrap_or(false);
            if let Some(seq) = seq {
                outbound.push(ServerMessage::ResizeAck {
                    session_id,
                    seq,
                    cols,
                    rows,
                    applied,
                    // Grid arbitration between competing clients is juancode-1th.1's
                    // problem and lands with the state layer; nothing is denied yet.
                    denied: false,
                });
            }
        }
        ClientMessage::Kill { session_id } => {
            if let Err(e) = registry.kill(&session_id) {
                outbound.push(ServerMessage::Error {
                    session_id: Some(session_id),
                    message: e.to_string(),
                });
            }
        }
        ClientMessage::SubscribeScreen { session_id } => {
            screens.insert(session_id.clone(), ScreenStreamer::new(session_id));
        }
        ClientMessage::UnsubscribeScreen { session_id } => {
            screens.remove(&session_id);
        }
        // Feature-detected away by well-behaved clients; ignored either way.
        ClientMessage::Unknown { r#type } => debug!(r#type, "ignoring unimplemented message"),
    }
}
