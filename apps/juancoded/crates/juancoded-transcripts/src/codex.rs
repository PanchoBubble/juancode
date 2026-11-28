//! Codex prose comes from response items; usage comes from cumulative snapshots.
//! Cached input is included in input tokens; reasoning is included in output.

use std::path::{Path, PathBuf};

use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::tail::{read_new_lines, TailPosition};
use crate::{
    BindRequest, Binding, Cursor, Emitted, Source, TokenUsage, TranscriptEvent, TranscriptSource,
};

#[derive(Debug, Clone, Default)]
pub struct CodexJsonl {
    root: Option<PathBuf>,
}

#[derive(Default, Serialize, Deserialize)]
struct CodexCursor {
    position: TailPosition,
    model: Option<String>,
    #[serde(default)]
    prose_version: u8,
}

impl CodexJsonl {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_root(root: impl Into<PathBuf>) -> Self {
        Self {
            root: Some(root.into()),
        }
    }

    fn root(&self) -> PathBuf {
        self.root.clone().unwrap_or_else(|| {
            // Respect the user's real Codex configuration without changing it.
            std::env::var_os("CODEX_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".codex")
                })
                .join("sessions")
        })
    }
}

// Walk only the YYYY/MM/DD hierarchy, never symlink directories. Binding is cached
// by the hub, so a live poll reads only appended bytes from the resolved file.
fn find_rollout(root: &Path, id: &str, depth: usize) -> Option<PathBuf> {
    let suffix = format!("-{id}.jsonl");
    for entry in std::fs::read_dir(root).ok()?.flatten() {
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        if kind.is_file()
            && entry
                .file_name()
                .to_str()
                .is_some_and(|name| name.starts_with("rollout-") && name.ends_with(&suffix))
        {
            return Some(entry.path());
        }
        if kind.is_dir() && depth < 3 {
            if let Some(path) = find_rollout(&entry.path(), id, depth + 1) {
                return Some(path);
            }
        }
    }
    None
}

impl TranscriptSource for CodexJsonl {
    fn name(&self) -> &'static str {
        "codex-jsonl"
    }
    fn source(&self) -> Source {
        Source::CodexJsonl
    }

    fn bind(&self, req: &BindRequest) -> Option<Binding> {
        if req.provider != "codex" {
            return None;
        }
        let id = req.cli_session_id.as_deref()?;
        if id.is_empty() {
            return None;
        }
        find_rollout(&self.root(), id, 0).map(|path| Binding::CodexJsonl { path })
    }

    fn read(&self, binding: &Binding, cursor: &Cursor) -> Result<(Vec<Emitted>, Cursor)> {
        let Binding::CodexJsonl { path } = binding else {
            anyhow::bail!("codex-jsonl received a different source's binding");
        };
        let mut state: CodexCursor = serde_json::from_str(cursor).unwrap_or_default();
        // Older readers consumed the file but emitted only usage. Replay once to
        // recover prose (including pending handoff notes) for existing sessions.
        // Usage snapshots replace totals, so replay does not double bill usage.
        if state.prose_version == 0 {
            state.position = TailPosition::default();
            state.model = None;
            state.prose_version = 1;
        }
        let read = read_new_lines(path, &state.position)?;
        if read.restarted {
            state.model = None;
        }
        state.position = read.position;
        let mut out = Vec::new();
        for line in read.lines {
            let Ok(row) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            let payload = &row["payload"];
            // item_completed also mirrors these messages. Read only response_item
            // so each user prompt and assistant reply is emitted exactly once.
            if row["type"] == "response_item" && payload["type"] == "message" {
                let text = payload["content"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|part| {
                        matches!(part["type"].as_str(), Some("input_text" | "output_text"))
                    })
                    .filter_map(|part| part["text"].as_str())
                    .collect::<Vec<_>>()
                    .join("\n");
                if !text.trim().is_empty() {
                    let event = match payload["role"].as_str() {
                        Some("user") => Some(TranscriptEvent::TurnStart { prompt: text }),
                        Some("assistant") => Some(TranscriptEvent::Assistant { step: None, text }),
                        _ => None,
                    };
                    if let Some(event) = event {
                        out.push(Emitted::new(None, None, event));
                    }
                }
                continue;
            }
            if row["type"] == "turn_context" {
                state.model = payload["model"].as_str().map(str::to_owned);
                continue;
            }
            if row["type"] != "event_msg" || payload["type"] != "token_count" {
                continue;
            }
            let info = &payload["info"];
            let total = &info["total_token_usage"];
            let Some(input) = total["input_tokens"].as_u64() else {
                continue;
            };
            let Some(output) = total["output_tokens"].as_u64() else {
                continue;
            };
            let Some(context_tokens) = info["last_token_usage"]["total_tokens"].as_u64() else {
                continue;
            };
            let cached = total["cached_input_tokens"]
                .as_u64()
                .unwrap_or(0)
                .min(input);
            out.push(Emitted::new(
                None,
                None,
                TranscriptEvent::UsageSnapshot {
                    usage: TokenUsage {
                        input: input - cached,
                        cache_read: cached,
                        output,
                        reasoning: total["reasoning_output_tokens"].as_u64().unwrap_or(0),
                        ..TokenUsage::default()
                    },
                    context_tokens,
                    context_window: info["model_context_window"].as_u64().filter(|n| *n > 0),
                    model: state.model.clone(),
                },
            ));
        }
        Ok((out, serde_json::to_string(&state)?))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handoff_prose_is_read_once_and_backfilled_from_usage_only_cursors() {
        let path = std::env::temp_dir().join(format!("codex-handoff-{}.jsonl", std::process::id()));
        struct Cleanup(PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = std::fs::remove_file(&self.0);
            }
        }
        let _cleanup = Cleanup(path.clone());
        std::fs::write(&path, concat!(
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"developer\",\"content\":[{\"type\":\"input_text\",\"text\":\"instructions\"}]}}\n",
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Context handoff\"}]}}\n",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"item\":{\"type\":\"AgentMessage\",\"content\":[{\"type\":\"Text\",\"text\":\"duplicate\"}]}}}\n",
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"<<<HANDOFF>>>\"},{\"type\":\"output_text\",\"text\":\"Continue next step\\n<<<END HANDOFF>>>\"}]}}\n"
        )).unwrap();
        let source = CodexJsonl::new();
        let binding = Binding::CodexJsonl { path };
        let (events, cursor) = source.read(&binding, &String::new()).unwrap();
        assert_eq!(events.len(), 2);
        assert!(
            matches!(&events[0].event, TranscriptEvent::TurnStart { prompt } if prompt == "Context handoff")
        );
        assert!(
            matches!(&events[1].event, TranscriptEvent::Assistant { text, .. } if text == "<<<HANDOFF>>>\nContinue next step\n<<<END HANDOFF>>>")
        );
        assert!(source.read(&binding, &cursor).unwrap().0.is_empty());
        let mut old: Value = serde_json::from_str(&cursor).unwrap();
        old.as_object_mut().unwrap().remove("prose_version");
        let (backfilled, upgraded) = source.read(&binding, &old.to_string()).unwrap();
        assert_eq!(backfilled, events);
        assert!(source.read(&binding, &upgraded).unwrap().0.is_empty());
    }
}
