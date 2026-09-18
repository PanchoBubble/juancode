//! Unified diff, read back into the per-file shape the wire carries.
//!
//! The half of `DiffParse.swift` that is not a renderer. The hunk/line split that the
//! panel draws stays in Swift beside the view that consumes it — it produces
//! `CoreGraphics` offsets and comment anchors, and nothing on the wire has ever
//! carried a hunk. What DOES have to live here is the opposite direction: taking one
//! combined patch (`git diff -M <a> <b>`, which is how a commit's own diff is read)
//! and splitting it back into the `DiffFile` per-file shape, because that is the shape
//! `git.rs` answers with and a client parses.

use serde::{Deserialize, Serialize};

/// Per-file cap. A single file's patch larger than this is summarised — counts kept,
/// body dropped — rather than carried: a generated lockfile is megabytes of diff that
/// nobody reads line by line, and it would be megabytes on every poll.
pub const MAX_DIFF_BYTES: usize = 400_000;

/// What happened to a file, as the panel colours it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FileStatus {
    Modified,
    Added,
    Deleted,
    Renamed,
    Untracked,
}

/// One file's change: what it is, how much of it, and the patch itself.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffFile {
    pub path: String,
    /// Where a rename came from, else absent.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub old_path: Option<String>,
    pub status: FileStatus,
    pub additions: usize,
    pub deletions: usize,
    pub binary: bool,
    /// The unified diff. Empty for a binary file and for one past [`MAX_DIFF_BYTES`],
    /// which `truncated` distinguishes from a file with no changed lines.
    pub diff: String,
    pub truncated: bool,
}

/// Added and removed line counts, and whether the patch is binary at all.
///
/// The binary markers are matched only at the start of a line and only outside the
/// `+`/`-` prefixes, so a source file that happens to contain the words "Binary files"
/// on an added line is not reported as a binary blob with no changes.
pub fn count_changes(diff: &str) -> (usize, usize, bool) {
    let mut additions = 0usize;
    let mut deletions = 0usize;
    for line in diff.split('\n') {
        if line.starts_with("Binary files ") || line.starts_with("GIT binary patch") {
            return (0, 0, true);
        }
        if line.starts_with('+') && !line.starts_with("+++") {
            additions += 1;
        } else if line.starts_with('-') && !line.starts_with("---") {
            deletions += 1;
        }
    }
    (additions, deletions, false)
}

/// Split a combined unified diff into per-file entries.
///
/// Anything before the first `diff --git` header is a tool's preamble and is dropped.
/// Same-path entries are folded together, because a patch SERIES (one chunk per
/// commit) carries a file touched by three commits as three chunks, and three entries
/// for one path means duplicate ids in a list view and counts that describe only the
/// first commit.
pub fn parse_multi_file_diff(patch: &str) -> Vec<DiffFile> {
    if patch.is_empty() {
        return Vec::new();
    }
    let mut chunks: Vec<Vec<&str>> = Vec::new();
    for line in patch.split('\n') {
        if line.starts_with("diff --git ") {
            chunks.push(vec![line]);
        } else if let Some(cur) = chunks.last_mut() {
            cur.push(line);
        }
    }
    coalesce_by_path(chunks.iter().filter_map(|c| diff_file(c)).collect())
}

fn coalesce_by_path(files: Vec<DiffFile>) -> Vec<DiffFile> {
    let mut index: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    let mut out: Vec<DiffFile> = Vec::new();
    for f in files {
        match index.get(&f.path) {
            None => {
                index.insert(f.path.clone(), out.len());
                out.push(f);
            }
            Some(&i) => {
                let prev = &mut out[i];
                prev.old_path = prev.old_path.take().or(f.old_path);
                prev.additions += f.additions;
                prev.deletions += f.deletions;
                prev.binary = prev.binary || f.binary;
                prev.truncated = prev.truncated || f.truncated;
                if !prev.diff.is_empty() && !f.diff.is_empty() {
                    prev.diff.push('\n');
                    prev.diff.push_str(&f.diff);
                }
            }
        }
    }
    out
}

/// One `DiffFile` out of a single file's chunk, or `None` when no path can be found.
fn diff_file(lines: &[&str]) -> Option<DiffFile> {
    let mut old_marker: Option<String> = None;
    let mut new_marker: Option<String> = None;
    let mut rename_from: Option<String> = None;
    let mut rename_to: Option<String> = None;
    let mut saw_new = false;
    let mut saw_deleted = false;
    let mut binary = false;

    for line in lines {
        if line.starts_with("new file mode") {
            saw_new = true;
        } else if line.starts_with("deleted file mode") {
            saw_deleted = true;
        } else if let Some(rest) = line.strip_prefix("rename from ") {
            rename_from = Some(rest.to_string());
        } else if let Some(rest) = line.strip_prefix("rename to ") {
            rename_to = Some(rest.to_string());
        } else if line.starts_with("Binary files ") || line.starts_with("GIT binary patch") {
            binary = true;
        } else if let Some(rest) = line.strip_prefix("--- ") {
            if let Some(p) = path_from_marker(rest) {
                old_marker = Some(p);
            }
        } else if let Some(rest) = line.strip_prefix("+++ ") {
            if let Some(p) = path_from_marker(rest) {
                new_marker = Some(p);
            }
        }
    }

    let (status, path, old_path) = if let Some(to) = rename_to {
        (FileStatus::Renamed, Some(to), rename_from)
    } else if saw_new {
        (FileStatus::Added, new_marker.clone(), None)
    } else if saw_deleted {
        (FileStatus::Deleted, old_marker.clone(), None)
    } else {
        (
            FileStatus::Modified,
            new_marker.clone().or_else(|| old_marker.clone()),
            None,
        )
    };
    // A pure rename and a binary file carry no `---`/`+++` lines at all, so the
    // `diff --git a/<old> b/<new>` header is the only path left.
    let path = path
        .or_else(|| path_from_git_header(lines.first().copied().unwrap_or("")))
        .filter(|p| !p.is_empty())?;

    let (additions, deletions, _) = count_changes(&lines.join("\n"));
    let text = lines.join("\n");
    let too_large = text.len() > MAX_DIFF_BYTES;
    Some(DiffFile {
        path,
        old_path,
        status,
        additions: if binary { 0 } else { additions },
        deletions: if binary { 0 } else { deletions },
        binary,
        diff: if binary || too_large {
            String::new()
        } else {
            text
        },
        truncated: too_large,
    })
}

