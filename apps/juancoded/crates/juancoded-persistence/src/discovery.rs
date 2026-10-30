//! Post-spawn discovery of a provider's own conversation id.
//!
//! Claude takes the id we give it (`--session-id`), so a Claude session is resumable
//! the moment it starts. Codex, opencode and kimi have no such flag: they mint their
//! own id and write it into their own state, and the only way to learn it is to go and
//! read that state. This lives beside the store code because that is what it is:
//! reading somebody else's store — and one of the three is another tool's SQLite.
//!
//! All readers are strictly read-only and all are pure lookups: one pass answers
//! `Some` or `None`, and the caller decides how long to keep asking. Neither creates
//! a file, and the opencode reader opens the database read-only so a live opencode
//! holding the WAL is never disturbed. We are a reader of other tools' data, never a
//! second writer.

use std::path::{Path, PathBuf};
use std::time::Duration;

use juancoded_core::provider::IdSource;
use rusqlite::{Connection, OpenFlags};
use tracing::debug;

/// A CLI's clock and ours are not the same clock, and a file's mtime is rounded.
/// Anything written within this much of the spawn still counts as "after" it.
const CLOCK_SKEW_GRACE_MS: i64 = 2_000;

/// How long to keep looking, per source, and how often.
///
/// Codex can defer persisting its rollout until the first turn, minutes after boot.
/// opencode writes its `session` row when the FIRST message is sent, which can be
/// minutes after spawn, so its window matches the one past which a cwd match stops
/// being trustworthy anyway. Each pass is one indexed lookup, so waiting is cheap.
pub fn window(source: IdSource) -> (Duration, Duration) {
    let timeout = match source {
        IdSource::Pinned => Duration::ZERO,
        IdSource::CodexRollout => Duration::from_secs(15 * 60),
        IdSource::OpencodeDb => Duration::from_secs(15 * 60),
        IdSource::KimiIndex => Duration::from_secs(15 * 60),
    };
    (timeout, Duration::from_millis(1_500))
}

/// One pass for the id of a conversation started in `cwd` at or after `since_ms`.
pub fn scan_once(source: IdSource, cwd: &str, since_ms: i64) -> Option<String> {
    match source {
        // Nothing to find: we named it.
        IdSource::Pinned => None,
        IdSource::CodexRollout => codex_scan_once(cwd, since_ms, &codex_root()),
        IdSource::OpencodeDb => opencode_scan_once(cwd, since_ms, &opencode_db_path()),
        IdSource::KimiIndex => kimi_scan_once(cwd, since_ms, &kimi_home()),
    }
}

/// A directory and its symlink-resolved self. A CLI records whichever it was given,
/// and on a Mac `/tmp` and `/private/tmp` are the same place under two names.
fn directory_variants(cwd: &str) -> Vec<String> {
    let mut dirs = vec![cwd.to_string()];
    if let Ok(resolved) = std::fs::canonicalize(cwd) {
        let resolved = resolved.to_string_lossy().to_string();
        if resolved != cwd {
            dirs.push(resolved);
        }
    }
    dirs
}

// MARK: - codex

/// Where Codex keeps its rollouts: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
pub fn codex_root() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    PathBuf::from(home).join(".codex/sessions")
}

/// Match the rollout's immutable conversation timestamp to the spawn, never its
/// mtime: an older conversation in the same directory may still be receiving writes.
/// The file can land minutes later, but its header still records when Codex started.
pub fn codex_scan_once(cwd: &str, since_ms: i64, root: &Path) -> Option<String> {
    let dirs = directory_variants(cwd);
    let floor = since_ms - CLOCK_SKEW_GRACE_MS;
    let mut best: Option<(String, i64)> = None;
    for (path, mtime_ms) in rollout_files(root) {
        if mtime_ms < floor {
            continue;
        }
        if let Some((id, header_cwd, started_ms)) = codex_header(&path) {
            // Bound the startup interval so a later session cannot be adopted while
            // this one's rollout is still buffered. Prefer the closest start.
            let distance = (started_ms - since_ms).abs();
            if started_ms < floor || started_ms > since_ms + 30_000 {
                continue;
            }
            if dirs.iter().any(|d| d == &header_cwd)
                && best.as_ref().is_none_or(|(_, d)| distance < *d)
            {
                best = Some((id, distance));
            }
        }
    }
    best.map(|(id, _)| id)
}

