//! "Review with Claude" — a headless pass over a working tree's diff.
//!
//! A port of `JuancodeServices/Review.swift`. The genuine `claude` binary is launched
//! with the user's own environment untouched — their auth, their config, their MCP —
//! exactly like a session pty. Nothing is shadowed and nothing is overridden. The only
//! thing asked of the CLI is `-p` with a JSON schema, so what comes back is structured
//! enough to hang on the lines of a diff instead of being prose somebody has to read.
//!
//! Three pure pieces and one process. The prompt is a pure function of the diff and the
//! human comments staged against it; the output parse is a pure function of the CLI's
//! stdout; the normalisation of one finding is a pure function of one JSON object. Only
//! [`run_review`] spawns anything, which is why the interesting half of this file is
//! testable without a model.

use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::diff::{DiffFile, FileStatus};
use crate::provider::resolve_provider_bin;

/// Cap on the prompt, so an enormous change set cannot blow up cost or latency.
const MAX_PROMPT_BYTES: usize = 200_000;

/// A review is a whole model turn over a whole diff. Four minutes is long, and the
/// alternative to waiting is reporting a timeout on a pass that was going to succeed.
const REVIEW_TIMEOUT: Duration = Duration::from_secs(240);

/// Severity, most serious first — the order is the enum's, and the schema hands the CLI
/// exactly these spellings.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ReviewSeverity {
    Critical,
    High,
    Medium,
    Low,
    Info,
}

impl ReviewSeverity {
    const ALL: [Self; 5] = [
        Self::Critical,
        Self::High,
        Self::Medium,
        Self::Low,
        Self::Info,
    ];

    fn as_str(self) -> &'static str {
        match self {
            Self::Critical => "critical",
            Self::High => "high",
            Self::Medium => "medium",
            Self::Low => "low",
            Self::Info => "info",
        }
    }

    fn parse(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|v| v.as_str() == s)
    }
}

/// Which side of a hunk a line is on. `new` for added and context lines, `old` for
/// removed ones.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CommentSide {
    Old,
    New,
}

impl CommentSide {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Old => "old",
            Self::New => "new",
        }
    }
}

/// One finding, anchored to the file and line it concerns.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReviewFinding {
    pub file: String,
    pub side: CommentSide,
    /// Absent for a file-level finding with no single line — which the schema asks for
    /// explicitly, so the model says "the whole file" rather than picking line 1.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<i64>,
    pub severity: ReviewSeverity,
    pub title: String,
    pub note: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ReviewStatus {
    Ok,
    Empty,
    Error,
}

/// One review pass, ready to cache and serve.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReviewResult {
    pub status: ReviewStatus,
    pub findings: Vec<ReviewFinding>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    pub created_at: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl ReviewResult {
    fn failed(created_at: i64, message: impl Into<String>) -> Self {
        Self {
            status: ReviewStatus::Error,
            findings: Vec::new(),
            summary: None,
            created_at,
            error: Some(message.into()),
        }
    }
}

/// One inline comment a human staged against a diff.
///
/// Both a stored record and the steering a review pass is given, which is why it is one
/// type and not two: a comment the panel is showing and a comment the model is told
/// about are the same comment, and a second shape for it is a second thing to keep in
/// step.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffComment {
    pub id: String,
    pub session_id: String,
    pub file: String,
    pub side: CommentSide,
    pub line: i64,
    pub end_line: i64,
    pub body: String,
    pub created_at: i64,
    /// The annotated diff line(s) the comment was staged against, each with its `+`/`-`
    /// marker intact, newline-joined — captured at staging time so the composer can
    /// quote exactly what was highlighted rather than what the line says now.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quote: Option<String>,
    /// When the comment was staged against one commit's diff rather than the working
    /// tree: that commit's sha and subject, so the composer can label the group.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit_sha: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit_subject: Option<String>,
}

const SYSTEM_PROMPT: &str = concat!(
    "You are a meticulous senior code reviewer. You are given a unified git diff of a working tree. ",
    "Review ONLY the changes shown — bugs, correctness, security, error handling, and clear quality issues. ",
    "Anchor each finding to the file and line it concerns, using the line numbers from the diff's new side ",
    "(removed lines use the old side). Be concrete and skip nitpicks and style preferences. ",
    "If the diff looks clean, return an empty findings array with a short summary saying so. ",
    "Respond ONLY via the structured output schema.",
);

