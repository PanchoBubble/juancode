//! The portable half of the harness: providers, ptys, the session registry.
//!
//! Ported from `JuancodeCore` (Swift). The prime directive travels with the code:
//! we spawn the genuine CLIs with their environment **untouched** — no shadow
//! `HOME`/`CODEX_HOME`, no `mcpServers` override — so `~/.claude.json`, connectors,
//! `~/.codex/config.toml` and project `.mcp.json` resolve exactly as they do in a
//! terminal. See `provider::ProviderSpec::spawn_env` for the single sanctioned
//! exception (opencode's opt-in bypass, which has no flag).

pub mod actions_log;
pub mod activity;
pub mod at_risk;
pub mod changes;
pub mod commit_message;
pub mod diff;
pub mod gh;
pub mod gh_convo;
pub mod git;
pub mod heavy;
pub mod model;
pub mod notify;
pub mod pr;
pub mod pr_timeline;
pub mod preset;
pub mod pricing;
pub mod proc;
pub mod provider;
pub mod pty;
pub mod reexec;
pub mod review;
pub mod usage;
pub mod worktree;

pub use actions_log::{parse_actions_log, ActionsLog, ActionsLogSection, ActionsLogSeverity};
pub use activity::{
    ActivityClock, ActivityDetector, Armed, ManualClock, MonotonicClock, ScreenText, Step,
    Transition,
};
pub use changes::ChangeStat;
pub use diff::{DiffFile, FileStatus};
pub use gh::{
    pr_age_label, pr_attention_reason, pr_matches_query, prs_needing_you, sort_prs_by_submit_date,
    sort_prs_tracked_first, FolderPrs, GhError, NeedsYou, PrAttentionReason, PrCheckRun,
    PrListResult, PullRequest, GH_PR_LIST_LIMIT,
};
pub use gh_convo::{
    PrCommit, PrConversation, PrConversationComment, PrReaction, PrReviewItem, PrReviewThread,
};
pub use git::{
    BaseDiffResult, CommitResult, DiffResult, GitError, GitState, PushResult, RecentCommit,
    RevertResult, Worktree, WorktreeStatusEntry,
};
pub use heavy::{HeavyJob, HeavyQueue, HeavyQueueSnapshot};
pub use model::{ProviderId, SessionActivity, SessionKind, SessionMeta, SessionStatus};
pub use notify::{notification_text, webhook_body, NotificationEvent};
pub use pr::{
    auto_fix_prompt, classify_pr_activity, derive_track_state, stalled_ci_fix_reason,
    track_seed_prompt, BranchWorktree, PrActivity, PrBaseline, PrChecks, PrClassification,
    PrComment, PrReview, TrackEvent, TrackNotification, TrackState, TrackedPr,
};
pub use pr_timeline::{
    check_outcome, pr_visible_timeline, PrCheckOutcome, PrThreadGroup, PrTimelineItem,
};
pub use preset::{preset_needs_body, Preset, PresetError, PresetStore};
pub use proc::{descendant_count, tree_cpu_time_ms};
pub use provider::{
    bin_override, editor_command_string, resolve_bin, resolve_editor_command, resolve_provider_bin,
    shell_command, IdSource, ProviderSpec, Providers, SpawnOptions,
};
pub use pty::{PtyEvent, PtyHandle, SpawnSpec};
pub use review::{
    build_prompt, parse_review_output, run_review, working_tree_files, DiffComment, ReviewFinding,
    ReviewResult, ReviewSeverity, ReviewStatus,
};
pub use worktree::{CreatedWorktree, WorktreeError};
