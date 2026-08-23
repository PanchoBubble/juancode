//! The claude-jsonl source: `~/.claude/projects/<slug>/<sessionId>.jsonl`.
//!
//! # Correlating a juancode session to its file
//!
//! The mapping is not a guess, it is something the spawn already established.
//! `juancoded-core`'s provider spec starts claude with `--session-id <juancode id>`
//! (`IdSource::Pinned`), so the CLI adopts our UUID as its own conversation id and
//! `SessionMeta::cli_session_id` is that same string. The file name is that id, and
//! the directory is the session's cwd with every character outside `[A-Za-z0-9]`
//! replaced by `-`. That rule was checked against all 304 project directories on this
//! machine that carry a `cwd`, and matched every one.
//!
//! Two things keep it honest when the primary path misses. The cwd claude recorded is
//! the one it was given, so a symlinked path (`/tmp` against `/private/tmp`) produces
//! a different slug: the canonicalised cwd is tried second. And a session whose cwd
//! moved, or that was adopted with only an id, is found by a scan for `<id>.jsonl`
//! across the project directories, newest first. The scan is the fallback rather than
//! the rule because it is a directory walk and the slug is a string operation.
//!
//! Adopt-external sessions are covered by the same answer, and by the same code:
//! `adoptExternal` carries the CLI's own `cliSessionId` from the client, the registry
//! writes it to `cli_session_id`, and the resume spawns `--resume <that id>`, which
//! keeps writing to the file already named after it. What adopt-external does not
//! bring is a trustworthy cwd, since the conversation may have been started somewhere
//! else entirely, and that is exactly the case the scan fallback exists for.
//!
//! # What is deliberately not read
//!
//! `isSidechain` lines (a sub-agent's own conversation), attachments,
//! `file-history-snapshot`/`file-history-delta`, `mode`, `permission-mode`,
//! `ai-title`, `atis-latch`, `last-prompt`, hook summaries, and the `signature` on a
//! thinking block. None of them map onto one of the eight typed events, and the seam
//! is not a transcription of claude's format.

use std::path::{Path, PathBuf};

use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::tail::{read_new_lines, TailPosition};
use crate::{
    clamp, BindRequest, Binding, Cursor, Emitted, Source, TokenUsage, TranscriptEvent,
    TranscriptSource,
};

/// Where claude keeps its per-project transcripts.
pub fn projects_root() -> PathBuf {
    if let Ok(override_dir) = std::env::var("JUANCODE_CLAUDE_PROJECTS_DIR") {
        if !override_dir.is_empty() {
            return PathBuf::from(override_dir);
        }
    }
    PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".claude/projects")
}

/// A cwd as claude names its directory: every non-alphanumeric character becomes `-`.
pub fn project_slug(cwd: &str) -> String {
    cwd.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

/// The transcript for one conversation id, by slug first and by search second.
pub fn transcript_path(root: &Path, cwd: &str, cli_session_id: &str) -> Option<PathBuf> {
    let file = format!("{cli_session_id}.jsonl");
    let direct = root.join(project_slug(cwd)).join(&file);
    if direct.is_file() {
        return Some(direct);
    }
    // The cwd claude recorded is the one it was handed, and on a Mac `/tmp` and
    // `/private/tmp` are the same directory under two names.
    if let Ok(resolved) = std::fs::canonicalize(cwd) {
        let resolved = root
            .join(project_slug(&resolved.to_string_lossy()))
            .join(&file);
        if resolved.is_file() {
            return Some(resolved);
        }
    }
    search_projects(root, &file)
}

/// Every project directory, newest match wins. The cost of a walk is why this is the
/// fallback: a session that moved, or one adopted with an id and no reliable cwd.
fn search_projects(root: &Path, file: &str) -> Option<PathBuf> {
    let mut best: Option<(PathBuf, std::time::SystemTime)> = None;
    for entry in std::fs::read_dir(root).ok()?.flatten() {
        if !entry.file_type().is_ok_and(|t| t.is_dir()) {
            continue;
        }
        let candidate = entry.path().join(file);
        let Ok(meta) = std::fs::metadata(&candidate) else {
            continue;
        };
        if !meta.is_file() {
            continue;
        }
        let mtime = meta.modified().unwrap_or(std::time::UNIX_EPOCH);
        if best.as_ref().is_none_or(|(_, best_at)| mtime > *best_at) {
            best = Some((candidate, mtime));
        }
    }
    best.map(|(path, _)| path)
}

/// The durable resume point for one transcript file.
///
/// The parser's own state rides along with the offset because it is derived from the
/// bytes before it: which turn is open, and which model request has already been
/// announced. Restoring one without the other would either duplicate a `Step` after a
/// restart or orphan every event of the turn in progress.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeCursor {
    #[serde(flatten)]
    pub position: TailPosition,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub step: Option<String>,
}

