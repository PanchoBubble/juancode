//! The addressable steering queue, mounted.
//!
//! The plugin is small on purpose: it claims the `queue` key, points the queue's
//! change hook at the bus, and contributes the two things a queued row may do. The
//! rules live in [`crate::services::queue`], and the client's half of them lives in
//! [`mirror`].
//!
//! What it deliberately does not do:
//!
//! - It does not deliver. Typing into a pty is the delivery engine's job, and the
//!   boundary between the two is [`QueueApi::claim_next`]: the engine claims before it
//!   writes a byte, and the claim is what makes edit and remove answer not-found.
//! - It does not clear a queue when a session exits. A session that exited can be
//!   reactivated, and messages queued for it are still meant for it; a queue is
//!   cleared when the session is deleted, by whoever deletes it.
//! - It contributes no send-now and no reorder. The head is the head.

pub mod mirror;

use std::sync::Arc;

use serde_json::Value;

use crate::bus::ObserveEvent;
use crate::contribution::{
    Activation, ActivationOutcome, Contribution, MenuTarget, Placement, Scope,
};
use crate::plugin::{Context, Plugin};
use crate::services::queue::{QueueApi, QueueError, QueueService, QueueSnapshot, SessionQueues};

pub use mirror::{Dock, QueueMirror, QueueRequest};

/// A session's whole queue, pushed on every change.
///
/// Observed rather than around: the WS fan-out, a Telegram bridge and a local view all
/// want the same snapshot, and none of them may alter it on the way to the others.
/// This is the only queue payload that exists; there is no delta event to listen for.
pub struct QueueChanged;

impl ObserveEvent for QueueChanged {
    const NAME: &'static str = "session.queue";
    type Payload = QueueSnapshot;
}

/// Contributed by this plugin, and the ids a client's activation names.
pub const EDIT_ID: &str = "session.queue.edit";
pub const REMOVE_ID: &str = "session.queue.remove";

pub struct SteeringQueue;

impl Plugin for SteeringQueue {
    fn name(&self) -> &'static str {
        "steering-queue"
    }

    fn apply(&self, ctx: &Context) -> anyhow::Result<()> {
        let queue = SessionQueues::new();

        // Every mutation publishes, and publishing is one emit of the whole queue.
        // The plugin owns this wiring rather than the queue, so a test can hold a
        // queue with no bus at all.
        let bus = ctx.bus().clone();
        queue.on_change(Arc::new(move |snapshot: &QueueSnapshot| {
            bus.emit::<QueueChanged>(snapshot);
        }));

        let api: Arc<dyn QueueApi> = queue.clone();
        ctx.provide::<QueueService>(api.clone())?;

        let editor = api.clone();
        ctx.contribute_with(
            Contribution::new(
                EDIT_ID,
                Placement::ContextMenuItem {
                    target: MenuTarget::Session,
                    label: "Edit queued message".into(),
                    icon: Some("pencil".into()),
                    destructive: false,
                },
            )
            .sort_key(20),
            move |activation, scope| edit(&*editor, activation, scope),
        )?;

        let remover = api;
        ctx.contribute_with(
            Contribution::new(
                REMOVE_ID,
                Placement::ContextMenuItem {
                    target: MenuTarget::Session,
                    label: "Delete queued message".into(),
                    icon: Some("trash".into()),
                    destructive: true,
                },
            )
            .sort_key(30),
            move |activation, scope| remove(&*remover, activation, scope),
        )?;

        Ok(())
    }
}

/// The daemon-side half of an edit, refusing rather than guessing at every step.
///
/// A refusal carries the wire code rather than prose, because the client's only
/// correct reaction to `queue-item-not-found` is to stop showing the row it was
/// editing and take the next snapshot as the truth.
fn edit(queue: &dyn QueueApi, activation: &Activation, _scope: &Scope) -> ActivationOutcome {
    let (session, id) = match addressed(activation) {
        Ok(pair) => pair,
        Err(outcome) => return outcome,
    };
    let Some(text) = activation.payload.get("text").and_then(Value::as_str) else {
        return ActivationOutcome::refused("no replacement text");
    };
    match queue.edit(session, id, text) {
        Ok(occurrence) => ActivationOutcome::Handled {
            result: serde_json::json!({ "edited": occurrence }),
        },
        Err(error) => ActivationOutcome::refused(error.code()),
    }
}

