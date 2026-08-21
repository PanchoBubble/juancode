//! Provider specs and binary resolution — a port of `JuancodeCore/Providers.swift`.
//!
//! The prime directive lives here. The only args we pass are a session-id pin
//! (where the CLI supports one) and an opt-in skip-permissions flag; the only env
//! entry we ever add is opencode's bypass, which that CLI exposes *only* as an env
//! var. Everything else the child sees is inherited `environ`, verbatim.

use std::collections::HashMap;
use std::path::Path;
use std::process::Command;

use crate::model::ProviderId;

/// Per-session knobs that influence the spawned CLI's argv.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SpawnOptions {
    /// "Accept all" mode — no permission/approval prompts.
    pub skip_permissions: bool,
    /// Pin the CLI to a model. `None` = the CLI's own default. Model *names*
    /// differ per CLI; we forward whatever was asked for and let it validate.
    pub model: Option<String>,
}

/// Pure description of how to launch/resume a provider. No binary resolution here
/// (that's `resolve_bin`) so specs stay cheap and testable.
pub struct ProviderSpec {
    pub id: ProviderId,
    pub label: &'static str,
    /// True when `start_args` pins the CLI session id to our own UUID (Claude), so
    /// the resumable id is known immediately. False when it must be discovered
    /// from the CLI's own state after spawn (Codex, opencode).
    pub pins_session_id: bool,
    /// Whether the program reads bracketed-paste markers.
    pub bracketed_paste: bool,
    pub start_args: fn(&str, &SpawnOptions) -> Vec<String>,
    pub resume_args: fn(&str, &SpawnOptions) -> Vec<String>,
    /// Entries to overlay on the inherited environment. Empty for every provider
    /// that has a flag — an empty overlay means the child inherits `environ`
    /// verbatim, which is the point.
    pub spawn_env: fn(&SpawnOptions) -> HashMap<String, String>,
}

fn claude_perm_args(skip: bool) -> Vec<String> {
    // Deliberately NOT passing `--allow-dangerously-skip-permissions` for
    // non-bypass sessions: on real Claude builds it activates bypass and forces an
    // interactive prompt, which breaks plain resume. Bypass is strictly opt-in.
    if skip {
        vec!["--dangerously-skip-permissions".into()]
    } else {
        vec![]
    }
}

fn model_args(model: &Option<String>) -> Vec<String> {
    match model {
        Some(m) if !m.is_empty() => vec!["--model".into(), m.clone()],
        _ => vec![],
    }
}

fn no_env(_: &SpawnOptions) -> HashMap<String, String> {
    HashMap::new()
}

pub const CLAUDE: ProviderSpec = ProviderSpec {
    id: ProviderId::Claude,
    label: "Claude Code",
    pins_session_id: true,
    bracketed_paste: true,
    // Pin the CLI session id to our own UUID so `--resume` revives this exact
    // conversation with no discovery step.
    start_args: |juancode_id, opts| {
        let mut a = vec!["--session-id".to_string(), juancode_id.to_string()];
        a.extend(claude_perm_args(opts.skip_permissions));
        a.extend(model_args(&opts.model));
        a
    },
    resume_args: |cli_session_id, opts| {
        let mut a = vec!["--resume".to_string(), cli_session_id.to_string()];
        a.extend(claude_perm_args(opts.skip_permissions));
        a.extend(model_args(&opts.model));
        a
    },
    spawn_env: no_env,
};

pub const CODEX: ProviderSpec = ProviderSpec {
    id: ProviderId::Codex,
    label: "Codex",
    pins_session_id: false,
    bracketed_paste: true,
    // Codex has no flag to pin a session id, so it starts clean; the id is
    // discovered from its rollout file and resumed with `codex resume <id>`.
    start_args: |_, opts| {
        let mut a = Vec::new();
        if opts.skip_permissions {
            a.push("--dangerously-bypass-approvals-and-sandbox".to_string());
        }
        a.extend(model_args(&opts.model));
        a
    },
    resume_args: |cli_session_id, opts| {
        let mut a = vec!["resume".to_string()];
        if opts.skip_permissions {
            a.push("--dangerously-bypass-approvals-and-sandbox".to_string());
        }
        a.extend(model_args(&opts.model));
        a.push(cli_session_id.to_string());
        a
    },
    spawn_env: no_env,
};

pub const OPENCODE: ProviderSpec = ProviderSpec {
    id: ProviderId::Opencode,
    label: "opencode",
    pins_session_id: false,
    bracketed_paste: true,
    // `--session <id>` continues an EXISTING conversation only — there is no flag
    // to pin a new one — so a fresh session starts clean and the id is read out of
    // opencode's own database.
    start_args: |_, opts| model_args(&opts.model),
    resume_args: |cli_session_id, opts| {
        let mut a = vec!["--session".to_string(), cli_session_id.to_string()];
        a.extend(model_args(&opts.model));
        a
    },
    // opencode's TUI has no skip-permissions flag (only `opencode run` does), so
    // bypass rides on the env var its config layer reads. Set ONLY when the session
    // opted in; otherwise the overlay is empty and the environment is untouched.
    spawn_env: |opts| {
        let mut env = HashMap::new();
        if opts.skip_permissions {
            env.insert(
                "OPENCODE_PERMISSION".to_string(),
                r#"{"edit":"allow","bash":"allow","webfetch":"allow"}"#.to_string(),
            );
        }
        env
    },
};