/// Reads claude's own jsonl. Holds no state: everything it needs is in the cursor.
#[derive(Debug, Clone, Default)]
pub struct ClaudeJsonl {
    root: Option<PathBuf>,
}

impl ClaudeJsonl {
    pub fn new() -> Self {
        Self::default()
    }

    /// Point the source at a different projects directory. Tests use it; so would a
    /// second claude install.
    pub fn with_root(root: impl Into<PathBuf>) -> Self {
        Self {
            root: Some(root.into()),
        }
    }

    fn root(&self) -> PathBuf {
        self.root.clone().unwrap_or_else(projects_root)
    }
}

impl TranscriptSource for ClaudeJsonl {
    fn name(&self) -> &'static str {
        "claude-jsonl"
    }

    fn source(&self) -> Source {
        Source::ClaudeJsonl
    }

    fn bind(&self, req: &BindRequest) -> Option<Binding> {
        if req.provider != "claude" {
            return None;
        }
        let id = req.cli_session_id.as_deref()?;
        transcript_path(&self.root(), &req.cwd, id).map(|path| Binding::ClaudeJsonl { path })
    }

    fn read(&self, binding: &Binding, cursor: &Cursor) -> Result<(Vec<Emitted>, Cursor)> {
        let Binding::ClaudeJsonl { path } = binding else {
            anyhow::bail!(
                "claude-jsonl was handed a {} binding",
                binding.source().as_str()
            );
        };
        let mut state: ClaudeCursor = if cursor.is_empty() {
            ClaudeCursor::default()
        } else {
            serde_json::from_str(cursor).unwrap_or_default()
        };

        let read = read_new_lines(path, &state.position)?;
        if read.restarted {
            // The bytes the turn and step were derived from are gone.
            state.turn = None;
            state.step = None;
        }
        state.position = read.position;

        let mut out = Vec::new();
        for line in &read.lines {
            parse_line(line, &mut state, &mut out);
        }
        Ok((out, serde_json::to_string(&state)?))
    }
}

/// One jsonl line into zero or more events. Anything unrecognised is skipped: a schema
/// we have never seen must not be able to stop the stream, because the offset would
/// never get past it.
fn parse_line(line: &str, state: &mut ClaudeCursor, out: &mut Vec<Emitted>) {
    let Ok(value) = serde_json::from_str::<Value>(line) else {
        return;
    };
    // A sub-agent writes its whole conversation into the same file. Interleaving it
    // with the session's own turns would make every consumer filter it back out.
    if value.get("isSidechain").and_then(Value::as_bool) == Some(true) {
        return;
    }
    let at = value
        .get("timestamp")
        .and_then(Value::as_str)
        .and_then(crate::time::epoch_ms);

    match value.get("type").and_then(Value::as_str) {
        Some("user") => parse_user(&value, at, state, out),
        Some("assistant") => parse_assistant(&value, at, state, out),
        _ => {}
    }
}

fn parse_user(value: &Value, at: Option<i64>, state: &mut ClaudeCursor, out: &mut Vec<Emitted>) {
    let content = value.pointer("/message/content");

    // Tool results arrive as user messages; they continue the open turn rather than
    // starting one.
    let results = blocks(content)
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("tool_result"))
        .collect::<Vec<_>>();
    if !results.is_empty() {
        for block in results {
            let Some(call) = block.get("tool_use_id").and_then(Value::as_str) else {
                continue;
            };
            let ok = block.get("is_error").and_then(Value::as_bool) != Some(true);
            out.push(Emitted::new(
                at,
                state.turn.clone(),
                TranscriptEvent::ToolResult {
                    call: call.to_string(),
                    ok,
                    output: clamp(&flatten_text(block.get("content"))),
                },
            ));
        }
        return;
    }

    // The injections claude makes on the user's behalf (caveats, reminders) are marked
    // meta and are not somebody typing.
    if value.get("isMeta").and_then(Value::as_bool) == Some(true) {
        return;
    }
    let prompt = flatten_text(content);
    if prompt.trim().is_empty() {
        return;
    }

    // A prompt while a turn is open ended that turn, whatever the model was doing.
    if let Some(open) = state.turn.take() {
        out.push(Emitted::new(
            at,
            Some(open),
            TranscriptEvent::TurnEnd { reason: None },
        ));
    }
    let turn = value
        .get("promptId")
        .and_then(Value::as_str)
        .or_else(|| value.get("uuid").and_then(Value::as_str))
        .unwrap_or("turn")
        .to_string();
    state.turn = Some(turn.clone());
    state.step = None;
    out.push(Emitted::new(
        at,
        Some(turn),
        TranscriptEvent::TurnStart {
            prompt: clamp(&prompt),
        },
    ));
}

