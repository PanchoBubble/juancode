//! Drafting a commit message for a working-tree diff, by asking the genuine `claude`
//! CLI in headless print mode.
//!
//! A port of `Commit.swift`. The fidelity rule is the same one the whole harness is
//! built on: the real binary, resolved the way a login shell would resolve it,
//! environment inherited verbatim — so the model that answers is the one the user is
//! logged into, with their settings and their MCP servers, and not a second
//! configuration this daemon invented.
//!
//! Plain text out, no JSON schema: the reply IS the message.

use std::process::Stdio;
use std::time::Duration;

use tokio::io::AsyncWriteExt;

use crate::diff::DiffFile;
use crate::provider::resolve_bin;

/// Cap on the prompt. A change set larger than this is truncated with a note rather
/// than sent whole: past a point the model is summarising noise, and the request is
/// paid for by the line.
const MAX_PROMPT_BYTES: usize = 100_000;

/// A draft nobody is waiting on any more. Two minutes is well past the point where a
/// person has given up and typed their own message.
const TIMEOUT: Duration = Duration::from_secs(120);

const MAX_OUTPUT_BYTES: usize = 8 * 1024 * 1024;

const SYSTEM_PROMPT: &str = concat!(
    "You write a single git commit message for the given working-tree diff. ",
    "Use Conventional Commits style for the subject (e.g. 'feat: …', 'fix: …'), ",
    "imperative mood, ideally under 72 characters. Add a short body (blank line, then ",
    "concise bullet points) only when it genuinely clarifies the change. ",
    "Respond with ONLY the raw commit message — no code fences, no surrounding quotes, no preamble."
);

/// Why no message could be drafted, worded for the person who asked for one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitMessageError(pub String);

impl std::fmt::Display for CommitMessageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for CommitMessageError {}

/// Fold the diff into a prompt, capped.
pub fn build_prompt(files: &[DiffFile]) -> String {
    let mut parts: Vec<String> = vec!["Write a commit message for these changes.\n".to_string()];
    for f in files {
        let header = match f.old_path.as_deref().filter(|p| !p.is_empty()) {
            Some(old) => format!("{old} → {}", f.path),
            None => f.path.clone(),
        };
        let status = serde_json::to_value(f.status)
            .ok()
            .and_then(|v| v.as_str().map(str::to_string))
            .unwrap_or_else(|| "modified".into());
        parts.push(format!(
            "### {header} ({status}, +{} −{})",
            f.additions, f.deletions
        ));
        if f.binary {
            parts.push("(binary file)".into());
        } else if f.truncated {
            parts.push("(diff too large — omitted)".into());
        } else if !f.diff.is_empty() {
            parts.push(format!("```diff\n{}\n```", f.diff));
        }
        parts.push(String::new());
    }
    let prompt = parts.join("\n");
    if prompt.len() <= MAX_PROMPT_BYTES {
        return prompt;
    }
    // Cut on a char boundary: the cap is a size, not an index into a grapheme.
    let mut cut = MAX_PROMPT_BYTES;
    while cut > 0 && !prompt.is_char_boundary(cut) {
        cut -= 1;
    }
    format!("{}\n\n[diff truncated for length]", &prompt[..cut])
}

/// Strip the code fence or wrapping quotes a model sometimes adds around the message.
pub fn clean_message(raw: &str) -> String {
    let mut s = raw.trim();
    if let Some(rest) = s.strip_prefix("```") {
        // ```lang\n — drop the fence and its language tag, if there is a newline.
        s = match rest.find('\n') {
            Some(nl) if rest[..nl].chars().all(|c| c.is_ascii_alphabetic()) => &rest[nl + 1..],
            _ if rest.chars().all(|c| c.is_ascii_alphabetic()) => "",
            _ => s,
        };
    }
    if let Some(rest) = s.strip_suffix("```") {
        s = rest.strip_suffix('\n').unwrap_or(rest);
    }
    s.trim().to_string()
}

