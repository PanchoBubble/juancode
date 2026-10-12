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
//!
//! The cap bounds every slot in a repo, not only idle ones. Sessions usually exit
//! without being deleted, so their slots were never parked and the pool grew past its
//! cap one new slot per session. Once a repo is at the cap, a create with no idle slot
//! reclaims the slot whose session was updated longest ago: that session is deleted
//! (its branch stays in git) and its tree is switched onto the new branch. A running
//! session's slot and a slot with uncommitted files are never reclaimed; when every
//! slot is one of those, a new slot is cut past the cap rather than refusing.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

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

/// Slots handed out by this process and when. A slot is handed out before the session
/// row that records it is written, so for a moment it has no owner and would look
/// like the best slot to reclaim.
static HANDED_OUT: Mutex<Option<HashMap<PathBuf, Instant>>> = Mutex::new(None);
const HANDOUT_GRACE: Duration = Duration::from_secs(600);

#[derive(Debug, Clone, Default, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct PoolConfig {
    #[serde(default)]
    max_idle_per_repo: Option<usize>,
    #[serde(default)]
    reclaim_oldest: Option<bool>,
    #[serde(default)]
    confirm_recent_reclaim: Option<bool>,
}

/// Everything `worktree-pool.json` says.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PoolSettings {
    /// Slots per repo; `0` turns pooling off.
    pub max_slots: usize,
    /// Off: no session is ever deleted to free a slot, and slots grow past the cap.
    pub reclaim_oldest: bool,
    /// Ask before reclaiming the slot of a session updated today.
    pub confirm_recent: bool,
}

pub fn settings_at(path: &Path) -> PoolSettings {
    let config = std::fs::read_to_string(path)
        .ok()
        .and_then(|raw| serde_json::from_str::<PoolConfig>(&raw).ok())
        .unwrap_or_default();
    PoolSettings {
        max_slots: config
            .max_idle_per_repo
            .unwrap_or(DEFAULT_MAX_IDLE_PER_REPO),
        reclaim_oldest: config.reclaim_oldest.unwrap_or(true),
        confirm_recent: config.confirm_recent_reclaim.unwrap_or(true),
    }
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
    settings_at(path).max_slots
}

/// What a pooled create needs to know about the rest of the daemon.
pub struct Pool<'a> {
    pub max_idle: usize,
    /// Whether some session row still records this path as its tree. A stamp says a
    /// slot is idle; this is the second opinion, for a daemon that died mid-take.
    pub in_use: &'a dyn Fn(&str) -> bool,
    /// `None`: a full repo gets a new slot past the cap.
    pub reclaim: Option<Reclaim<'a>>,
}

/// How a full repo frees a slot.
pub struct Reclaim<'a> {
    /// The session that records this slot as its tree, if any.
    pub owner: &'a dyn Fn(&str) -> Option<SlotOwner>,
    /// A session updated at or after this is recent enough to ask about first.
    pub recent_since_ms: i64,
    /// Skip the question: the user said yes, turned it off, or nobody is there to ask.
    pub confirmed: bool,
    /// Delete the owning session and leave its tree alone. `false` keeps the slot.
    pub evict: &'a dyn Fn(&SlotOwner) -> bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SlotOwner {
    pub session_id: String,
    pub title: String,
    pub updated_at_ms: i64,
    pub running: bool,
}

/// The slot a full repo would take, and the session that taking it deletes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReclaimCandidate {
    pub slot: String,
    pub owner: Option<SlotOwner>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CreateError {
    Worktree(WorktreeError),
    /// The repo is full and the oldest slot's session was updated recently.
    NeedsConfirm(ReclaimCandidate),
}

impl std::fmt::Display for CreateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Worktree(e) => write!(f, "{}", e.0),
            Self::NeedsConfirm(c) => write!(f, "every slot is taken; the oldest is {}", c.slot),
        }
    }
}

impl From<WorktreeError> for CreateError {
    fn from(e: WorktreeError) -> Self {
        Self::Worktree(e)
    }
}