fn parse_assistant(
    value: &Value,
    at: Option<i64>,
    state: &mut ClaudeCursor,
    out: &mut Vec<Emitted>,
) {
    // One API request becomes several lines, one per content block, all carrying the
    // same `requestId` and the same `usage`. The step and its cost are announced when
    // the request is first seen, not once per block.
    let request = value.get("requestId").and_then(Value::as_str);
    if let Some(request) = request {
        if state.step.as_deref() != Some(request) {
            state.step = Some(request.to_string());
            out.push(Emitted::new(
                at,
                state.turn.clone(),
                TranscriptEvent::Step {
                    step: request.to_string(),
                    model: value
                        .pointer("/message/model")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                },
            ));
            let usage = usage_of(value.pointer("/message/usage"));
            if !usage.is_zero() {
                out.push(Emitted::new(
                    at,
                    state.turn.clone(),
                    TranscriptEvent::Usage {
                        step: Some(request.to_string()),
                        usage,
                    },
                ));
            }
        }
    }

    let step = state.step.clone();
    for block in blocks(value.pointer("/message/content")) {
        match block.get("type").and_then(Value::as_str) {
            Some("text") => {
                let text = block
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if !text.trim().is_empty() {
                    out.push(Emitted::new(
                        at,
                        state.turn.clone(),
                        TranscriptEvent::Assistant {
                            step: step.clone(),
                            text: clamp(text),
                        },
                    ));
                }
            }
            Some("thinking") => {
                let text = block
                    .get("thinking")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if !text.trim().is_empty() {
                    out.push(Emitted::new(
                        at,
                        state.turn.clone(),
                        TranscriptEvent::Thinking {
                            step: step.clone(),
                            text: clamp(text),
                        },
                    ));
                }
            }
            Some("tool_use") => {
                let Some(call) = block.get("id").and_then(Value::as_str) else {
                    continue;
                };
                out.push(Emitted::new(
                    at,
                    state.turn.clone(),
                    TranscriptEvent::ToolCall {
                        call: call.to_string(),
                        name: block
                            .get("name")
                            .and_then(Value::as_str)
                            .unwrap_or("tool")
                            .to_string(),
                        input: clamp(&compact(block.get("input"))),
                    },
                ));
            }
            _ => {}
        }
    }

    if value
        .pointer("/message/stop_reason")
        .and_then(Value::as_str)
        == Some("end_turn")
    {
        if let Some(open) = state.turn.take() {
            state.step = None;
            out.push(Emitted::new(
                at,
                Some(open),
                TranscriptEvent::TurnEnd {
                    reason: Some("end_turn".into()),
                },
            ));
        }
    }
}

fn blocks(content: Option<&Value>) -> impl Iterator<Item = &Value> {
    content
        .and_then(Value::as_array)
        .map(|a| a.as_slice())
        .unwrap_or(&[])
        .iter()
}

/// A message's content as plain text, whether it is a string, a block list, or the
/// nested content of a tool result.
fn flatten_text(content: Option<&Value>) -> String {
    match content {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(items)) => {
            let mut parts = Vec::new();
            for item in items {
                match item.get("type").and_then(Value::as_str) {
                    Some("text") => {
                        if let Some(text) = item.get("text").and_then(Value::as_str) {
                            parts.push(text.to_string());
                        }
                    }
                    Some("tool_result") => parts.push(flatten_text(item.get("content"))),
                    _ => {}
                }
            }
            parts.retain(|p| !p.is_empty());
            parts.join("\n")
        }
        _ => String::new(),
    }
}

