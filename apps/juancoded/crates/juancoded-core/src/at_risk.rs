//! Whether a folder is holding work nothing else will ever come back for.
//!
//! A port of the probe half of `WorkAtRisk.swift`. The classification — which roots to
//! look at, what counts as at risk, when to nudge about it — stays beside the UI that
//! draws the badge; what moves here is the one thing that shells out.
//!
//! The probe is deliberately ONE `git status --porcelain=v2 --branch` for branch,
//! upstream, ahead/behind and the dirty count together, where [`crate::git::state`]
//! uses five separate invocations for the same facts. That is not a micro-optimisation:
//! this runs across every watched worktree on the machine, and a fork costs 257ms here
//! before the child runs an instruction. `state` is left alone because the commit/push
//! CTAs depend on its exact semantics, including the `remote` flag this cannot know.

use std::process::Command;

use crate::git::GitState;

/// Everything one root's probe found, for the classifier to judge.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Probe {
    pub state: GitState,
    pub dirty_files: usize,
    /// Commits beyond the inferred base branch. Only computed, and only meaningful,
    /// when there is no upstream — `state.ahead` counts the branch's ENTIRE history in
    /// that case and must not be read as "unpushed".
    pub ahead_of_base: Option<i64>,
    /// HEAD is already contained in some remote-tracking branch: pushed without `-u`,
    /// or sharing history with a branch that was. Nothing is unpushed however large
    /// `ahead_of_base` is.
    pub head_on_remote: bool,
}

/// The branch facts and the dirty count, out of one porcelain-v2 listing.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct StatusSummary {
    pub branch: Option<String>,
    pub detached: bool,
    pub upstream: Option<String>,
    pub ahead: i64,
    pub behind: i64,
    pub dirty_files: usize,
}

/// Parse `git status --porcelain=v2 --branch`.
///
/// Header lines (`# key value`) carry the branch facts; every other line is one
/// changed path — `1`/`2` tracked, `u` unmerged, `?` untracked — which is exactly what
/// porcelain v1 counted, so the number the badge shows does not move with the format.
pub fn parse_status_summary(out: &str) -> StatusSummary {
    let mut s = StatusSummary::default();
    for line in out.lines() {
        let Some(rest) = line.strip_prefix("# ") else {
            if line.starts_with(['1', '2', 'u', '?']) {
                s.dirty_files += 1;
            }
            continue;
        };
        let mut parts = rest.split_whitespace();
        let Some(key) = parts.next() else { continue };
        match key {
            "branch.head" => match parts.next() {
                // git spells a detached HEAD "(detached)" in this field.
                Some("(detached)") => s.detached = true,
                Some(v) if !v.is_empty() => s.branch = Some(v.to_string()),
                _ => {}
            },
            "branch.upstream" => {
                if let Some(v) = parts.next() {
                    s.upstream = Some(v.to_string());
                }
            }
            // "+<ahead> -<behind>"
            "branch.ab" => {
                for token in parts {
                    let Some(sign) = token.chars().next() else {
                        continue;
                    };
                    let Ok(n) = token[1..].parse::<i64>() else {
                        continue;
                    };
                    match sign {
                        '+' => s.ahead = n,
                        '-' => s.behind = n,
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    s
}

/// Probe one folder, or `None` when it is missing or not a git work tree.
pub fn probe(path: &str) -> Option<Probe> {
    if !std::path::Path::new(path).exists() {
        return None;
    }
    // A directory that is not a repo makes this fail, which is also how it is detected.
    let out = capture(path, &["status", "--porcelain=v2", "--branch"])?;
    let summary = parse_status_summary(&out);

    let state = GitState {
        git: true,
        branch: summary.branch,
        detached: summary.detached,
        // `remote` is the one field this fast path cannot know without another fork.
        // The classifier never reads it, so it is inferred rather than paid for.
        remote: summary.upstream.is_some(),
        upstream: summary.upstream,
        // git omits the `branch.ab` header entirely when there is no upstream, so both
        // stay 0 there — which is right: `ahead_of_base` below is the answer instead.
        ahead: summary.ahead,
        behind: summary.behind,
        dirty: summary.dirty_files > 0,
    };

    let mut ahead_of_base = None;
    let mut head_on_remote = false;
    if state.upstream.is_none() && !state.detached {
        head_on_remote = head_contained_in_any_remote(path);
        if !head_on_remote {
            if let Some(base) = crate::worktree::default_base_branch(path) {
                ahead_of_base = capture(path, &["rev-list", "--count", &format!("{base}..HEAD")])
                    .and_then(|c| c.trim().parse::<i64>().ok());
            }
        }
    }

    Some(Probe {
        state,
        dirty_files: summary.dirty_files,
        ahead_of_base,
        head_on_remote,
    })
}

/// Whether HEAD is contained in at least one remote-tracking branch.
fn head_contained_in_any_remote(path: &str) -> bool {
    capture(path, &["branch", "-r", "--contains", "HEAD"])
        .is_some_and(|out| out.lines().any(|l| !l.trim().is_empty()))
}

fn capture(cwd: &str, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .args(args)
        .current_dir(cwd)
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_header_lines_carry_the_branch_and_the_rest_are_paths() {
        let s = parse_status_summary(
            "# branch.oid abc\n\
             # branch.head feature/x\n\
             # branch.upstream origin/feature/x\n\
             # branch.ab +3 -1\n\
             1 .M N... 100644 100644 100644 aaa bbb src/a.rs\n\
             ? untracked.txt\n\
             u UU N... 100644 100644 100644 100644 a b c d conflict.rs\n",
        );
        assert_eq!(s.branch.as_deref(), Some("feature/x"));
        assert!(!s.detached);
        assert_eq!(s.upstream.as_deref(), Some("origin/feature/x"));
        assert_eq!(s.ahead, 3);
        assert_eq!(s.behind, 1);
        assert_eq!(s.dirty_files, 3);
    }

    #[test]
    fn a_detached_head_is_not_a_branch_called_detached() {
        let s = parse_status_summary("# branch.head (detached)\n");
        assert!(s.detached);
        assert_eq!(s.branch, None);
    }

    #[test]
    fn no_upstream_means_no_ab_header_and_that_is_not_zero_ahead() {
        let s = parse_status_summary("# branch.head main\n1 .M N... 1 1 1 a b x\n");
        assert_eq!(s.upstream, None);
        assert_eq!(s.ahead, 0, "the header is absent, so nothing was counted");
        assert_eq!(s.dirty_files, 1);
    }

    #[test]
    fn a_dirty_repo_with_no_remote_counts_its_commits_against_the_base() {
        let dir = crate::git::tests::repo("atrisk");
        let path = dir.to_str().unwrap();
        let clean = probe(path).expect("a work tree");
        assert!(clean.state.git);
        assert_eq!(clean.dirty_files, 0);
        assert!(clean.state.upstream.is_none());
        assert!(!clean.head_on_remote);

        std::fs::write(dir.join("a.txt"), "changed\n").unwrap();
        let dirty = probe(path).expect("a work tree");
        assert_eq!(dirty.dirty_files, 1);
        assert!(dirty.state.dirty);
        std::fs::remove_dir_all(dir.parent().unwrap()).ok();
    }

    #[test]
    fn a_plain_directory_and_a_missing_one_are_both_nothing() {
        let dir = crate::git::tests::scratch("atrisk-nogit");
        assert!(probe(dir.to_str().unwrap()).is_none());
        assert!(probe(&format!("{}/definitely-not-here", dir.display())).is_none());
        std::fs::remove_dir_all(&dir).ok();
    }
}