/// Local midnight before `now_ms`, for "updated today".
pub fn start_of_local_day_ms(now_ms: i64) -> i64 {
    let secs = (now_ms / 1000) as libc::time_t;
    // SAFETY: localtime_r and mktime only touch the structs passed to them.
    unsafe {
        let mut tm: libc::tm = std::mem::zeroed();
        if libc::localtime_r(&secs, &mut tm).is_null() {
            return now_ms - 86_400_000;
        }
        tm.tm_hour = 0;
        tm.tm_min = 0;
        tm.tm_sec = 0;
        tm.tm_isdst = -1;
        libc::mktime(&mut tm) as i64 * 1000
    }
}

fn mark_handed_out(slot: &Path) {
    let mut map = HANDED_OUT.lock().unwrap_or_else(|e| e.into_inner());
    let map = map.get_or_insert_with(HashMap::new);
    map.retain(|_, at| at.elapsed() < HANDOUT_GRACE);
    map.insert(slot.to_path_buf(), Instant::now());
}

fn recently_handed_out(slot: &Path) -> bool {
    HANDED_OUT
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .and_then(|m| m.get(slot))
        .is_some_and(|at| at.elapsed() < HANDOUT_GRACE)
}

fn is_clean(tree: &Path) -> bool {
    git(&tree.to_string_lossy(), &["status", "--porcelain"]).is_some_and(|s| s.trim().is_empty())
}

/// The slot a full repo gives up: least recently updated owner first, an ownerless
/// slot before any of them. Running and dirty slots are skipped; `git status` runs
/// only until one passes, because each one is an exec.
fn reclaim_candidate(worktrees_dir: &Path, reclaim: &Reclaim<'_>) -> Option<ReclaimCandidate> {
    let mut ranked: Vec<(PathBuf, Option<SlotOwner>)> = slots(worktrees_dir)
        .into_iter()
        .filter(|p| parked_at(p).is_none())
        .map(|p| {
            let owner = (reclaim.owner)(&p.to_string_lossy());
            (p, owner)
        })
        .filter(|(p, owner)| match owner {
            Some(o) => !o.running,
            None => !recently_handed_out(p),
        })
        .collect();
    ranked.sort_by_key(|(p, owner)| {
        (
            owner.as_ref().map_or(i64::MIN, |o| o.updated_at_ms),
            p.clone(),
        )
    });
    ranked
        .into_iter()
        .find(|(p, _)| is_clean(p))
        .map(|(p, owner)| ReclaimCandidate {
            slot: p.to_string_lossy().to_string(),
            owner,
        })
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
) -> Result<(CreatedWorktree, CreateStages), CreateError> {
    if pool.max_idle == 0 {
        return Ok(super::create_timed(repo_cwd, name)?);
    }
    if !safe_name(name) {
        return Err(WorktreeError(format!(
            "\"{name}\" is not a usable worktree name: letters, digits, -, _ and . only."
        ))
        .into());
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
                return Err(WorktreeError(format!("Failed to create worktree: {why}")).into());
            }
            stages.reused_slot = true;
            slot
        }
        None => match take_oldest(&worktrees_dir, pool, &branch, base.as_deref())? {
            Some(slot) => {
                stages.reused_slot = true;
                slot
            }
            None => cut_slot(repo_cwd, &worktrees_dir, &branch, base.as_deref())?,
        },
    };
    mark_handed_out(&dir);
    stages.worktree_add_ms = step.elapsed().as_secs_f64() * 1000.0;
    let path = dir.to_string_lossy().to_string();
    let step = std::time::Instant::now();
    link_node_modules(&root, &path);
    stages.link_modules_ms = step.elapsed().as_secs_f64() * 1000.0;
    Ok((CreatedWorktree { path, branch }, stages))
}