/// The schema handed to `claude --json-schema`, so findings come back validated rather
/// than as prose this core would have to guess at.
fn findings_schema() -> Value {
    let severities: Vec<&str> = ReviewSeverity::ALL.iter().map(|s| s.as_str()).collect();
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "summary": { "type": "string" },
            "findings": {
                "type": "array",
                "items": {
                    "type": "object",
                    "additionalProperties": false,
                    "properties": {
                        "file": { "type": "string",
                                  "description": "Repo-relative path exactly as it appears in the diff header" },
                        "side": { "type": "string", "enum": ["old", "new"],
                                  "description": "'new' for added/context lines, 'old' for removed lines" },
                        "line": { "type": ["integer", "null"],
                                  "description": "Line number on the chosen side; null for a file-level finding with no single line" },
                        "severity": { "type": "string", "enum": severities },
                        "title": { "type": "string", "description": "One-line summary of the issue" },
                        "note": { "type": "string", "description": "What's wrong and how to fix it" }
                    },
                    "required": ["file", "side", "line", "severity", "title", "note"]
                }
            }
        },
        "required": ["summary", "findings"]
    })
}

/// Build the user prompt: the diff, with any human inline comments ahead of it as
/// steering. The comments come first on purpose — they are what the person asking for
/// the review already knows they are worried about.
pub fn build_prompt(files: &[DiffFile], comments: &[DiffComment]) -> String {
    let mut parts: Vec<String> = vec!["Review the following working-tree changes.\n".into()];

    if !comments.is_empty() {
        parts.push(
            "The human reviewer left these inline comments — treat them as priorities and \
respond to their concerns where relevant:"
                .into(),
        );
        for c in comments {
            let lines = if c.end_line > c.line {
                format!("{}-{}", c.line, c.end_line)
            } else {
                c.line.to_string()
            };
            parts.push(format!(
                "- {}:{} ({}) — {}",
                c.file,
                lines,
                c.side.as_str(),
                c.body
            ));
        }
        parts.push(String::new());
    }

    parts.push("Unified diff:\n".into());
    for f in files {
        let header = match &f.old_path {
            Some(old) => format!("{old} → {}", f.path),
            None => f.path.clone(),
        };
        parts.push(format!(
            "### {header} ({}, +{} −{})",
            status_word(f.status),
            f.additions,
            f.deletions
        ));
        if f.binary {
            parts.push("(binary file — no textual diff)".into());
        } else if f.truncated {
            parts.push("(diff too large — omitted)".into());
        } else if !f.diff.is_empty() {
            parts.push(format!("```diff\n{}\n```", f.diff));
        }
        parts.push(String::new());
    }

    let prompt = parts.join("\n");
    if prompt.chars().count() <= MAX_PROMPT_BYTES {
        return prompt;
    }
    let head: String = prompt.chars().take(MAX_PROMPT_BYTES).collect();
    format!("{head}\n\n[diff truncated for length — review what is shown]")
}

/// Parse `claude -p --output-format json` stdout into a result.
///
/// Two layers, and the second one is why this is not a one-line deserialise: the CLI's
/// envelope carries the schema-validated payload as a *string* in its `result` field.
/// When that string is not schema-shaped — the model answered in prose despite the
/// schema — the prose is kept as the summary rather than thrown away, because a review
/// that says "looks fine" is still an answer.
pub fn parse_review_output(stdout: &str, created_at: i64) -> ReviewResult {
    let Some(envelope) = serde_json::from_str::<Value>(stdout)
        .ok()
        .filter(Value::is_object)
    else {
        return ReviewResult::failed(created_at, "Could not parse CLI output.");
    };

    let is_error = envelope.get("is_error").and_then(Value::as_bool) == Some(true);
    let subtype = envelope.get("subtype").and_then(Value::as_str);
    // Only a genuine string is a result: a `result` that is an object is the CLI
    // reporting something other than the answer that was asked for.
    let result = envelope.get("result").and_then(Value::as_str);

    if is_error || subtype != Some("success") || result.is_none() {
        let message = result
            .filter(|r| !r.is_empty())
            .unwrap_or("Review run failed.");
        return ReviewResult::failed(created_at, message);
    }
    let result = result.unwrap_or_default();

    let Some(payload) = serde_json::from_str::<Value>(result)
        .ok()
        .filter(Value::is_object)
    else {
        let trimmed = result.trim();
        return ReviewResult {
            status: ReviewStatus::Ok,
            findings: Vec::new(),
            summary: (!trimmed.is_empty()).then(|| trimmed.to_string()),
            created_at,
            error: None,
        };
    };

    let findings = payload
        .get("findings")
        .and_then(Value::as_array)
        .map(|raw| raw.iter().filter_map(normalize_finding).collect())
        .unwrap_or_default();
    let summary = payload
        .get("summary")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);

    ReviewResult {
        status: ReviewStatus::Ok,
        findings,
        summary,
        created_at,
        error: None,
    }
}

