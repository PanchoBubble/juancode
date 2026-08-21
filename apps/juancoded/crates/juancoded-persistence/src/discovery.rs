//! Post-spawn discovery of a provider's own conversation id.
//!
//! Claude takes the id we give it (`--session-id`), so a Claude session is resumable
//! the moment it starts. Codex and opencode have no such flag: they mint their own id
//! and write it into their own state, and the only way to learn it is to go and read
//! that state. This lives beside the store code because that is what it is: reading
//! somebody else's store, and one of the two is another tool's SQLite.
//!
//! Both readers are strictly read-only and both are pure lookups: one pass answers
//! `Some` or `None`, and the caller decides how long to keep asking. Neither creates a
//! file, and the opencode reader opens the database read-only so a live opencode
//! holding the WAL is never disturbed. We are a reader of its data, never a second
//! writer.

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
/// Codex writes its rollout file while it boots, so half a minute is generous.
/// opencode writes its `session` row when the FIRST message is sent, which can be
/// minutes after spawn, so its window matches the one past which a cwd match stops
/// being trustworthy anyway. Each pass is one indexed lookup, so waiting is cheap.
pub fn window(source: IdSource) -> (Duration, Duration) {
    let timeout = match source {
        IdSource::Pinned => Duration::ZERO,
        IdSource::CodexRollout => Duration::from_secs(30),
        IdSource::OpencodeDb => Duration::from_secs(15 * 60),
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

/// The newest rollout for `cwd` written at or after `since_ms`, by its own header.
///
/// Matching on cwd as well as time is what keeps a concurrent Codex in another
/// project from being handed to this session.
pub fn codex_scan_once(cwd: &str, since_ms: i64, root: &Path) -> Option<String> {
    let dirs = directory_variants(cwd);
    let floor = since_ms - CLOCK_SKEW_GRACE_MS;
    let mut best: Option<(String, i64)> = None;
    for (path, mtime_ms) in rollout_files(root) {
        if mtime_ms < floor {
            continue;
        }
        if best
            .as_ref()
            .is_some_and(|(_, best_ms)| mtime_ms <= *best_ms)
        {
            continue;
        }
        if let Some((id, header_cwd)) = codex_header(&path) {
            if dirs.iter().any(|d| d == &header_cwd) {
                best = Some((id, mtime_ms));
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
fn codex_header(path: &Path) -> Option<(String, String)> {
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
    Some((id, cwd))
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
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\",\"cwd\":\"{cwd}\"}}}}\n\
                 {{\"type\":\"turn\",\"payload\":{{}}}}\n"
            ),
        )
        .expect("write rollout");
        path
    }

    fn now_ms() -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock")
            .as_millis() as i64
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
        let since = now_ms() - 60_000;

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
        let since = now_ms() + 600_000;
        assert_eq!(codex_scan_once("/tmp/mine", since, &root), None);
        std::fs::remove_dir_all(&root).ok();
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
        // And opencode waits far longer than codex, because its row lands on the
        // first message rather than at boot.
        assert!(window(IdSource::OpencodeDb).0 > window(IdSource::CodexRollout).0);
    }
}
