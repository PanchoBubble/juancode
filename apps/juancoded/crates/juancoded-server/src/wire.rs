//! Client → server and server → client frames, mirroring `WireProtocol.swift`.
//!
//! Two rules are load-bearing:
//!   1. An unrecognised `type` degrades to `Unknown` instead of failing the decode
//!      (juancode-tgc) — a newer client must not be able to kill the connection.
//!   2. `serverInfo` goes out first on every connection, and its capability list is
//!      honest about what this core implements. A narrower core is a supported
//!      configuration precisely because clients feature-detect off this.

use std::sync::Arc;

use serde::Deserialize;
use serde_json::{json, Value};

use juancoded_cordis::contribution::{ActivationOutcome, Snapshot as ContributionSnapshot};
use juancoded_cordis::services::queue::{Content, ItemState, Occurrence, QueueSnapshot};
use juancoded_core::changes::ChangeStat;
use juancoded_core::model::{SessionActivity, SessionMeta};
use juancoded_state::ClientId;
use juancoded_vt::wire::RowUpdate;

use crate::identity::DaemonIdentity;

pub const PROTOCOL_VERSION: u32 = 1;

/// What the Rust core implements today, and nothing more. Deliberately shorter than
/// the Swift core's list: no `trackedPrs`, no `editor`/`terminal`. Clients
/// feature-detect off this, so a name here that the core does not answer is worse than
/// an omission — it turns a hidden button into a broken one.
///
/// `queue` is advertised now on exactly the terms it was withheld on. It was absent
/// while every frame decoded and every snapshot went out but nothing typed a queued
/// message into a pty, because a client switching its send button on off the capability
/// would have watched messages pile up forever. Delivery landed with the claim
/// boundary, so the button now does what it says.
///
/// `queueEdit` is separate from `queue` rather than folded into it, because the two are
/// not the same promise. `queue` says messages can be queued and will be typed, which
/// the Swift core also does; `queueEdit` says every occurrence has an id that survives
/// being rewritten, which needs the addressable queue and which the Swift core has no
/// frame for. Folding it in would make an otherwise conformant core a liar.
///
/// `contributions` is still withheld, and for its own reason rather than by
/// association. The daemon side is complete: descriptors register, snapshots go out on
/// subscribe and on every revision, and activations round-trip to the owning plugin.
/// What does not exist yet is a client that renders a descriptor, and advertising the
/// capability before one does would promise chrome nothing draws.
///
/// `reaper` says this core puts idle sessions to sleep on its own and will honour a
/// client's idle window and never-sleep set. It is advertised because both halves are
/// real: the sweep runs in the daemon, and the two frames its gate names change what
/// the sweep does. A client that does not know them still gets a reaper — at the
/// daemon's own boot defaults — which is the honest shape: the capability is about the
/// frames, not about whether anything sleeps.
///
/// `transcript` is advertised on the same terms `queue` finally was: the promise is
/// about what this core answers, and it answers all of it. A session's transcript is
/// bound to its CLI's own store, read forward as the session works, kept across a
/// restart, and replayed from the beginning of what is kept on `subscribeTranscript`.
/// It is not the `contributions` case — there is no button to draw here and no chrome
/// to promise, only records a client either asks for or does not. A client that does
/// not know the frame never sends the subscribe and never sees one.
pub const CAPABILITIES: &[&str] = &[
    "inputAck",
    "resizeAck",
    "screen",
    "adoptExternal",
    "sessionMeta",
    "gridOwner",
    "queue",
    "isolateWorktree",
    "queueEdit",
    "transcript",
    "reaper",
    // Both only ever advertised once the flag actually reaches the CLI's argv: a
    // capability a client trusts and the core drops is worse than one it never had.
    "spawnModel",
    "spawnPreset",
];

/// One queued occurrence on the wire.
///
/// `content` is flattened rather than nested, so a client reads `kind` and then `text`
/// or `label` without walking into a sub-object; the Swift core's `QueuedMessage` was
/// exactly `{ id, text, createdAt }` and a text occurrence is still a superset of it.
///
/// `state` is here because it is the difference between a row a client may still offer
/// an edit on and one whose text is already in the agent's box. A client that drew both
/// the same way would show an edit button that can only answer `queue-item-not-found`.
fn queue_item(item: &Occurrence) -> Value {
    let mut v = json!({
        "id": item.id,
        "source": item.source,
        "createdAt": item.created_at,
        "state": match item.state {
            ItemState::Pending => "pending",
            ItemState::InFlight => "inFlight",
        },
    });
    match &item.content {
        Content::Text { text } => {
            v["kind"] = json!("text");
            v["text"] = json!(text);
        }
        Content::Keys { label, bytes } => {
            v["kind"] = json!("keys");
            v["label"] = json!(label);
            // The bytes themselves stay off the wire. A client renders the label and
            // addresses the id; nothing it can do with a control sequence is a thing it
            // should be doing, and an edit of one is refused as `queue-item-not-text`.
            v["bytes"] = json!(bytes.len());
        }
    }
    v
}

/// How a connection's arbitration id is spelled on the wire. A client only ever
/// compares it: to the `clientId` its own handshake gave it, so it can tell "somebody
/// drives this grid" from "I do". The number behind it is the registry's own token,
/// and it means nothing outside one daemon's lifetime.
pub fn client_token(client: ClientId) -> String {
    format!("client-{client}")
}