pub struct Providers;

impl Providers {
    pub fn spec(id: ProviderId) -> &'static ProviderSpec {
        match id {
            ProviderId::Claude => &CLAUDE,
            ProviderId::Codex => &CODEX,
            ProviderId::Opencode => &OPENCODE,
        }
    }
}

/// Resolve a CLI to the SAME absolute path the user's interactive terminal would.
///
/// A GUI/daemon process often has a different (or stripped) PATH than the login
/// shell, so we ask the login shell to resolve the command. Faithful environment is
/// the whole point — we never inject a shadow HOME/PATH to get there.
///
/// Returns `None` when every probe came up empty, so a caller can refuse the spawn
/// instead of handing the user a dead pane.
pub fn resolve_bin(cmd: &str, override_path: Option<&str>) -> Option<String> {
    if let Some(path) = override_path {
        if !path.is_empty() && Path::new(path).exists() {
            return Some(path.to_string());
        }
    }
    if cmd.contains('/') {
        return Path::new(cmd).exists().then(|| cmd.to_string());
    }
    if let Some(found) = which_via_login_shell(cmd) {
        return Some(found);
    }
    // Last resort: the usual install roots, in the order a login shell would hit
    // them. Keep this list in step with the Swift `locateBin` probes.
    let home = std::env::var("HOME").unwrap_or_default();
    let candidates = [
        format!("{home}/.local/bin/{cmd}"),
        format!("{home}/.bun/bin/{cmd}"),
        format!("{home}/.volta/bin/{cmd}"),
        format!("/opt/homebrew/bin/{cmd}"),
        format!("/usr/local/bin/{cmd}"),
        format!("/usr/bin/{cmd}"),
    ];
    candidates.into_iter().find(|p| Path::new(p).exists())
}

fn which_via_login_shell(cmd: &str) -> Option<String> {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
    let out = Command::new(&shell)
        .args(["-l", "-i", "-c", &format!("command -v {cmd}")])
        .output()
        .ok()?;
    let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!path.is_empty() && Path::new(&path).exists()).then_some(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_pins_the_session_id_and_keeps_bypass_opt_in() {
        let opts = SpawnOptions::default();
        assert_eq!(
            (CLAUDE.start_args)("abc", &opts),
            vec!["--session-id".to_string(), "abc".to_string()]
        );
        let bypass = SpawnOptions {
            skip_permissions: true,
            model: None,
        };
        assert_eq!(
            (CLAUDE.start_args)("abc", &bypass),
            vec![
                "--session-id".to_string(),
                "abc".to_string(),
                "--dangerously-skip-permissions".to_string()
            ]
        );
    }

    #[test]
    fn claude_resume_forwards_a_pinned_model() {
        let opts = SpawnOptions {
            skip_permissions: false,
            model: Some("opus".into()),
        };
        assert_eq!(
            (CLAUDE.resume_args)("sid", &opts),
            vec![
                "--resume".to_string(),
                "sid".to_string(),
                "--model".to_string(),
                "opus".to_string()
            ]
        );
    }

    #[test]
    fn codex_resume_puts_the_id_last() {
        let opts = SpawnOptions::default();
        assert_eq!(
            (CODEX.resume_args)("sid", &opts),
            vec!["resume".to_string(), "sid".to_string()]
        );
    }

    #[test]
    fn only_opencode_bypass_overlays_the_environment() {
        let plain = SpawnOptions::default();
        assert!((CLAUDE.spawn_env)(&plain).is_empty());
        assert!((CODEX.spawn_env)(&plain).is_empty());
        assert!((OPENCODE.spawn_env)(&plain).is_empty());

        let bypass = SpawnOptions {
            skip_permissions: true,
            model: None,
        };
        // Still nothing for the two CLIs that have a flag — the directive holds.
        assert!((CLAUDE.spawn_env)(&bypass).is_empty());
        assert!((CODEX.spawn_env)(&bypass).is_empty());
        let env = (OPENCODE.spawn_env)(&bypass);
        assert_eq!(env.len(), 1);
        assert!(env.contains_key("OPENCODE_PERMISSION"));
    }

    #[test]
    fn resolve_bin_honours_an_existing_override_and_rejects_a_bogus_one() {
        assert_eq!(
            resolve_bin("claude", Some("/bin/echo")).as_deref(),
            Some("/bin/echo")
        );
        // A bogus override falls through to real resolution rather than being trusted.
        assert_ne!(
            resolve_bin("sh", Some("/nope/does-not-exist")).as_deref(),
            Some("/nope/does-not-exist")
        );
    }
}
