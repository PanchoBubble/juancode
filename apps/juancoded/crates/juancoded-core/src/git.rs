//! The git working tree of a session's cwd: what changed, what state the branch is
//! in, and the three writes a person makes about it — commit, push, discard.
//!
//! A port of `Git.swift`, which was the last service the desktop kept for itself.
//! Doing it in the app meant the answer only existed on the Mac the app was running
//! on: a phone looking at a session could be told an agent had finished and never be
//! told what it had changed. The daemon is the process that holds the session, so it
//! is the one that answers for the tree that session works in.
//!
//! Every call here shells out to `git` with the environment inherited verbatim — the
//! prime directive travels with the code. `core.quotepath=false` on every invocation
//! so a path with a non-ASCII byte comes back readable instead of octal-escaped.
//!
//! ## The cost of a fork here
//!
//! `fork`+`exec` on this machine costs 257ms before the child runs an instruction
//! (SentinelOne endpoint security), and over 7.5s under load. That is why
//! [`change_stat`] is two invocations and not one per file, why [`work_tree_status`]
//! reads one porcelain listing rather than asking about each path, and why the
//! per-file patches in [`collect_diff`] are the one place a loop is allowed: there is
//! no single `git` invocation that produces per-file diffs separately, and the shape
//! is what the panel draws.

use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};

use serde::{Deserialize, Serialize};

use crate::diff::{count_changes, parse_multi_file_diff, DiffFile, FileStatus, MAX_DIFF_BYTES};

/// The empty tree object, used as the diff base in a repo with no commits yet.
pub const EMPTY_TREE: &str = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

/// Most files one diff answers with. A change set past this is truncated and says so
/// rather than being streamed whole into a panel nobody can scroll.
const MAX_FILES: usize = 300;

/// A git failure worded for a person: the first useful line of what git said.
///
/// Its own type rather than `anyhow`, because every one of these reaches a UI and is
/// read: "Nothing to commit." and "Detached HEAD — checkout a branch to push." are the
/// whole answer, and a wrapped chain of contexts would bury them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitError(pub String);

impl std::fmt::Display for GitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for GitError {}

impl GitError {
    fn new(msg: impl Into<String>) -> Self {
        Self(msg.into())
    }
}

type Result<T> = std::result::Result<T, GitError>;

// ── the two runners ──────────────────────────────────────────────────────────

/// Run git and hand back stdout, tolerating exit 1.
///
/// `git diff` uses exit 1 to mean "there are differences", which is not a failure and
/// is in fact the interesting case. Every read below goes through this; every write
/// goes through [`git_strict`], where a non-zero exit is a hook rejecting a commit or
/// a remote refusing a push and must not be swallowed.
fn git(cwd: &str, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .args(["-c", "core.quotepath=false"])
        .args(args)
        .current_dir(cwd)
        .output()
        .ok()?;
    if out.status.success() || out.status.code() == Some(1) {
        return Some(String::from_utf8_lossy(&out.stdout).into_owned());
    }
    None
}

/// `git`, trimmed, and `None` for an empty answer — the shape most probes want.
fn git_line(cwd: &str, args: &[&str]) -> Option<String> {
    let out = git(cwd, args)?;
    let out = out.trim();
    (!out.is_empty()).then(|| out.to_string())
}

/// Run git with no special-casing of the exit code, feeding `stdin` when given.
///
/// The failure carries git's own first useful line, because that is the sentence the
/// person needs: "! [rejected] main -> main (fetch first)" says what to do and
/// "push failed" does not.
fn git_strict(cwd: &str, args: &[&str], stdin: Option<&str>) -> Result<(String, String)> {
    let mut cmd = Command::new("git");
    cmd.args(["-c", "core.quotepath=false"])
        .args(args)
        .current_dir(cwd)
        .stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd
        .spawn()
        .map_err(|e| GitError::new(format!("could not run git: {e}")))?;
    if let Some(text) = stdin {
        use std::io::Write;
        // A patch git refuses to read leaves the pipe closed under us; that shows up
        // as a non-zero exit below, which is the error we want to report anyway.
        if let Some(mut pipe) = child.stdin.take() {
            let _ = pipe.write_all(text.as_bytes());
        }
    }
    let out = child
        .wait_with_output()
        .map_err(|e| GitError::new(format!("could not run git: {e}")))?;
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    if out.status.success() {
        return Ok((stdout, stderr));
    }
    Err(GitError::new(
        first_useful_line(&stderr, &stdout).unwrap_or_else(|| {
            format!("git {} failed", args.first().copied().unwrap_or("command"))
        }),
    ))
}

/// The first non-blank line of stderr, then stdout — what a person needs out of a
/// failure, without the rest of git's advice block.
fn first_useful_line(stderr: &str, stdout: &str) -> Option<String> {
    format!("{stderr}\n{stdout}")
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .map(str::to_string)
}

fn with_fallback(e: GitError, fallback: &str) -> GitError {
    if e.0.trim().is_empty() {
        GitError::new(fallback)
    } else {
        e
    }
}

// ── the shapes on the wire ───────────────────────────────────────────────────

/// A whole working tree's diff. Field for field `DiffResult` in the Swift core, so a
/// client that drew one core's answer draws the other's.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffResult {
    /// `false` for a cwd that is not a git work tree. Not an error: a session in a
    /// plain directory is normal, and the panel draws "not a repo" rather than a
    /// failure.
    pub git: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub root: Option<String>,
    pub files: Vec<DiffFile>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub truncated_files: Option<bool>,
}