/// A `--- `/`+++ ` marker stripped to its path: drop a leading `a/`/`b/`, and map
/// `/dev/null` (the add/delete sentinel) to nothing.
fn path_from_marker(raw: &str) -> Option<String> {
    let s = raw.trim();
    if s == "/dev/null" {
        return None;
    }
    let s = s
        .strip_prefix("a/")
        .or_else(|| s.strip_prefix("b/"))
        .unwrap_or(s);
    (!s.is_empty()).then(|| s.to_string())
}

fn path_from_git_header(header: &str) -> Option<String> {
    let rest = header.strip_prefix("diff --git ")?;
    let (_, new) = rest.split_once(" b/")?;
    (!new.is_empty()).then(|| new.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_two_file_patch_splits_into_two_entries() {
        let patch = "\
diff --git a/one.rs b/one.rs
index 111..222 100644
--- a/one.rs
+++ b/one.rs
@@ -1 +1,2 @@
 keep
+added
diff --git a/two.rs b/two.rs
new file mode 100644
--- /dev/null
+++ b/two.rs
@@ -0,0 +1 @@
+fresh
";
        let files = parse_multi_file_diff(patch);
        assert_eq!(files.len(), 2);
        assert_eq!(files[0].path, "one.rs");
        assert_eq!(files[0].status, FileStatus::Modified);
        assert_eq!(files[0].additions, 1);
        assert_eq!(files[0].deletions, 0);
        assert_eq!(files[1].path, "two.rs");
        assert_eq!(files[1].status, FileStatus::Added);
    }

    #[test]
    fn a_rename_keeps_both_names() {
        let patch = "\
diff --git a/old.rs b/new.rs
similarity index 100%
rename from old.rs
rename to new.rs
";
        let files = parse_multi_file_diff(patch);
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].path, "new.rs");
        assert_eq!(files[0].old_path.as_deref(), Some("old.rs"));
        assert_eq!(files[0].status, FileStatus::Renamed);
    }

    #[test]
    fn a_deletion_is_read_off_the_old_marker() {
        let patch = "\
diff --git a/gone.rs b/gone.rs
deleted file mode 100644
--- a/gone.rs
+++ /dev/null
@@ -1 +0,0 @@
-was here
";
        let files = parse_multi_file_diff(patch);
        assert_eq!(files[0].path, "gone.rs");
        assert_eq!(files[0].status, FileStatus::Deleted);
        assert_eq!(files[0].deletions, 1);
    }

    #[test]
    fn a_binary_file_carries_no_body_and_no_counts() {
        let patch = "\
diff --git a/logo.png b/logo.png
index 111..222 100644
Binary files a/logo.png and b/logo.png differ
";
        let files = parse_multi_file_diff(patch);
        assert_eq!(files[0].path, "logo.png");
        assert!(files[0].binary);
        assert_eq!(files[0].additions, 0);
        assert!(files[0].diff.is_empty());
    }

    #[test]
    fn one_path_touched_by_two_commits_is_one_entry() {
        let patch = "\
diff --git a/x.rs b/x.rs
--- a/x.rs
+++ b/x.rs
@@ -1 +1,2 @@
 keep
+first
diff --git a/x.rs b/x.rs
--- a/x.rs
+++ b/x.rs
@@ -2 +2,3 @@
 first
+second
";
        let files = parse_multi_file_diff(patch);
        assert_eq!(files.len(), 1, "a series folds into one entry per path");
        assert_eq!(files[0].additions, 2, "and its counts sum");
        assert!(files[0].diff.contains("+first"));
        assert!(files[0].diff.contains("+second"));
    }

    #[test]
    fn a_preamble_before_the_first_header_is_dropped() {
        let files = parse_multi_file_diff("some tool said this\nand this\n");
        assert!(files.is_empty());
        assert!(parse_multi_file_diff("").is_empty());
    }

    #[test]
    fn the_binary_marker_only_counts_as_a_header_line() {
        // The words on an ADDED line are content, not a marker.
        let (adds, dels, binary) = count_changes("@@ -1 +1 @@\n+Binary files are awkward\n-old\n");
        assert!(!binary);
        assert_eq!((adds, dels), (1, 1));
    }
}
