use std::sync::Arc;

use juancoded_transcripts::claude::ClaudeJsonl;
use juancoded_transcripts::TranscriptSource;

use crate::plugin::{Context, Plugin};
use crate::services::transcripts::TranscriptsService;

/// Registers the claude-jsonl source with the `transcripts` hub.
///
/// Mounting this row is what makes a claude session's turns, reasoning and tool calls
/// readable as data rather than as terminal bytes. Disabling it by id withdraws the
/// source and every binding it made, and the sessions it was reading go back to being
/// pty output and nothing else.
pub struct TranscriptClaude;

impl Plugin for TranscriptClaude {
    fn name(&self) -> &'static str {
        "transcript-claude"
    }

    fn inject(&self) -> &'static [&'static str] {
        &["transcripts"]
    }

    fn apply(&self, ctx: &Context) -> anyhow::Result<()> {
        // A projects directory in the config is for a test fixture or a second claude
        // install; with none, the source resolves it the way claude does.
        let source: Arc<dyn TranscriptSource> =
            match ctx.config().get("root").and_then(|v| v.as_str()) {
                Some(root) if !root.is_empty() => Arc::new(ClaudeJsonl::with_root(root)),
                _ => Arc::new(ClaudeJsonl::new()),
            };
        let transcripts = ctx.resolve::<TranscriptsService>()?;
        ctx.track(transcripts.register_source(source)?);
        Ok(())
    }
}
