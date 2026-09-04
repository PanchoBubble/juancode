//! Provider specs and binary resolution — a port of `JuancodeCore/Providers.swift`.
//!
//! The prime directive lives here. The only args we pass are a session-id pin
//! (where the CLI supports one) and an opt-in skip-permissions flag; the only env
//! entry we ever add is opencode's bypass, which that CLI exposes *only* as an env
//! var. Everything else the child sees is inherited `environ`, verbatim.

use std::collections::HashMap;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::model::ProviderId;
use crate::preset::Preset;

/// Per-session knobs that influence the spawned CLI's argv.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SpawnOptions {
    /// "Accept all" mode — no permission/approval prompts.
    pub skip_permissions: bool,
    /// Pin the CLI to a model. `None` = the CLI's own default. Model *names*
    /// differ per CLI; we forward whatever was asked for and let it validate.
    pub model: Option<String>,
    /// A per-spawn instruction set, already resolved by `PresetStore`. `None` = none.
    /// One name, three mechanisms — see [`Preset`] for why each provider takes a
    /// different half of it.
    pub preset: Option<Preset>,
}

/// Where a provider's resumable conversation id comes from.
///
/// Only Claude lets us name it, so only Claude is resumable the moment it starts.
/// The other two write theirs into their own state and we go and read it, which is
/// why the variants name the file rather than just saying "later".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdSource {
    /// `--session-id <ours>`: the CLI adopts our UUID, so there is nothing to find.
    Pinned,
    /// Codex writes `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` at startup, and
    /// its first line carries the id and the cwd.
    CodexRollout,
    /// opencode writes a `session` row into its own SQLite, on the first message and
    /// not at spawn, so this one can be minutes away.
    OpencodeDb,
}

/// Pure description of how to launch/resume a provider. No binary resolution here
/// (that's `resolve_provider_bin`) so specs stay cheap and testable.
pub struct ProviderSpec {
    pub id: ProviderId,
    pub label: &'static str,
    /// Where the resumable id comes from, and therefore when it is known.
    pub id_source: IdSource,
    /// Whether the program reads bracketed-paste markers.
    pub bracketed_paste: bool,
    pub start_args: fn(&str, &SpawnOptions) -> Vec<String>,
    pub resume_args: fn(&str, &SpawnOptions) -> Vec<String>,
    /// Entries to overlay on the inherited environment. Empty for every provider
    /// that has a flag — an empty overlay means the child inherits `environ`
    /// verbatim, which is the point.
    pub spawn_env: fn(&SpawnOptions) -> HashMap<String, String>,
}