/// Every `rollout-*.jsonl` under `root`, with its mtime in epoch millis. The tree is
/// three levels of date directories, so a plain recursive walk is the whole of it.
fn rollout_files(root: &Path) -> Vec<(PathBuf, i64)> {
    let mut found = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(meta) = entry.metadata() else { continue };
            if meta.is_dir() {
                stack.push(path);
                continue;
            }
            let name = entry.file_name().to_string_lossy().to_string();
            if !name.starts_with("rollout-") || !name.ends_with(".jsonl") {
                continue;
            }
            let mtime_ms = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as i64);
            if let Some(mtime_ms) = mtime_ms {
                found.push((path, mtime_ms));
            }
        }
    }
    found
}

/// The id and cwd out of a rollout's first line, which is its `session_meta`.
fn codex_header(path: &Path) -> Option<(String, String, i64)> {
    use std::io::{BufRead, BufReader};
    let file = std::fs::File::open(path).ok()?;
    // The header is the first line, and a rollout grows without bound, so read one
    // line rather than the file.
    let mut line = String::new();
    BufReader::new(file).read_line(&mut line).ok()?;
    let value: serde_json::Value = serde_json::from_str(line.trim()).ok()?;
    if value.get("type").and_then(|t| t.as_str()) != Some("session_meta") {
        return None;
    }
    let payload = value.get("payload")?;
    let id = payload.get("id")?.as_str()?.to_string();
    let cwd = payload.get("cwd")?.as_str()?.to_string();
    let started_ms = juancoded_transcripts::time::epoch_ms(payload.get("timestamp")?.as_str()?)?;
    Some((id, cwd, started_ms))
}

// MARK: - opencode

/// opencode's data directory: `$XDG_DATA_HOME/opencode`, else `~/.local/share/opencode`
/// (the same resolution opencode's own `Global.Path.data` does).
fn opencode_data_dir() -> PathBuf {
    match std::env::var("XDG_DATA_HOME") {
        Ok(xdg) if !xdg.is_empty() => PathBuf::from(xdg).join("opencode"),
        _ => PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".local/share/opencode"),
    }
}

/// The opencode database to read.
///
/// `JUANCODE_OPENCODE_DB` wins (a test points it at a fixture), then opencode's own
/// `OPENCODE_DB` (absolute, or relative to the data dir, its rule and not ours). With
/// neither set it is `opencode.db`, and if that is missing the newest `opencode*.db`
/// in the data dir, which is where a non-release channel puts its own file.
pub fn opencode_db_path() -> PathBuf {
    if let Ok(ours) = std::env::var("JUANCODE_OPENCODE_DB") {
        if !ours.is_empty() {
            return PathBuf::from(ours);
        }
    }
    let dir = opencode_data_dir();
    if let Ok(theirs) = std::env::var("OPENCODE_DB") {
        if !theirs.is_empty() {
            return if theirs.starts_with('/') {
                PathBuf::from(theirs)
            } else {
                dir.join(theirs)
            };
        }
    }
    let release = dir.join("opencode.db");
    if release.exists() {
        return release;
    }
    newest_opencode_db(&dir).unwrap_or(release)
}

fn newest_opencode_db(dir: &Path) -> Option<PathBuf> {
    let entries = std::fs::read_dir(dir).ok()?;
    entries
        .flatten()
        .filter(|e| {
            let name = e.file_name().to_string_lossy().to_string();
            name.starts_with("opencode") && name.ends_with(".db")
        })
        .filter_map(|e| {
            let mtime = e.metadata().ok()?.modified().ok()?;
            Some((e.path(), mtime))
        })
        .max_by_key(|(_, mtime)| *mtime)
        .map(|(path, _)| path)
}

