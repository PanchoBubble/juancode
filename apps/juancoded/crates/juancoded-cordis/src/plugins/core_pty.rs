use std::sync::Arc;

use juancoded_core::resolve_bin;

use crate::events::ResolveBinary;
use crate::plugin::{Context, Plugin};
use crate::services::pty::{PtyHost, PtySpawnService};

/// Claims the `pty` key with real `portable-pty` children, and answers binary lookups.
pub struct CorePty;

impl Plugin for CorePty {
    fn name(&self) -> &'static str {
        "core-pty"
    }

    fn apply(&self, ctx: &Context) -> anyhow::Result<()> {
        let buffer = ctx
            .config()
            .get("buffer")
            .and_then(|v| v.as_u64())
            .unwrap_or(1_024) as usize;
        ctx.provide::<PtySpawnService>(Arc::new(PtyHost::new(buffer)))?;

        // Registered last in the ordered chain by convention: an override listener
        // mounted ahead of this one gets to answer before PATH is consulted.
        ctx.on_serial::<ResolveBinary, _>("path.lookup", |query| {
            Box::pin(async move { resolve_bin(&query.provider, None) })
        });
        Ok(())
    }
}