/// Coerce one raw finding into a [`ReviewFinding`], or drop it.
///
/// The schema is a request, not a guarantee — a model can still answer with a line
/// number as a string or a severity nobody defined. Anything that is not the literal
/// `"old"` is the new side, a non-integer line is no line, an unknown severity is
/// `info`, and a finding with no file, or with neither a title nor a note, is dropped:
/// it could not be shown anywhere or say anything if it were.
fn normalize_finding(raw: &Value) -> Option<ReviewFinding> {
    let obj = raw.as_object()?;
    let file = obj.get("file").and_then(Value::as_str).unwrap_or_default();
    if file.is_empty() {
        return None;
    }
    let side = if obj.get("side").and_then(Value::as_str) == Some("old") {
        CommentSide::Old
    } else {
        CommentSide::New
    };
    // Integral only: a string, a float or a bool is not a line number, however much it
    // looks like one.
    let line = obj.get("line").and_then(|v| match v {
        Value::Number(n) if n.is_i64() => n.as_i64(),
        _ => None,
    });
    let severity = obj
        .get("severity")
        .and_then(Value::as_str)
        .and_then(ReviewSeverity::parse)
        .unwrap_or(ReviewSeverity::Info);
    let title = obj
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let note = obj
        .get("note")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    if title.is_empty() && note.is_empty() {
        return None;
    }
    Some(ReviewFinding {
        file: file.to_string(),
        side,
        line,
        severity,
        title,
        note,
    })
}

/// Run a full review pass.
///
/// An empty diff short-circuits to `Empty` without launching anything: there is nothing
/// to review, and spending a model turn to be told so is a cost with no answer at the
/// end of it.
pub async fn run_review(
    cwd: &str,
    files: &[DiffFile],
    comments: &[DiffComment],
    now: i64,
) -> ReviewResult {
    if files.is_empty() {
        return ReviewResult {
            status: ReviewStatus::Empty,
            findings: Vec::new(),
            summary: None,
            created_at: now,
            error: None,
        };
    }
    match run_claude(&build_prompt(files, comments), cwd).await {
        Ok(stdout) => parse_review_output(&stdout, now),
        Err(message) => ReviewResult::failed(now, message),
    }
}

/// Launch the user's own `claude`, feeding the prompt over stdin so a large diff cannot
/// hit `ARG_MAX`. Environment untouched, per the prime directive.
async fn run_claude(prompt: &str, cwd: &str) -> Result<String, String> {
    use tokio::io::AsyncWriteExt;

    let bin =
        resolve_provider_bin("claude").ok_or_else(|| "claude CLI not installed".to_string())?;
    let schema = findings_schema().to_string();
    let mut child = tokio::process::Command::new(bin)
        .args([
            "-p",
            "--output-format",
            "json",
            "--json-schema",
            &schema,
            "--append-system-prompt",
            SYSTEM_PROMPT,
        ])
        .current_dir(cwd)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| e.to_string())?;

    if let Some(mut stdin) = child.stdin.take() {
        // A CLI that exited before reading the whole prompt is not an error here: its
        // stdout still carries the envelope, and that is what the caller is after.
        let _ = stdin.write_all(prompt.as_bytes()).await;
        let _ = stdin.shutdown().await;
    }

    let out = tokio::time::timeout(REVIEW_TIMEOUT, child.wait_with_output())
        .await
        .map_err(|_| "Review timed out.".to_string())?
        .map_err(|e| e.to_string())?;

    // `claude -p` exits non-zero on a hard failure, and the JSON envelope — when there
    // is one — carries the real reason, so stdout wins and stderr is only the fallback.
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    if !stdout.trim().is_empty() {
        return Ok(stdout);
    }
    let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
    Err(if stderr.is_empty() {
        format!(
            "claude exited with code {}",
            out.status.code().unwrap_or(-1)
        )
    } else {
        stderr
    })
}

// ── the diff a review is of ────────────────────────────────────────────────