impl ProviderSpec {
    /// True when the CLI adopts our session id at spawn, so the session is
    /// resumable immediately and there is no discovery to run.
    pub fn pins_session_id(&self) -> bool {
        self.id_source == IdSource::Pinned
    }
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

/// claude's `--append-system-prompt <body>`: the one true append of the three, and
/// the only mechanism where juancode supplies the prose. Empty when no preset, or when
/// a body somehow did not resolve — `PresetStore::resolve` refuses for claude before we
/// ever get here, so the `None` branch is belt, not a silent drop.
fn claude_preset_args(preset: &Option<Preset>) -> Vec<String> {
    match preset.as_ref().and_then(|p| p.body.as_deref()) {
        Some(body) if !body.is_empty() => {
            vec!["--append-system-prompt".to_string(), body.to_string()]
        }
        _ => vec![],
    }
}

/// codex's `--profile <name>`, which layers `$CODEX_HOME/<name>.config.toml` on the
/// user's base config. We forward the name and let codex validate it, exactly as with
/// `--model`: the file is the user's to write, and inventing one for them is the
/// shadow-config move the prime directive forbids.
fn codex_preset_args(preset: &Option<Preset>) -> Vec<String> {
    match preset.as_ref().map(|p| p.name.as_str()) {
        Some(name) if !name.is_empty() => vec!["--profile".to_string(), name.to_string()],
        _ => vec![],
    }
}

/// opencode's `--agent <name>`, naming an agent defined in the user's own config.
/// Note this SELECTS rather than appends: unlike claude's flag it replaces the agent's
/// prompt wholesale, which is opencode's model of the concept and not something we can
/// paper over.
fn opencode_preset_args(preset: &Option<Preset>) -> Vec<String> {
    match preset.as_ref().map(|p| p.name.as_str()) {
        Some(name) if !name.is_empty() => vec!["--agent".to_string(), name.to_string()],
        _ => vec![],
    }
}

fn no_env(_: &SpawnOptions) -> HashMap<String, String> {
    HashMap::new()
}

pub const CLAUDE: ProviderSpec = ProviderSpec {
    id: ProviderId::Claude,
    label: "Claude Code",
    id_source: IdSource::Pinned,
    bracketed_paste: true,
    // Pin the CLI session id to our own UUID so `--resume` revives this exact
    // conversation with no discovery step.
    start_args: |juancode_id, opts| {
        let mut a = vec!["--session-id".to_string(), juancode_id.to_string()];
        a.extend(claude_perm_args(opts.skip_permissions));
        a.extend(model_args(&opts.model));
        a.extend(claude_preset_args(&opts.preset));
        a
    },
    // The preset rides on resume too: all three mechanisms are per-invocation flags,
    // not state the conversation carries, so a resumed session without it would
    // quietly lose its instruction set halfway through.
    resume_args: |cli_session_id, opts| {
        let mut a = vec!["--resume".to_string(), cli_session_id.to_string()];
        a.extend(claude_perm_args(opts.skip_permissions));
        a.extend(model_args(&opts.model));
        a.extend(claude_preset_args(&opts.preset));
        a
    },
    spawn_env: no_env,
};

pub const CODEX: ProviderSpec = ProviderSpec {
    id: ProviderId::Codex,
    label: "Codex",
    id_source: IdSource::CodexRollout,
    bracketed_paste: true,
    // Codex has no flag to pin a session id, so it starts clean; the id is
    // discovered from its rollout file and resumed with `codex resume <id>`.
    start_args: |_, opts| {
        let mut a = Vec::new();
        if opts.skip_permissions {
            a.push("--dangerously-bypass-approvals-and-sandbox".to_string());
        }
        a.extend(model_args(&opts.model));
        a.extend(codex_preset_args(&opts.preset));
        a
    },
    resume_args: |cli_session_id, opts| {
        let mut a = vec!["resume".to_string()];
        if opts.skip_permissions {
            a.push("--dangerously-bypass-approvals-and-sandbox".to_string());
        }
        a.extend(model_args(&opts.model));
        a.extend(codex_preset_args(&opts.preset));
        a.push(cli_session_id.to_string());
        a
    },
    spawn_env: no_env,
};

pub const OPENCODE: ProviderSpec = ProviderSpec {
    id: ProviderId::Opencode,
    label: "opencode",
    id_source: IdSource::OpencodeDb,
    bracketed_paste: true,
    // `--session <id>` continues an EXISTING conversation only — there is no flag
    // to pin a new one — so a fresh session starts clean and the id is read out of
    // opencode's own database.
    start_args: |_, opts| {
        let mut a = model_args(&opts.model);
        a.extend(opencode_preset_args(&opts.preset));
        a
    },
    resume_args: |cli_session_id, opts| {
        let mut a = vec!["--session".to_string(), cli_session_id.to_string()];
        a.extend(model_args(&opts.model));
        a.extend(opencode_preset_args(&opts.preset));
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

/// The env var that says where a provider's CLI lives, for the three that have one.
fn bin_override_key(provider: &str) -> Option<&'static str> {
    match provider {
        "claude" => Some("JUANCODE_CLAUDE_BIN"),
        "codex" => Some("JUANCODE_CODEX_BIN"),
        "opencode" => Some("JUANCODE_OPENCODE_BIN"),
        _ => None,
    }
}

/// What `JUANCODE_<PROVIDER>_BIN` says, if it says anything.
pub fn bin_override(provider: &str) -> Option<String> {
    bin_override_key(provider)
        .and_then(|key| std::env::var(key).ok())
        .filter(|value| !value.is_empty())
}

/// Where a provider's CLI is, override included. **The one answer to that question.**
///
/// Both callers go through here rather than through `resolve_bin` with an override
/// they each remember to pass: one of them used to forget, and a forgotten override
/// means the conformance suite's fake agent is quietly ignored in favour of the real
/// `claude`. Folding the override into the lookup makes forgetting it unwritable.
pub fn resolve_provider_bin(provider: &str) -> Option<String> {
    resolve_bin(provider, bin_override(provider).as_deref())
}

/// Resolve a command to the SAME absolute path the user's interactive terminal would.
///
/// A GUI/daemon process often has a different (or stripped) PATH than the login
/// shell, so we ask the login shell to resolve the command. Faithful environment is
/// the whole point — we never inject a shadow HOME/PATH to get there.
///
/// Returns `None` when every probe came up empty, so a caller can refuse the spawn
/// instead of handing the user a dead pane.
///
/// Prefer [`resolve_provider_bin`] for a provider CLI; this is the lower level, for
/// a command that has no override of its own.
pub fn resolve_bin(cmd: &str, override_path: Option<&str>) -> Option<String> {
    // An explicit override short-circuits before the cache, so a test can point a
    // binary at a stub on any call. It is taken as given rather than verified: a
    // typo'd override that silently resolved to the real CLI instead would be a
    // far worse answer than a spawn that fails and says which path it tried.
    if let Some(path) = override_path.filter(|p| !p.is_empty()) {
        return Some(path.to_string());
    }
    // Already a path: there is nothing to search.
    if cmd.contains('/') {
        return Some(cmd.to_string());
    }
    if let Some(hit) = cache().hit(cmd) {
        return Some(hit);
    }
    // A recent probe already came up empty. Report the miss again rather than paying
    // the shell round-trips; the cooldown expires, so a CLI installed while the
    // daemon runs still resolves.
    if cache().in_miss_cooldown(cmd) {
        return None;
    }

    // Probes, cheapest first. Each one alone is enough on some setup:
    //  1. the inherited PATH, no subprocess. A terminal-launched daemon already has
    //     the user's full PATH, so this hits instantly.
    //  2. `$SHELL -lc`: login but not interactive, so /etc/zprofile (path_helper,
    //     /etc/paths.d, where Homebrew registers itself) and .zprofile/.zshenv
    //     apply. Milliseconds on a normal setup.
    //  3. the well-known install dirs, no subprocess. Covers a Homebrew or local
    //     install even when the shell probes are unavailable or slow.
    //  4. `$SHELL -lic`: interactive, the only shell that sees a PATH built in
    //     .zshrc. Last because it pays for the user's whole interactive rc, 6s+ with
    //     a plugin-heavy zsh, which is what used to wedge the Swift path (juancode-z0c6).
    let found = lookup_in_path(cmd)
        .or_else(|| lookup_via_shell(cmd, false, Duration::from_secs(5)))
        .or_else(|| lookup_in_well_known_dirs(cmd))
        .or_else(|| lookup_via_shell(cmd, true, Duration::from_secs(20)));
    match found {
        Some(hit) => {
            cache().remember(cmd, &hit);
            Some(hit)
        }
        None => {
            // Remember the miss only for the cooldown: a probe comes up empty for
            // reasons that have nothing to do with the binary, and caching that for
            // good would wedge every later call until restart.
            cache().note_miss(cmd);
            None
        }
    }
}

/// Where a Mac keeps user-installed CLIs, in the order a login shell puts them on
/// PATH. Kept in step with `wellKnownBinDirs` in Providers.swift.
fn well_known_bin_dirs() -> Vec<String> {
    let home = std::env::var("HOME").unwrap_or_default();
    vec![
        "/opt/homebrew/bin".into(),
        "/opt/homebrew/sbin".into(),
        "/usr/local/bin".into(),
        format!("{home}/.local/bin"),
        format!("{home}/.bun/bin"),
        format!("{home}/.cargo/bin"),
        format!("{home}/go/bin"),
        format!("{home}/.volta/bin"),
        format!("{home}/.npm-global/bin"),
        format!("{home}/.opencode/bin"),
        "/opt/local/bin".into(),
    ]
}

#[cfg(unix)]
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

#[cfg(not(unix))]
fn is_executable(path: &Path) -> bool {
    path.is_file()
}

fn lookup_in_dirs(cmd: &str, dirs: impl IntoIterator<Item = String>) -> Option<String> {
    dirs.into_iter()
        .map(|dir| format!("{dir}/{cmd}"))
        .find(|full| is_executable(Path::new(full)))
}

fn lookup_in_path(cmd: &str) -> Option<String> {
    let path = std::env::var("PATH").ok()?;
    lookup_in_dirs(
        cmd,
        path.split(':')
            .filter(|d| !d.is_empty())
            .map(|d| d.to_string())
            .collect::<Vec<_>>(),
    )
}

fn lookup_in_well_known_dirs(cmd: &str) -> Option<String> {
    lookup_in_dirs(cmd, well_known_bin_dirs())
}

/// Ask the user's shell where `cmd` is, bounded by `timeout`. `interactive` adds
/// `-i`, which is what makes a PATH built in `.zshrc` visible, and what makes the
/// probe cost the user's whole interactive rc, so callers try the plain form first.
fn lookup_via_shell(cmd: &str, interactive: bool, timeout: Duration) -> Option<String> {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
    let flag = if interactive { "-lic" } else { "-lc" };
    let mut child = Command::new(&shell)
        .args([flag, &format!("command -v {cmd} 2>/dev/null")])
        // A non-tty stdin, so an interactive shell does not start its line editor
        // and reach for the terminal.
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(POLL_EVERY),
            // Out of time, or the wait itself failed: this probe is over, and the
            // ladder has cheaper rungs left.
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    let out = child.wait_with_output().ok()?;
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .next_back()
        .filter(|l| l.starts_with('/'))
        .map(str::to_string)
}

const POLL_EVERY: Duration = Duration::from_millis(25);
/// How long a failed lookup is remembered. Long enough to stop a fan-out of spawns
/// each paying the shell probes, short enough that installing the CLI while the
/// daemon runs is noticed.
const MISS_TTL: Duration = Duration::from_secs(60);

/// Process-lifetime memo of the no-override resolutions (juancode-8fp).
///
/// Hits are kept for good, since PATH and the login shell do not change under us, and
/// misses only for [`MISS_TTL`]. The Swift original needs a guard against a
/// backwards clock jump pinning the cooldown on forever; `Instant` is monotonic, so
/// here that bug cannot be written.
#[derive(Default)]
struct BinCache {
    inner: Mutex<CacheState>,
}

#[derive(Default)]
struct CacheState {
    hits: HashMap<String, String>,
    misses: HashMap<String, Instant>,
}

impl BinCache {
    fn state(&self) -> std::sync::MutexGuard<'_, CacheState> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn hit(&self, cmd: &str) -> Option<String> {
        self.state().hits.get(cmd).cloned()
    }

    fn remember(&self, cmd: &str, path: &str) {
        let mut state = self.state();
        state.hits.insert(cmd.to_string(), path.to_string());
        state.misses.remove(cmd);
    }

    fn note_miss(&self, cmd: &str) {
        self.state().misses.insert(cmd.to_string(), Instant::now());
    }

    fn in_miss_cooldown(&self, cmd: &str) -> bool {
        let mut state = self.state();
        match state.misses.get(cmd) {
            Some(at) if at.elapsed() < MISS_TTL => true,
            Some(_) => {
                state.misses.remove(cmd);
                false
            }
            None => false,
        }
    }
}

fn cache() -> &'static BinCache {
    static CACHE: OnceLock<BinCache> = OnceLock::new();
    CACHE.get_or_init(BinCache::default)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::preset::Preset;

