//! The session row's own decorations, expressed as contributions.
//!
//! This is the acceptance test for the contribution contract, shipped rather than
//! written down: the activity indicator every session row already draws is a built-in
//! surface, and here it is registered the same way a third-party plugin would register
//! it. If a built-in cannot be said in the contract, the contract is wrong; this one
//! needed a badge, a filter on the state it applies to, and a declared data need, all
//! of which the descriptor already had.
//!
//! It also carries the row's one action, "interrupt", so the round trip is real: the
//! client sends an activation naming the contribution and the session, and this plugin
//! decides what happens. The client executes nothing.

use crate::contribution::{
    Activation, ActivationOutcome, Badge, Contribution, DataNeed, MenuTarget, Placement, Scope,
    Tone,
};
use crate::plugin::{Context, Plugin};

/// Contributed by this plugin, and the id a client's activation names.
pub const INTERRUPT_ID: &str = "session.menu.interrupt";

pub struct SessionChrome;

impl Plugin for SessionChrome {
    fn name(&self) -> &'static str {
        "session-chrome"
    }

    fn apply(&self, ctx: &Context) -> anyhow::Result<()> {
        // Waiting first, because a row can only be in one activity state and the row
        // that needs a human is the one worth reading first in a long list.
        ctx.contribute(
            Contribution::new(
                "session.badge.waiting",
                Placement::SessionBadge {
                    badge: Badge::new("needs input")
                        .tone(Tone::Warning)
                        .icon("questionmark.bubble"),
                    when_activity: vec!["waitingInput".into()],
                },
            )
            .sort_key(0)
            .needs(DataNeed::SessionActivity),
        )?;

        ctx.contribute(
            Contribution::new(
                "session.badge.busy",
                Placement::SessionBadge {
                    badge: Badge::new("working").tone(Tone::Info).icon("gearshape"),
                    when_activity: vec!["busy".into()],
                },
            )
            .sort_key(10)
            .needs(DataNeed::SessionActivity),
        )?;

        ctx.contribute_with(
            Contribution::new(
                INTERRUPT_ID,
                Placement::ContextMenuItem {
                    target: MenuTarget::Session,
                    label: "Interrupt".into(),
                    icon: Some("stop.circle".into()),
                    destructive: false,
                },
            )
            .sort_key(0)
            .needs(DataNeed::SessionActivity),
            interrupt,
        )?;

        Ok(())
    }
}

/// The daemon-side half of the round trip.
///
/// It refuses rather than guesses when the client did not say which session: an action
/// with no target would otherwise have to pick one, and picking one is how a menu item
/// interrupts the wrong agent.
fn interrupt(activation: &Activation, scope: &Scope) -> ActivationOutcome {
    if let Err(e) = scope.require(DataNeed::SessionActivity) {
        return ActivationOutcome::refused(e.to_string());
    }
    match &activation.target {
        Some(session) => ActivationOutcome::Handled {
            result: serde_json::json!({ "interrupted": session }),
        },
        None => ActivationOutcome::refused("no session named"),
    }
}
