use std::sync::Arc;

use juancoded_core::provider::resolve_provider_bin;

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

        // Registered last in the ordered chain by convention: a listener mounted
        // ahead of this one gets to answer before PATH is consulted. `JUANCODE_*_BIN`
        // is not that listener: the override is part of the answer, not a rung
        // above it, so this and the registry resolve identically.
        ctx.on_serial::<ResolveBinary, _>("path.lookup", |query| {
            Box::pin(async move { resolve_provider_bin(&query.provider) })
        });
        Ok(())
    }
}