#[derive(Debug, Clone, PartialEq)]
pub enum ClientMessage {
    Create {
        provider: String,
        cwd: String,
        cols: Option<u16>,
        rows: Option<u16>,
        initial_input: Option<String>,
        skip_permissions: Option<bool>,
        /// Pin the CLI to one model for this spawn. Absent and empty are the same
        /// thing — the CLI's own default — so a client that always sends the key does
        /// not get a bare `--model` with nothing behind it.
        model: Option<String>,
        /// Name a per-spawn instruction set the core resolves against its own preset
        /// directory. Absent and empty are the same thing; a name the core cannot
        /// resolve is answered with `error` rather than dropped.
        preset: Option<String>,
        /// Spawn in a fresh git worktree off `cwd` rather than in `cwd`. Absent and
        /// `false` are the same thing; `true` is a promise, so a core that cannot
        /// keep it answers `error` rather than starting in the shared tree.
        isolate_worktree: Option<bool>,
        dispatch_id: Option<String>,
    },
    Attach {
        session_id: String,
        cols: u16,
        rows: u16,
    },
    /// Revive a session whose pty is gone. Distinct from `attach`, which only ever
    /// reads: only a reactivate can answer `unresumable`.
    Reactivate {
        session_id: String,
        cols: u16,
        rows: u16,
    },
    /// Take over a conversation started outside juancode, by its own CLI id.
    AdoptExternal {
        provider: String,
        cli_session_id: String,
        cwd: String,
        start_ms: i64,
        cols: u16,
        rows: u16,
    },
    /// Change a live session's permission mode, restarting the CLI in place.
    SetSkipPermissions {
        session_id: String,
        skip_permissions: bool,
        cols: u16,
        rows: u16,
    },
    Input {
        session_id: String,
        data: String,
        seq: Option<i64>,
    },
    Resize {
        session_id: String,
        cols: u16,
        rows: u16,
        seq: Option<i64>,
    },
    Kill {
        session_id: String,
    },
    SubscribeScreen {
        session_id: String,
    },
    UnsubscribeScreen {
        session_id: String,
    },
    /// Watch a session's steering queue: the complete ordered list now, and again
    /// after every change, until `unsubscribeQueue` or the socket closes.
    SubscribeQueue {
        session_id: String,
    },
    UnsubscribeQueue {
        session_id: String,
    },
    QueueMessage {
        session_id: String,
        text: String,
    },
    /// Replace a still-pending message's text in place, addressed by the id its
    /// snapshot gave it. Not a cancel-and-requeue: the occurrence keeps its id, its
    /// position in delivery order and the surface it arrived from, so editing the third
    /// message in a queue does not send it to the back of one nobody asked to reorder.
    EditQueued {
        session_id: String,
        message_id: String,
        text: String,
    },
    /// Watch a session's structured transcript: the history that is kept now, and
    /// every record the seam reads afterwards, until `unsubscribeTranscript` or the
    /// socket closes.
    ///
    /// The second data plane, beside the pty bytes. `attached.scrollback` is unchanged
    /// and stays the thing a pane repaints from; this is the typed record of what the
    /// agent did — turn boundaries, reasoning, tool calls and what each step cost —
    /// which is a shape no amount of scraping the grid recovers.
    SubscribeTranscript {
        session_id: String,
    },
    UnsubscribeTranscript {
        session_id: String,
    },
    /// Watch the contribution list: the complete set now, and again on every change,
    /// until `unsubscribeContributions` or the socket closes.
    SubscribeContributions,
    UnsubscribeContributions,
    /// Run a contribution's action. The daemon hands it to the plugin that registered
    /// the descriptor; the client never executes plugin logic of its own.
    ActivateContribution {
        contribution: String,
        target: Option<String>,
        payload: Value,
    },
    /// The Settings → Sessions knobs for the idle reaper. Every field is optional and
    /// only the ones present are applied, so a client that only has an idle-window
    /// stepper does not have to invent a ceiling.
    ///
    /// `windowMs` exists beside `minutes` because the daemon is a separate process and
    /// this frame is the only channel to it: the Settings stepper speaks minutes, and
    /// anything that needs to be exact — a conformance run, a shorter window than the
    /// stepper can express — needs the precise unit. `windowMs` wins when both are
    /// sent. `0` in either spelling disables idle reaping; the ceiling is separate and
    /// keeps applying.
    SetReaperPolicy {
        minutes: Option<i64>,
        window_ms: Option<i64>,
        max_live: Option<usize>,
    },
    /// The sessions this client says must never be slept: the pane it has open and the
    /// active Oracle. Replaces this client's whole set — it is never a patch — and an
    /// empty list clears it.
    ///
    /// Per connection, unlike the in-process Swift core's single set, because a daemon
    /// outlives its clients: a protection that survived the connection that declared it
    /// would be a session nobody is looking at that can never be reaped again.
    SetReaperProtectedIds {
        session_ids: Vec<String>,
    },
    /// Cancel a still-pending message by the id its snapshot gave it.
    DequeueMessage {
        session_id: String,
        message_id: String,
    },
    /// A well-formed frame this core doesn't implement. Ignored, not fatal.
    Unknown {
        r#type: String,
    },
}

#[derive(Deserialize)]
struct RawClient {
    r#type: String,
    #[serde(default)]
    provider: Option<String>,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    cols: Option<u16>,
    #[serde(default)]
    rows: Option<u16>,
    #[serde(default)]
    initial_input_camel: Option<String>,
    #[serde(rename = "initialInput", default)]
    initial_input: Option<String>,
    #[serde(rename = "skipPermissions", default)]
    skip_permissions: Option<bool>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    preset: Option<String>,
    #[serde(rename = "isolateWorktree", default)]
    isolate_worktree: Option<bool>,
    #[serde(rename = "cliSessionId", default)]
    cli_session_id: Option<String>,
    #[serde(rename = "startMs", default)]
    start_ms: Option<i64>,
    #[serde(rename = "dispatchId", default)]
    dispatch_id: Option<String>,
    #[serde(rename = "sessionId", default)]
    session_id: Option<String>,
    #[serde(default)]
    data: Option<String>,
    #[serde(default)]
    seq: Option<i64>,
    #[serde(default)]
    text: Option<String>,
    #[serde(rename = "messageId", default)]
    message_id: Option<String>,
    #[serde(default)]
    contribution: Option<String>,
    #[serde(default)]
    target: Option<String>,
    #[serde(default)]
    payload: Option<Value>,
    #[serde(default)]
    minutes: Option<i64>,
    #[serde(rename = "windowMs", default)]
    window_ms: Option<i64>,
    #[serde(rename = "maxLive", default)]
    max_live: Option<usize>,
    #[serde(rename = "sessionIds", default)]
    session_ids: Option<Vec<String>>,
}

