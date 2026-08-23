use std::sync::Arc;

use juancoded_transcripts::opencode::OpencodeSqlite;
use juancoded_transcripts::TranscriptSource;

use crate::plugin::{Context, Plugin};
use crate::services::transcripts::TranscriptsService;

/// Registers the opencode-sqlite source with the `transcripts` hub.
///
/// opencode has no flag to pin a conversation id, so a session it owns binds later
/// than a claude one: the registry discovers the id from opencode's own `session` row,
/// which is written on the first message rather than at spawn. Until then `attach`
/// simply finds nothing, which is why it is retried rather than done once.
pub struct TranscriptOpencode;

impl Plugin for TranscriptOpencode {
    fn name(&self) -> &'static str {
        "transcript-opencode"
    }

    fn inject(&self) -> &'static [&'static str] {
        &["transcripts"]
    }

    fn apply(&self, ctx: &Context) -> anyhow::Result<()> {
        // A database in the config is a fixture; with none, the source resolves
        // opencode's own path the way opencode does.
        let source: Arc<dyn TranscriptSource> =
            match ctx.config().get("db").and_then(|v| v.as_str()) {
                Some(db) if !db.is_empty() => Arc::new(OpencodeSqlite::with_db(db)),
                _ => Arc::new(OpencodeSqlite::new()),
            };
        let transcripts = ctx.resolve::<TranscriptsService>()?;
        ctx.track(transcripts.register_source(source)?);
        Ok(())
    }
}
