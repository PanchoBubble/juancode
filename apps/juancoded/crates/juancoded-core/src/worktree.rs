//! Isolating a session in a fresh git worktree.
//!
//! A port of the `createWorktree` half of `Git.swift`, and the reason the `create`
//! frame's `isolateWorktree` means anything at all. Juan runs several agents against
//! one checkout at a time; the worktree is the only thing that stops them writing
//! over each other, so a core that cannot make one has to SAY so rather than quietly
//! spawn in the shared tree (juancode-yiho).
//!
//! Layout matches the Swift core exactly, because both cores are pointed at the same
//! checkouts and a session started under one has to be recognisable to the other:
//! sibling `<repo>-worktrees/<name>` directory, branch `juancode/<name>`.
//!
//! A worktree outlives the session that made it, because the work in it usually
//! outlives the agent. So nothing on a timer removes one, and neither does an exit:
//! `remove` below is only ever reached from the session-DELETE path, which is the
//! Swift core's rule too (`DELETE /api/sessions/:id` reads `worktreePath` and calls
//! `removeWorktree`). `SessionMeta::worktree_path` is what the reaper reads
//! (juancode-oe30).

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::pr::BranchWorktree;

/// A worktree this core made, and the branch checked out in it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreatedWorktree {
    /// Absolute path to the new worktree's root: the session's real cwd.
    pub path: String,
    /// The branch created for it, `juancode/<name>`.
    pub branch: String,
}

/// Why isolation could not be given, worded for a human: this text reaches the
/// dispatcher and, through it, whoever asked for the agent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorktreeError(pub String);

impl std::fmt::Display for WorktreeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for WorktreeError {}

/// Create `<repo>-worktrees/<name>` off `repo_cwd` on a new `juancode/<name>` branch.
///
/// Every failure is an `Err` and never a silent fall back to `repo_cwd`: a session
/// that was asked to be isolated and is not is indistinguishable, from the outside,
/// from one that is.
pub fn create(repo_cwd: &str, name: &str) -> Result<CreatedWorktree, WorktreeError> {
    create_timed(repo_cwd, name).map(|(created, _)| created)
}

/// How long each step of [`create`] took, in milliseconds.
///
/// Session start is the one latency a person watches end to end, and the steps below
/// are wildly uneven — a no-op `git fetch` against a remote costs an order of
/// magnitude more than the checkout it exists to date-stamp. Measuring them
/// separately is what stops the next person optimising the cheap one.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct CreateStages {
    /// `rev-parse` twice: is this a work tree, and where is its root.
    pub repo_root_ms: f64,
    /// Resolving the base branch, including the `git fetch` that refreshes it.
    pub base_ref_ms: f64,
    /// `git worktree add` itself: the branch and the checkout.
    pub worktree_add_ms: f64,
    /// Symlinking the source checkout's `node_modules` into the new tree.
    pub link_modules_ms: f64,
}

/// [`create`], with the cost of each step alongside the result.
pub fn create_timed(
    repo_cwd: &str,
    name: &str,
) -> Result<(CreatedWorktree, CreateStages), WorktreeError> {
    let mut stages = CreateStages::default();
    let step = std::time::Instant::now();
    let root = repo_root(repo_cwd).ok_or_else(|| {
        WorktreeError("Not a git repository — can't isolate this session in a worktree.".into())
    })?;
    stages.repo_root_ms = step.elapsed().as_secs_f64() * 1000.0;
    let branch = format!("juancode/{name}");
    let worktrees_dir = siblings_dir(&root);
    // Best effort, exactly as the Swift core does it: `git worktree add` reports the
    // real problem better than a mkdir error would.
    let _ = std::fs::create_dir_all(&worktrees_dir);
    let dir = worktrees_dir.join(name);
    // `--no-track` so a branch cut from `origin/main` does not take main as its
    // upstream, which would aim a later `git push` at main.
    let mut args = vec![
        "worktree".to_string(),
        "add".to_string(),
        "--no-track".to_string(),
        "-b".to_string(),
        branch.clone(),
        dir.to_string_lossy().to_string(),
    ];
    let step = std::time::Instant::now();
    let base = base_ref(repo_cwd);
    stages.base_ref_ms = step.elapsed().as_secs_f64() * 1000.0;
    if let Some(base) = base {
        args.push(base);
    }
    let step = std::time::Instant::now();
    let out = Command::new("git")
        .args(&args)
        .current_dir(repo_cwd)
        .output()
        .map_err(|e| WorktreeError(format!("Failed to create worktree: {e}")))?;
    if !out.status.success() {
        let why = String::from_utf8_lossy(&out.stderr).trim().to_string();
        let why = if why.is_empty() {
            String::from_utf8_lossy(&out.stdout).trim().to_string()
        } else {
            why
        };
        return Err(WorktreeError(format!("Failed to create worktree: {why}")));
    }
    stages.worktree_add_ms = step.elapsed().as_secs_f64() * 1000.0;
    let path = dir.to_string_lossy().to_string();
    let step = std::time::Instant::now();
    link_node_modules(&root, &path);
    stages.link_modules_ms = step.elapsed().as_secs_f64() * 1000.0;
    Ok((CreatedWorktree { path, branch }, stages))
}

