//! Wire model types, mirrored field-for-field from `JuancodeCore/Protocol.swift`.
//! The JSON these produce is consumed by clients written against the Swift core,
//! so field names, casing and enum spellings are protocol, not taste.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProviderId {
    Claude,
    Codex,
    Opencode,
}

impl ProviderId {
    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "claude" => Some(Self::Claude),
            "codex" => Some(Self::Codex),
            "opencode" => Some(Self::Opencode),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Opencode => "opencode",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionActivity {
    Busy,
    Idle,
    WaitingInput,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SessionStatus {
    Running,
    Exited,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SessionKind {
    Agent,
    Editor,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionUsage {
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_read_tokens: i64,
    pub cache_write_tokens: i64,
    pub total_tokens: i64,
    pub cost_usd: Option<f64>,
}

/// `SessionMeta` — the session row every client renders. `skipPermissions`,
/// `archived`, `dormant` and `kind` are always emitted (the Swift encoder does the
/// same); the optionals are omitted when absent so older clients ignore them.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionMeta {
    pub id: String,
    pub provider: ProviderId,
    pub cwd: String,
    pub title: String,
    pub status: SessionStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    /// ms since epoch, matching the TS `Date.now()` shape.
    pub created_at: i64,
    pub updated_at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cli_session_id: Option<String>,
    pub skip_permissions: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub worktree_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usage: Option<SessionUsage>,
    pub archived: bool,
    pub dormant: bool,
    pub kind: SessionKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dispatch_id: Option<String>,
}

impl SessionMeta {
    pub fn new(
        id: String,
        provider: ProviderId,
        cwd: String,
        title: String,
        now_ms: i64,
        skip_permissions: bool,
    ) -> Self {
        Self {
            id,
            provider,
            cwd,
            title,
            status: SessionStatus::Running,
            exit_code: None,
            created_at: now_ms,
            updated_at: now_ms,
            cli_session_id: None,
            skip_permissions,
            worktree_path: None,
            usage: None,
            archived: false,
            dormant: false,
            kind: SessionKind::Agent,
            parent_session_id: None,
            dispatch_id: None,
        }
    }

    /// The directory an agent is actually working in.
    pub fn effective_cwd(&self) -> &str {
        self.worktree_path.as_deref().unwrap_or(&self.cwd)
    }
}

/// ms since the unix epoch — the timestamp shape every wire field uses.
pub fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enum_spellings_match_the_swift_wire() {
        assert_eq!(
            serde_json::to_string(&ProviderId::Claude).unwrap(),
            r#""claude""#
        );
        assert_eq!(
            serde_json::to_string(&SessionActivity::WaitingInput).unwrap(),
            r#""waiting_input""#
        );
        assert_eq!(
            serde_json::to_string(&SessionStatus::Exited).unwrap(),
            r#""exited""#
        );
        assert_eq!(
            serde_json::to_string(&SessionKind::Editor).unwrap(),
            r#""editor""#
        );
    }

    #[test]
    fn meta_omits_absent_optionals_and_camel_cases_the_rest() {
        let meta = SessionMeta::new(
            "s1".into(),
            ProviderId::Claude,
            "/tmp".into(),
            "tmp".into(),
            1_700_000_000_000,
            false,
        );
        let json = serde_json::to_value(&meta).unwrap();
        assert_eq!(json["createdAt"], 1_700_000_000_000i64);
        assert_eq!(json["skipPermissions"], false);
        assert_eq!(json["kind"], "agent");
        assert!(json.get("exitCode").is_none());
        assert!(json.get("cliSessionId").is_none());
    }
}
