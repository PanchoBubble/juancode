//! Per-spawn instruction sets — a port of `JuancodeCore/PresetStore.swift`.
//!
//! The three CLIs expose nothing in common here, so one preset name means three
//! mechanisms and each provider needs a different half of it:
//!
//! - claude takes the **body**, through `--append-system-prompt`. It is the only true
//!   append, and the only one where juancode supplies the prose.
//! - codex takes the **name**, through `--profile <name>`, which layers
//!   `$CODEX_HOME/<name>.config.toml` — a file the user wrote.
//! - opencode takes the **name**, through `--agent <name>`, naming an agent the user
//!   defined in their own config.
//!
//! That asymmetry is what keeps this inside the prime directive: for the two CLIs that
//! own the concept we select what the user already configured, and we never author a
//! CLI's config. Only claude, which has no such concept, gets prose from us — through
//! a flag built for exactly that.

use std::path::PathBuf;

use crate::model::ProviderId;

/// A preset resolved before any argv is built, so `start_args` stays a pure function
/// of its inputs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Preset {
    /// The name the client asked for, already validated by [`PresetStore`].
    pub name: String,
    /// The prose behind the name. `Some` only for the provider that needs it
    /// (claude); the other two are selecting a definition the user owns, so there is
    /// nothing for us to read.
    pub body: Option<String>,
}

/// Why a preset name could not become a [`Preset`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PresetError {
    BadName(String),
    NoBody {
        name: String,
        path: String,
    },
    TooLarge {
        name: String,
        bytes: usize,
        limit: usize,
    },
}

impl std::fmt::Display for PresetError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BadName(name) => write!(
                f,
                "preset \"{name}\" is not allowed: use letters, digits, '-' or '_', \
                 starting with a letter or digit, at most {} characters",
                PresetStore::NAME_LIMIT
            ),
            Self::NoBody { name, path } => {
                write!(
                    f,
                    "preset \"{name}\" has no body: expected a file at {path}"
                )
            }
            Self::TooLarge { name, bytes, limit } => {
                write!(
                    f,
                    "preset \"{name}\" is {bytes} bytes, over the {limit}-byte limit"
                )
            }
        }
    }
}

impl std::error::Error for PresetError {}

/// Resolves a `create.preset` name against juancode's own preset directory.
///
/// The directory is ours, not a CLI's: `~/.juancode/presets`, or `<data dir>/presets`
/// when the data dir is relocated, overridable outright with `JUANCODE_PRESET_DIR`.
/// Nothing here reads or writes a provider's config.
pub struct PresetStore;

impl PresetStore {
    /// Bodies ride in the CLI's argv, which is bounded (`ARG_MAX`). A prompt this long
    /// is a file the user meant to pass some other way, and a clear refusal beats an
    /// `E2BIG` from `execve` that surfaces as a session that would not start.
    pub const BODY_LIMIT: usize = 32 * 1024;

    /// Names go into both a filesystem path and an argv slot, so the allowlist is the
    /// validation rather than escaping. It rejects `..` and `/` (traversal out of the
    /// preset directory) and a leading `-` (which the CLI would read as a flag).
    pub const NAME_LIMIT: usize = 64;

    /// An empty variable counts as unset, so an exported-but-blank knob cannot point
    /// the store at the process's own working directory.
    fn env_value(key: &str) -> Option<String> {
        std::env::var(key).ok().filter(|v| !v.is_empty())
    }

    /// Where preset bodies live. `JUANCODED_DATA_DIR` before `JUANCODE_DATA_DIR` for
    /// the same reason `db_path` does it: the daemon's own knob wins, but a harness
    /// that only knows the Swift core's variable still isolates us.
    pub fn directory() -> PathBuf {
        if let Some(dir) = Self::env_value("JUANCODE_PRESET_DIR") {
            return PathBuf::from(dir);
        }
        if let Some(dir) =
            Self::env_value("JUANCODED_DATA_DIR").or_else(|| Self::env_value("JUANCODE_DATA_DIR"))
        {
            return PathBuf::from(dir).join("presets");
        }
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
        PathBuf::from(home).join(".juancode").join("presets")
    }

    pub fn path_for(name: &str) -> PathBuf {
        Self::directory().join(format!("{name}.md"))
    }

    pub fn is_valid_name(name: &str) -> bool {
        let mut chars = name.chars();
        let Some(first) = chars.next() else {
            return false;
        };
        if name.chars().count() > Self::NAME_LIMIT {
            return false;
        }
        if !first.is_ascii_alphanumeric() {
            return false;
        }
        chars.all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    }

    /// Resolve a name for one provider, or refuse.
    ///
    /// Refusing rather than degrading to no preset on purpose: a preset the client
    /// asked for and the core quietly dropped is indistinguishable from one it
    /// applied, which is the same class of bug the `spawn-model` scenario exists to
    /// catch.
    pub fn resolve(name: &str, provider: ProviderId) -> Result<Preset, PresetError> {
        Self::resolve_in(&Self::directory(), name, provider)
    }

