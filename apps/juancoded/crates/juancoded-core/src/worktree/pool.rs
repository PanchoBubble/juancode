//! Recycling a deleted session's worktree for the next one, instead of cutting a new
//! tree every time.
//!
//! `git worktree add` is ~300ms of every isolated start here, and a fresh tree starts
//! with no build caches, so the agent's first `cargo`/`swift build` is a cold one too.
//! A pooled tree keeps both: its checkout only moves by the diff to the new base, and
//! its ignored files (`target/`, `.build/`) are still there.
//!
//! Pooled trees live at `<repo>-worktrees/slot-NN` and never move, because cargo and
//! SwiftPM bake absolute paths into their caches and a renamed tree would rebuild
//! from scratch. The session's name rides on the branch, `juancode/<name>`.
//!
//! Membership is a stamp file in the tree's git admin dir (`.git/worktrees/<id>/`),
//! written on park and removed before a take. A slot without a stamp belongs to a
//! session, live or exited, and is never handed out. The stamp lives outside the work
//! tree so it can never be committed, and it goes with the admin dir when anything
//! (the sweeper, a person) removes the tree.

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use super::{
    base_ref, git, link_node_modules, remove, repo_root, safe_name, siblings_dir, CreateStages,
    CreatedWorktree, WorktreeError,
};

/// Idle trees kept per repo when nothing is configured.
pub const DEFAULT_MAX_IDLE_PER_REPO: usize = 20;

const STAMP: &str = "juancode-parked";
const SLOT_PREFIX: &str = "slot-";

/// Serialises take, park and eviction within this process: two creates must not be
/// handed the same slot, and an eviction must not remove the tree a take just claimed.
static POOL_LOCK: Mutex<()> = Mutex::new(());

#[derive(Debug, Clone, Default, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct PoolConfig {
    #[serde(default)]
    max_idle_per_repo: Option<usize>,
}

/// `worktree-pool.json` beside the daemon's store, or `JUANCODE_WORKTREE_POOL_CONFIG`.
pub fn config_path() -> PathBuf {
    if let Some(path) = std::env::var("JUANCODE_WORKTREE_POOL_CONFIG")
        .ok()
        .filter(|v| !v.is_empty())
    {
        return PathBuf::from(path);
    }
    crate::notify::daemon_data_dir().join("worktree-pool.json")
}

/// How many idle trees a repo may keep; `0` turns pooling off.
///
/// Read on every call, like `notify.json`, so changing it in Settings never needs a
/// daemon restart (which would end every live session). A missing or malformed file
/// is the default.
pub fn max_idle_per_repo() -> usize {
    max_idle_per_repo_at(&config_path())
}

pub fn max_idle_per_repo_at(path: &Path) -> usize {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|raw| serde_json::from_str::<PoolConfig>(&raw).ok())
        .and_then(|c| c.max_idle_per_repo)
        .unwrap_or(DEFAULT_MAX_IDLE_PER_REPO)
}

/// What a pooled create needs to know about the rest of the daemon.
pub struct Pool<'a> {
    pub max_idle: usize,
    /// Whether some session row still records this path as its tree. A stamp says a
    /// slot is idle; this is the second opinion, for a daemon that died mid-take.
    pub in_use: &'a dyn Fn(&str) -> bool,
}

/// Whether `path` is a pool slot rather than a tree named after its session.
pub fn is_slot(path: &str) -> bool {
    slot_number(Path::new(path)).is_some()
        && Path::new(path)
            .parent()
            .and_then(|p| p.file_name())
            .is_some_and(|n| n.to_string_lossy().ends_with("-worktrees"))
}

fn slot_number(path: &Path) -> Option<u32> {
    path.file_name()?
        .to_str()?
        .strip_prefix(SLOT_PREFIX)?
        .parse()
        .ok()
}

/// The tree's git admin dir, read from its `.git` file so no git has to run.
fn admin_dir(tree: &Path) -> Option<PathBuf> {
    let pointer = std::fs::read_to_string(tree.join(".git")).ok()?;
    let dir = pointer.trim().strip_prefix("gitdir:")?.trim();
    let dir = PathBuf::from(dir);
    dir.is_dir().then_some(dir)
}

