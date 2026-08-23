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
use juancoded_core::model::ProviderId;
use juancoded_state::registry::{AdoptRequest, Attached, CreateRequest, SessionEvent, StateError};
use juancoded_state::{ClientId, SessionsApi};

use crate::screen::ScreenStreamer;
use crate::serve::CoreHandles;
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
    /// The contribution revision this connection last saw, once it asked to watch.
    /// `None` means it is not watching, which is every client that does not know the
    /// surface exists.
    contribution_revision: Option<u64>,
    carries: HashMap<String, Utf8Stream>,
}

/// Screen-diff cadence: at most one frame per tick, matching the Swift streamer.
const SCREEN_TICK: Duration = Duration::from_millis(80);
/// The grid a client with no viewport of its own gets. Whatever the CLI prints in
/// its first turn is wrapped at the spawn width forever, so a nominal 80x24 would
/// leave a permanently narrow transcript that resizing the pane cannot widen.
const DEFAULT_GRID: (u16, u16) = (120, 40);

static NEXT_CLIENT_ID: AtomicU64 = AtomicU64::new(1);

pub async fn handle(socket: WebSocket, handles: CoreHandles) {
    let CoreHandles {
        sessions,
        contributions,
    } = handles;
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
        queue_watchers: HashSet::new(),
        contribution_revision: None,
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
                                msg, &sessions, &contributions, client, &mut fanout,
                                &mut screens, &mut reply,
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
                        drain_bus(&mut events, &sessions, &mut fanout, &mut outbound, &mut behind);
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
                    Ok(event) => push_event(event, &sessions, &mut fanout, &mut outbound),
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
fn push_event(
    event: SessionEvent,
    sessions: &Arc<dyn SessionsApi>,
    fanout: &mut Fanout,
    outbound: &mut Vec<ServerMessage>,
) {
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
        SessionEvent::QueueChanged { session_id } => {
            // Gated on a watch, like output: a queue is something a client opted
            // into, not a fact about a session everyone is owed. The list is read
            // here rather than carried on the event, so what goes out is the queue
            // as it stands now and a late notification cannot regress a client.
            if fanout.queue_watchers.contains(&session_id) {
                outbound.push(ServerMessage::Queue {
                    items: sessions.queue(&session_id),
                    session_id,
                });
            }
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
    sessions: &Arc<dyn SessionsApi>,
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
                push_event(event, sessions, fanout, bucket);
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
    contributions: &ContributionRegistry,
    client: ClientId,
    fanout: &mut Fanout,
    screens: &mut HashMap<String, ScreenStreamer>,
    outbound: &mut Vec<ServerMessage>,
) {
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

        // The queue surface is complete and the `queue` capability is still withheld:
        // nothing here types a queued message into the pty, so a client that switched
        // its send button on off the capability would watch messages pile up.
        ClientMessage::SubscribeQueue { session_id } => {
            // Idempotent per session: a second subscribe from the same connection is
            // not a second snapshot.
            if !fanout.queue_watchers.insert(session_id.clone()) {
                return;
            }
            outbound.push(ServerMessage::Queue {
                items: sessions.queue(&session_id),
                session_id,
            });
        }

        ClientMessage::UnsubscribeQueue { session_id } => {
            fanout.queue_watchers.remove(&session_id);
        }

        ClientMessage::QueueMessage { session_id, text } => {
            // A whitespace-only text is not a message: it is dropped, and no snapshot
            // goes out for a queue that did not move. The new snapshot for a real one
            // rides the bus like every other change, so every watcher sees it and not
            // only the client that sent this frame.
            if let Err(e) = sessions.queue_message(&session_id, &text) {
                outbound.push(ServerMessage::Error {
                    session_id: Some(session_id),
                    message: e.to_string(),
                });
            }
        }

        ClientMessage::DequeueMessage {
            session_id,
            message_id,
        } => {
            // A message that is not in the queue is not an error: it was already
            // cancelled, or belongs to another session, and the client's snapshot
            // already says so. Only a real removal moves the queue, so only a real
            // removal is announced.
            if let Err(e) = sessions.dequeue_message(&session_id, &message_id) {
                outbound.push(ServerMessage::Error {
                    session_id: Some(session_id),
                    message: e.to_string(),
                });
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
    use crate::testing::sessions;
    use juancoded_state::registry::CreateRequest;

    fn fanout() -> Fanout {
        Fanout {
            attached: HashSet::new(),
            queue_watchers: HashSet::new(),
            contribution_revision: None,
            carries: HashMap::new(),
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
            &handles.sessions,
            &handles.contributions,
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

    /// Feed one client frame through the handler, then fold in whatever the registry
    /// broadcast for it, in the order the connection loop would send them.
    fn step(
        msg: ClientMessage,
        sessions: &Arc<dyn SessionsApi>,
        events: &mut tokio::sync::broadcast::Receiver<SessionEvent>,
        fanout: &mut Fanout,
    ) -> Vec<ServerMessage> {
        let mut reply = Vec::new();
        let mut screens = HashMap::new();
        handle_client_message(
            msg,
            sessions,
            &ContributionRegistry::new(),
            1,
            fanout,
            &mut screens,
            &mut reply,
        );
        let mut ahead = Vec::new();
        let mut behind = Vec::new();
        drain_bus(events, sessions, fanout, &mut ahead, &mut behind);
        ahead.extend(reply);
        ahead.extend(behind);
        ahead
    }

    /// The queue snapshots in a batch of frames, as their item texts. Everything else
    /// a session emits while this runs (output, activity, a grid grant) is somebody
    /// else's assertion.
    fn snapshots(frames: &[ServerMessage]) -> Vec<Vec<String>> {
        frames
            .iter()
            .filter_map(|f| match f {
                ServerMessage::Queue { items, .. } => {
                    Some(items.iter().map(|i| i.text.clone()).collect())
                }
                _ => None,
            })
            .collect()
    }

    /// The wire half of scenario 10: a watcher gets the complete ordered list on
    /// subscribe and after every change, gets nothing for a change that did not
    /// happen, and stops hearing about the queue once it unsubscribes.
    #[tokio::test]
    async fn a_watcher_gets_the_whole_queue_on_subscribe_and_after_every_change() {
        let sessions = sessions();
        let mut events = sessions.subscribe();
        let mut fanout = fanout();
        let id = sessions
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

        let subscribed = step(
            ClientMessage::SubscribeQueue {
                session_id: id.clone(),
            },
            &sessions,
            &mut events,
            &mut fanout,
        );
        assert_eq!(
            snapshots(&subscribed),
            vec![Vec::<String>::new()],
            "an empty queue is still a snapshot: silence would leave a client guessing"
        );

        // A second subscribe is not a second snapshot.
        let again = step(
            ClientMessage::SubscribeQueue {
                session_id: id.clone(),
            },
            &sessions,
            &mut events,
            &mut fanout,
        );
        assert!(snapshots(&again).is_empty());

        let first = step(
            ClientMessage::QueueMessage {
                session_id: id.clone(),
                text: "first".into(),
            },
            &sessions,
            &mut events,
            &mut fanout,
        );
        assert_eq!(snapshots(&first), vec![vec!["first".to_string()]]);

        let second = step(
            ClientMessage::QueueMessage {
                session_id: id.clone(),
                text: "second".into(),
            },
            &sessions,
            &mut events,
            &mut fanout,
        );
        assert_eq!(
            snapshots(&second),
            vec![vec!["first".to_string(), "second".to_string()]],
            "the frame is the whole list, in insertion order, not a delta"
        );

        let blank = step(
            ClientMessage::QueueMessage {
                session_id: id.clone(),
                text: "   ".into(),
            },
            &sessions,
            &mut events,
            &mut fanout,
        );
        assert!(
            snapshots(&blank).is_empty(),
            "a whitespace-only message is not queued, so no snapshot goes out"
        );

        let pending = sessions.queue(&id);
        let dequeued = step(
            ClientMessage::DequeueMessage {
                session_id: id.clone(),
                message_id: pending[0].id.clone(),
            },
            &sessions,
            &mut events,
            &mut fanout,
        );
        assert_eq!(snapshots(&dequeued), vec![vec!["second".to_string()]]);

        let missing = step(
            ClientMessage::DequeueMessage {
                session_id: id.clone(),
                message_id: "never-queued".into(),
            },
            &sessions,
            &mut events,
            &mut fanout,
        );
        assert!(
            snapshots(&missing).is_empty(),
            "removing nothing changes nothing, and a client is not told otherwise"
        );

        let _ = step(
            ClientMessage::UnsubscribeQueue {
                session_id: id.clone(),
            },
            &sessions,
            &mut events,
            &mut fanout,
        );
        let after = step(
            ClientMessage::QueueMessage {
                session_id: id.clone(),
                text: "third".into(),
            },
            &sessions,
            &mut events,
            &mut fanout,
        );
        assert!(
            snapshots(&after).is_empty(),
            "the watch is gone, so the queue is no longer this client's business"
        );
        // The message itself was still queued — unsubscribing is a client's choice
        // about frames, not a mute button on the queue.
        assert_eq!(sessions.queue(&id).len(), 2);
    }

    /// A queue watch is per-connection: one client's unsubscribe cannot silence
    /// another's, and a change made by anyone reaches every watcher.
    #[tokio::test]
    async fn one_connections_watch_says_nothing_about_anothers() {
        let sessions = sessions();
        let mut events = sessions.subscribe();
        let mut watcher = fanout();
        let mut bystander = fanout();
        let id = sessions
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
        let _ = step(
            ClientMessage::SubscribeQueue {
                session_id: id.clone(),
            },
            &sessions,
            &mut events,
            &mut watcher,
        );

        // The bystander sends the message; the watcher is the one that hears about it.
        let sent = step(
            ClientMessage::QueueMessage {
                session_id: id.clone(),
                text: "steer".into(),
            },
            &sessions,
            &mut events,
            &mut bystander,
        );
        assert!(snapshots(&sent).is_empty(), "it never asked to watch");

        let mut outbound = Vec::new();
        push_event(
            SessionEvent::QueueChanged {
                session_id: id.clone(),
            },
            &sessions,
            &mut watcher,
            &mut outbound,
        );
        assert_eq!(snapshots(&outbound), vec![vec!["steer".to_string()]]);
    }

    #[tokio::test]
    async fn queueing_to_a_session_that_does_not_exist_answers_with_an_error() {
        let sessions = sessions();
        let mut events = sessions.subscribe();
        let mut fanout = fanout();
        let frames = step(
            ClientMessage::QueueMessage {
                session_id: "no-such-session".into(),
                text: "hello".into(),
            },
            &sessions,
            &mut events,
            &mut fanout,
        );
        assert!(matches!(
            frames.first(),
            Some(ServerMessage::Error { session_id: Some(id), .. }) if id == "no-such-session"
        ));
    }
}