impl DiffResult {
    /// The answer for a cwd that is not a repo.
    pub fn none() -> Self {
        Self {
            git: false,
            root: None,
            files: Vec::new(),
            truncated_files: None,
        }
    }
}

/// A branch diffed against its base, carrying which base was used so the panel can
/// label what it is comparing against.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BaseDiffResult {
    pub base: String,
    pub result: DiffResult,
}

/// Branch, upstream, ahead/behind and dirtiness: everything the commit/push CTAs read
/// to decide what is actionable.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitState {
    pub git: bool,
    pub branch: Option<String>,
    pub detached: bool,
    pub upstream: Option<String>,
    pub ahead: i64,
    pub behind: i64,
    pub dirty: bool,
    /// Whether the repo has any remote at all. A tree with none can be committed to
    /// and never pushed, and the panel says so instead of offering a push that fails.
    pub remote: bool,
}

/// One linked worktree of a repo.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Worktree {
    pub path: String,
    pub branch: Option<String>,
    pub head: Option<String>,
    /// The repo's main worktree — the one holding the real `.git` directory. Always
    /// the first entry git prints.
    pub main: bool,
    /// Why the worktree is locked, when it is. Agent CLIs record their own pid here,
    /// which is the whole basis of [`crate::worktree::detect_agent_worktree`].
    #[serde(skip_serializing_if = "Option::is_none")]
    pub locked_reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommitResult {
    pub sha: String,
    pub subject: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PushResult {
    pub branch: String,
    pub output: String,
}

/// What a discard acted on. `path` is the worktree-relative path that was actually
/// touched, never the one the client sent — see [`scoped_relative_path`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RevertResult {
    pub path: String,
    pub reverted: bool,
}

/// One commit in the commit picker, newest first.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecentCommit {
    pub sha: String,
    pub short_sha: String,
    pub subject: String,
    /// git's own `%cr`, e.g. "3 hours ago".
    pub relative_age: String,
    /// In `<base>..HEAD`: not on the base branch yet.
    pub ahead_of_base: bool,
}

/// One changed path in a `git status --porcelain` snapshot.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeStatusEntry {
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub orig_path: Option<String>,
    /// Index (staged) status code, as a one-character string so it survives JSON.
    pub index: String,
    /// Work-tree (unstaged) status code.
    pub work_tree: String,
}

impl WorktreeStatusEntry {
    pub fn untracked(&self) -> bool {
        self.index == "?" && self.work_tree == "?"
    }
}

// ── reads ────────────────────────────────────────────────────────────────────

/// The top level of the work tree `cwd` is in, or `None` when it is not one.
pub fn repo_root(cwd: &str) -> Option<String> {
    let inside = git_line(cwd, &["rev-parse", "--is-inside-work-tree"])?;
    if inside != "true" {
        return None;
    }
    git_line(cwd, &["rev-parse", "--show-toplevel"])
}

/// The working-tree diff vs HEAD: every tracked change, staged and unstaged, plus
/// every untracked file as a full addition.
///
/// A non-git cwd answers `{ git: false }` rather than failing, because it is not a
/// failure — it is what a session in a scratch directory looks like.
pub fn diff(cwd: &str) -> DiffResult {
    let Some(root) = repo_root(cwd) else {
        return DiffResult::none();
    };
    // An unborn branch has no HEAD; the empty tree stands in, so the first commit's
    // worth of work still shows as a diff instead of as nothing.
    let base = if git_line(cwd, &["rev-parse", "--verify", "HEAD"]).is_some() {
        "HEAD".to_string()
    } else {
        EMPTY_TREE.to_string()
    };
    collect_diff(cwd, &root, &base)
}

/// Everything this branch introduced relative to where it diverged from `base` —
/// committed and uncommitted both.
///
/// The diff is against the MERGE BASE, not against the base branch's tip: otherwise a
/// branch that is simply behind shows every commit that landed on main since as its
/// own deletion.
pub fn base_diff(cwd: &str, requested: Option<&str>) -> Result<BaseDiffResult> {
    let Some(root) = repo_root(cwd) else {
        return Ok(BaseDiffResult {
            base: String::new(),
            result: DiffResult::none(),
        });
    };
    let base = match requested.map(str::trim).filter(|b| !b.is_empty()) {
        Some(b) => b.to_string(),
        None => crate::worktree::default_base_branch(cwd)
            .ok_or_else(|| GitError::new("No base branch found to diff against."))?,
    };
    let merge_base = git_line(cwd, &["merge-base", &base, "HEAD"])
        .ok_or_else(|| GitError::new("No base branch found to diff against."))?;
    if merge_base.is_empty() {
        return Err(GitError::new(format!("No common history with {base}.")));
    }
    Ok(BaseDiffResult {
        base,
        result: collect_diff(cwd, &root, &merge_base),
    })
}

