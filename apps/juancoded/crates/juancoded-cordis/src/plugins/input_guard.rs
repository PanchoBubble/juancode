use crate::events::{InputDecision, SessionInput};
use crate::plugin::{Context, Plugin};
use crate::services::pty::PtySpawnService;

/// Input policy, as around-middleware: refuse a write to a session with no live pty,
/// annotate and delegate otherwise.
///
/// Registered ahead of the plugin that performs the write, which is what "ordered by
/// registration" buys: composition order is the entry list's order.
pub struct InputGuard;

impl Plugin for InputGuard {
    fn name(&self) -> &'static str {
        "input-guard"
    }

    fn inject(&self) -> &'static [&'static str] {
        &["pty"]
    }

    fn apply(&self, ctx: &Context) -> anyhow::Result<()> {
        let pty = ctx.resolve::<PtySpawnService>()?;
        ctx.around::<SessionInput, _>("guard.live-session", move |request, next| {
            if pty.handle(&request.session).is_none() {
                return InputDecision::Refused(format!(
                    "session `{}` has no live pty",
                    request.session
                ));
            }
            request.notes.push("input-guard: live".into());
            next.run(request)
        });
        Ok(())
    }
}