fn compact(value: Option<&Value>) -> String {
    value.map(Value::to_string).unwrap_or_else(|| "{}".into())
}

fn usage_of(usage: Option<&Value>) -> TokenUsage {
    let Some(usage) = usage else {
        return TokenUsage::default();
    };
    let n = |key: &str| usage.get(key).and_then(Value::as_u64).unwrap_or(0);
    TokenUsage {
        input: n("input_tokens"),
        output: n("output_tokens"),
        cache_read: n("cache_read_input_tokens"),
        cache_write: n("cache_creation_input_tokens"),
        reasoning: usage
            .pointer("/output_tokens_details/thinking_tokens")
            .and_then(Value::as_u64)
            .unwrap_or(0),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn events(lines: &[&str]) -> Vec<TranscriptEvent> {
        let mut state = ClaudeCursor::default();
        let mut out = Vec::new();
        for line in lines {
            parse_line(line, &mut state, &mut out);
        }
        out.into_iter().map(|e| e.event).collect()
    }

    #[test]
    fn the_slug_is_every_non_alphanumeric_character_replaced() {
        assert_eq!(
            project_slug("/Users/me/workdir/personal/juancode"),
            "-Users-me-workdir-personal-juancode"
        );
        // A dot becomes a dash like everything else, which is what makes
        // `~/.config/nvim` land in `-Users-me--config-nvim`.
        assert_eq!(
            project_slug("/Users/me/.config/nvim"),
            "-Users-me--config-nvim"
        );
        assert_eq!(project_slug("/tmp/a_b.c"), "-tmp-a-b-c");
    }

    #[test]
    fn a_human_prompt_opens_a_turn_and_an_end_turn_closes_it() {
        let out = events(&[
            r#"{"type":"user","promptId":"p1","message":{"role":"user","content":"do the thing"}}"#,
            r#"{"type":"assistant","requestId":"req_1","message":{"model":"claude-opus-5","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}"#,
        ]);
        assert_eq!(
            out,
            [
                TranscriptEvent::TurnStart {
                    prompt: "do the thing".into()
                },
                TranscriptEvent::Step {
                    step: "req_1".into(),
                    model: Some("claude-opus-5".into())
                },
                TranscriptEvent::Assistant {
                    step: Some("req_1".into()),
                    text: "done".into()
                },
                TranscriptEvent::TurnEnd {
                    reason: Some("end_turn".into())
                },
            ]
        );
    }

    #[test]
    fn one_request_split_across_lines_announces_its_step_and_cost_once() {
        let usage = r#""usage":{"input_tokens":2,"output_tokens":313,"cache_read_input_tokens":27982,"cache_creation_input_tokens":22602,"output_tokens_details":{"thinking_tokens":43}}"#;
        let out = events(&[
            &format!(
                r#"{{"type":"assistant","requestId":"req_1","message":{{"model":"m",{usage},"content":[{{"type":"thinking","thinking":"hm","signature":"sig"}}],"stop_reason":"tool_use"}}}}"#
            ),
            &format!(
                r#"{{"type":"assistant","requestId":"req_1","message":{{"model":"m",{usage},"content":[{{"type":"tool_use","id":"toolu_1","name":"Bash","input":{{"command":"ls"}}}}],"stop_reason":"tool_use"}}}}"#
            ),
        ]);
        assert_eq!(
            out,
            [
                TranscriptEvent::Step {
                    step: "req_1".into(),
                    model: Some("m".into())
                },
                TranscriptEvent::Usage {
                    step: Some("req_1".into()),
                    usage: TokenUsage {
                        input: 2,
                        output: 313,
                        cache_read: 27982,
                        cache_write: 22602,
                        reasoning: 43,
                    }
                },
                TranscriptEvent::Thinking {
                    step: Some("req_1".into()),
                    text: "hm".into()
                },
                TranscriptEvent::ToolCall {
                    call: "toolu_1".into(),
                    name: "Bash".into(),
                    input: r#"{"command":"ls"}"#.into()
                },
            ]
        );
    }

    #[test]
    fn a_tool_result_is_matched_to_its_call_and_carries_its_error_flag() {
        let out = events(&[
            r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}}"#,
            r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_2","is_error":true,"content":[{"type":"text","text":"no such file"}]}]}}"#,
        ]);
        assert_eq!(
            out,
            [
                TranscriptEvent::ToolResult {
                    call: "toolu_1".into(),
                    ok: true,
                    output: "ok".into()
                },
                TranscriptEvent::ToolResult {
                    call: "toolu_2".into(),
                    ok: false,
                    output: "no such file".into()
                },
            ]
        );
    }

    #[test]
    fn a_redacted_thinking_block_is_a_signature_and_not_a_thought() {
        let out = events(&[
            r#"{"type":"assistant","requestId":"r","message":{"content":[{"type":"thinking","thinking":"","signature":"long-base64"}]}}"#,
        ]);
        assert_eq!(
            out,
            [TranscriptEvent::Step {
                step: "r".into(),
                model: None
            }]
        );
    }

    #[test]
    fn a_line_we_do_not_recognise_is_skipped_rather_than_failing_the_stream() {
        let out = events(&[
            r#"{"type":"user","promptId":"p1","message":{"content":"first"}}"#,
            "not json at all",
            r#"{"type":"file-history-snapshot","messageId":"x"}"#,
            r#"{"type":"ai-title","aiTitle":"something"}"#,
            r#"{"type":"someTypeFromTheFuture","payload":{"deeply":{"nested":true}}}"#,
            r#"{}"#,
            r#"{"type":"assistant","requestId":"r","message":{"content":[{"type":"text","text":"still here"}]}}"#,
        ]);
        assert_eq!(
            out,
            [
                TranscriptEvent::TurnStart {
                    prompt: "first".into()
                },
                TranscriptEvent::Step {
                    step: "r".into(),
                    model: None
                },
                TranscriptEvent::Assistant {
                    step: Some("r".into()),
                    text: "still here".into()
                },
            ]
        );
    }

    #[test]
    fn a_sub_agents_conversation_stays_out_of_the_sessions_own_turns() {
        let out = events(&[
            r#"{"type":"user","promptId":"p1","message":{"content":"parent asks"}}"#,
            r#"{"type":"assistant","isSidechain":true,"requestId":"sub","message":{"content":[{"type":"text","text":"child thinks"}]}}"#,
            r#"{"type":"user","isSidechain":true,"message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"child tool"}]}}"#,
        ]);
        assert_eq!(
            out,
            [TranscriptEvent::TurnStart {
                prompt: "parent asks".into()
            }]
        );
    }

    #[test]
    fn an_injected_meta_message_is_not_somebody_typing() {
        let out = events(&[
            r#"{"type":"user","isMeta":true,"message":{"content":"Caveat: the messages below were generated..."}}"#,
        ]);
        assert!(out.is_empty());
    }

    #[test]
    fn a_second_prompt_closes_the_turn_the_model_was_still_working_on() {
        let out = events(&[
            r#"{"type":"user","promptId":"p1","message":{"content":"first"}}"#,
            r#"{"type":"assistant","requestId":"r1","message":{"content":[{"type":"text","text":"working"}],"stop_reason":"tool_use"}}"#,
            r#"{"type":"user","promptId":"p2","message":{"content":"actually, stop"}}"#,
        ]);
        assert_eq!(out[3], TranscriptEvent::TurnEnd { reason: None });
        assert_eq!(
            out[4],
            TranscriptEvent::TurnStart {
                prompt: "actually, stop".into()
            }
        );
    }

    #[test]
    fn every_event_of_a_turn_carries_the_turn_it_belongs_to() {
        let mut state = ClaudeCursor::default();
        let mut out = Vec::new();
        for line in [
            r#"{"type":"user","promptId":"p1","message":{"content":"go"}}"#,
            r#"{"type":"assistant","requestId":"r1","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{}}]}}"#,
            r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"bytes"}]}}"#,
        ] {
            parse_line(line, &mut state, &mut out);
        }
        assert!(
            out.iter().all(|e| e.turn.as_deref() == Some("p1")),
            "{out:?}"
        );
        assert_eq!(state.turn.as_deref(), Some("p1"));
        assert_eq!(state.step.as_deref(), Some("r1"));
    }

    #[test]
    fn a_timestamp_is_carried_as_epoch_millis() {
        let mut state = ClaudeCursor::default();
        let mut out = Vec::new();
        parse_line(
            r#"{"type":"user","promptId":"p1","timestamp":"2026-08-23T10:09:58.290Z","message":{"content":"go"}}"#,
            &mut state,
            &mut out,
        );
        assert_eq!(out[0].at_ms, Some(1_787_479_798_290));
    }
}