/// The diff one commit introduced, in the same per-file shape [`diff`] produces.
///
/// A merge commit is diffed against its FIRST parent rather than shown: `git show` of
/// a merge emits combined `@@@` hunks, which no unified-diff parser on either side of
/// the wire reads. A root commit is diffed against the empty tree.
pub fn commit_diff(cwd: &str, sha: &str) -> Result<DiffResult> {
    if repo_root(cwd).is_none() {
        return Ok(DiffResult::none());
    }
    let short: String = sha.chars().take(7).collect();
    let not_found = || {
        GitError::new(format!(
            "Commit {short} not found — it may have been rewritten or rebased away."
        ))
    };
    let parents =
        git_line(cwd, &["rev-list", "--parents", "-n", "1", sha]).ok_or_else(not_found)?;
    let tokens: Vec<&str> = parents.split_whitespace().collect();
    let resolved = *tokens.first().ok_or_else(not_found)?;
    let parent = tokens.get(1).copied().unwrap_or(EMPTY_TREE);

    let patch = git(cwd, &["diff", "-M", parent, resolved]).unwrap_or_default();
    let mut files = parse_multi_file_diff(&patch);
    let truncated = files.len() > MAX_FILES;
    if truncated {
        files.truncate(MAX_FILES);
    }
    sort_files(&mut files);
    Ok(DiffResult {
        git: true,
        root: None,
        files,
        truncated_files: Some(truncated),
    })
}

/// Per-file diffs of a known work tree against `base`: name-status for the tracked
/// changes (with `-M` so a rename is one entry, not a delete and an add), then one
/// patch per file, then the untracked files against `/dev/null`.
fn collect_diff(cwd: &str, root: &str, base: &str) -> DiffResult {
    let mut files: Vec<DiffFile> = Vec::new();

    let name_status = git(cwd, &["diff", "--name-status", "-M", base]).unwrap_or_default();
    for raw in name_status.lines() {
        if raw.trim().is_empty() {
            continue;
        }
        if files.len() >= MAX_FILES {
            break;
        }
        let parts: Vec<&str> = raw.split('\t').collect();
        let code = parts.first().copied().unwrap_or("");
        if code.starts_with('R') {
            let (Some(old), Some(new)) = (
                parts.get(1).copied().filter(|p| !p.is_empty()),
                parts.get(2).copied().filter(|p| !p.is_empty()),
            ) else {
                continue;
            };
            let patch = git(cwd, &["diff", "-M", base, "--", old, new]).unwrap_or_default();
            files.push(build_file(new, Some(old), FileStatus::Renamed, &patch));
        } else if let Some(path) = parts.get(1).copied().filter(|p| !p.is_empty()) {
            let status = match code.chars().next() {
                Some('A') => FileStatus::Added,
                Some('D') => FileStatus::Deleted,
                _ => FileStatus::Modified,
            };
            let patch = git(cwd, &["diff", base, "--", path]).unwrap_or_default();
            files.push(build_file(path, None, status, &patch));
        }
    }

    let untracked = git(cwd, &["ls-files", "--others", "--exclude-standard"]).unwrap_or_default();
    for path in untracked.lines() {
        if path.trim().is_empty() {
            continue;
        }
        if files.len() >= MAX_FILES {
            break;
        }
        // `--no-index` exits 1 when the files differ, which is every time.
        let patch = git(cwd, &["diff", "--no-index", "--", "/dev/null", path]).unwrap_or_default();
        files.push(build_file(path, None, FileStatus::Untracked, &patch));
    }

    let truncated = files.len() >= MAX_FILES;
    sort_files(&mut files);
    DiffResult {
        git: true,
        root: Some(root.to_string()),
        files,
        truncated_files: Some(truncated),
    }
}

fn sort_files(files: &mut [DiffFile]) {
    files.sort_by(|a, b| a.path.to_lowercase().cmp(&b.path.to_lowercase()));
}

fn build_file(path: &str, old_path: Option<&str>, status: FileStatus, patch: &str) -> DiffFile {
    let (additions, deletions, binary) = count_changes(patch);
    let too_large = patch.len() > MAX_DIFF_BYTES;
    DiffFile {
        path: path.to_string(),
        old_path: old_path.map(str::to_string),
        status,
        additions,
        deletions,
        binary,
        diff: if binary || too_large {
            String::new()
        } else {
            patch.to_string()
        },
        truncated: too_large,
    }
}

/// Branch, upstream, ahead/behind and dirtiness for `cwd`.
///
/// With no upstream every local commit counts as ahead, which is what the Swift core
/// reported and what the at-risk classifier knows to distrust: see
/// [`crate::at_risk`], which counts against the base branch instead.
pub fn state(cwd: &str) -> GitState {
    let Some(inside) = git_line(cwd, &["rev-parse", "--is-inside-work-tree"]) else {
        return GitState::default();
    };
    if inside != "true" {
        return GitState::default();
    }

    // `symbolic-ref` fails on a detached HEAD, which is how a detached HEAD is
    // detected: there is no branch name to report and the panel has to say so.
    let branch = git_line(cwd, &["symbolic-ref", "--short", "HEAD"]);
    let detached = branch.is_none();
    let remote = git_line(cwd, &["remote"]).is_some();
    let upstream = git_line(
        cwd,
        &[
            "rev-parse",
            "--abbrev-ref",
            "--symbolic-full-name",
            "@{upstream}",
        ],
    );

    let (mut ahead, mut behind) = (0i64, 0i64);
    match &upstream {
        Some(u) => {
            if let Some(counts) = git_line(
                cwd,
                &[
                    "rev-list",
                    "--left-right",
                    "--count",
                    &format!("{u}...HEAD"),
                ],
            ) {
                let nums: Vec<i64> = counts
                    .split_whitespace()
                    .map(|n| n.parse().unwrap_or(0))
                    .collect();
                behind = nums.first().copied().unwrap_or(0);
                ahead = nums.get(1).copied().unwrap_or(0);
            }
        }
        None => {
            ahead = git_line(cwd, &["rev-list", "--count", "HEAD"])
                .and_then(|c| c.parse().ok())
                .unwrap_or(0);
        }
    }

    let dirty = git_line(cwd, &["status", "--porcelain"]).is_some();

    GitState {
        git: true,
        branch,
        detached,
        upstream,
        ahead,
        behind,
        dirty,
        remote,
    }
}