/// Create `<repo>-worktrees/<name>` with an **existing** branch checked out, for
/// working a branch somebody else pushed — a PR's head branch.
///
/// A port of `createWorktree(_:_:checkingOut:)`. Unlike [`create`], which starts a
/// fresh `juancode/<name>` branch, this has to cope with a branch that may not be
/// local yet and may already be checked out. In order: fetch it if it is unknown,
/// check it out normally, fall back to tracking `origin/<branch>`, and finally fall
/// back to a **detached** checkout at its head — git allows one worktree per branch,
/// so a branch already open elsewhere can only be read detached. `branch` in the
/// result is `None` in that last case, so the caller can tell the agent it has no
/// branch to commit onto rather than let it discover that mid-fix.
pub fn create_on_branch(
    repo_cwd: &str,
    name: &str,
    branch: &str,
) -> Result<BranchWorktree, WorktreeError> {
    let root = repo_root(repo_cwd).ok_or_else(|| {
        WorktreeError("Not a git repository — can't isolate this session in a worktree.".into())
    })?;
    let worktrees_dir = siblings_dir(&root);
    let _ = std::fs::create_dir_all(&worktrees_dir);
    // A previous tracking run may have left `<name>` behind — worktrees outlive the
    // session that made them — and `git worktree add` refuses an existing directory.
    let mut dir = worktrees_dir.join(name);
    let mut suffix = 2;
    while dir.exists() {
        dir = worktrees_dir.join(format!("{name}-{suffix}"));
        suffix += 1;
    }
    let dir = dir.to_string_lossy().to_string();

    // A PR branch pushed by somebody else may not exist locally at all. Best-effort:
    // being offline must not stop the worktree being made, since the detached fallback
    // still has whatever remote-tracking ref is already here.
    let local = format!("refs/heads/{branch}");
    let have_local = git(repo_cwd, &["rev-parse", "--verify", "--quiet", &local])
        .is_some_and(|out| !out.trim().is_empty());
    if !have_local {
        let _ = Command::new("git")
            .args(["fetch", "origin", branch])
            .current_dir(repo_cwd)
            .output();
    }

    if have_local && worktree_add(repo_cwd, &["worktree", "add", &dir, branch]) {
        link_node_modules(&root, &dir);
        return Ok(BranchWorktree {
            path: dir,
            branch: Some(branch.to_string()),
        });
    }
    let remote = format!("origin/{branch}");
    if !have_local
        && worktree_add(
            repo_cwd,
            &["worktree", "add", "--track", "-b", branch, &dir, &remote],
        )
    {
        link_node_modules(&root, &dir);
        return Ok(BranchWorktree {
            path: dir,
            branch: Some(branch.to_string()),
        });
    }
    // Already checked out elsewhere, or the branch resolves but cannot be attached:
    // detached at whichever ref does resolve.
    for r#ref in [branch, remote.as_str()] {
        if worktree_add(repo_cwd, &["worktree", "add", "--detach", &dir, r#ref]) {
            link_node_modules(&root, &dir);
            return Ok(BranchWorktree {
                path: dir,
                branch: None,
            });
        }
    }
    Err(WorktreeError(format!(
        "Couldn't create a worktree for branch {branch}."
    )))
}