fn parked_at(tree: &Path) -> Option<u64> {
    let raw = std::fs::read_to_string(admin_dir(tree)?.join(STAMP)).ok()?;
    raw.trim().parse().ok()
}

fn stamp(tree: &Path) -> bool {
    let Some(dir) = admin_dir(tree) else {
        return false;
    };
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    std::fs::write(dir.join(STAMP), now.to_string()).is_ok()
}

fn unstamp(tree: &Path) -> bool {
    admin_dir(tree).is_some_and(|dir| std::fs::remove_file(dir.join(STAMP)).is_ok())
}

fn slots(worktrees_dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(worktrees_dir) else {
        return Vec::new();
    };
    entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| slot_number(p).is_some() && p.is_dir())
        .collect()
}

/// Idle slots, most recently parked first.
fn idle_slots(worktrees_dir: &Path) -> Vec<(PathBuf, u64)> {
    let mut idle: Vec<_> = slots(worktrees_dir)
        .into_iter()
        .filter_map(|p| parked_at(&p).map(|t| (p, t)))
        .collect();
    idle.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| b.0.cmp(&a.0)));
    idle
}

fn next_free_slot(worktrees_dir: &Path) -> PathBuf {
    let taken: std::collections::HashSet<u32> = std::fs::read_dir(worktrees_dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| slot_number(&e.path()))
        .collect();
    let n = (1..).find(|n| !taken.contains(n)).unwrap_or(1);
    worktrees_dir.join(format!("{SLOT_PREFIX}{n:02}"))
}

/// [`super::create_timed`], taking an idle slot when there is one and cutting a new
/// slot when there is not. `max_idle == 0` is the unpooled create, named paths and all.
pub fn create_timed(
    repo_cwd: &str,
    name: &str,
    pool: &Pool<'_>,
) -> Result<(CreatedWorktree, CreateStages), WorktreeError> {
    if pool.max_idle == 0 {
        return super::create_timed(repo_cwd, name);
    }
    if !safe_name(name) {
        return Err(WorktreeError(format!(
            "\"{name}\" is not a usable worktree name: letters, digits, -, _ and . only."
        )));
    }
    let mut stages = CreateStages::default();
    let step = std::time::Instant::now();
    let root = repo_root(repo_cwd).ok_or_else(|| {
        WorktreeError("Not a git repository — can't isolate this session in a worktree.".into())
    })?;
    stages.repo_root_ms = step.elapsed().as_secs_f64() * 1000.0;
    let branch = format!("juancode/{name}");
    let worktrees_dir = siblings_dir(&root);
    let _ = std::fs::create_dir_all(&worktrees_dir);

    let step = std::time::Instant::now();
    let base = base_ref(repo_cwd);
    stages.base_ref_ms = step.elapsed().as_secs_f64() * 1000.0;

    let step = std::time::Instant::now();
    let reused = {
        let _guard = POOL_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        idle_slots(&worktrees_dir)
            .into_iter()
            .map(|(p, _)| p)
            .find(|p| !(pool.in_use)(&p.to_string_lossy()) && unstamp(p))
    };
    let dir = match reused {
        Some(slot) => {
            let path = slot.to_string_lossy().to_string();
            let mut args = vec!["switch", "--no-track", "--quiet", "-c", &branch];
            if let Some(base) = base.as_deref() {
                args.push(base);
            }
            if let Err(why) = run_git(&path, &args) {
                // Nothing about the slot changed, so it goes back to the pool.
                stamp(&slot);
                return Err(WorktreeError(format!("Failed to create worktree: {why}")));
            }
            stages.reused_slot = true;
            slot
        }
        None => {
            let dir = {
                let _guard = POOL_LOCK.lock().unwrap_or_else(|e| e.into_inner());
                let dir = next_free_slot(&worktrees_dir);
                // Held until `worktree add` creates it, so a concurrent create picks
                // the next number.
                let _ = std::fs::create_dir(&dir);
                dir
            };
            let path = dir.to_string_lossy().to_string();
            let mut args = vec!["worktree", "add", "--no-track", "-b", &branch, &path];
            if let Some(base) = base.as_deref() {
                args.push(base);
            }
            if let Err(why) = run_git(repo_cwd, &args) {
                let _ = std::fs::remove_dir(&dir);
                return Err(WorktreeError(format!("Failed to create worktree: {why}")));
            }
            dir
        }
    };
    stages.worktree_add_ms = step.elapsed().as_secs_f64() * 1000.0;
    let path = dir.to_string_lossy().to_string();
    let step = std::time::Instant::now();
    link_node_modules(&root, &path);
    stages.link_modules_ms = step.elapsed().as_secs_f64() * 1000.0;
    Ok((CreatedWorktree { path, branch }, stages))
}

