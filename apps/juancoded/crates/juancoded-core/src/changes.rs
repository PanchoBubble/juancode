//! The whole-tree change rollup that rides the settle edge.
//!
//! A port of `ChangeBadge.swift`'s stat half. It exists so a remote client can badge
//! "finished, N files changed" without git access of its own, which is the only
//! reason it is computed in the core at all.
//!
//! Deliberately cheap and deliberately rare: two `git` invocations, run only on the
//! edge that ends a busy turn (see [`should_compute`]), never per output chunk.

use std::process::Command;

use crate::model::SessionActivity;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ChangeStat {
    pub files: usize,
    pub additions: usize,
    pub deletions: usize,
    /// Sorted fingerprint of the changed name-status set: the debounce key. Sorted so
    /// a mere re-ordering never re-badges.
    pub signature: String,
}

impl ChangeStat {
    pub fn is_empty(&self) -> bool {
        self.files == 0
    }
}

/// Whether a settle edge deserves a rollup. The review moment is an agent finishing
/// a turn: a real busy → not-busy boundary that notifies, not a teardown reset and
/// not a mid-turn flicker.
pub fn should_compute(prev: SessionActivity, next: SessionActivity, notify: bool) -> bool {
    notify && prev == SessionActivity::Busy && next != SessionActivity::Busy
}

/// The rollup for `cwd`, or `None` when it is not a git worktree (or git is absent).
/// A clean tree returns an empty stat, which callers omit from the wire.
pub fn rollup(cwd: &str) -> Option<ChangeStat> {
    let status = git(cwd, &["status", "--porcelain"])?;
    let mut entries: Vec<String> = status
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| l.to_string())
        .collect();
    entries.sort();
    let files = entries.len();

    let mut additions = 0usize;
    let mut deletions = 0usize;
    // `HEAD` covers staged and unstaged together; an unborn branch has no HEAD, so
    // fall back to the index-only diff rather than reporting nothing.
    let numstat = git(cwd, &["diff", "--numstat", "HEAD"])
        .or_else(|| git(cwd, &["diff", "--numstat", "--cached"]))
        .unwrap_or_default();
    for line in numstat.lines() {
        let mut parts = line.split_whitespace();
        // A binary file's counts are "-", which is not zero and not a number.
        additions += parts
            .next()
            .and_then(|v| v.parse::<usize>().ok())
            .unwrap_or(0);
        deletions += parts
            .next()
            .and_then(|v| v.parse::<usize>().ok())
            .unwrap_or(0);
    }

    Some(ChangeStat {
        files,
        additions,
        deletions,
        signature: entries.join("\n"),
    })
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

#[cfg(test)]
mod tests {
    use super::*;

    fn run(cwd: &std::path::Path, args: &[&str]) {
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

    #[test]
    fn only_a_notifying_turn_boundary_is_worth_a_rollup() {
        use SessionActivity::*;
        assert!(should_compute(Busy, Idle, true));
        assert!(should_compute(Busy, WaitingInput, true));
        assert!(
            !should_compute(Busy, Idle, false),
            "a quiet demotion is not a review moment"
        );
        assert!(
            !should_compute(Idle, WaitingInput, true),
            "a prompt with no turn behind it"
        );
        assert!(!should_compute(Busy, Busy, true));
    }

    #[test]
    fn a_dirty_worktree_reports_files_and_lines_and_a_clean_one_reports_nothing() {
        let dir = std::env::temp_dir().join(format!("juancoded-changes-{}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).unwrap();
        run(&dir, &["init", "--quiet", "--initial-branch=main"]);
        std::fs::write(dir.join("a.txt"), "one\n").unwrap();
        run(&dir, &["add", "a.txt"]);
        run(&dir, &["commit", "--quiet", "-m", "base"]);

        let clean = rollup(dir.to_str().unwrap()).expect("a git worktree");
        assert!(clean.is_empty(), "{clean:?}");

        std::fs::write(dir.join("a.txt"), "one\ntwo\n").unwrap();
        let dirty = rollup(dir.to_str().unwrap()).expect("a git worktree");
        assert_eq!(dirty.files, 1);
        assert_eq!(dirty.additions, 1);
        assert_eq!(dirty.deletions, 0);
        assert!(!dirty.signature.is_empty());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_plain_directory_is_not_a_worktree_and_reports_none() {
        let dir = std::env::temp_dir().join(format!("juancoded-nogit-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // `git status` inside a directory that is not a repo fails, and a failure is
        // "no rollup" rather than an empty one, so the field is omitted entirely.
        assert!(rollup(dir.to_str().unwrap()).is_none());
        std::fs::remove_dir_all(&dir).ok();
    }
}