/// The newest top-level conversation opencode recorded in `cwd` at or after
/// `since_ms`. `parent_id IS NULL` keeps a sub-agent's conversation from being
/// mistaken for the session's own.
pub fn opencode_scan_once(cwd: &str, since_ms: i64, db: &Path) -> Option<String> {
    if !db.exists() {
        return None;
    }
    let conn = Connection::open_with_flags(db, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .inspect_err(|e| debug!(error = %e, db = %db.display(), "opencode db unreadable"))
        .ok()?;
    conn.busy_handler(None).ok();
    let _ = conn.busy_timeout(Duration::from_millis(250));
    let dirs = directory_variants(cwd);
    let placeholders = (1..=dirs.len())
        .map(|i| format!("?{i}"))
        .collect::<Vec<_>>()
        .join(", ");
    let sql = format!(
        "SELECT id FROM session \
         WHERE directory IN ({placeholders}) AND parent_id IS NULL AND time_created >= ?{} \
         ORDER BY time_created DESC LIMIT 1",
        dirs.len() + 1
    );
    let mut params: Vec<Box<dyn rusqlite::ToSql>> = dirs
        .iter()
        .map(|d| Box::new(d.clone()) as Box<dyn rusqlite::ToSql>)
        .collect();
    params.push(Box::new(since_ms - CLOCK_SKEW_GRACE_MS));
    let refs: Vec<&dyn rusqlite::ToSql> = params.iter().map(|p| p.as_ref()).collect();
    let mut stmt = conn.prepare(&sql).ok()?;
    stmt.query_row(refs.as_slice(), |row| row.get::<_, String>(0))
        .ok()
}

// MARK: - kimi

/// kimi's data home: `$KIMI_CODE_HOME`, else `~/.kimi-code` — the root kimi's own
/// docs give for config, sessions and the session index alike.
pub fn kimi_home() -> PathBuf {
    match std::env::var("KIMI_CODE_HOME") {
        Ok(dir) if !dir.is_empty() => PathBuf::from(dir),
        _ => PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".kimi-code"),
    }
}

/// One `{sessionId, sessionDir, workDir}` mirror line. The index carries no
/// timestamps — the clock lives in the session's own `state.json` — so the line is
/// a directory hint and a cwd claim, nothing more.
struct KimiIndexLine {
    session_id: String,
    session_dir: String,
    work_dir: String,
}

/// The fields discovery needs out of a session's `state.json`.
struct KimiState {
    cwd: Option<String>,
    /// `createdAt` in epoch millis, 0 when absent or unparseable — kimi's own
    /// reader takes a number or an ISO string and reports garbage as 0, and a 0
    /// can never fall inside a real spawn window.
    created_ms: i64,
    archived: bool,
    /// A child session (kimi's own subagent) names its parent in `custom`; only
    /// conversations that stand on their own are candidates.
    child: bool,
}

impl KimiState {
    fn from_json(value: &serde_json::Value) -> Option<Self> {
        let str_field = |meta: &serde_json::Value, key: &str| -> Option<String> {
            meta.get(key)
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .map(str::to_string)
        };
        let cwd = str_field(value, "cwd")
            .or_else(|| str_field(value, "workDir"))
            .or_else(|| {
                value
                    .get("custom")
                    .filter(|c| c.is_object())
                    .and_then(|c| str_field(c, "cwd"))
            });
        Some(KimiState {
            cwd,
            created_ms: match value.get("createdAt") {
                Some(serde_json::Value::Number(n)) => n
                    .as_i64()
                    .or_else(|| n.as_f64().map(|f| f as i64))
                    .unwrap_or(0),
                Some(serde_json::Value::String(s)) => {
                    juancoded_transcripts::time::epoch_ms(s).unwrap_or(0)
                }
                _ => 0,
            },
            archived: value.get("archived").and_then(|v| v.as_bool()) == Some(true),
            child: value
                .get("custom")
                .filter(|c| c.is_object())
                .and_then(|c| str_field(c, "parent_session_id"))
                .is_some(),
        })
    }
}