/// A full repo's oldest slot, switched onto `branch`, or `None` when the repo is not
/// full, reclaiming is off, or nothing is reclaimable.
fn take_oldest(
    worktrees_dir: &Path,
    pool: &Pool<'_>,
    branch: &str,
    base: Option<&str>,
) -> Result<Option<PathBuf>, CreateError> {
    let Some(reclaim) = pool.reclaim.as_ref() else {
        return Ok(None);
    };
    // Held from choosing to switching, so two creates cannot reclaim one slot.
    let _guard = POOL_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    if slots(worktrees_dir).len() < pool.max_idle {
        return Ok(None);
    }
    let Some(candidate) = reclaim_candidate(worktrees_dir, reclaim) else {
        return Ok(None);
    };
    if let Some(owner) = &candidate.owner {
        if !reclaim.confirmed && owner.updated_at_ms >= reclaim.recent_since_ms {
            return Err(CreateError::NeedsConfirm(candidate));
        }
        if !(reclaim.evict)(owner) {
            return Ok(None);
        }
    }
    let slot = PathBuf::from(&candidate.slot);
    let mut args = vec!["switch", "--no-track", "--quiet", "-c", branch];
    if let Some(base) = base {
        args.push(base);
    }
    if let Err(why) = run_git(&candidate.slot, &args) {
        // Its session is gone either way, so the slot is idle now.
        stamp(&slot);
        return Err(WorktreeError(format!("Failed to create worktree: {why}")).into());
    }
    Ok(Some(slot))
}

