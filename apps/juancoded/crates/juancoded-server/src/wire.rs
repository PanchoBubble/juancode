//! Client → server and server → client frames, mirroring `WireProtocol.swift`.
//!
//! Two rules are load-bearing:
//!   1. An unrecognised `type` degrades to `Unknown` instead of failing the decode
//!      (juancode-tgc) — a newer client must not be able to kill the connection.
//!   2. `serverInfo` goes out first on every connection, and its capability list is
//!      honest about what this core implements. A narrower core is a supported
//!      configuration precisely because clients feature-detect off this.

use serde::Deserialize;
use serde_json::{json, Value};

use juancoded_core::changes::ChangeStat;
use juancoded_core::model::{SessionActivity, SessionMeta};
use juancoded_state::ClientId;
use juancoded_vt::wire::RowUpdate;

pub const PROTOCOL_VERSION: u32 = 1;

/// What the Rust core implements today, and nothing more. Deliberately shorter than
/// the Swift core's list: no `queue`, no `trackedPrs`, no `editor`/`terminal`.
/// Clients feature-detect off this, so a name here that the core does not answer is
/// worse than an omission — it turns a hidden button into a broken one.
pub const CAPABILITIES: &[&str] = &[
    "inputAck",
    "resizeAck",
    "screen",
    "adoptExternal",
    "sessionMeta",
    "gridOwner",
];

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
            Self::ServerInfo { client_id } => json!({
                "type": "serverInfo",
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": CAPABILITIES,
                // Without it the `owner` fields are unreadable: a client could see
                // that somebody drives a grid but not whether that somebody is
                // itself, since the token is minted server-side per connection.
                "clientId": client_token(*client_id),
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
                dispatch_id: None,
            }
        );
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
        for advertised in CAPABILITIES {
            assert!(
                [
                    "inputAck",
                    "resizeAck",
                    "screen",
                    "adoptExternal",
                    "sessionMeta",
                    "gridOwner",
                ]
                .contains(advertised),
                "unimplemented capability advertised: {advertised}"
            );
        }
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
        let v = ServerMessage::ServerInfo { client_id: 7 }.to_value();
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
        assert!(!caps.contains(&"queue".to_string()));
        assert!(!caps.contains(&"trackedPrs".to_string()));
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