    #[test]
    fn claude_pins_the_session_id_and_keeps_bypass_opt_in() {
        let opts = SpawnOptions::default();
        assert_eq!(
            (CLAUDE.start_args)("abc", &opts),
            vec!["--session-id".to_string(), "abc".to_string()]
        );
        let bypass = SpawnOptions {
            skip_permissions: true,
            ..Default::default()
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
            model: Some("opus".into()),
            ..Default::default()
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
    fn one_preset_name_becomes_three_different_mechanisms() {
        // The body is claude's alone; the other two get the name, because they are
        // selecting a definition the user already wrote.
        let opts = SpawnOptions {
            preset: Some(Preset {
                name: "review".into(),
                body: Some("BODY".into()),
            }),
            ..Default::default()
        };
        assert_eq!(
            (CLAUDE.start_args)("abc", &opts),
            vec![
                "--session-id".to_string(),
                "abc".to_string(),
                "--append-system-prompt".to_string(),
                "BODY".to_string()
            ]
        );
        assert_eq!(
            (CODEX.start_args)("abc", &opts),
            vec!["--profile".to_string(), "review".to_string()]
        );
        assert_eq!(
            (OPENCODE.start_args)("abc", &opts),
            vec!["--agent".to_string(), "review".to_string()]
        );
    }

    #[test]
    fn a_preset_rides_on_resume_too() {
        // All three mechanisms are per-invocation flags, so a resume without them is
        // a session that quietly lost its instruction set halfway through.
        let opts = SpawnOptions {
            preset: Some(Preset {
                name: "review".into(),
                body: Some("BODY".into()),
            }),
            ..Default::default()
        };
        assert_eq!(
            (CLAUDE.resume_args)("sid", &opts),
            vec![
                "--resume".to_string(),
                "sid".to_string(),
                "--append-system-prompt".to_string(),
                "BODY".to_string()
            ]
        );
        assert_eq!(
            (CODEX.resume_args)("sid", &opts),
            vec![
                "resume".to_string(),
                "--profile".to_string(),
                "review".to_string(),
                "sid".to_string()
            ]
        );
        assert_eq!(
            (OPENCODE.resume_args)("sid", &opts),
            vec![
                "--session".to_string(),
                "sid".to_string(),
                "--agent".to_string(),
                "review".to_string()
            ]
        );
    }

    #[test]
    fn no_preset_means_no_flag_on_any_of_the_three() {
        let plain = SpawnOptions::default();
        for args in [
            (CLAUDE.start_args)("abc", &plain),
            (CODEX.start_args)("abc", &plain),
            (OPENCODE.start_args)("abc", &plain),
            (CLAUDE.resume_args)("sid", &plain),
            (CODEX.resume_args)("sid", &plain),
            (OPENCODE.resume_args)("sid", &plain),
        ] {
            for flag in ["--append-system-prompt", "--profile", "--agent"] {
                assert!(!args.iter().any(|a| a == flag), "{args:?} carries {flag}");
            }
        }
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
            ..Default::default()
        };
        // Still nothing for the two CLIs that have a flag — the directive holds.
        assert!((CLAUDE.spawn_env)(&bypass).is_empty());
        assert!((CODEX.spawn_env)(&bypass).is_empty());
        let env = (OPENCODE.spawn_env)(&bypass);
        assert_eq!(env.len(), 1);
        assert!(env.contains_key("OPENCODE_PERMISSION"));
    }

    #[test]
    fn an_override_wins_outright_and_is_not_second_guessed() {
        assert_eq!(
            resolve_bin("claude", Some("/bin/echo")).as_deref(),
            Some("/bin/echo")
        );
        // Even one that does not exist: the spawn then fails naming the path that was
        // asked for, which is a better answer than silently running the real CLI.
        assert_eq!(
            resolve_bin("claude", Some("/nope/does-not-exist")).as_deref(),
            Some("/nope/does-not-exist")
        );
        // An empty override counts as unset, so an exported-but-blank var cannot
        // shadow a working resolution.
        assert_eq!(resolve_bin("sh", Some("")), resolve_bin("sh", None));
    }

    #[test]
    fn a_command_resolves_off_the_inherited_path_without_a_shell() {
        // `sh` is on PATH everywhere this builds, so the first rung answers and the
        // expensive shell probes are never reached.
        let found = resolve_bin("sh", None).expect("sh is somewhere");
        assert!(found.starts_with('/'), "{found} is not absolute");
        assert!(found.ends_with("/sh"), "{found} is not sh");
    }

    #[test]
    fn a_resolution_is_memoized_and_a_miss_is_only_remembered_for_a_while() {
        let cache = BinCache::default();
        assert!(cache.hit("claude").is_none());
        cache.remember("claude", "/opt/homebrew/bin/claude");
        assert_eq!(
            cache.hit("claude").as_deref(),
            Some("/opt/homebrew/bin/claude")
        );

        cache.note_miss("codex");
        assert!(cache.in_miss_cooldown("codex"));
        // A hit clears the miss, so a CLI installed mid-run stops being reported
        // absent the moment it is found.
        cache.remember("codex", "/usr/local/bin/codex");
        assert!(!cache.in_miss_cooldown("codex"));
    }

    #[test]
    fn the_provider_override_env_vars_are_the_swift_ones() {
        for (provider, key) in [
            ("claude", "JUANCODE_CLAUDE_BIN"),
            ("codex", "JUANCODE_CODEX_BIN"),
            ("opencode", "JUANCODE_OPENCODE_BIN"),
        ] {
            assert_eq!(bin_override_key(provider), Some(key));
        }
        // Anything else has no override, so a bare command name never picks one up
        // from a provider's variable by accident.
        assert_eq!(bin_override_key("gh"), None);
    }

    #[test]
    fn only_claude_is_resumable_the_moment_it_starts() {
        assert!(CLAUDE.pins_session_id());
        assert!(!CODEX.pins_session_id());
        assert!(!OPENCODE.pins_session_id());
        assert_eq!(CODEX.id_source, IdSource::CodexRollout);
        assert_eq!(OPENCODE.id_source, IdSource::OpencodeDb);
    }
}