/// Draft a message for `files`, run in `cwd`.
pub async fn generate(cwd: &str, files: &[DiffFile]) -> Result<String, CommitMessageError> {
    if files.is_empty() {
        return Err(CommitMessageError("No changes to describe.".into()));
    }
    let bin = resolve_bin(
        "claude",
        std::env::var("JUANCODE_CLAUDE_BIN").ok().as_deref(),
    )
    .ok_or_else(|| CommitMessageError("claude is not on PATH.".into()))?;
    let prompt = build_prompt(files);

    let mut child = tokio::process::Command::new(bin)
        .args(["-p", "--append-system-prompt", SYSTEM_PROMPT])
        .current_dir(cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| CommitMessageError(format!("could not run claude: {e}")))?;
    if let Some(mut pipe) = child.stdin.take() {
        let _ = pipe.write_all(prompt.as_bytes()).await;
        let _ = pipe.shutdown().await;
    }

    let out = match tokio::time::timeout(TIMEOUT, child.wait_with_output()).await {
        Err(_) => {
            return Err(CommitMessageError(
                "Commit-message generation timed out.".into(),
            ))
        }
        Ok(Err(e)) => return Err(CommitMessageError(format!("could not run claude: {e}"))),
        Ok(Ok(out)) => out,
    };
    if out.stdout.len() > MAX_OUTPUT_BYTES {
        return Err(CommitMessageError(
            "Commit message was implausibly large.".into(),
        ));
    }
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    // Any non-blank stdout is the answer, EVEN on a non-zero exit: the CLI prints its
    // reply and then complains about something unrelated often enough that discarding
    // a good message over the exit code loses the thing that was asked for.
    if stdout.trim().is_empty() {
        let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
        return Err(CommitMessageError(if stderr.is_empty() {
            format!(
                "claude exited with code {}",
                out.status.code().unwrap_or(-1)
            )
        } else {
            stderr
        }));
    }
    let message = clean_message(&stdout);
    if message.is_empty() {
        return Err(CommitMessageError("Empty commit message.".into()));
    }
    Ok(message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diff::FileStatus;

    fn file(path: &str, diff: &str) -> DiffFile {
        DiffFile {
            path: path.into(),
            old_path: None,
            status: FileStatus::Modified,
            additions: 1,
            deletions: 0,
            binary: false,
            diff: diff.into(),
            truncated: false,
        }
    }

    #[test]
    fn the_prompt_names_every_file_and_fences_its_diff() {
        let prompt = build_prompt(&[file("src/a.rs", "@@\n+one\n")]);
        assert!(prompt.contains("### src/a.rs (modified, +1 −0)"));
        assert!(prompt.contains("```diff\n@@\n+one\n\n```"));
    }

    #[test]
    fn a_rename_shows_both_names_and_a_binary_shows_neither_body() {
        let mut renamed = file("new.rs", "");
        renamed.old_path = Some("old.rs".into());
        renamed.status = FileStatus::Renamed;
        let mut binary = file("logo.png", "");
        binary.binary = true;
        let prompt = build_prompt(&[renamed, binary]);
        assert!(prompt.contains("old.rs → new.rs (renamed"));
        assert!(prompt.contains("(binary file)"));
    }

    #[test]
    fn an_enormous_change_set_is_cut_and_says_so() {
        let huge = file("big.rs", &"+line\n".repeat(40_000));
        let prompt = build_prompt(&[huge]);
        assert!(prompt.ends_with("[diff truncated for length]"));
        assert!(prompt.len() < MAX_PROMPT_BYTES + 64);
    }

    #[test]
    fn a_fenced_reply_is_unwrapped() {
        assert_eq!(clean_message("```\nfeat: a thing\n```"), "feat: a thing");
        assert_eq!(clean_message("```text\nfix: b\n```"), "fix: b");
        assert_eq!(clean_message("  feat: plain  \n"), "feat: plain");
        // The trailing fence is stripped wherever it ends the reply — the Swift core
        // does the same, and a model that ends its message with a stray fence is far
        // more common than one that ends it with meaningful backticks.
        assert_eq!(
            clean_message("feat: a thing\n\nsee ```x```"),
            "feat: a thing\n\nsee ```x"
        );
    }

    #[tokio::test]
    async fn nothing_to_describe_is_refused_before_anything_is_spawned() {
        assert_eq!(
            generate("/tmp", &[]).await.unwrap_err(),
            CommitMessageError("No changes to describe.".into())
        );
    }
}