/// Read a session's `state.json` out of its directory relative to kimi's home, in
/// either layout kimi ships (`<dir>/state.json`, legacy `<dir>/session-meta/state.json`).
fn kimi_state(root: &Path, session_dir: &str) -> Option<KimiState> {
    let state_in = |paths: &[PathBuf]| -> Option<KimiState> {
        paths
            .iter()
            .filter_map(|p| std::fs::read_to_string(p).ok())
            .find_map(|raw| serde_json::from_str::<serde_json::Value>(&raw).ok())
            .and_then(|value| KimiState::from_json(&value))
    };
    let dir = if Path::new(session_dir).is_absolute() {
        PathBuf::from(session_dir)
    } else {
        root.join(session_dir)
    };
    state_in(&[dir.join("state.json"), dir.join("session-meta").join("state.json")])
}

fn kimi_index_lines(root: &Path) -> Vec<KimiIndexLine> {
    use std::io::{BufRead, BufReader};
    let Ok(file) = std::fs::File::open(root.join("session_index.jsonl")) else {
        return Vec::new();
    };
    BufReader::new(file)
        .lines()
        .map_while(|line| line.ok())
        .filter_map(|line| {
            let value: serde_json::Value = serde_json::from_str(line.trim()).ok()?;
            Some(KimiIndexLine {
                session_id: value.get("sessionId")?.as_str()?.to_string(),
                session_dir: value.get("sessionDir")?.as_str()?.to_string(),
                work_dir: value.get("workDir")?.as_str()?.to_string(),
            })
        })
        .collect()
}

/// The newest top-level, un-archived kimi conversation kimi recorded in `cwd` at or
/// after `since_ms`.
///
/// The index is consulted first because it answers in one read, but it is a mirror:
/// kimi's own reconcile can lag a startup by a little, so a miss falls back to
/// walking the session tree, stat-gated so only state files written since the spawn
/// are opened. Either way the decision is the session's own `createdAt` versus the
/// spawn clock, never an mtime alone.
/// The newest top-level, un-archived kimi conversation kimi recorded in `cwd` at or
/// after `since_ms`.
///
/// The index is consulted first because it answers in one read, but it is a mirror:
/// kimi's own reconcile can lag a startup by a little, so a miss falls back to
/// walking the session tree, stat-gated so only state files written since the spawn
/// are opened. Either way the decision is the session's own `createdAt` versus the
/// spawn clock, never an mtime alone.
pub fn kimi_scan_once(cwd: &str, since_ms: i64, root: &Path) -> Option<String> {
    let dirs = directory_variants(cwd);
    let floor = since_ms - CLOCK_SKEW_GRACE_MS;
    let ceiling = since_ms + 30_000;
    // (id, |createdAt - spawn|) for every conversation in the window.
    let mut candidates: Vec<(String, i64)> = Vec::new();

    for line in kimi_index_lines(root) {
        if !dirs.iter().any(|d| *d == line.work_dir) {
            continue;
        }
        let Some(state) = kimi_state(root, &line.session_dir) else {
            continue;
        };
        if state.archived || state.child {
            continue;
        }
        if state.created_ms >= floor && state.created_ms <= ceiling {
            candidates.push((line.session_id, (state.created_ms - since_ms).abs()));
        }
    }
    if candidates.is_empty() {
        for found in kimi_session_files(root) {
            if found.mtime_ms < floor {
                continue;
            }
            let Ok(raw) = std::fs::read_to_string(&found.path) else {
                continue;
            };
            let Some(state) = serde_json::from_str::<serde_json::Value>(&raw)
                .ok()
                .as_ref()
                .and_then(KimiState::from_json)
            else {
                continue;
            };
            if state.archived || state.child {
                continue;
            }
            if !state.cwd.is_some_and(|c| dirs.iter().any(|d| *d == c)) {
                continue;
            }
            if state.created_ms >= floor && state.created_ms <= ceiling {
                // The id is the folder's name, confirmed live by the state file's
                // cwd and created clock.
                candidates.push((found.session_id, (state.created_ms - since_ms).abs()));
            }
        }
    }
    candidates
        .into_iter()
        .min_by_key(|(_, distance)| *distance)
        .map(|(id, _)| id)
}