impl ClientMessage {
    /// Decode a frame. `Err` is reserved for genuinely malformed JSON or a frame
    /// missing a field its own type requires; an unknown `type` is `Unknown`.
    pub fn decode(text: &str) -> Result<Self, String> {
        let raw: RawClient = serde_json::from_str(text).map_err(|e| e.to_string())?;
        let _ = raw.initial_input_camel;
        let need_session = || {
            raw.session_id
                .clone()
                .ok_or_else(|| "missing sessionId".to_string())
        };
        match raw.r#type.as_str() {
            "create" => Ok(Self::Create {
                provider: raw.provider.ok_or("missing provider")?,
                cwd: raw.cwd.ok_or("missing cwd")?,
                cols: raw.cols,
                rows: raw.rows,
                initial_input: raw.initial_input,
                skip_permissions: raw.skip_permissions,
                model: raw.model,
                preset: raw.preset,
                isolate_worktree: raw.isolate_worktree,
                dispatch_id: raw.dispatch_id,
            }),
            "attach" => Ok(Self::Attach {
                session_id: need_session()?,
                cols: raw.cols.ok_or("missing cols")?,
                rows: raw.rows.ok_or("missing rows")?,
            }),
            "reactivate" => Ok(Self::Reactivate {
                session_id: need_session()?,
                cols: raw.cols.ok_or("missing cols")?,
                rows: raw.rows.ok_or("missing rows")?,
            }),
            "adoptExternal" => Ok(Self::AdoptExternal {
                provider: raw.provider.ok_or("missing provider")?,
                cli_session_id: raw.cli_session_id.ok_or("missing cliSessionId")?,
                cwd: raw.cwd.ok_or("missing cwd")?,
                start_ms: raw.start_ms.ok_or("missing startMs")?,
                cols: raw.cols.unwrap_or(0),
                rows: raw.rows.unwrap_or(0),
            }),
            "setSkipPermissions" => Ok(Self::SetSkipPermissions {
                session_id: need_session()?,
                skip_permissions: raw.skip_permissions.unwrap_or(false),
                cols: raw.cols.unwrap_or(0),
                rows: raw.rows.unwrap_or(0),
            }),
            "input" => Ok(Self::Input {
                session_id: need_session()?,
                data: raw.data.ok_or("missing data")?,
                seq: raw.seq,
            }),
            "resize" => Ok(Self::Resize {
                session_id: need_session()?,
                cols: raw.cols.ok_or("missing cols")?,
                rows: raw.rows.ok_or("missing rows")?,
                seq: raw.seq,
            }),
            "kill" => Ok(Self::Kill {
                session_id: need_session()?,
            }),
            "subscribeScreen" => Ok(Self::SubscribeScreen {
                session_id: need_session()?,
            }),
            "unsubscribeScreen" => Ok(Self::UnsubscribeScreen {
                session_id: need_session()?,
            }),
            "subscribeQueue" => Ok(Self::SubscribeQueue {
                session_id: need_session()?,
            }),
            "unsubscribeQueue" => Ok(Self::UnsubscribeQueue {
                session_id: need_session()?,
            }),
            "queueMessage" => Ok(Self::QueueMessage {
                session_id: need_session()?,
                text: raw.text.ok_or("missing text")?,
            }),
            "editQueued" => Ok(Self::EditQueued {
                session_id: need_session()?,
                message_id: raw.message_id.ok_or("missing messageId")?,
                text: raw.text.ok_or("missing text")?,
            }),
            "dequeueMessage" => Ok(Self::DequeueMessage {
                session_id: need_session()?,
                message_id: raw.message_id.ok_or("missing messageId")?,
            }),
            "subscribeTranscript" => Ok(Self::SubscribeTranscript {
                session_id: need_session()?,
            }),
            "unsubscribeTranscript" => Ok(Self::UnsubscribeTranscript {
                session_id: need_session()?,
            }),
            "setReaperPolicy" => Ok(Self::SetReaperPolicy {
                minutes: raw.minutes,
                window_ms: raw.window_ms,
                max_live: raw.max_live,
            }),
            "setReaperProtectedIds" => Ok(Self::SetReaperProtectedIds {
                // An absent list is an empty one: "protect nothing" and "I sent no
                // list" mean the same thing to a set that is replaced wholesale.
                session_ids: raw.session_ids.unwrap_or_default(),
            }),
            "subscribeContributions" => Ok(Self::SubscribeContributions),
            "unsubscribeContributions" => Ok(Self::UnsubscribeContributions),
            "activateContribution" => Ok(Self::ActivateContribution {
                contribution: raw.contribution.ok_or("missing contribution")?,
                target: raw.target,
                payload: raw.payload.unwrap_or(Value::Null),
            }),
            other => Ok(Self::Unknown {
                r#type: other.to_string(),
            }),
        }
    }
}

impl From<&str> for ClientMessage {
    fn from(s: &str) -> Self {
        Self::decode(s).unwrap_or_else(|_| Self::Unknown {
            r#type: "malformed".into(),
        })
    }
}