/// What deleting a session did with its tree.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Released {
    /// Parked for the next session.
    Pooled,
    /// Removed, as an unpooled delete always does.
    Removed,
}

/// Give a deleted session's tree back: park it when it is a clean slot and the pool
/// is on, remove it otherwise. Either way the session no longer has a tree.
///
/// Only a clean tree is pooled. Uncommitted edits are removed with the tree exactly
/// as before, never carried into another agent's checkout.
pub fn release(worktree_path: &str, max_idle: usize) -> Result<Released, WorktreeError> {
    let tree = Path::new(worktree_path);
    if max_idle == 0 || !is_slot(worktree_path) || !tree.is_dir() || !park(tree) {
        return remove(worktree_path).map(|()| Released::Removed);
    }
    if let Some(dir) = tree.parent() {
        evict(dir, max_idle);
    }
    Ok(Released::Pooled)
}

fn park(tree: &Path) -> bool {
    let path = tree.to_string_lossy();
    let clean = git(&path, &["status", "--porcelain"]).is_some_and(|s| s.trim().is_empty());
    // Detached, so the old branch is free to be checked out anywhere else.
    clean && run_git(&path, &["switch", "--detach", "--quiet"]).is_ok() && {
        let _guard = POOL_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        stamp(tree)
    }
}

/// Remove the least recently parked slots until at most `max_idle` are idle.
fn evict(worktrees_dir: &Path, max_idle: usize) {
    let _guard = POOL_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    for (slot, _) in idle_slots(worktrees_dir).into_iter().skip(max_idle) {
        if unstamp(&slot) {
            let _ = remove(&slot.to_string_lossy());
        }
    }
}

fn run_git(cwd: &str, args: &[&str]) -> Result<(), String> {
    let out = std::process::Command::new("git")
        .args(args)
        .current_dir(cwd)
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        return Ok(());
    }
    let why = String::from_utf8_lossy(&out.stderr).trim().to_string();
    Err(if why.is_empty() {
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    } else {
        why
    })
}

#[cfg(test)]
mod tests {
    use super::super::tests::{repo, run};
    use super::*;

    fn nobody(_: &str) -> bool {
        false
    }

