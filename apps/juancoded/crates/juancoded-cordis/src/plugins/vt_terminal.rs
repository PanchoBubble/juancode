use std::sync::Arc;

use crate::plugin::{Context, Plugin};
use crate::services::terminal::{TerminalService, VtTerminals};

/// Claims the `terminal` key with the real `juancoded-vt` grids.
pub struct VtTerminal;

impl Plugin for VtTerminal {
    fn name(&self) -> &'static str {
        "vt-terminal"
    }

    fn apply(&self, ctx: &Context) -> anyhow::Result<()> {
        let history = ctx
            .config()
            .get("history")
            .and_then(|v| v.as_u64())
            .unwrap_or(2_000) as usize;
        ctx.provide::<TerminalService>(Arc::new(VtTerminals::new(history)))?;
        Ok(())
    }
}