/// The last `limit` commits of HEAD, newest first, with the ones not yet on the base
/// branch marked.
///
/// Never fails: an empty repo, a non-repo, or a git that will not answer all come back
/// as an empty picker, because there is nothing for a person to do about any of them.
pub fn recent_commits(cwd: &str, limit: usize) -> Vec<RecentCommit> {
    if repo_root(cwd).is_none() {
        return Vec::new();
    }
    let limit_s = limit.to_string();
    // Unit separator, because a commit subject may contain anything a person typed,
    // tabs included.
    let Some(log) = git(
        cwd,
        &["log", "-n", &limit_s, "--format=%H%x1f%h%x1f%s%x1f%cr"],
    ) else {
        return Vec::new();
    };

    // The `--max-count` cap is safe: any `base..HEAD` commit inside the first `limit`
    // log entries is inside the first `limit` rev-list entries too.
    let ahead: Vec<String> = crate::worktree::default_base_branch(cwd)
        .and_then(|base| {
            git(
                cwd,
                &[
                    "rev-list",
                    &format!("--max-count={limit}"),
                    &format!("{base}..HEAD"),
                ],
            )
        })
        .map(|revs| revs.lines().map(|l| l.trim().to_string()).collect())
        .unwrap_or_default();

    log.lines()
        .filter_map(|line| {
            let f: Vec<&str> = line.split('\u{1f}').collect();
            if f.len() < 4 {
                return None;
            }
            Some(RecentCommit {
                sha: f[0].to_string(),
                short_sha: f[1].to_string(),
                subject: f[2].to_string(),
                relative_age: f[3].to_string(),
                ahead_of_base: ahead.iter().any(|a| a == f[0]),
            })
        })
        .collect()
}

/// The whole-tree change snapshot a file tree and a Quick Open index consume.
pub fn work_tree_status(cwd: &str) -> Vec<WorktreeStatusEntry> {
    let Some(raw) = git(cwd, &["status", "--porcelain"]) else {
        return Vec::new();
    };
    parse_work_tree_status(&raw)
}

/// Parse `git status --porcelain` (v1). `XY <path>`, with renames and copies as
/// `XY <orig> -> <new>`. Lenient: a line that will not parse is skipped rather than
/// failing a whole snapshot.
pub fn parse_work_tree_status(raw: &str) -> Vec<WorktreeStatusEntry> {
    let mut entries = Vec::new();
    for line in raw.lines() {
        let chars: Vec<char> = line.chars().collect();
        if chars.len() < 4 {
            continue;
        }
        let index = chars[0];
        let work_tree = chars[1];
        let rest: String = chars[3..].iter().collect();
        let renamed = matches!(index, 'R' | 'C') || matches!(work_tree, 'R' | 'C');
        let (path, orig) = match renamed.then(|| rest.split_once(" -> ")).flatten() {
            Some((orig, new)) => (new.to_string(), Some(orig.to_string())),
            None => (rest, None),
        };
        entries.push(WorktreeStatusEntry {
            path,
            orig_path: orig,
            index: index.to_string(),
            work_tree: work_tree.to_string(),
        });
    }
    entries
}

/// The Quick Open index: tracked files plus untracked-but-not-ignored ones,
/// worktree-relative, deduped and sorted.
///
/// `git ls-files` rather than a directory walk, because it honours `.gitignore` for
/// free — `node_modules` and `.build` never enter the list — and because a walk of a
/// large checkout is thousands of syscalls for an answer git already has indexed.
/// `-z` so a filename containing a newline stays one entry.
pub fn tracked_files(cwd: &str, limit: usize) -> Vec<String> {
    let Some(out) = git(
        cwd,
        &[
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
        ],
    ) else {
        return Vec::new();
    };
    let mut seen = std::collections::HashSet::new();
    let mut files: Vec<String> = Vec::new();
    for raw in out.split('\0') {
        if raw.is_empty() || !seen.insert(raw.to_string()) {
            continue;
        }
        files.push(raw.to_string());
        if files.len() >= limit {
            break;
        }
    }
    files.sort_by_key(|f| f.to_lowercase());
    files
}

/// A cheap change summary: file count and total line additions/deletions vs HEAD,
/// plus a signature of the name-status set for debouncing the review badge.
///
/// Two invocations whatever the tree holds, which is the point — this runs on every
/// settle edge, and a per-file patch loop here would cost a fork per changed file on
/// a machine where a fork is a quarter of a second.
pub fn change_stat(cwd: &str) -> crate::changes::ChangeStat {
    crate::changes::rollup(cwd).unwrap_or_default()
}