    /// [`resolve`](Self::resolve) against a directory named outright, which is how a
    /// test can be believed: the environment is process-global, so a test that moved
    /// `JUANCODE_PRESET_DIR` would be moving it for every other test in the binary.
    pub fn resolve_in(
        dir: &std::path::Path,
        name: &str,
        provider: ProviderId,
    ) -> Result<Preset, PresetError> {
        if !Self::is_valid_name(name) {
            return Err(PresetError::BadName(name.to_string()));
        }
        if !preset_needs_body(provider) {
            return Ok(Preset {
                name: name.to_string(),
                body: None,
            });
        }
        let file = dir.join(format!("{name}.md"));
        let path = file.to_string_lossy().to_string();
        let no_body = || PresetError::NoBody {
            name: name.to_string(),
            path: path.clone(),
        };
        let raw = std::fs::read_to_string(&file).map_err(|_| no_body())?;
        let body = raw.trim();
        if body.is_empty() {
            return Err(no_body());
        }
        let bytes = body.len();
        if bytes > Self::BODY_LIMIT {
            return Err(PresetError::TooLarge {
                name: name.to_string(),
                bytes,
                limit: Self::BODY_LIMIT,
            });
        }
        Ok(Preset {
            name: name.to_string(),
            body: Some(body.to_string()),
        })
    }
}

/// Whether this provider's mechanism needs the preset's prose rather than its name.
/// True only for claude: codex and opencode select a definition the user owns.
pub fn preset_needs_body(provider: ProviderId) -> bool {
    match provider {
        ProviderId::Claude => true,
        ProviderId::Codex | ProviderId::Opencode => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_allowlist_rejects_what_would_escape_a_path_or_read_as_a_flag() {
        assert!(PresetStore::is_valid_name("conformance"));
        assert!(PresetStore::is_valid_name("a"));
        assert!(PresetStore::is_valid_name("code-review_2"));
        assert!(!PresetStore::is_valid_name(""));
        assert!(!PresetStore::is_valid_name(".."));
        assert!(!PresetStore::is_valid_name("../etc/passwd"));
        assert!(!PresetStore::is_valid_name("a/b"));
        assert!(!PresetStore::is_valid_name("-flag"));
        assert!(!PresetStore::is_valid_name("_leading"));
        assert!(!PresetStore::is_valid_name("has space"));
        assert!(!PresetStore::is_valid_name(
            &"a".repeat(PresetStore::NAME_LIMIT + 1)
        ));
        assert!(PresetStore::is_valid_name(
            &"a".repeat(PresetStore::NAME_LIMIT)
        ));
    }

    #[test]
    fn only_claude_needs_the_body_behind_the_name() {
        assert!(preset_needs_body(ProviderId::Claude));
        assert!(!preset_needs_body(ProviderId::Codex));
        assert!(!preset_needs_body(ProviderId::Opencode));
    }

    #[test]
    fn a_name_the_allowlist_refuses_never_reaches_the_filesystem() {
        // Even for a provider that only needs the name: the name is an argv slot too.
        assert_eq!(
            PresetStore::resolve("../secrets", ProviderId::Codex),
            Err(PresetError::BadName("../secrets".into()))
        );
    }

    #[test]
    fn a_name_with_no_body_behind_it_is_refused_for_claude_and_fine_for_the_others() {
        let dir = std::env::temp_dir().join(format!("juancoded-preset-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("present.md"), "  BODY-MARKER\n").unwrap();
        std::fs::write(dir.join("blank.md"), "   \n\n").unwrap();

        assert_eq!(
            PresetStore::resolve_in(&dir, "present", ProviderId::Claude),
            Ok(Preset {
                name: "present".into(),
                // Trimmed, so a trailing newline never rides into the argv.
                body: Some("BODY-MARKER".into()),
            })
        );
        // The two that select a definition the user owns never read a file, so the
        // same missing name is not an error for them.
        assert_eq!(
            PresetStore::resolve_in(&dir, "missing", ProviderId::Codex),
            Ok(Preset {
                name: "missing".into(),
                body: None,
            })
        );
        assert!(matches!(
            PresetStore::resolve_in(&dir, "missing", ProviderId::Claude),
            Err(PresetError::NoBody { .. })
        ));
        // A file that exists but holds only whitespace is the same "no body": an
        // empty `--append-system-prompt` would be a preset applied in name only.
        assert!(matches!(
            PresetStore::resolve_in(&dir, "blank", ProviderId::Claude),
            Err(PresetError::NoBody { .. })
        ));

        std::fs::write(dir.join("huge.md"), "x".repeat(PresetStore::BODY_LIMIT + 1)).unwrap();
        assert!(matches!(
            PresetStore::resolve_in(&dir, "huge", ProviderId::Claude),
            Err(PresetError::TooLarge { .. })
        ));
        std::fs::remove_dir_all(&dir).ok();
    }
}