/// Server → client frames. Built as `serde_json::Value` rather than a derive so
/// the omit-when-nil / always-emit-null distinctions the Swift encoder makes stay
/// visible at the call site instead of hiding in attributes.
#[derive(Debug, Clone)]
pub enum ServerMessage {
    ServerInfo {
        client_id: ClientId,
        /// Who this daemon is: build, boot time and effective retention. The one
        /// frame a client can use to notice it reconnected to a core older than its
        /// own launch — see `crate::identity`.
        identity: Arc<DaemonIdentity>,
    },
    Created {
        session: SessionMeta,
    },
    Attached {
        session_id: String,
        scrollback: String,
        session: SessionMeta,
    },
    Output {
        session_id: String,
        data: String,
    },
    Screen {
        session_id: String,
        reset: bool,
        cols: usize,
        rows: usize,
        cursor_x: usize,
        cursor_y: usize,
        cursor_visible: bool,
        alt: bool,
        lines: Vec<RowUpdate>,
    },
    InputAck {
        session_id: String,
        seq: i64,
    },
    ResizeAck {
        session_id: String,
        seq: i64,
        cols: u16,
        rows: u16,
        applied: bool,
        denied: bool,
        /// Who holds the grid after the arbitration, so a denied client learns who to
        /// wait for rather than only that it lost. `None` is an unclaimed grid.
        owner: Option<ClientId>,
    },
    Exit {
        session_id: String,
        exit_code: Option<i32>,
    },
    Activity {
        session_id: String,
        state: SessionActivity,
        notify: bool,
        /// Rides along only on the settle edge that computed it, so a client can
        /// badge "finished, N files changed" without git access of its own.
        changes: Option<ChangeStat>,
        dispatch_id: Option<String>,
    },
    /// A session's steering queue, complete, sent on `subscribeQueue` and again after
    /// every change. Replace wholesale: it is never a patch, and the items carry the
    /// ids `editQueued` and `dequeueMessage` address.
    ///
    /// `revision` is per session and strictly increasing, so a client that somehow sees
    /// two snapshots out of order drops the older one. It is not a cursor; there is
    /// nothing to fetch between revisions because there are no deltas to fetch.
    Queue {
        snapshot: QueueSnapshot,
    },
    /// A session's persisted row changed out of band: a title the CLI set for itself,
    /// a conversation id discovered after the spawn, a permission-mode flip. Carries
    /// the whole row — replace wholesale rather than patching fields. `created` and
    /// `attached` stay the snapshot; this is the delta, so a client's session row is
    /// not frozen at whatever meta it arrived with.
    SessionMeta {
        session_id: String,
        session: SessionMeta,
    },
    /// The arbitrated grid changed hands: a request was granted, or an owner let go
    /// (its connection closed). Broadcast to every connection, unlike `resizeAck`,
    /// which only ever reaches the client that sent the seq — so a viewer can render
    /// "someone else is driving" and take the pane read-only, and can tell when the
    /// grid is free again. `owner` is null for a release. Also sent once per
    /// already-claimed session when a connection opens, so a client that arrives
    /// mid-flight starts from the truth instead of assuming the grid is unclaimed.
    GridChange {
        session_id: String,
        owner: Option<ClientId>,
        cols: u16,
        rows: u16,
    },
    /// Structured transcript records for one session, oldest first.
    ///
    /// Two kinds of frame, one shape. `replay: true` is the history a `subscribe`
    /// answers with — what the daemon kept, bounded, ready to draw. `replay: false` is
    /// a batch the seam has just read.
    ///
    /// Append by `seq`, never replace: `seq` is promised append-only per session and
    /// never repeats, across restarts included, so a client's whole job is to ignore a
    /// `seq` it already holds. That is also why a record can legitimately arrive twice
    /// — a subscribe that lands in the middle of a poll gets it in the history and
    /// again live — and why doing so costs a client nothing.
    Transcript {
        session_id: String,
        replay: bool,
        records: Vec<Value>,
    },
    /// Everything the mounted tree contributes to the built-in surfaces, with the
    /// revision it is a snapshot of. Replace wholesale — never a patch — and skip any
    /// row whose `surface` this client does not render, which is what lets a new
    /// plugin reach an old client without breaking it.
    Contributions {
        snapshot: ContributionSnapshot,
    },
    /// What the owning plugin answered for one activation.
    ContributionResult {
        contribution: String,
        outcome: ActivationOutcome,
    },
    Unresumable {
        session_id: String,
        reason: String,
    },
    Error {
        session_id: Option<String>,
        message: String,
    },
}

