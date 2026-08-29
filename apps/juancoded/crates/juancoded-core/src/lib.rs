//! The portable half of the harness: providers, ptys, the session registry.
//!
//! Ported from `JuancodeCore` (Swift). The prime directive travels with the code:
//! we spawn the genuine CLIs with their environment **untouched** — no shadow
//! `HOME`/`CODEX_HOME`, no `mcpServers` override — so `~/.claude.json`, connectors,
//! `~/.codex/config.toml` and project `.mcp.json` resolve exactly as they do in a
//! terminal. See `provider::ProviderSpec::spawn_env` for the single sanctioned
//! exception (opencode's opt-in bypass, which has no flag).

pub mod activity;
pub mod changes;
pub mod model;
pub mod proc;
pub mod provider;
pub mod pty;
pub mod worktree;

pub use activity::{
    ActivityClock, ActivityDetector, Armed, ManualClock, MonotonicClock, ScreenText, Step,
    Transition,
};
pub use changes::ChangeStat;
pub use model::{ProviderId, SessionActivity, SessionKind, SessionMeta, SessionStatus};
pub use proc::{descendant_count, tree_cpu_time_ms};
pub use provider::{
    bin_override, resolve_bin, resolve_provider_bin, IdSource, ProviderSpec, Providers,
    SpawnOptions,
};
pub use pty::{PtyEvent, PtyHandle, SpawnSpec};
pub use worktree::{CreatedWorktree, WorktreeError};
