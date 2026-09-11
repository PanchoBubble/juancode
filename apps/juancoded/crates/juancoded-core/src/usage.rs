//! Folding the transcript seam's `Usage` events onto a session row.
//!
//! `juancoded-transcripts` already parses what every API request cost — claude's
//! `message.usage` block, opencode's `step-finish` tokens — and emits one
//! [`TranscriptEvent::Usage`] per request. Until this module existed nothing consumed
//! them, so `SessionMeta.usage` was `NULL` on every session the Rust core ever ran and
//! the cost badge, the spend total, the budget and the sidecar's threshold ping were
//! all quiet. This is the consumer.
//!
//! # Why the running total lives on the row, not here
//!
//! A transcript is read from a durable cursor: a daemon that restarts resumes where it
//! stopped rather than re-reading the file from the top, so an accumulator held only in
//! memory would restart at zero and the session would lose everything it had spent. The
//! persisted `SessionMeta.usage` IS the accumulator — each batch is added to what the
//! row already carries — which makes a restart cost nothing and needs no second store.
//!
//! [`UsageFold`] therefore holds only what a row cannot: which model the next `Usage`
//! belongs to, and whether every request so far had a price.
//!
//! # What each field means
//!
//! The four token counts and `total_tokens` are cumulative and only ever grow.
//! `context_tokens` is the opposite and is REPLACED on every request: it is the newest
//! request's input + cache read + cache write, i.e. what the next one has to re-send,
//! which is the number that actually runs out and the one a compaction brings back
//! down. `context_window` comes from the price table for the model of
//! that same newest request.
//!
//! `cost_usd` is a best-effort estimate and goes `None` for good the moment one
//! request ran on a model the table has no rate for: a partial sum presented as a total
//! is worse than saying nothing, which is the rule the Swift core follows too.

use juancoded_transcripts::{TranscriptEvent, TranscriptRecord};

use crate::model::SessionUsage;
use crate::pricing;

/// The model id claude writes on a locally-generated message that was never a billed
/// API call. It carries no usage, so it is skipped rather than priced.
const SYNTHETIC_MODEL: &str = "<synthetic>";

/// The per-session state a row cannot carry. Small on purpose — one entry per live
/// session, and nothing in it is worth persisting.
#[derive(Debug, Clone)]
pub struct UsageFold {
    /// The model of the most recent `Step`. A `Usage` event names its step but not its
    /// model, and both sources emit the `Step` first, so "the last model announced" is
    /// exactly the model the next `Usage` was spent on.
    last_model: Option<String>,
    /// Cleared for good by the first request on an unpriced model. Starts true.
    cost_known: bool,
}

/// A fresh session: nothing spent, and every request so far (none) had a price.
/// Spelled out rather than derived because `cost_known` defaults the wrong way round —
/// a derived `false` would mean a brand-new session could never report a cost.
impl Default for UsageFold {
    fn default() -> Self {
        Self {
            last_model: None,
            cost_known: true,
        }
    }
}

impl UsageFold {
    /// A fold for a session whose row already carries `usage`, so a restarted daemon
    /// resumes rather than restarts.
    ///
    /// A row with usage but no cost is a session that already met an unpriced model;
    /// re-arming the cost would let a later priced request produce a total that silently
    /// omits everything before it.
    pub fn resuming(usage: Option<&SessionUsage>) -> Self {
        Self {
            last_model: None,
            cost_known: usage.is_none_or(|u| u.cost_usd.is_some()),
        }
    }

