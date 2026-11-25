//! A seeded create's prompt-delivery outcome lives on the session row, so it outlives
//! the client that asked for the create (a dispatcher hangs up at `created`) and the
//! daemon itself (juancode-axou.2).

mod harness;

use harness::Harness;
use juancoded_core::model::{PromptDelivery, PromptDeliveryState};

const DESKTOP: u64 = 1;

fn delivery(state: PromptDeliveryState, reason: Option<&str>) -> PromptDelivery {
    PromptDelivery {
        state,
        verified: None,
        reason: reason.map(str::to_string),
        at: 1,
    }
}

#[tokio::test]
async fn a_failed_delivery_survives_a_restart() {
    let harness = Harness::new("prompt-delivery-failed");
    let id = harness.create("/tmp", 80, 24, DESKTOP).await;
    let failed = delivery(PromptDeliveryState::Failed, Some("never submitted"));
    assert!(harness.sessions.set_prompt_delivery(&id, failed.clone()));
    assert_eq!(
        harness.sessions.meta(&id).unwrap().prompt_delivery,
        Some(failed.clone())
    );

    let harness = harness.restart();
    assert_eq!(
        harness.sessions.meta(&id).unwrap().prompt_delivery,
        Some(failed)
    );
}

#[tokio::test]
async fn a_delivery_still_pending_at_restart_reads_back_failed_not_pending() {
    // The task typing it died with the old process. Pending forever would read as "still
    // trying", and re-sending could paste the prompt twice, so it must come back failed.
    let harness = Harness::new("prompt-delivery-pending");
    let id = harness.create("/tmp", 80, 24, DESKTOP).await;
    harness
        .sessions
        .set_prompt_delivery(&id, delivery(PromptDeliveryState::Pending, None));

    let harness = harness.restart();
    let back = harness.sessions.meta(&id).unwrap().prompt_delivery.unwrap();
    assert_eq!(back.state, PromptDeliveryState::Failed);
    assert!(back.reason.unwrap().contains("restarted"));
}