fn remove(queue: &dyn QueueApi, activation: &Activation, _scope: &Scope) -> ActivationOutcome {
    let (session, id) = match addressed(activation) {
        Ok(pair) => pair,
        Err(outcome) => return outcome,
    };
    match queue.remove(session, id) {
        Ok(occurrence) => ActivationOutcome::Handled {
            result: serde_json::json!({ "removed": occurrence }),
        },
        Err(error) => ActivationOutcome::refused(error.code()),
    }
}

/// The session and the occurrence an activation names. An action that named neither
/// would have to pick a row, and picking one rewrites somebody's other message.
fn addressed(activation: &Activation) -> Result<(&str, &str), ActivationOutcome> {
    let Some(session) = activation.target.as_deref() else {
        return Err(ActivationOutcome::refused("no session named"));
    };
    let Some(id) = activation.payload.get("item").and_then(Value::as_str) else {
        return Err(ActivationOutcome::refused(QueueError::NotFound.code()));
    };
    Ok((session, id))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    use crate::entry::{Entry, EntryList};
    use crate::events::{InputDecision, InputRequest, SessionInput};
    use crate::loader::Loader;
    use crate::plugins::register_builtins;
    use crate::services::queue::{Claim, ClaimRefused, Content, Delivery, ItemState};

    fn booted() -> Loader {
        let mut loader = Loader::new();
        register_builtins(&mut loader);
        loader
            .apply(&EntryList::new().push(Entry::new("queue", "steering-queue")))
            .expect("unique ids");
        loader
    }

    fn activation(id: &str, session: &str, payload: Value) -> Activation {
        Activation::new(id).on(session).with(payload)
    }

    #[test]
    fn the_plugin_claims_the_key_and_gives_it_back_when_it_unmounts() {
        let mut loader = booted();
        assert!(loader.services().has("queue"));
        let mut off = EntryList::new().push(Entry::new("queue", "steering-queue"));
        off.set_disabled("queue", true);
        loader.apply(&off).unwrap();
        assert!(!loader.services().has("queue"));
    }

    /// Pending steering, meaning input for a turn that is already running, is not
    /// queue business: it is a write, it happens now, and there is no not-yet-typed
    /// occurrence for anyone to address. The queue enforces that by staying off the
    /// input path entirely rather than by filtering there.
    #[test]
    fn the_queue_never_intercepts_a_write_so_steering_is_not_addressable() {
        let loader = booted();
        assert!(
            loader.bus().listeners_of::<SessionInput>().is_empty(),
            "a queue that sat on session.input would make live steering a row"
        );

        let mut request = InputRequest::new("s1", b"stop what you are doing\r".to_vec());
        let decision = loader
            .bus()
            .waterfall::<SessionInput>(&mut request, |r| InputDecision::Delivered(r.data.len()));
        assert_eq!(decision, InputDecision::Delivered(24));

        let queue = loader.services().resolve::<QueueService>().unwrap();
        assert!(queue.snapshot("s1").is_empty());
    }

    #[test]
    fn every_change_reaches_the_bus_as_a_complete_snapshot() {
        let loader = booted();
        let seen: Arc<Mutex<Vec<QueueSnapshot>>> = Arc::new(Mutex::new(Vec::new()));
        let sink = seen.clone();
        let _watch = loader
            .bus()
            .on::<QueueChanged, _>("test.watch", move |snapshot| {
                sink.lock().unwrap().push(snapshot.clone());
            });

        let queue = loader.services().resolve::<QueueService>().unwrap();
        let first = queue.enqueue("s1", Content::text("one"), "telegram");
        queue.enqueue("s1", Content::text("two"), "telegram");
        queue.edit("s1", &first.id, "uno").unwrap();

        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 3);
        assert_eq!(
            seen[2].items.len(),
            2,
            "the whole queue, not the edited row"
        );
        assert_eq!(seen[2].items[0].content.as_text(), Some("uno"));
    }

    #[test]
    fn a_client_edits_and_deletes_through_the_contribution_round_trip() {
        let loader = booted();
        let queue = loader.services().resolve::<QueueService>().unwrap();
        let item = queue.enqueue("s1", Content::text("typo"), "telegram");

        let outcome = loader.contributions().activate(&activation(
            EDIT_ID,
            "s1",
            serde_json::json!({ "item": item.id, "text": "fixed" }),
        ));
        assert!(matches!(outcome, ActivationOutcome::Handled { .. }));
        assert_eq!(
            queue.snapshot("s1").items[0].content.as_text(),
            Some("fixed")
        );

        let outcome = loader.contributions().activate(&activation(
            REMOVE_ID,
            "s1",
            serde_json::json!({ "item": item.id }),
        ));
        assert!(matches!(outcome, ActivationOutcome::Handled { .. }));
        assert!(queue.snapshot("s1").is_empty());
    }

    #[test]
    fn an_activation_that_names_no_row_is_refused_rather_than_guessing() {
        let loader = booted();
        let queue = loader.services().resolve::<QueueService>().unwrap();
        queue.enqueue("s1", Content::text("one"), "telegram");

        let no_row = loader
            .contributions()
            .activate(&activation(REMOVE_ID, "s1", Value::Null));
        assert_eq!(
            no_row,
            ActivationOutcome::refused("queue-item-not-found"),
            "one queued row is not the same as the row the client meant"
        );

        let no_session = loader.contributions().activate(
            &Activation::new(EDIT_ID).with(serde_json::json!({ "item": "q1", "text": "x" })),
        );
        assert_eq!(no_session, ActivationOutcome::refused("no session named"));
        assert_eq!(queue.snapshot("s1").items.len(), 1);
    }

    /// The whole boundary, from the client's side of it: a message is queued, the
    /// delivery engine claims it, the client's edit is refused with the code that
    /// tells it to stop guessing, and the row retires only when the host says so.
    #[test]
    fn a_client_mirror_follows_the_host_across_the_claim_boundary() {
        let loader = booted();
        let queue = loader.services().resolve::<QueueService>().unwrap();

        let mirror: Arc<Mutex<QueueMirror>> = Arc::new(Mutex::new(QueueMirror::new()));
        let sink = mirror.clone();
        let _watch = loader
            .bus()
            .on::<QueueChanged, _>("mirror", move |snapshot| {
                sink.lock().unwrap().apply_broadcast(snapshot.clone());
            });

        let item = queue.enqueue("s1", Content::text("run the tests"), "telegram");
        mirror.lock().unwrap().apply_baseline(queue.snapshot("s1"));
        assert_eq!(mirror.lock().unwrap().rows("s1").len(), 1);

        // The engine claims. The row is still on screen, now in flight.
        let claim: Claim = queue.claim_next("s1").expect("a claim");
        assert_eq!(
            mirror.lock().unwrap().rows("s1")[0].state,
            ItemState::InFlight
        );

        // The client, which has not read that state and does not need to, asks for an
        // edit anyway. The host refuses and the client's row does not move.
        let request = mirror.lock().unwrap().edit("s1", &item.id, "cancel that");
        let QueueRequest::Edit { session, id, text } = request else {
            panic!("an edit request");
        };
        assert_eq!(
            queue.edit(&session, &id, &text).unwrap_err(),
            QueueError::NotFound
        );
        assert_eq!(
            mirror.lock().unwrap().rows("s1")[0].content.as_text(),
            Some("run the tests")
        );

        // A second claim is refused while the first is outstanding, so a retry under
        // load types the message it already pasted rather than a second one.
        assert_eq!(
            queue.claim_next("s1").unwrap_err(),
            ClaimRefused::AlreadyClaimed { id: item.id }
        );

        claim.settle(Delivery::Delivered);
        assert!(mirror.lock().unwrap().rows("s1").is_empty());
    }
}