fn worktree_add(repo_cwd: &str, args: &[&str]) -> bool {
    Command::new("git")
        .args(args)
        .current_dir(repo_cwd)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Remove a worktree `create` made, and its directory. The branch is left alone, so
/// committed work survives being forgotten.
///
/// A port of `removeWorktree` in `Git.swift`, including both things that are not
/// obvious. It runs from the repo's MAIN worktree, because git refuses to remove the
/// worktree you are standing in, and it `--force`s past uncommitted changes, because
/// the only caller is a session being deleted and a refusal there would leave a tree
/// nothing else will ever come back for.
///
/// A path that is already gone is `Ok`: the two states a caller cares about are "the
/// tree is there" and "the tree is not", and a delete that fails because someone
/// removed the directory by hand would report a leak that does not exist. The
/// administrative entry git keeps for a missing worktree is pruned on the way past.
pub fn remove(worktree_path: &str) -> Result<(), WorktreeError> {
    let dir = Path::new(worktree_path);
    if !dir.exists() {
        // `git worktree list` still names it until something prunes it, and a stale
        // entry blocks a later `worktree add` at the same path. The prune has to run
        // somewhere that still exists, and the missing tree is not it, so this is the
        // one place that inverts the layout `create` chose rather than asking git.
        if let Some(root) = repo_of_worktree(worktree_path) {
            let _ = Command::new("git")
                .args(["worktree", "prune"])
                .current_dir(&root)
                .output();
        }
        return Ok(());
    }
    // Falling back to the tree itself is what the Swift core does. `worktree remove`
    // run from inside the target refuses, which is an honest error rather than a
    // silent no-op, so the fallback cannot turn a leak into a reported success.
    let from = main_worktree(worktree_path).unwrap_or_else(|| worktree_path.to_string());
    let out = Command::new("git")
        .args(["worktree", "remove", "--force", worktree_path])
        .current_dir(&from)
        .output()
        .map_err(|e| WorktreeError(format!("Failed to remove worktree: {e}")))?;
    if !out.status.success() {
        let why = String::from_utf8_lossy(&out.stderr).trim().to_string();
        let why = if why.is_empty() {
            String::from_utf8_lossy(&out.stdout).trim().to_string()
        } else {
            why
        };
        return Err(WorktreeError(format!("Failed to remove worktree: {why}")));
    }
    Ok(())
}

/// The repo a `<parent>/<repo>-worktrees/<name>` path belongs to: `<parent>/<repo>`.
/// The inverse of [`siblings_dir`], and only ever a fallback for a tree that is
/// already gone — while it exists, git itself is asked.
fn repo_of_worktree(worktree_path: &str) -> Option<String> {
    let dir = Path::new(worktree_path).parent()?;
    let name = dir.file_name()?.to_string_lossy().to_string();
    let repo = name.strip_suffix("-worktrees")?;
    let root = dir.parent()?.join(repo);
    root.is_dir().then(|| root.to_string_lossy().to_string())
}

/// The main worktree of the repo `cwd` belongs to: the first entry `git worktree
/// list --porcelain` prints, which is the one holding the real `.git` directory.
fn main_worktree(cwd: &str) -> Option<String> {
    let listing = git(cwd, &["worktree", "list", "--porcelain"])?;
    let first = listing
        .lines()
        .find_map(|line| line.strip_prefix("worktree "))?;
    let first = first.trim();
    if first.is_empty() {
        return None;
    }
    Some(first.to_string())
}

/// How long a create is willing to wait for the base-branch refresh before it
/// branches off the ref it already has.
///
/// A `git fetch` that has nothing to fetch still costs a full SSH handshake to the
/// forge — measured at 1.8-2.3s against github.com on this machine, which was 67% of
/// the entire cost of starting an isolated session and the single thing that made a
/// worktree session feel slower than an ordinary one. The budget is set so a fetch
/// that IS cheap (a local or on-LAN remote) is still waited for, and a handshake to
/// the internet is not.
const FETCH_BUDGET: Duration = Duration::from_millis(250);

/// How long a completed fetch counts as current for.
///
/// The case this exists for is a burst: "dispatch five agents" used to pay the
/// handshake five times over, serially, for five refreshes of the same branch.
const FETCH_TTL: Duration = Duration::from_secs(60);

/// The ref a fresh session worktree branches from: the repo's default branch as
/// `origin` has it. Mirrors `worktreeBaseRef` in the Swift core, including the
/// fallbacks: the local branch when there is no remote, and `None` (branch off HEAD,
/// the old behaviour) when the repo has no default branch at all.
///
/// The refresh that keeps a new agent off a stale base is NOT waited out. It is
/// started, given [`FETCH_BUDGET`], and then left to finish on its own while the
/// worktree is created off the ref we already have — so the cost a person waits
/// through is the checkout, and the fetch it used to hide behind lands in time for
/// the next session instead. Staleness is bounded by how recently a session was
/// started in this repo, which in practice is minutes at worst and is the same
/// window a `git pull` in the main checkout leaves open anyway.
fn base_ref(repo_cwd: &str) -> Option<String> {
    let base = default_base_branch(repo_cwd)?;
    let short = base.strip_prefix("origin/").unwrap_or(&base).to_string();
    let fetched = refresh_base(repo_cwd, &short);
    // A local-only `main` can become `origin/main` once the fetch has run.
    if fetched && !base.starts_with("origin/") {
        let remote = format!("origin/{short}");
        if git(repo_cwd, &["rev-parse", "--verify", "--quiet", &remote])
            .is_some_and(|out| !out.trim().is_empty())
        {
            return Some(remote);
        }
    }
    Some(base)
}

/// Bring `origin/<branch>` up to date, waiting at most [`FETCH_BUDGET`] for it.
///
/// `true` only when the fetch finished, successfully, inside the budget — the one
/// case where the caller may conclude something about refs it did not have before.
/// A fetch still running when the budget expires is deliberately left alone rather
/// than killed: it is the thing that makes the NEXT create current, and a reaper
/// thread waits on it so nothing is left for `launchd` to inherit.
fn refresh_base(repo_cwd: &str, branch: &str) -> bool {
    let key = format!("{repo_cwd}\u{0}{branch}");
    if fetch_clock().is_current(&key) {
        return false;
    }
    // A remote that hangs rather than answering — no route to the forge — would
    // otherwise leave one stuck `git fetch` per create, and a person starting a
    // batch of sessions offline would pile up a dozen of them.
    if !fetch_clock().begin(&key) {
        return false;
    }
    let Ok(mut child) = Command::new("git")
        .args(["fetch", "origin", branch])
        .current_dir(repo_cwd)
        // Inherited pipes would be a place for git's progress output to block on.
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
    else {
        fetch_clock().settle(&key, false);
        return false;
    };
    let deadline = Instant::now() + FETCH_BUDGET;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                fetch_clock().settle(&key, status.success());
                return status.success();
            }
            // Unwaitable: nothing to reap and nothing to conclude.
            Err(_) => {
                fetch_clock().settle(&key, false);
                return false;
            }
            Ok(None) => {}
        }
        if Instant::now() >= deadline {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    // Bounded by git's own exit, and the only reason the thread exists: an
    // unwaited child stays a zombie for the life of the daemon.
    std::thread::spawn(move || {
        let ok = child.wait().map(|s| s.success()).unwrap_or(false);
        fetch_clock().settle(&key, ok);
    });
    false
}