/// Read one file out of the work tree, refusing any path that leaves it.
///
/// The same guard the discard paths use, for the same reason: this is addressed by a
/// client over a socket, and a `path` carrying `../` would turn a session read into a
/// read of the whole filesystem.
pub fn read_file(cwd: &str, requested: &str) -> Result<(String, String)> {
    let root = repo_root(cwd).unwrap_or_else(|| cwd.to_string());
    let rel = scoped_relative_path(&root, requested)
        .ok_or_else(|| GitError::new("path escapes working dir"))?;
    let abs = Path::new(&root).join(&rel);
    let body = std::fs::read(&abs).map_err(|_| GitError::new("could not read file"))?;
    let text = String::from_utf8(body).map_err(|_| GitError::new("file is not utf-8 text"))?;
    Ok((rel, text))
}

// ── writes ───────────────────────────────────────────────────────────────────

/// Stage everything and commit it.
///
/// The emptiness check is before the commit and not after: `git commit` with nothing
/// staged exits non-zero with advice about `git add`, and "Nothing to commit." is the
/// sentence a person can act on.
pub fn commit_all(cwd: &str, message: &str) -> Result<CommitResult> {
    git_strict(cwd, &["add", "-A"], None)?;
    let staged = git_strict(cwd, &["diff", "--cached", "--name-only"], None)?.0;
    if staged.trim().is_empty() {
        return Err(GitError::new("Nothing to commit."));
    }
    git_strict(cwd, &["commit", "-m", message], None)
        .map_err(|e| with_fallback(e, "Commit failed"))?;
    let sha = git_strict(cwd, &["rev-parse", "--short", "HEAD"], None)?
        .0
        .trim()
        .to_string();
    let subject = git_strict(cwd, &["log", "-1", "--pretty=%s"], None)?
        .0
        .trim()
        .to_string();
    Ok(CommitResult { sha, subject })
}

/// Push the current branch, setting the upstream to origin on the first push.
pub fn push_current(cwd: &str) -> Result<PushResult> {
    let branch = git_line(cwd, &["symbolic-ref", "--short", "HEAD"])
        .ok_or_else(|| GitError::new("Detached HEAD — checkout a branch to push."))?;
    let has_upstream = git_line(cwd, &["rev-parse", "--abbrev-ref", "@{upstream}"]).is_some();
    let args: Vec<&str> = if has_upstream {
        vec!["push"]
    } else {
        vec!["push", "-u", "origin", &branch]
    };
    let (stdout, stderr) =
        git_strict(cwd, &args, None).map_err(|e| with_fallback(e, "Push failed"))?;
    // git reports a SUCCESSFUL push on stderr, so both streams are the output.
    let combined = format!("{stdout}{stderr}").trim().to_string();
    Ok(PushResult {
        branch,
        output: if combined.is_empty() {
            "Pushed.".to_string()
        } else {
            combined
        },
    })
}

/// Discard the uncommitted changes to ONE file and nothing else.
///
/// A tracked file is restored from HEAD; an untracked one is deleted, because that is
/// what discarding a brand-new file means. Never `git checkout .` and never `git reset
/// --hard`: the blast radius is exactly the path [`scoped_relative_path`] approved.
pub fn revert_file(cwd: &str, requested: &str) -> Result<RevertResult> {
    let root = repo_root(cwd).ok_or_else(|| GitError::new("Not a git repository."))?;
    let rel = scoped_relative_path(&root, requested)
        .ok_or_else(|| GitError::new("Refusing to revert an unscoped or out-of-tree path."))?;
    if is_tracked(&root, &rel) {
        if git_strict(&root, &["checkout", "HEAD", "--", &rel], None).is_err() {
            // A repo with no commit yet has no HEAD to restore from; the index is the
            // only thing behind the file.
            git_strict(&root, &["checkout", "--", &rel], None)
                .map_err(|e| with_fallback(e, "Revert failed"))?;
        }
    } else {
        let abs = Path::new(&root).join(&rel);
        std::fs::remove_file(&abs)
            .map_err(|_| GitError::new(format!("Could not remove untracked file: {rel}")))?;
    }
    Ok(RevertResult {
        path: rel,
        reverted: true,
    })
}

/// Discard ONE hunk of a tracked file's change, leaving the rest of the file alone.
///
/// The patch is re-derived here rather than taken from the client: the diff the panel
/// is showing may be seconds old, and reverse-applying a stale hunk either fails or
/// discards the wrong lines. A hunk index that no longer resolves says so.
pub fn revert_hunk(cwd: &str, requested: &str, hunk_index: usize) -> Result<RevertResult> {
    let root = repo_root(cwd).ok_or_else(|| GitError::new("Not a git repository."))?;
    let rel = scoped_relative_path(&root, requested)
        .ok_or_else(|| GitError::new("Refusing to revert an unscoped or out-of-tree path."))?;
    if !is_tracked(&root, &rel) {
        return Err(GitError::new(
            "Per-hunk revert isn't supported for untracked files — revert the whole file.",
        ));
    }
    let base = if git_line(&root, &["rev-parse", "--verify", "HEAD"]).is_some() {
        "HEAD"
    } else {
        EMPTY_TREE
    };
    let patch = git(&root, &["diff", base, "--", &rel]).unwrap_or_default();
    let single = single_hunk_patch(&patch, hunk_index).ok_or_else(|| {
        GitError::new("That hunk no longer exists — the file changed since the diff was shown.")
    })?;
    git_strict(&root, &["apply", "--reverse", "--recount"], Some(&single))
        .map_err(|e| with_fallback(e, "Revert hunk failed"))?;
    Ok(RevertResult {
        path: rel,
        reverted: true,
    })
}