/// A `sessions/<workdirKey>/<id>/` whose state file exists, ready to be read.
#[derive(Debug)]
struct KimiSessionFile {
    path: PathBuf,
    /// The `<id>` folder's name — kimi's convention for where it keeps a
    /// conversation, not a field inside `state.json`.
    session_id: String,
    /// mtime of the state file, epoch millis, so the walk can skip everything
    /// older than the spawn without reading a file.
    mtime_ms: i64,
}

fn kimi_session_files(root: &Path) -> Vec<KimiSessionFile> {
    let sessions = root.join("sessions");
    let Ok(workspaces) = std::fs::read_dir(&sessions) else {
        return Vec::new();
    };
    let mut found = Vec::new();
    for workspace in workspaces.flatten().filter(|w| w.path().is_dir()) {
        let Ok(ids) = std::fs::read_dir(workspace.path()) else {
            continue;
        };
        for id_dir in ids.flatten().filter(|s| s.path().is_dir()) {
            let dir = workspace.path().join(id_dir.file_name());
            // Either of the two layouts kimi ships or has shipped.
            let Some(state_path) = [
                dir.join("state.json"),
                dir.join("session-meta").join("state.json"),
            ]
            .into_iter()
            .find(|p| p.exists())
            else {
                continue;
            };
            let Ok(mtime) = state_path.metadata().and_then(|m| m.modified()) else {
                continue;
            };
            let Ok(since_epoch) = mtime.duration_since(std::time::UNIX_EPOCH) else {
                continue;
            };
            found.push(KimiSessionFile {
                path: state_path,
                session_id: id_dir.file_name().to_string_lossy().to_string(),
                mtime_ms: since_epoch.as_millis() as i64,
            });
        }
    }
    found
}



