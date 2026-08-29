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
//! Nothing here removes one. That is the Swift core's rule too: a worktree outlives
//! the session that made it, because the work in it usually outlives the agent, and
//! it is reaped when the SESSION is deleted (`DELETE /api/sessions/:id` removes
//! `worktreePath`) or by the desktop's worktree sweep. This daemon has no session
//! delete route yet, so today an isolated session's tree is only ever removed by hand
//! or by that sweep; `SessionMeta::worktree_path` is what a reaper will read when
//! there is one (juancode-yiho).

use std::path::{Path, PathBuf};
use std::process::Command;

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
    let root = repo_root(repo_cwd).ok_or_else(|| {
        WorktreeError("Not a git repository — can't isolate this session in a worktree.".into())
    })?;
    let branch = format!("juancode/{name}");
    let worktrees_dir = siblings_dir(&root);
    // Best effort, exactly as the Swift core does it: `git worktree add` reports the
    // real problem better than a mkdir error would.
    let _ = std::fs::create_dir_all(&worktrees_dir);
    let dir = worktrees_dir.join(name);
    let out = Command::new("git")
        .args(["worktree", "add", "-b", &branch])
        .arg(&dir)
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
    let path = dir.to_string_lossy().to_string();
    link_node_modules(&root, &path);
    Ok(CreatedWorktree { path, branch })
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