/// The word a prompt header uses for a file's status, which is the word git uses.
fn status_word(status: FileStatus) -> &'static str {
    match status {
        FileStatus::Modified => "modified",
        FileStatus::Added => "added",
        FileStatus::Deleted => "deleted",
        FileStatus::Renamed => "renamed",
        FileStatus::Untracked => "untracked",
    }
}

/// The working tree's changes against `HEAD`, as a review prompt needs them.
///
/// A thin wrapper over [`crate::git::diff`] rather than a read of its own: that is the
/// diff the Changes panel draws (juancode-52e8.14.5), and a review of a *different*
/// diff from the one on screen would be a review of something nobody is looking at.
/// Empty for a clean tree, for a directory that is not a worktree, and for a git that
/// is not there — all three of which [`run_review`] answers `Empty` to, without
/// spending a model turn.
pub fn working_tree_files(cwd: &str) -> Vec<DiffFile> {
    crate::git::diff(cwd).files
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file() -> DiffFile {
        DiffFile {
            path: "src/a.ts".into(),
            old_path: None,
            status: FileStatus::Modified,
            additions: 1,
            deletions: 0,
            binary: false,
            diff: "@@ -0,0 +1 @@\n+const x = 1;\n".into(),
            truncated: false,
        }
    }

    fn comment() -> DiffComment {
        DiffComment {
            id: "c1".into(),
            session_id: "s1".into(),
            file: "src/a.ts".into(),
            side: CommentSide::New,
            line: 1,
            end_line: 1,
            body: "is this right?".into(),
            created_at: 0,
            quote: None,
            commit_sha: None,
            commit_subject: None,
        }
    }

    /// Wrap a payload the way `claude -p --output-format json` does: the schema JSON
    /// arrives as a *string* inside the envelope, not as an object.
    fn envelope(result: Value) -> String {
        json!({
            "type": "result",
            "subtype": "success",
            "is_error": false,
            "result": result.to_string(),
        })
        .to_string()
    }

    #[test]
    fn the_prompt_carries_each_files_diff_and_its_size() {
        let prompt = build_prompt(&[file()], &[]);
        assert!(prompt.contains("src/a.ts"));
        assert!(prompt.contains("+const x = 1;"));
        assert!(prompt.contains("(modified, +1 −0)"));
    }

    #[test]
    fn a_humans_inline_comments_lead_the_prompt() {
        let prompt = build_prompt(&[file()], &[comment()]);
        assert!(prompt.contains("inline comments"));
        assert!(prompt.contains("src/a.ts:1 (new) — is this right?"));
        // A range reads as a range rather than as its first line.
        let ranged = build_prompt(
            &[file()],
            &[DiffComment {
                end_line: 4,
                ..comment()
            }],
        );
        assert!(ranged.contains("src/a.ts:1-4 (new)"));
    }

    /// A file with no readable diff still has to appear: a review that silently skipped
    /// the binary asset somebody just committed would be a review of the wrong change.
    #[test]
    fn a_binary_or_oversized_file_is_named_rather_than_dropped() {
        let prompt = build_prompt(
            &[
                DiffFile {
                    binary: true,
                    diff: String::new(),
                    ..file()
                },
                DiffFile {
                    path: "b".into(),
                    diff: String::new(),
                    truncated: true,
                    ..file()
                },
            ],
            &[],
        );
        assert!(prompt.contains("binary file"));
        assert!(prompt.contains("diff too large"));
        assert!(prompt.contains("### b"));
    }

    #[test]
    fn an_enormous_diff_is_capped_and_says_so() {
        let huge = DiffFile {
            diff: "+x\n".repeat(200_000),
            ..file()
        };
        let prompt = build_prompt(&[huge], &[]);
        assert!(prompt.contains("[diff truncated for length"));
        assert!(prompt.chars().count() < 210_000);
    }

    #[test]
    fn a_validated_payload_comes_back_as_findings_and_a_summary() {
        let out = parse_review_output(
            &envelope(json!({
                "summary": "One issue found.",
                "findings": [
                    {"file": "src/a.ts", "side": "new", "line": 1,
                     "severity": "high", "title": "Bug", "note": "Off by one."}
                ]
            })),
            5,
        );
        assert_eq!(out.status, ReviewStatus::Ok);
        assert_eq!(out.summary.as_deref(), Some("One issue found."));
        assert_eq!(out.created_at, 5);
        assert_eq!(
            out.findings,
            vec![ReviewFinding {
                file: "src/a.ts".into(),
                side: CommentSide::New,
                line: Some(1),
                severity: ReviewSeverity::High,
                title: "Bug".into(),
                note: "Off by one.".into(),
            }]
        );
    }

    /// The schema is a request, not a guarantee. Everything here is a shape a model has
    /// actually produced despite one.
    #[test]
    fn a_payload_that_ignored_the_schema_is_clamped_rather_than_refused() {
        let out = parse_review_output(
            &envelope(json!({
                "summary": 42,
                "findings": [
                    {"file": "a", "side": "weird", "line": "x",
                     "severity": "nope", "title": "", "note": "kept"},
                    {"file": "", "side": "new", "line": 1,
                     "severity": "low", "title": "x", "note": "y"},
                    {"file": "b", "side": "old", "line": 2,
                     "severity": "low", "title": "", "note": ""}
                ]
            })),
            0,
        );
        assert_eq!(out.summary, None, "a number is not a summary");
        assert_eq!(
            out.findings,
            vec![ReviewFinding {
                file: "a".into(),
                side: CommentSide::New,
                line: None,
                severity: ReviewSeverity::Info,
                title: String::new(),
                note: "kept".into(),
            }],
            "the fileless one and the empty one are dropped; the rest is clamped"
        );
    }

    /// A line number that is a float or a bool is not a line number. JSON has one
    /// number type, so this is the check that keeps `1.5` off line 1.
    #[test]
    fn only_a_whole_number_is_a_line() {
        let out = parse_review_output(
            &envelope(json!({
                "summary": "",
                "findings": [
                    {"file": "a", "side": "new", "line": 1.5, "severity": "low", "title": "t", "note": ""},
                    {"file": "b", "side": "new", "line": true, "severity": "low", "title": "t", "note": ""},
                    {"file": "c", "side": "new", "line": null, "severity": "low", "title": "t", "note": ""}
                ]
            })),
            0,
        );
        assert_eq!(
            out.findings.iter().map(|f| f.line).collect::<Vec<_>>(),
            vec![None, None, None]
        );
    }

    #[test]
    fn a_cli_level_failure_is_reported_as_itself() {
        let out = parse_review_output(
            r#"{"type":"result","subtype":"success","is_error":true,"result":"Credit balance is too low"}"#,
            0,
        );
        assert_eq!(out.status, ReviewStatus::Error);
        assert_eq!(out.error.as_deref(), Some("Credit balance is too low"));

        assert_eq!(
            parse_review_output("not json", 0).status,
            ReviewStatus::Error
        );
        // A subtype that is not success is a failure even when nothing said so.
        assert_eq!(
            parse_review_output(r#"{"subtype":"error_max_turns","result":"gave up"}"#, 0)
                .error
                .as_deref(),
            Some("gave up")
        );
    }

    /// The model answered in prose despite the schema. Keeping the prose is the whole
    /// difference between "looks fine to me" and an empty panel.
    #[test]
    fn prose_where_a_payload_was_asked_for_is_kept_as_the_summary() {
        let out = parse_review_output(
            r#"{"type":"result","subtype":"success","is_error":false,"result":"Looks fine to me."}"#,
            0,
        );
        assert_eq!(out.status, ReviewStatus::Ok);
        assert_eq!(out.summary.as_deref(), Some("Looks fine to me."));
        assert!(out.findings.is_empty());
    }

    /// The schema is what makes the output machine-readable, so the five severities and
    /// the two sides in it have to be the ones this file parses back.
    #[test]
    fn the_schema_offers_exactly_the_values_the_parse_accepts() {
        let schema = findings_schema().to_string();
        for sev in ReviewSeverity::ALL {
            assert!(schema.contains(sev.as_str()), "{sev:?} must be offered");
        }
        assert!(schema.contains(r#"["old","new"]"#));
        assert!(schema.contains(r#"["integer","null"]"#));
    }

    #[tokio::test]
    async fn an_empty_diff_is_answered_without_spending_a_model_turn() {
        // The binary is pointed at nothing reachable: if this spawned, it would fail
        // loudly rather than pass.
        std::env::set_var("JUANCODE_CLAUDE_BIN", "/does/not/exist/claude");
        let out = run_review("/tmp", &[], &[], 7).await;
        assert_eq!(out.status, ReviewStatus::Empty);
        assert_eq!(out.created_at, 7);
        assert!(out.error.is_none());
        std::env::remove_var("JUANCODE_CLAUDE_BIN");
    }
}
