use crate::plugin::{Context, Plugin};

/// Injects a `transcripts` service that nothing provides yet, so it sits PENDING.
///
/// It is in the default tree on purpose. A harness where the unfinished half is
/// invisible is the failure mode this whole module exists to avoid, and keeping one
/// genuinely pending row in the booted tree means the diagnosis path is exercised
/// every time anyone runs `dump-config`.
pub struct ActivityLog;

impl Plugin for ActivityLog {
    fn name(&self) -> &'static str {
        "activity-log"
    }

    fn inject(&self) -> &'static [&'static str] {
        &["transcripts"]
    }

    fn apply(&self, _ctx: &Context) -> anyhow::Result<()> {
        Ok(())
    }
}