#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(label: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "juancoded-discovery-{label}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).expect("scratch dir");
        dir
    }

    fn write_rollout(root: &Path, day: &str, name: &str, id: &str, cwd: &str) -> PathBuf {
        let dir = root.join(day);
        std::fs::create_dir_all(&dir).expect("rollout dir");
        let path = dir.join(name);
        std::fs::write(
            &path,
            format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\",\"cwd\":\"{cwd}\",\"timestamp\":\"2026-10-29T11:00:00.000Z\"}}}}\n\
                 {{\"type\":\"turn\",\"payload\":{{}}}}\n"
            ),
        )
        .expect("write rollout");
        path
    }

    #[test]
    fn a_codex_rollout_is_matched_on_its_own_cwd_not_just_its_age() {
        let root = scratch("codex");
        write_rollout(
            &root,
            "2026/08/21",
            "rollout-a.jsonl",
            "id-here",
            "/tmp/mine",
        );
        write_rollout(
            &root,
            "2026/08/21",
            "rollout-b.jsonl",
            "id-elsewhere",
            "/tmp/somebody-else",
        );
        let since = juancoded_transcripts::time::epoch_ms("2026-10-29T11:00:00.000Z").unwrap();

        assert_eq!(
            codex_scan_once("/tmp/mine", since, &root).as_deref(),
            Some("id-here")
        );
        // A conversation in another project is not ours, however recent it is.
        assert_eq!(codex_scan_once("/tmp/nobody", since, &root), None);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_rollout_written_before_the_spawn_is_somebody_elses_conversation() {
        let root = scratch("codex-age");
        write_rollout(
            &root,
            "2026/08/21",
            "rollout-old.jsonl",
            "old-id",
            "/tmp/mine",
        );
        // The file was written now, so a spawn well in the future cannot own it.
        let since = juancoded_transcripts::time::epoch_ms("2026-10-29T11:10:00.000Z").unwrap();
        assert_eq!(codex_scan_once("/tmp/mine", since, &root), None);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn delayed_rollout_matches_start_time_instead_of_recent_writes_to_other_sessions() {
        let root = scratch("codex-delayed");
        let own = write_rollout(&root, "2026/10/29", "rollout-own.jsonl", "own", "/tmp/mine");
        let other = write_rollout(
            &root,
            "2026/10/29",
            "rollout-other.jsonl",
            "other",
            "/tmp/mine",
        );
        let since = juancoded_transcripts::time::epoch_ms("2026-10-29T11:00:00.000Z").unwrap();
        // A previous conversation is being modified now, after our file appeared.
        let body = std::fs::read_to_string(&other)
            .unwrap()
            .replace("11:00:00", "10:59:00");
        std::fs::write(&other, body).unwrap();
        assert_eq!(
            codex_scan_once("/tmp/mine", since, &root).as_deref(),
            Some("own")
        );
        std::fs::remove_file(&own).unwrap();
        assert_eq!(codex_scan_once("/tmp/mine", since, &root), None);
        // A later session must not be mistaken for a buffered rollout either.
        let body = std::fs::read_to_string(&other)
            .unwrap()
            .replace("10:59:00", "11:04:00");
        std::fs::write(&other, body).unwrap();
        assert_eq!(codex_scan_once("/tmp/mine", since, &root), None);
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn a_missing_codex_root_is_no_answer_rather_than_an_error() {
        assert_eq!(
            codex_scan_once("/tmp", 0, Path::new("/nope/no/sessions/here")),
            None
        );
    }

    #[test]
    fn the_newest_top_level_opencode_conversation_in_the_directory_wins() {
        let dir = scratch("opencode");
        let db = dir.join("opencode.db");
        {
            let conn = Connection::open(&db).expect("fixture db");
            conn.execute_batch(
                "CREATE TABLE session (id TEXT, directory TEXT, parent_id TEXT, time_created INTEGER);
                 INSERT INTO session VALUES ('older', '/tmp/mine', NULL, 1000);
                 INSERT INTO session VALUES ('newest', '/tmp/mine', NULL, 3000);
                 INSERT INTO session VALUES ('a-subagent', '/tmp/mine', 'newest', 4000);
                 INSERT INTO session VALUES ('elsewhere', '/tmp/other', NULL, 5000);",
            )
            .expect("fixture schema");
        }

        assert_eq!(
            opencode_scan_once("/tmp/mine", 0, &db).as_deref(),
            Some("newest")
        );
        // A sub-agent's conversation is not the session's, even though it is newer.
        assert_ne!(
            opencode_scan_once("/tmp/mine", 0, &db).as_deref(),
            Some("a-subagent")
        );
        // Nothing in this directory after that time.
        assert_eq!(opencode_scan_once("/tmp/mine", 10_000, &db), None);
        assert_eq!(opencode_scan_once("/tmp/nobody", 0, &db), None);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_missing_opencode_database_is_no_answer_rather_than_a_created_file() {
        let path = std::env::temp_dir().join("juancoded-discovery-absent.db");
        std::fs::remove_file(&path).ok();
        assert_eq!(opencode_scan_once("/tmp", 0, &path), None);
        assert!(
            !path.exists(),
            "reading somebody else's store must never create it"
        );
    }

    #[test]
    fn a_pinned_provider_has_nothing_to_discover() {
        assert_eq!(scan_once(IdSource::Pinned, "/tmp", 0), None);
        assert_eq!(window(IdSource::Pinned).0, Duration::ZERO);
        // All three unpinned providers may defer their first durable write until a
        // turn, so each gets the same generous window.
        assert!(window(IdSource::CodexRollout).0 >= Duration::from_secs(15 * 60));
        assert!(window(IdSource::KimiIndex).0 >= Duration::from_secs(15 * 60));
    }

    // MARK: kimi fixtures

    /// A kimi home with one session's mirror line and state file in place. Sessions
    /// live under a workdir-key folder that decodes to nothing we can match on, so
    /// the tests use arbitrary key names — as kimi does.
    fn kimi_fixture(label: &str) -> PathBuf {
        let root = scratch(label);
        std::fs::create_dir_all(root.join("sessions/ws-key/ses_kimi"))
            .expect("session dir");
        std::fs::create_dir_all(root.join("sessions/other/ses_elsewhere"))
            .expect("other session dir");
        let index = concat!(
            r#"{"sessionId":"ses_kimi","sessionDir":"sessions/ws-key/ses_kimi","workDir":"/tmp/mine"}"#,
            "\n",
            r#"{"sessionId":"ses_elsewhere","sessionDir":"sessions/other/ses_elsewhere","workDir":"/tmp/somebody-else"}"#,
            "\n",
        );
        std::fs::write(root.join("session_index.jsonl"), index).expect("index");
        std::fs::write(
            root.join("sessions/ws-key/ses_kimi/state.json"),
            r#"{"title":"Our session","createdAt":2000,"updatedAt":2000,"cwd":"/tmp/mine","custom":{}}"#,
        )
        .expect("state");
        std::fs::write(
            root.join("sessions/other/ses_elsewhere/state.json"),
            r#"{"createdAt":1500,"cwd":"/tmp/somebody-else"}"#,
        )
        .expect("other state");
        root
    }

    #[test]
    fn a_kimi_index_line_answers_when_the_state_file_confirms_the_cwd_and_clock() {
        let root = kimi_fixture("kimi-index");
        // Inside the spawn window, closer to the spawn clock than the other
        // workspace's session.
        assert_eq!(
            kimi_scan_once("/tmp/mine", 2_000, &root).as_deref(),
            Some("ses_kimi")
        );
        // A different directory is not ours, however recent it is.
        assert_eq!(kimi_scan_once("/tmp/nobody", 2_000, &root), None);
        // Before the spawn floor is somebody else's conversation.
        assert_eq!(kimi_scan_once("/tmp/mine", 8_000, &root), None);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_lagging_kimi_mirror_falls_back_to_the_session_tree() {
        let root = kimi_fixture("kimi-fallback");
        // A mirror that has not caught up with the fresh session yet.
        std::fs::write(root.join("session_index.jsonl"), "").expect("empty index");
        // The state file's mtime is "now", well past the spawn, so the prefilter
        // lets it through and the state's own createdAt answers.
        assert_eq!(
            kimi_scan_once("/tmp/mine", 2_000, &root).as_deref(),
            Some("ses_kimi")
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_kimi_child_session_is_not_a_conversation_to_adopt() {
        let root = kimi_fixture("kimi-child");
        // The mirror is missing, so the walk sees only the files; even through it,
        // a subagent's session must never be mistaken for the session's own.
        std::fs::write(root.join("session_index.jsonl"), "").expect("empty index");
        std::fs::write(
            root.join("sessions/ws-key/ses_kimi/state.json"),
            concat!(
                r#"{"createdAt":2000,"cwd":"/tmp/mine","custom":{"parent_session_id":"ses_parent","child_session_kind":"child"}}"#,
                "\n"
            ),
        )
        .expect("child state");
        assert_eq!(kimi_scan_once("/tmp/mine", 2_000, &root), None);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn an_archived_kimi_session_stays_out_of_the_answer() {
        let root = kimi_fixture("kimi-archived");
        let body = std::fs::read_to_string(root.join("sessions/ws-key/ses_kimi/state.json"))
            .unwrap()
            .replace("2000", "2000,\"archived\":true");
        std::fs::write(root.join("sessions/ws-key/ses_kimi/state.json"), body).unwrap();
        assert_eq!(kimi_scan_once("/tmp/mine", 2_000, &root), None);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_missing_kimi_home_is_no_answer_rather_than_an_error() {
        assert_eq!(
            kimi_scan_once("/tmp", 0, Path::new("/nope/no/kimi/here")),
            None
        );
    }

    #[test]
    fn a_kimi_state_may_hide_an_iso_created_clock_or_bear_no_cwd_at_all() {
        // ISO strings and the legacy session-meta layout both parse.
        let root = scratch("kimi-iso");
        std::fs::create_dir_all(root.join("sessions/k/ses_1/s")).expect("dir");
        std::fs::write(
            root.join("session_index.jsonl"),
            r#"{"sessionId":"ses_1","sessionDir":"sessions/k/ses_1","workDir":"/tmp/mine"}"#,
        )
        .expect("index");
        std::fs::write(
            root.join("sessions/k/ses_1/state.json"),
            r#"{"createdAt":"1970-01-01T00:00:02.000Z"}"#, // no cwd — index still owns the claim
        )
        .expect("iso state");
        assert_eq!(
            kimi_scan_once("/tmp/mine", 2_000, &root).as_deref(),
            Some("ses_1")
        );
        std::fs::remove_dir_all(&root).ok();
    }
}