impl ServerMessage {
    pub fn to_value(&self) -> Value {
        match self {
            Self::ServerInfo {
                client_id,
                identity,
            } => json!({
                "type": "serverInfo",
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": CAPABILITIES,
                // Without it the `owner` fields are unreadable: a client could see
                // that somebody drives a grid but not whether that somebody is
                // itself, since the token is minted server-side per connection.
                "clientId": client_token(*client_id),
                // Present because this core is a separate process. An in-process
                // core cannot be stale relative to its app, and sends nothing here.
                "daemon": identity.to_value(),
            }),
            Self::Transcript {
                session_id,
                replay,
                records,
            } => json!({
                "type": "transcript",
                "sessionId": session_id,
                "replay": replay,
                "records": records,
            }),
            Self::Created { session } => json!({ "type": "created", "session": session }),
            Self::Attached {
                session_id,
                scrollback,
                session,
            } => json!({
                "type": "attached",
                "sessionId": session_id,
                "scrollback": scrollback,
                "session": session,
            }),
            Self::Output { session_id, data } => json!({
                "type": "output", "sessionId": session_id, "data": data,
            }),
            Self::Screen {
                session_id,
                reset,
                cols,
                rows,
                cursor_x,
                cursor_y,
                cursor_visible,
                alt,
                lines,
            } => json!({
                "type": "screen",
                "sessionId": session_id,
                "reset": reset,
                "cols": cols,
                "rows": rows,
                "cursorX": cursor_x,
                "cursorY": cursor_y,
                "cursorVisible": cursor_visible,
                "alt": alt,
                "lines": lines,
            }),
            Self::InputAck { session_id, seq } => json!({
                "type": "inputAck", "sessionId": session_id, "seq": seq,
            }),
            Self::ResizeAck {
                session_id,
                seq,
                cols,
                rows,
                applied,
                denied,
                owner,
            } => json!({
                "type": "resizeAck",
                "sessionId": session_id,
                "seq": seq,
                "cols": cols,
                "rows": rows,
                "applied": applied,
                "denied": denied,
                // `owner: string | null` is always present, like `exit.exitCode`: an
                // omitted key and an unclaimed grid must not read the same.
                "owner": owner.map(client_token),
            }),
            // `exitCode: number | null` is always present in the TS — emit null
            // rather than omitting the key.
            Self::Exit {
                session_id,
                exit_code,
            } => json!({
                "type": "exit", "sessionId": session_id, "exitCode": exit_code,
            }),
            Self::Activity {
                session_id,
                state,
                notify,
                changes,
                dispatch_id,
            } => {
                let mut v = json!({
                    "type": "activity",
                    "sessionId": session_id,
                    "state": state,
                    "notify": notify,
                });
                if let Some(c) = changes {
                    v["changes"] = json!({
                        "files": c.files,
                        "additions": c.additions,
                        "deletions": c.deletions,
                    });
                }
                if let Some(d) = dispatch_id {
                    v["dispatchId"] = json!(d);
                }
                v
            }
            Self::Queue { snapshot } => json!({
                "type": "queue",
                // The item's own session id stays out of the items: the frame already
                // says which session this is.
                "sessionId": snapshot.session,
                "revision": snapshot.revision,
                "items": snapshot.items.iter().map(queue_item).collect::<Vec<_>>(),
            }),
            Self::SessionMeta {
                session_id,
                session,
            } => json!({
                "type": "sessionMeta", "sessionId": session_id, "session": session,
            }),
            Self::GridChange {
                session_id,
                owner,
                cols,
                rows,
            } => json!({
                "type": "gridChange",
                "sessionId": session_id,
                "owner": owner.map(client_token),
                "cols": cols,
                "rows": rows,
            }),
            Self::Contributions { snapshot } => json!({
                "type": "contributions",
                "schemaVersion": snapshot.schema_version,
                "revision": snapshot.revision,
                "items": snapshot.items,
            }),
            Self::ContributionResult {
                contribution,
                outcome,
            } => {
                // The outcome tag is flattened in, so a client reads `outcome` off the
                // frame rather than off a nested object it has to know about.
                let mut v = json!({ "type": "contributionResult", "contribution": contribution });
                if let (Some(map), Some(fields)) = (
                    v.as_object_mut(),
                    serde_json::to_value(outcome).ok().and_then(|o| match o {
                        Value::Object(m) => Some(m),
                        _ => None,
                    }),
                ) {
                    map.extend(fields);
                }
                v
            }
            Self::Unresumable { session_id, reason } => json!({
                "type": "unresumable", "sessionId": session_id, "reason": reason,
            }),
            Self::Error {
                session_id,
                message,
            } => {
                let mut v = json!({ "type": "error", "message": message });
                if let Some(id) = session_id {
                    v["sessionId"] = json!(id);
                }
                v
            }
        }
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(&self.to_value()).unwrap_or_else(|_| "{}".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use juancoded_core::model::{now_ms, ProviderId};

    fn meta() -> SessionMeta {
        SessionMeta::new(
            "s1".into(),
            ProviderId::Claude,
            "/tmp".into(),
            "tmp".into(),
            now_ms(),
            false,
        )
    }

    #[test]
    fn an_unknown_type_decodes_instead_of_failing() {
        let msg = ClientMessage::decode(r#"{"type":"steerMessage","sessionId":"x"}"#).unwrap();
        assert_eq!(
            msg,
            ClientMessage::Unknown {
                r#type: "steerMessage".into()
            }
        );
    }

    #[test]
    fn malformed_json_is_still_an_error() {
        assert!(ClientMessage::decode("{not json").is_err());
    }

    #[test]
    fn create_takes_an_optional_grid_so_a_headless_client_can_omit_it() {
        let msg =
            ClientMessage::decode(r#"{"type":"create","provider":"claude","cwd":"/tmp"}"#).unwrap();
        assert_eq!(
            msg,
            ClientMessage::Create {
                provider: "claude".into(),
                cwd: "/tmp".into(),
                cols: None,
                rows: None,
                initial_input: None,
                skip_permissions: None,
                model: None,
                preset: None,
                isolate_worktree: None,
                dispatch_id: None,
            }
        );
    }

    #[test]
    fn create_decodes_the_model_pin_and_the_preset_name() {
        let msg = ClientMessage::decode(
            r#"{"type":"create","provider":"claude","cwd":"/tmp","model":"opus","preset":"review"}"#,
        )
        .unwrap();
        assert!(
            matches!(
                &msg,
                ClientMessage::Create { model: Some(m), preset: Some(p), .. }
                    if m == "opus" && p == "review"
            ),
            "{msg:?}"
        );
        // Both are advertised, so a client that sends them is entitled to have them
        // reach the CLI rather than be accepted and dropped.
        assert!(CAPABILITIES.contains(&"spawnModel"));
        assert!(CAPABILITIES.contains(&"spawnPreset"));
    }

    #[test]
    fn input_and_resize_carry_an_optional_seq() {
        let with_seq =
            ClientMessage::decode(r#"{"type":"input","sessionId":"s","data":"x","seq":7}"#)
                .unwrap();
        assert_eq!(
            with_seq,
            ClientMessage::Input {
                session_id: "s".into(),
                data: "x".into(),
                seq: Some(7)
            }
        );
        let without =
            ClientMessage::decode(r#"{"type":"input","sessionId":"s","data":"x"}"#).unwrap();
        assert!(matches!(without, ClientMessage::Input { seq: None, .. }));
    }

    #[test]
    fn reactivate_is_its_own_message_not_an_attach() {
        // Decoding it as `attach` made `unresumable` unreachable: attach only reads,
        // and only a reactivate can be told there is nothing left to resume.
        let msg =
            ClientMessage::decode(r#"{"type":"reactivate","sessionId":"s","cols":80,"rows":24}"#)
                .unwrap();
        assert_eq!(
            msg,
            ClientMessage::Reactivate {
                session_id: "s".into(),
                cols: 80,
                rows: 24
            }
        );
    }

    #[test]
    fn every_advertised_capability_has_a_message_that_decodes() {
        // The lie this guards against: advertising a capability whose frame falls
        // through to `Unknown` and is silently dropped.
        let adopt = ClientMessage::decode(
            r#"{"type":"adoptExternal","provider":"claude","cliSessionId":"c-1",
                "cwd":"/tmp","startMs":1700000000000,"cols":80,"rows":24}"#,
        )
        .unwrap();
        assert_eq!(
            adopt,
            ClientMessage::AdoptExternal {
                provider: "claude".into(),
                cli_session_id: "c-1".into(),
                cwd: "/tmp".into(),
                start_ms: 1_700_000_000_000,
                cols: 80,
                rows: 24,
            }
        );
        assert!(CAPABILITIES.contains(&"adoptExternal"));
        // `queue` covers four frames, and the send button a client draws off the
        // capability is worth nothing if any one of them falls through to `Unknown`.
        for frame in [
            r#"{"type":"subscribeQueue","sessionId":"s"}"#,
            r#"{"type":"unsubscribeQueue","sessionId":"s"}"#,
            r#"{"type":"queueMessage","sessionId":"s","text":"x"}"#,
            r#"{"type":"editQueued","sessionId":"s","messageId":"q-1","text":"x"}"#,
            r#"{"type":"dequeueMessage","sessionId":"s","messageId":"q-1"}"#,
            // Same rule for `transcript`: a client feature-detecting off it must find
            // both halves of the subscription, not one.
            r#"{"type":"subscribeTranscript","sessionId":"s"}"#,
            r#"{"type":"unsubscribeTranscript","sessionId":"s"}"#,
            // And for `reaper`: a Settings stepper that reached `Unknown` would be the
            // exact failure this capability was added to end.
            r#"{"type":"setReaperPolicy","minutes":30}"#,
            r#"{"type":"setReaperProtectedIds","sessionIds":["s"]}"#,
        ] {
            assert!(
                !matches!(
                    ClientMessage::decode(frame).unwrap(),
                    ClientMessage::Unknown { .. }
                ),
                "{frame}"
            );
        }
        // `isolateWorktree` gates a FIELD, not a frame, so the lie it could tell is
        // one level down: the create still decodes, minus the flag, and the session
        // starts in the shared checkout under a `created` that says otherwise.
        let isolated = ClientMessage::decode(
            r#"{"type":"create","provider":"claude","cwd":"/tmp","isolateWorktree":true}"#,
        )
        .unwrap();
        assert!(
            matches!(
                isolated,
                ClientMessage::Create {
                    isolate_worktree: Some(true),
                    ..
                }
            ),
            "{isolated:?}"
        );
        for advertised in CAPABILITIES {
            assert!(
                [
                    "inputAck",
                    "resizeAck",
                    "screen",
                    "adoptExternal",
                    "sessionMeta",
                    "gridOwner",
                    "queue",
                    "isolateWorktree",
                    "queueEdit",
                    "transcript",
                    "reaper",
                    "spawnModel",
                    "spawnPreset",
                ]
                .contains(advertised),
                "unimplemented capability advertised: {advertised}"
            );
        }
    }

    #[test]
    fn the_reaper_policy_frame_carries_both_spellings_of_the_window() {
        // The Settings stepper speaks minutes; anything that needs to be exact — a
        // conformance run, a window shorter than a minute — needs the precise unit.
        assert_eq!(
            ClientMessage::decode(r#"{"type":"setReaperPolicy","minutes":30}"#).unwrap(),
            ClientMessage::SetReaperPolicy {
                minutes: Some(30),
                window_ms: None,
                max_live: None,
            }
        );
        assert_eq!(
            ClientMessage::decode(r#"{"type":"setReaperPolicy","windowMs":1500,"maxLive":4}"#)
                .unwrap(),
            ClientMessage::SetReaperPolicy {
                minutes: None,
                window_ms: Some(1_500),
                max_live: Some(4),
            }
        );
        // Every field optional: a client with only a stepper does not have to invent a
        // ceiling, and one with only a ceiling does not have to resend a window.
        assert_eq!(
            ClientMessage::decode(r#"{"type":"setReaperPolicy"}"#).unwrap(),
            ClientMessage::SetReaperPolicy {
                minutes: None,
                window_ms: None,
                max_live: None,
            }
        );
    }

    #[test]
    fn an_absent_protected_list_is_an_empty_one() {
        // "Protect nothing" and "I sent no list" mean the same thing to a set that is
        // replaced wholesale, and a client clearing its selection sends exactly this.
        assert_eq!(
            ClientMessage::decode(r#"{"type":"setReaperProtectedIds"}"#).unwrap(),
            ClientMessage::SetReaperProtectedIds {
                session_ids: Vec::new(),
            }
        );
        assert_eq!(
            ClientMessage::decode(r#"{"type":"setReaperProtectedIds","sessionIds":["a","b"]}"#)
                .unwrap(),
            ClientMessage::SetReaperProtectedIds {
                session_ids: vec!["a".into(), "b".into()],
            }
        );
    }

    #[test]
    fn the_contribution_frames_decode_even_though_the_capability_is_withheld() {
        // Same shape as `queue`: the daemon half is complete and nothing renders a
        // descriptor yet, so the capability stays off while the frames work for
        // anything that asks for them by name.
        assert!(!CAPABILITIES.contains(&"contributions"));
        assert_eq!(
            ClientMessage::decode(r#"{"type":"subscribeContributions"}"#).unwrap(),
            ClientMessage::SubscribeContributions
        );
        assert_eq!(
            ClientMessage::decode(r#"{"type":"unsubscribeContributions"}"#).unwrap(),
            ClientMessage::UnsubscribeContributions
        );
        assert_eq!(
            ClientMessage::decode(
                r#"{"type":"activateContribution","contribution":"session.menu.interrupt",
                    "target":"s-1","payload":{"why":"stuck"}}"#
            )
            .unwrap(),
            ClientMessage::ActivateContribution {
                contribution: "session.menu.interrupt".into(),
                target: Some("s-1".into()),
                payload: json!({ "why": "stuck" }),
            }
        );
        // A target and a payload are both optional: a command has neither.
        assert_eq!(
            ClientMessage::decode(r#"{"type":"activateContribution","contribution":"c"}"#).unwrap(),
            ClientMessage::ActivateContribution {
                contribution: "c".into(),
                target: None,
                payload: Value::Null,
            }
        );
    }

    #[test]
    fn an_activation_with_no_contribution_named_is_an_error_not_a_silent_drop() {
        assert!(ClientMessage::decode(r#"{"type":"activateContribution"}"#).is_err());
    }

    #[test]
    fn a_contributions_frame_carries_the_schema_version_and_the_revision() {
        let snapshot = juancoded_cordis::ContributionSnapshot {
            schema_version: 1,
            revision: 4,
            items: vec![juancoded_cordis::Contribution::new(
                "goals.section",
                juancoded_cordis::Placement::SidebarSection {
                    title: "Goals".into(),
                    icon: None,
                    collapsible: true,
                },
            )],
        };
        let v = ServerMessage::Contributions { snapshot }.to_value();
        assert_eq!(v["type"], "contributions");
        assert_eq!(v["schemaVersion"], 1);
        assert_eq!(v["revision"], 4);
        assert_eq!(v["items"][0]["id"], "goals.section");
        assert_eq!(v["items"][0]["surface"], "sidebarSection");
    }

    #[test]
    fn a_contribution_result_reads_its_outcome_off_the_frame() {
        let v = ServerMessage::ContributionResult {
            contribution: "c".into(),
            outcome: ActivationOutcome::refused("no session named"),
        }
        .to_value();
        assert_eq!(v["type"], "contributionResult");
        assert_eq!(v["contribution"], "c");
        assert_eq!(v["outcome"], "refused");
        assert_eq!(v["reason"], "no session named");

        let handled = ServerMessage::ContributionResult {
            contribution: "c".into(),
            outcome: ActivationOutcome::Unhandled,
        }
        .to_value();
        assert_eq!(handled["outcome"], "unhandled");
    }

    #[test]
    fn the_queue_frames_decode_and_the_capability_says_they_are_answered() {
        // Advertised now that delivery landed: a client may switch its send button on
        // off this name and expect the message to be typed.
        assert!(CAPABILITIES.contains(&"queue"));
        assert_eq!(
            ClientMessage::decode(r#"{"type":"subscribeQueue","sessionId":"s"}"#).unwrap(),
            ClientMessage::SubscribeQueue {
                session_id: "s".into()
            }
        );
        assert_eq!(
            ClientMessage::decode(r#"{"type":"unsubscribeQueue","sessionId":"s"}"#).unwrap(),
            ClientMessage::UnsubscribeQueue {
                session_id: "s".into()
            }
        );
        assert_eq!(
            ClientMessage::decode(r#"{"type":"queueMessage","sessionId":"s","text":"ship it"}"#)
                .unwrap(),
            ClientMessage::QueueMessage {
                session_id: "s".into(),
                text: "ship it".into()
            }
        );
        assert_eq!(
            ClientMessage::decode(
                r#"{"type":"editQueued","sessionId":"s","messageId":"q-1","text":"revised"}"#
            )
            .unwrap(),
            ClientMessage::EditQueued {
                session_id: "s".into(),
                message_id: "q-1".into(),
                text: "revised".into()
            }
        );
        assert_eq!(
            ClientMessage::decode(r#"{"type":"dequeueMessage","sessionId":"s","messageId":"q-1"}"#)
                .unwrap(),
            ClientMessage::DequeueMessage {
                session_id: "s".into(),
                message_id: "q-1".into()
            }
        );
    }

    #[test]
    fn a_queue_frame_missing_its_own_required_field_is_an_error_not_a_silent_drop() {
        assert!(ClientMessage::decode(r#"{"type":"queueMessage","sessionId":"s"}"#).is_err());
        assert!(ClientMessage::decode(r#"{"type":"dequeueMessage","sessionId":"s"}"#).is_err());
        assert!(ClientMessage::decode(r#"{"type":"subscribeQueue"}"#).is_err());
        // An edit needs both halves of its address and the replacement, and a missing
        // one must not decode to an edit of something else with an empty string.
        assert!(ClientMessage::decode(
            r#"{"type":"editQueued","sessionId":"s","messageId":"q-1"}"#
        )
        .is_err());
        assert!(
            ClientMessage::decode(r#"{"type":"editQueued","sessionId":"s","text":"x"}"#).is_err()
        );
    }

    #[test]
    fn a_queue_snapshot_carries_the_ordered_list_the_revision_and_each_items_state() {
        use juancoded_cordis::services::queue::{QueueApi, SessionQueues};
        // A pinned epoch, so the ids in this test cannot collide with another run's.
        let queue = SessionQueues::with_epoch("test");
        let first = queue.enqueue("s1", Content::text("first"), "telegram");
        queue.enqueue("s1", Content::keys("esc", vec![0x1b]), "native");

        let v = ServerMessage::Queue {
            snapshot: queue.snapshot("s1"),
        }
        .to_value();
        assert_eq!(v["type"], "queue");
        assert_eq!(v["sessionId"], "s1");
        // Two mutations, so the revision a client compares against is 2.
        assert_eq!(v["revision"], 2);

        let items = v["items"].as_array().unwrap();
        assert_eq!(items.len(), 2);
        // Insertion order is delivery order, and the frame is the whole list.
        assert_eq!(items[0]["id"], first.id.as_str());
        assert_eq!(items[0]["kind"], "text");
        assert_eq!(items[0]["text"], "first");
        // The source survives onto the wire: an edited message is still the message
        // that arrived from that surface, and a client renders where it came from.
        assert_eq!(items[0]["source"], "telegram");
        assert_eq!(items[0]["state"], "pending");
        assert!(items[0]["createdAt"].is_i64());
        // The session is named once, on the frame; the item's own copy is ours.
        assert!(items[0].get("sessionId").is_none());

        // A keypress has a label and a count, never the bytes: nothing a client can do
        // with a control sequence is a thing it should be doing.
        assert_eq!(items[1]["kind"], "keys");
        assert_eq!(items[1]["label"], "esc");
        assert_eq!(items[1]["bytes"], 1);
        assert!(items[1].get("text").is_none());

        // A claim is visible, because it is the difference between a row a client may
        // still offer an edit on and one whose text is already in the agent's box.
        let claim = queue.claim_next("s1").expect("the head is claimable");
        let v = ServerMessage::Queue {
            snapshot: queue.snapshot("s1"),
        }
        .to_value();
        assert_eq!(v["items"][0]["state"], "inFlight");
        drop(claim);

        let v = ServerMessage::Queue {
            snapshot: SessionQueues::with_epoch("test").snapshot("never-queued-to"),
        }
        .to_value();
        assert!(
            v["items"].as_array().unwrap().is_empty(),
            "an empty queue is an empty list, not a missing key"
        );
        assert_eq!(v["revision"], 0, "a queue nobody has touched is at zero");
    }

    #[test]
    fn set_skip_permissions_decodes_with_the_grid_to_restart_at() {
        let msg = ClientMessage::decode(
            r#"{"type":"setSkipPermissions","sessionId":"s","skipPermissions":true,
                "cols":80,"rows":24}"#,
        )
        .unwrap();
        assert_eq!(
            msg,
            ClientMessage::SetSkipPermissions {
                session_id: "s".into(),
                skip_permissions: true,
                cols: 80,
                rows: 24
            }
        );
    }

    #[test]
    fn server_info_leads_with_the_version_and_an_honest_capability_list() {
        let v = ServerMessage::ServerInfo {
            client_id: 7,
            identity: Arc::new(DaemonIdentity::capture(40)),
        }
        .to_value();
        assert_eq!(v["type"], "serverInfo");
        assert_eq!(v["protocolVersion"], 1);
        // The token a client recognises itself by in an `owner` field.
        assert_eq!(v["clientId"], client_token(7));
        let caps: Vec<String> = v["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c.as_str().unwrap().into())
            .collect();
        assert!(caps.contains(&"screen".to_string()));
        // Not implemented yet — and the list must not claim otherwise.
        assert!(caps.contains(&"queue".to_string()));
        assert!(!caps.contains(&"trackedPrs".to_string()));
        // Staleness is decidable from frame 0 or not at all: by the time a client
        // has drawn a session list it has already believed the daemon.
        assert_eq!(v["daemon"]["pid"], std::process::id());
        assert_eq!(v["daemon"]["sessionsPerProject"], 40);
        assert!(v["daemon"]["startedAt"].is_i64());
    }

    #[test]
    fn exit_emits_a_null_code_rather_than_omitting_the_key() {
        let v = ServerMessage::Exit {
            session_id: "s".into(),
            exit_code: None,
        }
        .to_value();
        assert!(v.get("exitCode").is_some());
        assert!(v["exitCode"].is_null());
    }

    #[test]
    fn error_omits_the_session_id_when_there_is_none() {
        let v = ServerMessage::Error {
            session_id: None,
            message: "boom".into(),
        }
        .to_value();
        assert!(v.get("sessionId").is_none());
        let v = ServerMessage::Error {
            session_id: Some("s".into()),
            message: "boom".into(),
        }
        .to_value();
        assert_eq!(v["sessionId"], "s");
    }

    #[test]
    fn activity_snake_cases_waiting_input_and_omits_an_absent_dispatch() {
        let v = ServerMessage::Activity {
            session_id: "s".into(),
            state: SessionActivity::WaitingInput,
            notify: true,
            changes: None,
            dispatch_id: None,
        }
        .to_value();
        assert_eq!(v["state"], "waiting_input");
        assert!(v.get("dispatchId").is_none());
        assert!(v.get("changes").is_none(), "no rollup means no key");
    }

    #[test]
    fn activity_carries_the_change_rollup_when_one_was_computed() {
        let v = ServerMessage::Activity {
            session_id: "s".into(),
            state: SessionActivity::Idle,
            notify: true,
            changes: Some(ChangeStat {
                files: 3,
                additions: 120,
                deletions: 44,
                signature: "ignored on the wire".into(),
            }),
            dispatch_id: Some("d-1".into()),
        }
        .to_value();
        assert_eq!(v["changes"]["files"], 3);
        assert_eq!(v["changes"]["additions"], 120);
        assert_eq!(v["changes"]["deletions"], 44);
        assert_eq!(v["dispatchId"], "d-1");
        // The debounce signature is ours, not the client's.
        assert!(v["changes"].get("signature").is_none());
    }

    #[test]
    fn a_transcript_frame_says_whether_it_is_a_replay_and_carries_records_verbatim() {
        let records = vec![
            json!({"session":"s1","source":"claude-jsonl","seq":0,"kind":"turnStart","prompt":"go"}),
            json!({"session":"s1","source":"claude-jsonl","seq":1,"kind":"assistant","text":"ok"}),
        ];
        let v = ServerMessage::Transcript {
            session_id: "s1".into(),
            replay: true,
            records: records.clone(),
        }
        .to_value();
        assert_eq!(v["type"], "transcript");
        assert_eq!(v["sessionId"], "s1");
        assert_eq!(v["replay"], true);
        // Verbatim: the eight typed events are the transcripts crate's contract, and
        // the wire re-shaping them would give a client a third spelling to learn.
        assert_eq!(v["records"], json!(records));
        // `seq` is what a client orders and de-duplicates by, so it has to survive.
        assert_eq!(v["records"][1]["seq"], 1);

        let live = ServerMessage::Transcript {
            session_id: "s1".into(),
            replay: false,
            records: Vec::new(),
        }
        .to_value();
        assert_eq!(live["replay"], false);
        assert_eq!(live["records"], json!([]));
    }

    #[test]
    fn attached_carries_the_scrollback_and_the_session_row() {
        let v = ServerMessage::Attached {
            session_id: "s1".into(),
            scrollback: "prior output".into(),
            session: meta(),
        }
        .to_value();
        assert_eq!(v["scrollback"], "prior output");
        assert_eq!(v["session"]["provider"], "claude");
    }

    #[test]
    fn resize_ack_reports_applied_and_denied_separately() {
        let v = ServerMessage::ResizeAck {
            session_id: "s".into(),
            seq: 3,
            cols: 100,
            rows: 30,
            applied: false,
            denied: true,
            owner: Some(4),
        }
        .to_value();
        assert_eq!(v["applied"], false);
        assert_eq!(v["denied"], true);
        assert_eq!(v["cols"], 100);
        // A denied client is told who to wait for, not only that it lost.
        assert_eq!(v["owner"], client_token(4));
    }

    #[test]
    fn an_unclaimed_grid_emits_a_null_owner_rather_than_omitting_the_key() {
        let v = ServerMessage::ResizeAck {
            session_id: "s".into(),
            seq: 1,
            cols: 80,
            rows: 24,
            applied: false,
            denied: false,
            owner: None,
        }
        .to_value();
        assert!(v.get("owner").is_some());
        assert!(v["owner"].is_null());
        let v = ServerMessage::GridChange {
            session_id: "s".into(),
            owner: None,
            cols: 80,
            rows: 24,
        }
        .to_value();
        assert!(v.get("owner").is_some(), "a release is a null owner");
        assert!(v["owner"].is_null());
    }

    #[test]
    fn session_meta_carries_the_whole_row_so_a_client_replaces_it_wholesale() {
        let v = ServerMessage::SessionMeta {
            session_id: "s1".into(),
            session: meta(),
        }
        .to_value();
        assert_eq!(v["type"], "sessionMeta");
        assert_eq!(v["sessionId"], "s1");
        assert_eq!(v["session"]["id"], "s1");
        assert_eq!(v["session"]["cwd"], "/tmp");
    }

    #[test]
    fn a_grid_change_names_the_owner_and_the_grid_it_holds() {
        let v = ServerMessage::GridChange {
            session_id: "s1".into(),
            owner: Some(2),
            cols: 100,
            rows: 30,
        }
        .to_value();
        assert_eq!(v["type"], "gridChange");
        assert_eq!(v["sessionId"], "s1");
        assert_eq!(v["owner"], client_token(2));
        assert_eq!(v["cols"], 100);
        assert_eq!(v["rows"], 30);
    }
}