fn is_tracked(cwd: &str, rel: &str) -> bool {
    git_strict(cwd, &["ls-files", "--error-unmatch", "--", rel], None).is_ok()
}

/// Validate that `requested` names a single file STRICTLY inside `root`, returning the
/// worktree-relative path when it does.
///
/// This is the guard, and it is the reason a `sessionRevert` frame is not a write
/// primitive aimed at the whole filesystem. It refuses an empty request, a NUL or
/// newline (both of which change what `git` sees), anything that resolves to the
/// worktree root itself (that would be the whole tree), and anything that resolves
/// outside it — whether by `../` or by arriving absolute.
///
/// Resolution is lexical on purpose. A `std::fs::canonicalize` would refuse a path
/// that does not exist yet, and a discard of a file that was just deleted is exactly
/// the case that has to work; it would also follow symlinks, which would make the
/// answer depend on what is on disk rather than on what was asked for.
pub fn scoped_relative_path(root: &str, requested: &str) -> Option<String> {
    let trimmed = requested.trim();
    if trimmed.is_empty() || trimmed.contains('\0') || trimmed.contains('\n') {
        return None;
    }
    let root = lexically_normal(Path::new(root));
    let joined = if Path::new(trimmed).is_absolute() {
        PathBuf::from(trimmed)
    } else {
        root.join(trimmed)
    };
    let candidate = lexically_normal(&joined);
    let rel = candidate.strip_prefix(&root).ok()?;
    let rel = rel.to_str()?;
    (!rel.is_empty()).then(|| rel.to_string())
}