fn cut_slot(
    repo_cwd: &str,
    worktrees_dir: &Path,
    branch: &str,
    base: Option<&str>,
) -> Result<PathBuf, WorktreeError> {
    let dir = {
        let _guard = POOL_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = next_free_slot(worktrees_dir);
        // Held until `worktree add` creates it, so a concurrent create picks the
        // next number.
        let _ = std::fs::create_dir(&dir);
        dir
    };
    let path = dir.to_string_lossy().to_string();
    let mut args = vec!["worktree", "add", "--no-track", "-b", branch, &path];
    if let Some(base) = base {
        args.push(base);
    }
    if let Err(why) = run_git(repo_cwd, &args) {
        let _ = std::fs::remove_dir(&dir);
        return Err(WorktreeError(format!("Failed to create worktree: {why}")));
    }
    Ok(dir)
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
            reclaim: None,
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
            reclaim: None,
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

    fn owner(id: &str, updated_at_ms: i64, running: bool) -> SlotOwner {
        SlotOwner {
            session_id: id.into(),
            title: id.into(),
            updated_at_ms,
            running,
        }
    }

    /// Two owned slots at a cap of 2, the older one first.
    fn full_repo(
        tag: &str,
        owners: [SlotOwner; 2],
    ) -> (PathBuf, PathBuf, Vec<(String, SlotOwner)>) {
        let (parent, root) = repo(tag);
        let (a, _) = make(&root, "own-a", &pooled(2));
        let (b, _) = make(&root, "own-b", &pooled(2));
        let [oa, ob] = owners;
        (parent, root, vec![(a.path, oa), (b.path, ob)])
    }

    fn reclaiming<'a>(
        confirmed: bool,
        lookup: &'a dyn Fn(&str) -> Option<SlotOwner>,
        evict: &'a dyn Fn(&SlotOwner) -> bool,
    ) -> Pool<'a> {
        Pool {
            max_idle: 2,
            in_use: &nobody,
            reclaim: Some(Reclaim {
                owner: lookup,
                recent_since_ms: 1_000,
                confirmed,
                evict,
            }),
        }
    }

    #[test]
    fn a_full_repo_reclaims_the_least_recently_updated_slot() {
        let (parent, root, owned) = full_repo(
            "pool-reclaim",
            [owner("old", 10, false), owner("new", 500, false)],
        );
        let evicted = Mutex::new(Vec::new());
        let lookup = |p: &str| owned.iter().find(|(s, _)| s == p).map(|(_, o)| o.clone());
        let evict = |o: &SlotOwner| {
            evicted.lock().unwrap().push(o.session_id.clone());
            true
        };
        let pool = reclaiming(false, &lookup, &evict);
        let (made, stages) = make(&root, "fresh01", &pool);
        assert_eq!(made.path, owned[0].0);
        assert!(stages.reused_slot);
        assert_eq!(*evicted.lock().unwrap(), vec!["old".to_string()]);
        let head = git(&made.path, &["rev-parse", "--abbrev-ref", "HEAD"]).unwrap();
        assert_eq!(head.trim(), "juancode/fresh01");
        assert!(git(
            root.to_str().unwrap(),
            &["rev-parse", "--verify", "juancode/own-a"]
        )
        .is_some());
        std::fs::remove_dir_all(&parent).ok();
    }

    #[test]
    fn a_slot_updated_recently_asks_first_unless_confirmed() {
        let (parent, root, owned) = full_repo(
            "pool-confirm",
            [owner("today", 5_000, false), owner("later", 6_000, false)],
        );
        let evicted = Mutex::new(Vec::new());
        let lookup = |p: &str| owned.iter().find(|(s, _)| s == p).map(|(_, o)| o.clone());
        let evict = |o: &SlotOwner| {
            evicted.lock().unwrap().push(o.session_id.clone());
            true
        };
        let err = create_timed(
            root.to_str().unwrap(),
            "fresh02",
            &reclaiming(false, &lookup, &evict),
        )
        .expect_err("a same-day slot is not taken silently");
        match err {
            CreateError::NeedsConfirm(c) => {
                assert_eq!(c.slot, owned[0].0);
                assert_eq!(c.owner.unwrap().session_id, "today");
            }
            other => panic!("{other:?}"),
        }
        assert!(
            evicted.lock().unwrap().is_empty(),
            "nothing deleted before a yes"
        );
        let (made, _) = make(&root, "fresh02", &reclaiming(true, &lookup, &evict));
        assert_eq!(made.path, owned[0].0);
        std::fs::remove_dir_all(&parent).ok();
    }

    #[test]
    fn running_and_dirty_slots_are_never_reclaimed() {
        let (parent, root, owned) = full_repo(
            "pool-skip",
            [owner("live", 10, true), owner("dirty", 20, false)],
        );
        std::fs::write(Path::new(&owned[1].0).join("wip.txt"), "x").unwrap();
        let evicted = Mutex::new(Vec::new());
        let lookup = |p: &str| owned.iter().find(|(s, _)| s == p).map(|(_, o)| o.clone());
        let evict = |o: &SlotOwner| {
            evicted.lock().unwrap().push(o.session_id.clone());
            true
        };
        let (made, stages) = make(&root, "fresh03", &reclaiming(true, &lookup, &evict));
        assert!(
            made.path.ends_with("/repo-worktrees/slot-03"),
            "{}",
            made.path
        );
        assert!(!stages.reused_slot);
        assert!(evicted.lock().unwrap().is_empty());
        std::fs::remove_dir_all(&parent).ok();
    }

    #[test]
    fn reclaim_off_grows_past_the_cap() {
        let (parent, root) = repo("pool-grow");
        make(&root, "grow-a", &pooled(1));
        let (b, _) = make(&root, "grow-b", &pooled(1));
        assert!(b.path.ends_with("/repo-worktrees/slot-02"), "{}", b.path);
        std::fs::remove_dir_all(&parent).ok();
    }

    #[test]
    fn settings_default_to_reclaiming_with_a_question() {
        let dir = std::env::temp_dir().join(format!("juancoded-pool-set-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("worktree-pool.json");
        let defaults = settings_at(&file);
        assert!(defaults.reclaim_oldest && defaults.confirm_recent);
        std::fs::write(
            &file,
            r#"{"maxIdlePerRepo":5,"reclaimOldest":false,"confirmRecentReclaim":false}"#,
        )
        .unwrap();
        assert_eq!(
            settings_at(&file),
            PoolSettings {
                max_slots: 5,
                reclaim_oldest: false,
                confirm_recent: false
            }
        );
        std::fs::remove_dir_all(&dir).ok();
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