/// When each `<repo>/<branch>` pair was last fetched, and which fetches are still in
/// the air, so a burst of creates in one repo pays for one refresh rather than one
/// each.
#[derive(Default)]
struct FetchClock {
    state: Mutex<FetchState>,
}

#[derive(Default)]
struct FetchState {
    last: HashMap<String, Instant>,
    in_flight: HashSet<String>,
}

impl FetchClock {
    fn is_current(&self, key: &str) -> bool {
        let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state
            .last
            .get(key)
            .is_some_and(|at| at.elapsed() < FETCH_TTL)
    }

    /// Claim the right to fetch this key. `false` when one is already running.
    fn begin(&self, key: &str) -> bool {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.in_flight.insert(key.to_string())
    }

    fn settle(&self, key: &str, ok: bool) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.in_flight.remove(key);
        if ok {
            state.last.insert(key.to_string(), Instant::now());
        }
    }
}

fn fetch_clock() -> &'static FetchClock {
    static CLOCK: OnceLock<FetchClock> = OnceLock::new();
    CLOCK.get_or_init(FetchClock::default)
}

/// The repo's default branch: `origin/HEAD` when the remote has published one, else
/// the first of main/master/develop that exists as a remote or local ref. Same order
/// as `defaultBaseBranch` in the Swift core, so both cores pick the same base.
fn default_base_branch(cwd: &str) -> Option<String> {
    if let Some(head) = git(cwd, &["rev-parse", "--abbrev-ref", "origin/HEAD"]) {
        let head = head.trim();
        if !head.is_empty() && head != "origin/HEAD" {
            return Some(head.to_string());
        }
    }
    for name in ["main", "master", "develop"] {
        for r#ref in [format!("origin/{name}"), name.to_string()] {
            if git(cwd, &["rev-parse", "--verify", "--quiet", &r#ref])
                .is_some_and(|out| !out.trim().is_empty())
            {
                return Some(r#ref);
            }
        }
    }
    None
}

/// The top level of the work tree `cwd` sits in, or `None` when it is not one (or
/// git is absent).
fn repo_root(cwd: &str) -> Option<String> {
    let inside = git(cwd, &["rev-parse", "--is-inside-work-tree"])?;
    if inside.trim() != "true" {
        return None;
    }
    let root = git(cwd, &["rev-parse", "--show-toplevel"])?;
    let root = root.trim();
    if root.is_empty() {
        return None;
    }
    Some(root.to_string())
}

/// `<parent>/<repo>-worktrees`, the sibling directory every juancode worktree lives in.
fn siblings_dir(root: &str) -> PathBuf {
    let root = Path::new(root);
    let base = root
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "repo".to_string());
    let parent = root.parent().unwrap_or(Path::new("/"));
    parent.join(format!("{base}-worktrees"))
}

fn git(cwd: &str, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .args(args)
        .current_dir(cwd)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    String::from_utf8(out.stdout).ok()
}

/// How deep to look for a package's `node_modules`. Two levels covers a pnpm
/// workspace's `apps/*` / `packages/*` without walking a whole checkout.
const MAX_SCAN_DEPTH: usize = 2;

/// Symlink the source checkout's `node_modules` directories into a fresh worktree,
/// returning the repo-relative paths that were linked.
///
/// A port of `WorktreeDeps.swift`. Without it an isolated session in a JS repo cannot
/// run the project's own checks until somebody installs, which for a dispatched agent
/// means it cannot finish. Never clobbers anything the checkout already has, and a
/// failure to link one path is not a failure to isolate.
pub fn link_node_modules(source_root: &str, worktree_path: &str) -> Vec<String> {
    let mut linked = Vec::new();
    for rel in node_modules_paths(source_root) {
        let source = Path::new(source_root).join(&rel);
        let dest = Path::new(worktree_path).join(&rel);
        let Some(parent) = dest.parent() else {
            continue;
        };
        // The package does not exist on this branch: nothing to install into.
        if !parent.is_dir() {
            continue;
        }
        // `symlink_metadata`, not `metadata`: a leftover broken link is still taken.
        if dest.symlink_metadata().is_ok() {
            continue;
        }
        if std::os::unix::fs::symlink(&source, &dest).is_ok() {
            linked.push(rel);
        }
    }
    linked
}

/// Repo-relative paths of the `node_modules` directories under `root`, to
/// `MAX_SCAN_DEPTH`. Skips dot-directories and never descends into one it found.
fn node_modules_paths(root: &str) -> Vec<String> {
    let mut found = Vec::new();
    let mut frontier = vec![(String::new(), 0usize)];
    while let Some((rel, depth)) = frontier.pop() {
        let modules = if rel.is_empty() {
            "node_modules".to_string()
        } else {
            format!("{rel}/node_modules")
        };
        if Path::new(root).join(&modules).is_dir() {
            found.push(modules);
        }
        if depth >= MAX_SCAN_DEPTH {
            continue;
        }
        let abs = if rel.is_empty() {
            PathBuf::from(root)
        } else {
            Path::new(root).join(&rel)
        };
        let Ok(entries) = std::fs::read_dir(&abs) else {
            continue;
        };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with('.') || name == "node_modules" {
                continue;
            }
            if !entry.path().is_dir() {
                continue;
            }
            let child = if rel.is_empty() {
                name
            } else {
                format!("{rel}/{name}")
            };
            frontier.push((child, depth + 1));
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(cwd: &Path, args: &[&str]) {
        let status = Command::new("git")
            .args(args)
            .current_dir(cwd)
            .env("GIT_AUTHOR_NAME", "test")
            .env("GIT_AUTHOR_EMAIL", "test@localhost")
            .env("GIT_COMMITTER_NAME", "test")
            .env("GIT_COMMITTER_EMAIL", "test@localhost")
            .status()
            .expect("git");
        assert!(status.success(), "git {args:?}");
    }

    /// A scratch directory of its own per test: `create` writes a SIBLING of the repo
    /// it is given, so two tests sharing one parent would collide on the worktrees dir.
    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("juancoded-wt-{tag}-{}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A repo at `<scratch>/repo` with one commit, so `worktree add` has a HEAD.
    fn repo(tag: &str) -> (PathBuf, PathBuf) {
        let parent = scratch(tag);
        let root = parent.join("repo");
        std::fs::create_dir_all(&root).unwrap();
        run(&root, &["init", "--quiet", "--initial-branch=main"]);
        std::fs::write(root.join("committed.txt"), "base\n").unwrap();
        run(&root, &["add", "committed.txt"]);
        run(&root, &["commit", "--quiet", "-m", "base"]);
        (parent, root)
    }

    #[test]
    fn a_worktree_lands_beside_the_repo_on_its_own_branch() {
        let (parent, root) = repo("made");
        let made = create(root.to_str().unwrap(), "abc12345").expect("a worktree");
        assert_eq!(made.branch, "juancode/abc12345");
        // Suffix rather than equality: the path comes from `--show-toplevel`, which
        // resolves symlinks (on macOS `/var` is one), so the prefix is not the
        // literal string the test handed in.
        assert!(
            made.path.ends_with("/repo-worktrees/abc12345"),
            "{}",
            made.path
        );
        assert!(parent.join("repo-worktrees").join("abc12345").is_dir());
        assert!(Path::new(&made.path).join("committed.txt").is_file());
        // The point of the whole feature: a different tree from the one asked about.
        assert_ne!(made.path, root.to_string_lossy());
        std::fs::remove_dir_all(&parent).ok();
    }

    /// The PR case: an existing branch, checked out attached when it is free.
    #[test]
    fn a_pr_worktree_checks_out_the_branch_it_was_given() {
        let (parent, root) = repo("prbranch");
        run(&root, &["branch", "feature"]);
        let made = create_on_branch(root.to_str().unwrap(), "pr-7", "feature").expect("a worktree");
        assert_eq!(made.branch.as_deref(), Some("feature"));
        assert!(made.path.ends_with("/repo-worktrees/pr-7"), "{}", made.path);
        assert_eq!(
            git(&made.path, &["rev-parse", "--abbrev-ref", "HEAD"])
                .expect("rev-parse")
                .trim(),
            "feature"
        );
        std::fs::remove_dir_all(&parent).ok();
    }

    /// A branch already checked out elsewhere is the common case for the repo's OWN
    /// default branch, and git allows one worktree per branch. Detached at its head is
    /// still a usable tree, and `branch: None` is what tells the agent it has to make
    /// its own branch before it can push.
    #[test]
    fn a_branch_open_elsewhere_falls_back_to_a_detached_tree() {
        let (parent, root) = repo("prdetached");
        let made = create_on_branch(root.to_str().unwrap(), "pr-9", "main").expect("a worktree");
        assert_eq!(
            made.branch, None,
            "main is checked out in the repo itself, so this one cannot attach"
        );
        assert_eq!(
            git(&made.path, &["rev-parse", "HEAD"])
                .expect("rev-parse")
                .trim(),
            sha(&root, "main"),
            "detached, but at the branch's head rather than at nothing"
        );
        // A second run for the same PR does not fight the directory the first left.
        let again = create_on_branch(root.to_str().unwrap(), "pr-9", "main").expect("a worktree");
        assert!(
            again.path.ends_with("/repo-worktrees/pr-9-2"),
            "{}",
            again.path
        );
        std::fs::remove_dir_all(&parent).ok();
    }

    /// Reading a ref that is not HEAD, for the base-branch tests.
    fn sha(cwd: &Path, r#ref: &str) -> String {
        git(cwd.to_str().unwrap(), &["rev-parse", r#ref])
            .expect("rev-parse")
            .trim()
            .to_string()
    }

    /// The point of basing off the default branch: an agent dispatched while the main
    /// checkout sits on a feature branch must not inherit that branch's work.
    #[test]
    fn a_worktree_starts_at_the_default_branch_not_the_checked_out_head() {
        let (parent, root) = repo("basemain");
        let main = sha(&root, "main");
        run(&root, &["checkout", "-q", "-b", "feature/wip"]);
        std::fs::write(root.join("wip.txt"), "half done\n").unwrap();
        run(&root, &["add", "wip.txt"]);
        run(&root, &["commit", "--quiet", "-m", "wip"]);

        let made = create(root.to_str().unwrap(), "basemain").expect("a worktree");
        let at = sha(Path::new(&made.path), "HEAD");
        assert_eq!(at, main, "the worktree must start at main");
        assert!(!Path::new(&made.path).join("wip.txt").exists());
        std::fs::remove_dir_all(&parent).ok();
    }

    /// With a remote, the base is what origin has NOW: fetched before branching, so a
    /// worktree is never cut from a local `main` that is days behind. The new branch
    /// must also have no upstream, or a later push would aim at main.
    #[test]
    fn the_base_is_fetched_from_origin_before_branching() {
        let (parent, root) = repo("fetched");
        let remote = parent.join("remote.git");
        run(&parent, &["init", "--bare", "--quiet", "remote.git"]);
        run(
            &root,
            &["remote", "add", "origin", remote.to_str().unwrap()],
        );
        run(&root, &["push", "--quiet", "-u", "origin", "main"]);

        // Someone else lands on main; this checkout has not fetched it.
        let other = parent.join("other");
        run(
            &parent,
            &["clone", "--quiet", remote.to_str().unwrap(), "other"],
        );
        std::fs::write(other.join("theirs.txt"), "landed\n").unwrap();
        run(&other, &["add", "theirs.txt"]);
        run(&other, &["commit", "--quiet", "-m", "theirs"]);
        run(&other, &["push", "--quiet", "origin", "main"]);
        let landed = sha(&other, "HEAD");
        assert_ne!(landed, sha(&root, "main"), "local main must be behind");

        let made = create(root.to_str().unwrap(), "fetched1").expect("a worktree");
        let wt = Path::new(&made.path);
        assert_eq!(
            sha(wt, "HEAD"),
            landed,
            "must start at a freshly fetched origin/main"
        );
        assert!(
            git(made.path.as_str(), &["rev-parse", "--abbrev-ref", "@{u}"]).is_none(),
            "the session branch must not track origin/main"
        );
        std::fs::remove_dir_all(&parent).ok();
    }

    /// The refresh is best effort, and a forge that is slow to answer must not be
    /// something a person waits through. The remote here takes five seconds to say
    /// anything at all; a `create` that finishes long before that is a `create` that
    /// branched off the ref it already had, which is the whole point.
    #[test]
    fn a_slow_remote_does_not_hold_up_the_worktree() {
        let (parent, root) = repo("slowfetch");
        let remote = parent.join("remote.git");
        run(&parent, &["init", "--bare", "--quiet", "remote.git"]);
        run(
            &root,
            &["remote", "add", "origin", remote.to_str().unwrap()],
        );
        run(&root, &["push", "--quiet", "-u", "origin", "main"]);
        let base = sha(&root, "origin/main");
        // `ext::` runs the command as the transport, so this is a remote that hangs
        // for five seconds and then fails — no network, and no dependence on how a
        // machine behaves when a host is unreachable.
        run(&root, &["remote", "set-url", "origin", "ext::sleep 5"]);

        let start = Instant::now();
        let made = create(root.to_str().unwrap(), "slow1").expect("a worktree");
        let waited = start.elapsed();
        assert!(
            waited < Duration::from_secs(4),
            "create waited {waited:?} on a remote that answers in 5s"
        );
        assert_eq!(
            sha(Path::new(&made.path), "HEAD"),
            base,
            "must start at the origin/main we already had"
        );
        std::fs::remove_dir_all(&parent).ok();
    }

    #[test]
    fn a_directory_that_is_not_a_repo_is_refused_rather_than_run_in() {
        let dir = scratch("plain");
        let err =
            create(dir.to_str().unwrap(), "abc12345").expect_err("a plain directory is refusable");
        assert!(err.0.contains("Not a git repository"), "{}", err.0);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_branch_that_already_exists_is_an_error_not_a_shared_tree() {
        let (parent, root) = repo("taken");
        run(&root, &["branch", "juancode/taken"]);
        let err =
            create(root.to_str().unwrap(), "taken").expect_err("the branch is already claimed");
        assert!(err.0.starts_with("Failed to create worktree"), "{}", err.0);
        std::fs::remove_dir_all(&parent).ok();
    }

    #[test]
    fn removing_a_worktree_takes_the_directory_and_leaves_the_branch() {
        let (parent, root) = repo("reaped");
        let made = create(root.to_str().unwrap(), "reaped01").expect("a worktree");
        assert!(Path::new(&made.path).is_dir());

        remove(&made.path).expect("the tree is removable");
        assert!(
            !Path::new(&made.path).exists(),
            "the directory is what a `pnpm loose` sweep finds: {}",
            made.path
        );
        // Committed work outlives the session, which is the whole reason the branch
        // is spared: reaping the tree must not be a way to lose a commit.
        assert!(
            git(
                root.to_str().unwrap(),
                &["rev-parse", "--verify", "--quiet", &made.branch]
            )
            .is_some_and(|out| !out.trim().is_empty()),
            "the branch must survive"
        );
        std::fs::remove_dir_all(&parent).ok();
    }

    /// The `--force`: an agent that was killed mid-edit leaves a dirty tree, and a
    /// removal that refused there would leak exactly the trees this exists to reap.
    #[test]
    fn a_dirty_worktree_is_still_reaped() {
        let (parent, root) = repo("dirty");
        let made = create(root.to_str().unwrap(), "dirty001").expect("a worktree");
        std::fs::write(Path::new(&made.path).join("committed.txt"), "half done\n").unwrap();
        std::fs::write(Path::new(&made.path).join("untracked.txt"), "new\n").unwrap();

        remove(&made.path).expect("uncommitted changes are not a reason to keep it");
        assert!(!Path::new(&made.path).exists());
        std::fs::remove_dir_all(&parent).ok();
    }

    /// The 27 rows on this machine whose tree somebody already removed by hand. A
    /// delete that failed on them would report a leak that is not there.
    #[test]
    fn a_tree_that_is_already_gone_is_not_an_error() {
        let (parent, root) = repo("vanished");
        let made = create(root.to_str().unwrap(), "vanish01").expect("a worktree");
        std::fs::remove_dir_all(&made.path).unwrap();

        remove(&made.path).expect("already gone is the state the caller wanted");
        // And the administrative entry went with it, so the path is reusable.
        let listing = git(root.to_str().unwrap(), &["worktree", "list", "--porcelain"]).unwrap();
        assert!(!listing.contains(&made.path), "{listing}");
        std::fs::remove_dir_all(&parent).ok();
    }

    #[test]
    fn node_modules_are_linked_in_so_the_isolated_session_can_run_the_checks() {
        let (parent, root) = repo("deps");
        std::fs::create_dir_all(root.join("node_modules")).unwrap();
        std::fs::create_dir_all(root.join("apps/oracle-mcp/node_modules")).unwrap();
        std::fs::write(root.join("apps/oracle-mcp/keep.txt"), "x\n").unwrap();
        run(&root, &["add", "apps/oracle-mcp/keep.txt"]);
        run(&root, &["commit", "--quiet", "-m", "packages"]);

        let made = create(root.to_str().unwrap(), "deps1234").expect("a worktree");
        let wt = Path::new(&made.path);
        assert!(wt.join("node_modules").symlink_metadata().is_ok());
        assert!(wt
            .join("apps/oracle-mcp/node_modules")
            .symlink_metadata()
            .is_ok());
        std::fs::remove_dir_all(&parent).ok();
    }
}
