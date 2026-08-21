//! The portable half of the harness: providers, ptys, the session registry.
//!
//! Ported from `JuancodeCore` (Swift). The prime directive travels with the code:
//! we spawn the genuine CLIs with their environment **untouched** — no shadow
//! `HOME`/`CODEX_HOME`, no `mcpServers` override — so `~/.claude.json`, connectors,
//! `~/.codex/config.toml` and project `.mcp.json` resolve exactly as they do in a
//! terminal. See `provider::ProviderSpec::spawn_env` for the single sanctioned
//! exception (opencode's opt-in bypass, which has no flag).

pub mod model;
pub mod provider;
pub mod pty;
pub mod registry;

pub use model::{ProviderId, SessionActivity, SessionKind, SessionMeta, SessionStatus};
pub use provider::{resolve_bin, ProviderSpec, Providers, SpawnOptions};
pub use pty::{PtyEvent, PtyHandle};
pub use registry::{CreateRequest, Registry, SessionEvent};
