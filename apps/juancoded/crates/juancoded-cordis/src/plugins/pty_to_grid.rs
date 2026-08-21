use std::sync::Arc;

use crate::events::{InputDecision, SessionExit, SessionInput, SessionOutput};
use crate::plugin::{Context, Plugin};
use crate::services::pty::PtySpawnService;
use crate::services::terminal::TerminalService;

/// The glue: pty bytes into the grid, input out to the pty, grid released on exit.
///
/// It resolves both services by key and knows neither implementation, so a fake pty in
/// a test and a real `claude` in production mount identically.
pub struct PtyToGrid;

impl Plugin for PtyToGrid {
    fn name(&self) -> &'static str {
        "pty-to-grid"
    }

    fn inject(&self) -> &'static [&'static str] {
        &["pty", "terminal"]
    }

    fn apply(&self, ctx: &Context) -> anyhow::Result<()> {
        let terminal = ctx.resolve::<TerminalService>()?;
        let pty = ctx.resolve::<PtySpawnService>()?;
        let cols = ctx
            .config()
            .get("cols")
            .and_then(|v| v.as_u64())
            .unwrap_or(120) as usize;
        let rows = ctx
            .config()
            .get("rows")
            .and_then(|v| v.as_u64())
            .unwrap_or(40) as usize;

        let feed = Arc::clone(&terminal);
        ctx.on::<SessionOutput, _>("terminal.feed", move |frame| {
            // `open` resizes an existing grid and is a no-op at the same size, so the
            // first frame of a session creates its grid without a separate lifecycle
            // event to keep in sync.
            feed.open(&frame.session, cols, rows);
            feed.feed(&frame.session, &frame.bytes);
        });

        // The end of the around chain: this listener owns the write and does not
        // delegate, so anything registered ahead of it is a policy that can refuse.
        ctx.around::<SessionInput, _>("pty.write", move |request, _next| {
            match pty.write(&request.session, &request.data) {
                Ok(()) => InputDecision::Delivered(request.data.len()),
                Err(err) => InputDecision::Refused(err.to_string()),
            }
        });

        let close = Arc::clone(&terminal);
        ctx.on_fan_out::<SessionExit, _>("terminal.close", move |info| {
            let close = Arc::clone(&close);
            Box::pin(async move {
                close.close(&info.session);
            })
        });
        Ok(())
    }
}