    /// Fold one batch of transcript records into `base`.
    ///
    /// Returns the new usage when the batch actually moved it, and `None` when the batch
    /// carried no billable request — which is most batches, since prose, tool calls and
    /// turn boundaries all come through the same seam.
    pub fn apply(
        &mut self,
        base: Option<&SessionUsage>,
        records: &[TranscriptRecord],
    ) -> Option<SessionUsage> {
        let mut next = base.cloned().unwrap_or_else(zero);
        let mut changed = false;
        for record in records {
            match &record.event {
                // A synthetic message is not a request and must not become the model the
                // next real one is priced against.
                TranscriptEvent::Step {
                    model: Some(model), ..
                } if model != SYNTHETIC_MODEL => {
                    self.last_model = Some(model.clone());
                }
                TranscriptEvent::Usage { usage, .. } => {
                    if usage.is_zero() {
                        continue;
                    }
                    next.input_tokens += usage.input as i64;
                    next.output_tokens += usage.output as i64;
                    next.cache_read_tokens += usage.cache_read as i64;
                    next.cache_write_tokens += usage.cache_write as i64;
                    next.total_tokens = next.input_tokens
                        + next.output_tokens
                        + next.cache_read_tokens
                        + next.cache_write_tokens;
                    // Replaced, never summed: the running totals say what the session has
                    // spent, this says how full it is right now.
                    next.context_tokens =
                        Some((usage.input + usage.cache_read + usage.cache_write) as i64);
                    let model = self.last_model.as_deref().unwrap_or_default();
                    next.context_window = pricing::context_window(model);
                    match pricing::turn_cost(
                        model,
                        usage.input,
                        usage.output,
                        usage.cache_read,
                        usage.cache_write,
                    ) {
                        Some(cost) if self.cost_known => {
                            next.cost_usd = Some(next.cost_usd.unwrap_or(0.0) + cost);
                        }
                        Some(_) => {}
                        None => {
                            self.cost_known = false;
                            next.cost_usd = None;
                        }
                    }
                    changed = true;
                }
                _ => {}
            }
        }
        changed.then_some(next)
    }
}

