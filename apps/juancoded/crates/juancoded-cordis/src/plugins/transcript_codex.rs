use std::sync::Arc;

use juancoded_transcripts::codex::CodexJsonl;
use juancoded_transcripts::TranscriptSource;

use crate::plugin::{Context, Plugin};
use crate::services::transcripts::TranscriptsService;

/// Registers the codex-jsonl source with the `transcripts` hub.
///
/// Reports token totals and context occupancy from the CLI's own rollout file.
pub struct TranscriptCodex;

impl Plugin for TranscriptCodex {
    fn name(&self) -> &'static str {
        "transcript-codex"
    }

    fn inject(&self) -> &'static [&'static str] {
        &["transcripts"]
    }

    fn apply(&self, ctx: &Context) -> anyhow::Result<()> {
        // A sessions directory in the config is for a test fixture or a second codex
        // install; with none, the source resolves it the way codex does.
        let source: Arc<dyn TranscriptSource> =
            match ctx.config().get("root").and_then(|v| v.as_str()) {
                Some(root) if !root.is_empty() => Arc::new(CodexJsonl::with_root(root)),
                _ => Arc::new(CodexJsonl::new()),
            };
        let transcripts = ctx.resolve::<TranscriptsService>()?;
        ctx.track(transcripts.register_source(source)?);
        Ok(())
    }
}