/// Collapse `.` and `..` without touching the filesystem. A leading `..` that would
/// climb above the root is kept, so the `strip_prefix` above rejects it.
fn lexically_normal(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for part in path.components() {
        match part {
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    out.push("..");
                }
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// Reassemble a one-hunk patch from a one-file unified diff: the file header (every
/// line before the first `@@`) plus the hunk at `index`.
///
/// Pure, so the hunk arithmetic is testable without a repo — which matters, because
/// getting it wrong means reverse-applying a patch that silently takes the wrong lines
/// out of somebody's file.
pub fn single_hunk_patch(patch: &str, index: usize) -> Option<String> {
    if patch.is_empty() {
        return None;
    }
    let mut header: Vec<&str> = Vec::new();
    let mut hunks: Vec<Vec<&str>> = Vec::new();
    for line in patch.split('\n') {
        if line.starts_with("@@") {
            hunks.push(vec![line]);
        } else if let Some(cur) = hunks.last_mut() {
            cur.push(line);
        } else {
            header.push(line);
        }
    }
    let hunk = hunks.get(index)?;
    let mut out = header.join("\n");
    if !out.is_empty() {
        out.push('\n');
    }
    out.push_str(&hunk.join("\n"));
    if !out.ends_with('\n') {
        out.push('\n');
    }
    Some(out)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::path::PathBuf;

    pub(crate) fn run(cwd: &Path, args: &[&str]) {
        let out = Command::new("git")
            .args(args)
            .current_dir(cwd)
            .env("GIT_AUTHOR_NAME", "test")
            .env("GIT_AUTHOR_EMAIL", "test@localhost")
            .env("GIT_COMMITTER_NAME", "test")
            .env("GIT_COMMITTER_EMAIL", "test@localhost")
            .output()
            .expect("git");
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    pub(crate) fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "juancoded-git-{tag}-{}-{:?}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A repo with one commit and one modified file.
    pub(crate) fn repo(tag: &str) -> PathBuf {
        let dir = scratch(tag).join("repo");
        std::fs::create_dir_all(&dir).unwrap();
        run(&dir, &["init", "--quiet", "--initial-branch=main"]);
        std::fs::write(dir.join("a.txt"), "one\ntwo\nthree\n").unwrap();
        run(&dir, &["add", "a.txt"]);
        run(&dir, &["commit", "--quiet", "-m", "base"]);
        dir
    }

    #[test]
    fn a_directory_that_is_not_a_repo_is_not_a_failure() {
        let dir = scratch("nogit");
        let d = diff(dir.to_str().unwrap());
        assert!(!d.git);
        assert!(d.files.is_empty());
        assert!(!state(dir.to_str().unwrap()).git);
        assert!(recent_commits(dir.to_str().unwrap(), 10).is_empty());
        std::fs::remove_dir_all(dir.parent().unwrap()).ok();
    }

    #[test]
    fn a_modified_file_and_an_untracked_one_are_both_in_the_diff() {
        let dir = repo("diff");
        let cwd = dir.to_str().unwrap();
        std::fs::write(dir.join("a.txt"), "one\ntwo\nthree\nfour\n").unwrap();
        std::fs::write(dir.join("new.txt"), "fresh\n").unwrap();

        let d = diff(cwd);
        assert!(d.git);
        // git resolves symlinks in `--show-toplevel`, and /tmp is one on macOS.
        assert_eq!(
            d.root.map(std::path::PathBuf::from),
            Some(std::fs::canonicalize(&dir).unwrap())
        );
        let paths: Vec<&str> = d.files.iter().map(|f| f.path.as_str()).collect();
        assert_eq!(paths, vec!["a.txt", "new.txt"]);
        let a = &d.files[0];
        assert_eq!(a.status, FileStatus::Modified);
        assert_eq!(a.additions, 1);
        assert_eq!(a.deletions, 0);
        assert!(a.diff.contains("+four"));
        assert_eq!(d.files[1].status, FileStatus::Untracked);
        std::fs::remove_dir_all(dir.parent().unwrap()).ok();
    }

    #[test]
    fn state_reports_the_branch_and_the_dirt() {
        let dir = repo("state");
        let cwd = dir.to_str().unwrap();
        let clean = state(cwd);
        assert!(clean.git);
        assert_eq!(clean.branch.as_deref(), Some("main"));
        assert!(!clean.detached);
        assert!(!clean.dirty);
        assert!(!clean.remote, "a fresh repo has no remote");
        assert_eq!(clean.ahead, 1, "no upstream: every commit counts as ahead");

        std::fs::write(dir.join("a.txt"), "changed\n").unwrap();
        assert!(state(cwd).dirty);
        std::fs::remove_dir_all(dir.parent().unwrap()).ok();
    }

    #[test]
    fn commit_and_push_against_a_local_bare_remote() {
        let dir = repo("push");
        let cwd = dir.to_str().unwrap();
        let remote = dir.parent().unwrap().join("origin.git");
        run(
            dir.parent().unwrap(),
            &["init", "--quiet", "--bare", remote.to_str().unwrap()],
        );
        run(&dir, &["remote", "add", "origin", remote.to_str().unwrap()]);

        assert_eq!(
            commit_all(cwd, "nothing").unwrap_err(),
            GitError::new("Nothing to commit.")
        );

        std::fs::write(dir.join("a.txt"), "one\ntwo\nthree\nfour\n").unwrap();
        let committed = commit_all(cwd, "feat: a fourth line").unwrap();
        assert_eq!(committed.subject, "feat: a fourth line");
        assert!(!committed.sha.is_empty());

        let pushed = push_current(cwd).unwrap();
        assert_eq!(pushed.branch, "main");
        assert!(!pushed.output.is_empty());
        // The upstream exists now, so the second push takes the other branch.
        let after = state(cwd);
        assert_eq!(after.upstream.as_deref(), Some("origin/main"));
        assert_eq!(after.ahead, 0);
        assert!(after.remote);
        std::fs::remove_dir_all(dir.parent().unwrap()).ok();
    }

    #[test]
    fn reverting_one_file_leaves_the_others_alone() {
        let dir = repo("revert");
        let cwd = dir.to_str().unwrap();
        std::fs::write(dir.join("b.txt"), "b\n").unwrap();
        run(&dir, &["add", "b.txt"]);
        run(&dir, &["commit", "--quiet", "-m", "b"]);

        std::fs::write(dir.join("a.txt"), "clobbered\n").unwrap();
        std::fs::write(dir.join("b.txt"), "also clobbered\n").unwrap();
        std::fs::write(dir.join("junk.txt"), "untracked\n").unwrap();

        let r = revert_file(cwd, "a.txt").unwrap();
        assert_eq!(r.path, "a.txt");
        assert!(r.reverted);
        assert_eq!(
            std::fs::read_to_string(dir.join("a.txt")).unwrap(),
            "one\ntwo\nthree\n"
        );
        assert_eq!(
            std::fs::read_to_string(dir.join("b.txt")).unwrap(),
            "also clobbered\n",
            "the other file was not touched"
        );

        revert_file(cwd, "junk.txt").unwrap();
        assert!(
            !dir.join("junk.txt").exists(),
            "an untracked discard deletes"
        );
        std::fs::remove_dir_all(dir.parent().unwrap()).ok();
    }

    #[test]
    fn reverting_one_hunk_keeps_the_other() {
        let dir = repo("hunk");
        let cwd = dir.to_str().unwrap();
        // Far enough apart that git emits two hunks rather than one.
        let base: String = (1..=40).map(|n| format!("line {n}\n")).collect();
        std::fs::write(dir.join("wide.txt"), &base).unwrap();
        run(&dir, &["add", "wide.txt"]);
        run(&dir, &["commit", "--quiet", "-m", "wide"]);

        let edited = base
            .replace("line 3\n", "line 3 EDITED\n")
            .replace("line 37\n", "line 37 EDITED\n");
        std::fs::write(dir.join("wide.txt"), &edited).unwrap();
        let patch = git(cwd, &["diff", "HEAD", "--", "wide.txt"]).unwrap();
        assert_eq!(patch.matches("\n@@ ").count(), 2, "two hunks: {patch}");

        revert_hunk(cwd, "wide.txt", 0).unwrap();
        let after = std::fs::read_to_string(dir.join("wide.txt")).unwrap();
        assert!(after.contains("line 3\n"), "the first hunk was discarded");
        assert!(
            after.contains("line 37 EDITED"),
            "the second hunk survived: {after}"
        );
        std::fs::remove_dir_all(dir.parent().unwrap()).ok();
    }

    #[test]
    fn a_path_that_leaves_the_tree_is_refused() {
        let root = "/repo";
        assert_eq!(
            scoped_relative_path(root, "src/main.rs"),
            Some("src/main.rs".into())
        );
        assert_eq!(
            scoped_relative_path(root, "./src/./main.rs"),
            Some("src/main.rs".into())
        );
        assert_eq!(
            scoped_relative_path(root, "/repo/src/main.rs"),
            Some("src/main.rs".into())
        );
        assert_eq!(
            scoped_relative_path(root, "src/../lib/x.rs"),
            Some("lib/x.rs".into())
        );

        for bad in [
            "",
            "   ",
            "..",
            "../outside",
            "src/../../outside",
            "/etc/passwd",
            "/repo",
            "/repo/",
            ".",
            "/repo/../elsewhere/x",
            "a\0b",
            "a\nb",
        ] {
            assert_eq!(
                scoped_relative_path(root, bad),
                None,
                "{bad:?} must be refused"
            );
        }
        // A sibling whose name merely starts with the root's is not inside it.
        assert_eq!(scoped_relative_path(root, "/repository/x"), None);
    }

    #[test]
    fn a_refused_path_never_reaches_git() {
        let dir = repo("escape");
        let cwd = dir.to_str().unwrap();
        let outside = dir.parent().unwrap().join("secret.txt");
        std::fs::write(&outside, "do not touch\n").unwrap();

        let err = revert_file(cwd, "../secret.txt").unwrap_err();
        assert!(err.0.contains("unscoped or out-of-tree"), "{err}");
        assert!(outside.exists(), "the file outside the tree survived");
        assert!(revert_hunk(cwd, "../secret.txt", 0).is_err());
        assert!(read_file(cwd, "../secret.txt").is_err());
        std::fs::remove_dir_all(dir.parent().unwrap()).ok();
    }

    #[test]
    fn a_single_hunk_patch_keeps_the_header_and_one_hunk() {
        let patch = "diff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n@@ -9 +9 @@\n-c\n+d\n";
        let first = single_hunk_patch(patch, 0).unwrap();
        assert!(first.contains("--- a/x"));
        assert!(first.contains("@@ -1 +1 @@"));
        assert!(!first.contains("@@ -9 +9 @@"));
        let second = single_hunk_patch(patch, 1).unwrap();
        assert!(second.contains("@@ -9 +9 @@"));
        assert!(!second.contains("@@ -1 +1 @@"));
        assert!(single_hunk_patch(patch, 2).is_none());
        assert!(single_hunk_patch("", 0).is_none());
    }

    #[test]
    fn porcelain_parses_renames_and_untracked() {
        let entries = parse_work_tree_status(
            " M src/a.rs\n?? new.txt\nR  old/name.rs -> new/name.rs\nAD gone.rs\n",
        );
        assert_eq!(entries.len(), 4);
        assert_eq!(entries[0].path, "src/a.rs");
        assert_eq!(entries[0].index, " ");
        assert_eq!(entries[0].work_tree, "M");
        assert!(entries[1].untracked());
        assert_eq!(entries[2].path, "new/name.rs");
        assert_eq!(entries[2].orig_path.as_deref(), Some("old/name.rs"));
        assert_eq!(entries[3].path, "gone.rs");
    }

    #[test]
    fn tracked_files_lists_both_planes_and_honours_gitignore() {
        let dir = repo("lsfiles");
        let cwd = dir.to_str().unwrap();
        std::fs::write(dir.join(".gitignore"), "ignored/\n").unwrap();
        std::fs::create_dir_all(dir.join("ignored")).unwrap();
        std::fs::write(dir.join("ignored/x.txt"), "x\n").unwrap();
        std::fs::write(dir.join("untracked.txt"), "u\n").unwrap();

        let files = tracked_files(cwd, 100);
        assert!(files.contains(&"a.txt".to_string()));
        assert!(files.contains(&"untracked.txt".to_string()));
        assert!(
            !files.iter().any(|f| f.starts_with("ignored/")),
            "gitignore is honoured: {files:?}"
        );
        assert_eq!(tracked_files(cwd, 1).len(), 1, "the cap is a cap");
        std::fs::remove_dir_all(dir.parent().unwrap()).ok();
    }

    #[test]
    fn a_commits_own_diff_is_read_back_from_its_parent() {
        let dir = repo("commitdiff");
        let cwd = dir.to_str().unwrap();
        std::fs::write(dir.join("a.txt"), "one\ntwo\nthree\nfour\n").unwrap();
        let made = commit_all(cwd, "add four").unwrap();

        let commits = recent_commits(cwd, 10);
        assert_eq!(commits.len(), 2);
        assert_eq!(commits[0].subject, "add four");
        assert!(commits[0].short_sha.starts_with(&made.sha[..4]));

        let d = commit_diff(cwd, &commits[0].sha).unwrap();
        assert!(d.git);
        assert_eq!(d.files.len(), 1);
        assert_eq!(d.files[0].path, "a.txt");
        assert_eq!(d.files[0].additions, 1);

        // The root commit diffs against the empty tree rather than failing.
        let root = commit_diff(cwd, &commits[1].sha).unwrap();
        assert_eq!(root.files.len(), 1);
        assert_eq!(root.files[0].additions, 3);

        assert!(commit_diff(cwd, "deadbeefdeadbeef").is_err());
        std::fs::remove_dir_all(dir.parent().unwrap()).ok();
    }

    #[test]
    fn a_file_is_read_relative_to_the_tree() {
        let dir = repo("readfile");
        let cwd = dir.to_str().unwrap();
        let (rel, body) = read_file(cwd, "a.txt").unwrap();
        assert_eq!(rel, "a.txt");
        assert_eq!(body, "one\ntwo\nthree\n");
        assert!(read_file(cwd, "nope.txt").is_err());
        std::fs::remove_dir_all(dir.parent().unwrap()).ok();
    }
}