fn zero() -> SessionUsage {
    SessionUsage {
        input_tokens: 0,
        output_tokens: 0,
        cache_read_tokens: 0,
        cache_write_tokens: 0,
        total_tokens: 0,
        cost_usd: None,
        context_tokens: None,
        context_window: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use juancoded_transcripts::{Source, TokenUsage};

    fn record(seq: u64, event: TranscriptEvent) -> TranscriptRecord {
        TranscriptRecord {
            session: "s".into(),
            source: Source::ClaudeJsonl,
            seq,
            at_ms: None,
            turn: None,
            event,
        }
    }

    fn step(model: &str) -> TranscriptEvent {
        TranscriptEvent::Step {
            step: "req".into(),
            model: Some(model.into()),
        }
    }

    fn usage(input: u64, output: u64, cache_read: u64, cache_write: u64) -> TranscriptEvent {
        TranscriptEvent::Usage {
            step: Some("req".into()),
            usage: TokenUsage {
                input,
                output,
                cache_read,
                cache_write,
                reasoning: 0,
            },
        }
    }

    #[test]
    fn a_batch_with_no_usage_moves_nothing() {
        let mut fold = UsageFold::resuming(None);
        let batch = vec![
            record(
                1,
                TranscriptEvent::TurnStart {
                    prompt: "hi".into(),
                },
            ),
            record(2, step("claude-sonnet-5")),
            record(
                3,
                TranscriptEvent::Assistant {
                    step: None,
                    text: "hello".into(),
                },
            ),
        ];
        assert!(fold.apply(None, &batch).is_none());
    }

    #[test]
    fn one_request_lands_totals_cost_and_context() {
        let mut fold = UsageFold::resuming(None);
        let batch = vec![
            record(1, step("claude-sonnet-5")),
            record(2, usage(10, 20, 30, 40)),
        ];
        let u = fold.apply(None, &batch).expect("a billable request");
        assert_eq!(u.input_tokens, 10);
        assert_eq!(u.output_tokens, 20);
        assert_eq!(u.cache_read_tokens, 30);
        assert_eq!(u.cache_write_tokens, 40);
        assert_eq!(u.total_tokens, 100);
        // The live conversation holds input + cache, not the output it produced.
        assert_eq!(u.context_tokens, Some(80));
        assert_eq!(u.context_window, Some(200_000));
        let expected = (10.0 * 3.0 + 30.0 * 0.3 + 40.0 * 3.75 + 20.0 * 15.0) / 1_000_000.0;
        assert!((u.cost_usd.unwrap() - expected).abs() < 1e-12);
    }

    #[test]
    fn totals_accumulate_across_batches_while_context_is_replaced() {
        let mut fold = UsageFold::resuming(None);
        let first = fold
            .apply(
                None,
                &[
                    record(1, step("claude-sonnet-5")),
                    record(2, usage(100, 10, 0, 0)),
                ],
            )
            .unwrap();
        let second = fold
            .apply(
                Some(&first),
                &[
                    record(3, step("claude-sonnet-5")),
                    record(4, usage(40, 5, 0, 0)),
                ],
            )
            .unwrap();
        assert_eq!(second.input_tokens, 140);
        assert_eq!(second.total_tokens, 155);
        // Not 140: a compaction shrinks the window back down, and this is the number
        // that has to follow it.
        assert_eq!(second.context_tokens, Some(40));
        assert!(second.cost_usd.unwrap() > first.cost_usd.unwrap());
    }

    #[test]
    fn an_unpriced_model_drops_the_cost_for_good() {
        let mut fold = UsageFold::resuming(None);
        let priced = fold
            .apply(
                None,
                &[
                    record(1, step("claude-sonnet-5")),
                    record(2, usage(100, 10, 0, 0)),
                ],
            )
            .unwrap();
        assert!(priced.cost_usd.is_some());
        let mixed = fold
            .apply(
                Some(&priced),
                &[
                    record(3, step("fake-model")),
                    record(4, usage(100, 10, 0, 0)),
                ],
            )
            .unwrap();
        assert_eq!(mixed.cost_usd, None);
        assert_eq!(
            mixed.context_window, None,
            "an unknown model has no window either"
        );
        assert_eq!(mixed.total_tokens, 220, "tokens are still counted");
        // And a later priced request does not resurrect a total that would omit the
        // un-priced one.
        let after = fold
            .apply(
                Some(&mixed),
                &[
                    record(5, step("claude-sonnet-5")),
                    record(6, usage(100, 10, 0, 0)),
                ],
            )
            .unwrap();
        assert_eq!(after.cost_usd, None);
        assert_eq!(after.total_tokens, 330);
    }

    #[test]
    fn a_resumed_row_without_a_cost_stays_without_one() {
        let base = SessionUsage {
            input_tokens: 500,
            output_tokens: 100,
            cache_read_tokens: 0,
            cache_write_tokens: 0,
            total_tokens: 600,
            cost_usd: None,
            context_tokens: Some(500),
            context_window: None,
        };
        let mut fold = UsageFold::resuming(Some(&base));
        let next = fold
            .apply(
                Some(&base),
                &[
                    record(1, step("claude-sonnet-5")),
                    record(2, usage(10, 1, 0, 0)),
                ],
            )
            .unwrap();
        assert_eq!(
            next.total_tokens, 611,
            "the restart resumes, it does not restart"
        );
        assert_eq!(next.cost_usd, None);
    }

    #[test]
    fn a_synthetic_step_does_not_become_the_model_the_next_request_is_priced_against() {
        let mut fold = UsageFold::resuming(None);
        let batch = vec![
            record(1, step("claude-sonnet-5")),
            record(2, step(SYNTHETIC_MODEL)),
            record(3, usage(10, 1, 0, 0)),
        ];
        let u = fold.apply(None, &batch).unwrap();
        assert_eq!(u.context_window, Some(200_000));
        assert!(u.cost_usd.is_some());
    }

    #[test]
    fn a_usage_event_whose_step_was_never_announced_still_counts_its_tokens() {
        // opencode's `step-finish` can reach a later batch than its `step-start`; the
        // tokens are the part that must not be lost.
        let mut fold = UsageFold::resuming(None);
        let u = fold.apply(None, &[record(1, usage(10, 1, 0, 0))]).unwrap();
        assert_eq!(u.total_tokens, 11);
        assert_eq!(u.cost_usd, None);
        assert_eq!(u.context_window, None);
    }
}