    fn pooled(max_idle: usize) -> Pool<'static> {
        Pool {
            max_idle,
            in_use: &nobody,
        }
    }

    fn make(root: &Path, name: &str, pool: &Pool<'_>) -> (CreatedWorktree, CreateStages) {
        create_timed(root.to_str().unwrap(), name, pool).expect("a worktree")
    }

    #[test]
    fn a_pooled_create_lands_in_a_slot_on_the_named_branch() {
        let (parent, root) = repo("pool-slot");
        let (made, stages) = make(&root, "abc12345", &pooled(20));
        assert!(
            made.path.ends_with("/repo-worktrees/slot-01"),
            "{}",
            made.path
        );
        assert_eq!(made.branch, "juancode/abc12345");
        assert!(!stages.reused_slot);
        let (second, _) = make(&root, "def67890", &pooled(20));
        assert!(
            second.path.ends_with("/repo-worktrees/slot-02"),
            "{}",
            second.path
        );
        std::fs::remove_dir_all(&parent).ok();
    }

    #[test]
    fn a_released_clean_slot_is_reused_with_its_ignored_files() {
        let (parent, root) = repo("pool-reuse");
        std::fs::write(root.join(".gitignore"), "target/\n").unwrap();
        run(&root, &["add", ".gitignore"]);
        run(&root, &["commit", "--quiet", "-m", "ignore"]);
        let (first, _) = make(&root, "first001", &pooled(20));
        std::fs::create_dir_all(Path::new(&first.path).join("target")).unwrap();
        std::fs::write(Path::new(&first.path).join("target/cache"), "warm").unwrap();

        assert_eq!(release(&first.path, 20).unwrap(), Released::Pooled);
        assert!(Path::new(&first.path).is_dir());

        let (second, stages) = make(&root, "second01", &pooled(20));
        assert_eq!(second.path, first.path);
        assert!(stages.reused_slot);
        assert!(Path::new(&second.path).join("target/cache").is_file());
        let head = git(&second.path, &["rev-parse", "--abbrev-ref", "HEAD"]).unwrap();
        assert_eq!(head.trim(), "juancode/second01");
        // The first session's branch survives, and is free to check out elsewhere.
        assert!(git(
            root.to_str().unwrap(),
            &["rev-parse", "--verify", "juancode/first001"]
        )
        .is_some());
        std::fs::remove_dir_all(&parent).ok();
    }

    #[test]
    fn a_dirty_slot_is_removed_not_pooled() {
        let (parent, root) = repo("pool-dirty");
        let (made, _) = make(&root, "dirty001", &pooled(20));
        std::fs::write(Path::new(&made.path).join("untracked.txt"), "new\n").unwrap();
        assert_eq!(release(&made.path, 20).unwrap(), Released::Removed);
        assert!(!Path::new(&made.path).exists());
        std::fs::remove_dir_all(&parent).ok();
    }

    #[test]
    fn a_slot_some_session_still_records_is_not_handed_out() {
        let (parent, root) = repo("pool-inuse");
        let (made, _) = make(&root, "held0001", &pooled(20));
        release(&made.path, 20).unwrap();
        let held = made.path.clone();
        let in_use = move |p: &str| p == held;
        let pool = Pool {
            max_idle: 20,
            in_use: &in_use,
        };
        let (next, stages) = make(&root, "next0001", &pool);
        assert_ne!(next.path, made.path);
        assert!(!stages.reused_slot);
        std::fs::remove_dir_all(&parent).ok();
    }

    #[test]
    fn parking_past_the_cap_removes_the_oldest_idle_slot() {
        let (parent, root) = repo("pool-cap");
        let (a, _) = make(&root, "cap-a", &pooled(1));
        let (b, _) = make(&root, "cap-b", &pooled(1));
        release(&a.path, 1).unwrap();
        // Stamps are whole seconds; make the order unambiguous.
        std::fs::write(admin_dir(Path::new(&a.path)).unwrap().join(STAMP), "1").unwrap();
        release(&b.path, 1).unwrap();
        assert!(!Path::new(&a.path).exists(), "the oldest idle slot goes");
        assert!(Path::new(&b.path).is_dir());
        std::fs::remove_dir_all(&parent).ok();
    }

    #[test]
    fn a_taken_name_puts_the_slot_back() {
        let (parent, root) = repo("pool-taken");
        run(&root, &["branch", "juancode/taken"]);
        let (made, _) = make(&root, "free0001", &pooled(20));
        release(&made.path, 20).unwrap();
        create_timed(root.to_str().unwrap(), "taken", &pooled(20))
            .expect_err("the branch is already claimed");
        let (again, stages) = make(&root, "free0002", &pooled(20));
        assert_eq!(again.path, made.path);
        assert!(stages.reused_slot);
        std::fs::remove_dir_all(&parent).ok();
    }

    #[test]
    fn pooling_off_keeps_named_paths_and_removes_on_release() {
        let (parent, root) = repo("pool-off");
        let (made, _) = make(&root, "named001", &pooled(0));
        assert!(
            made.path.ends_with("/repo-worktrees/named001"),
            "{}",
            made.path
        );
        assert_eq!(release(&made.path, 20).unwrap(), Released::Removed);
        std::fs::remove_dir_all(&parent).ok();
    }

    #[test]
    fn the_cap_defaults_when_the_file_is_missing_or_bad() {
        let dir = std::env::temp_dir().join(format!("juancoded-pool-cfg-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("worktree-pool.json");
        assert_eq!(max_idle_per_repo_at(&file), DEFAULT_MAX_IDLE_PER_REPO);
        std::fs::write(&file, "not json").unwrap();
        assert_eq!(max_idle_per_repo_at(&file), DEFAULT_MAX_IDLE_PER_REPO);
        std::fs::write(&file, r#"{"maxIdlePerRepo":0}"#).unwrap();
        assert_eq!(max_idle_per_repo_at(&file), 0);
        std::fs::remove_dir_all(&dir).ok();
    }
}
