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
                TranscriptEvent::UsageSnapshot {
                    usage,
                    context_tokens,
                    context_window,
                    model,
                } => {
                    // Snapshots replace totals: rate-limit-only notifications may repeat
                    // the same counts, and replay after a restart must be idempotent.
                    next.input_tokens = usage.input as i64;
                    next.output_tokens = usage.output as i64;
                    next.cache_read_tokens = usage.cache_read as i64;
                    next.cache_write_tokens = usage.cache_write as i64;
                    next.total_tokens = next.input_tokens
                        + next.output_tokens
                        + next.cache_read_tokens
                        + next.cache_write_tokens;
                    next.context_tokens = Some(*context_tokens as i64);
                    next.context_window = context_window.map(|n| n as i64);
                    next.model = model.clone();
                    next.cost_usd = None;
                    self.cost_known = false;
                    changed = true;
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
                    // Claude Code's transcript ids never carry `[1m]`, so a session that has
                    // held more than its family window is running the long one, and stays so.
                    let family = pricing::context_window(model);
                    let long = family.is_some()
                        && (next.context_window == Some(pricing::LONG_CONTEXT_WINDOW)
                            || matches!((family, next.context_tokens), (Some(w), Some(c)) if c > w));
                    next.context_window = if long {
                        Some(pricing::LONG_CONTEXT_WINDOW)
                    } else {
                        family
                    };
                    // A request whose step was announced in an earlier batch (restart)
                    // leaves the row's model alone rather than blanking it.
                    if self.last_model.is_some() {
                        next.model = self.last_model.clone();
                    }
                    match pricing::turn_cost(
                        model,
                        usage.input,
                        usage.output,
                        usage.cache_read,
                        usage.cache_write,
                        usage.cache_write_1h,
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
        model: None,
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
                cache_write_1h: 0,
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
    fn a_claude_session_past_its_family_window_is_on_the_long_one_and_stays() {
        // Claude Code writes `claude-opus-5-5`, never `[1m]`, even on a 1M session.
        let mut fold = UsageFold::resuming(None);
        let big = fold
            .apply(
                None,
                &[
                    record(1, step("claude-opus-5-5")),
                    record(2, usage(0, 10, 300_000, 0)),
                ],
            )
            .unwrap();
        assert_eq!(big.context_window, Some(1_000_000));
        // A compaction drops the context back under 200k; the window does not shrink.
        let after = fold
            .apply(
                Some(&big),
                &[
                    record(3, step("claude-opus-5-5")),
                    record(4, usage(0, 10, 50_000, 0)),
                ],
            )
            .unwrap();
        assert_eq!(after.context_window, Some(1_000_000));
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
            model: None,
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
    fn the_row_names_the_model_of_the_newest_request_across_a_model_switch() {
        let mut fold = UsageFold::resuming(None);
        let first = fold
            .apply(
                None,
                &[
                    record(1, step("claude-opus-5")),
                    record(2, usage(10, 1, 0, 0)),
                ],
            )
            .unwrap();
        assert_eq!(first.model.as_deref(), Some("claude-opus-5"));
        let second = fold
            .apply(
                Some(&first),
                &[
                    record(3, step("claude-sonnet-5")),
                    record(4, usage(10, 1, 0, 0)),
                ],
            )
            .unwrap();
        assert_eq!(second.model.as_deref(), Some("claude-sonnet-5"));
        // A restarted fold has not seen a Step yet: the row keeps what it had.
        let mut resumed = UsageFold::resuming(Some(&second));
        let third = resumed
            .apply(Some(&second), &[record(5, usage(10, 1, 0, 0))])
            .unwrap();
        assert_eq!(third.model.as_deref(), Some("claude-sonnet-5"));
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

#[cfg(test)]
mod codex_tests {
    use super::*;
    use juancoded_transcripts::{codex::CodexJsonl, BindRequest, Source, TranscriptSource};
    use serde_json::json;
    use std::io::Write;

    fn snapshot(input: u64, output: u64, context: u64) -> String {
        json!({"type":"event_msg","payload":{"type":"token_count","info":{
            "total_token_usage":{"input_tokens":input,"cached_input_tokens":1000,
                "output_tokens":output,"reasoning_output_tokens":100},
            "last_token_usage":{"total_tokens":context},"model_context_window":475000
        }}})
        .to_string()
            + "\n"
    }

    #[test]
    fn codex_rollout_usage_survives_restart_repeats_and_compaction() {
        let dir = std::env::temp_dir().join(format!("juancode-codex-{}", std::process::id()));
        let day = dir.join("2026/11/16");
        std::fs::create_dir_all(&day).unwrap();
        let path = day.join("rollout-2026-11-16T10-00-00-session-id.jsonl");
        let first = snapshot(20000, 2000, 22000);
        std::fs::write(&path, format!("{{\"type\":\"turn_context\",\"payload\":{{\"model\":\"gpt-6.1-sol\"}}}}\n{first}{first}")).unwrap();
        let source = CodexJsonl::with_root(&dir);
        let req = BindRequest {
            session: "s".into(),
            provider: "codex".into(),
            cwd: "/tmp".into(),
            cli_session_id: Some("session-id".into()),
        };
        assert!(source
            .bind(&BindRequest {
                provider: "claude".into(),
                ..req.clone()
            })
            .is_none());
        let binding = source.bind(&req).expect("find the exact session rollout");
        let (events, cursor) = source.read(&binding, &String::new()).unwrap();
        let records = |events: Vec<juancoded_transcripts::Emitted>| {
            events
                .into_iter()
                .enumerate()
                .map(|(seq, e)| TranscriptRecord {
                    session: "s".into(),
                    source: Source::CodexJsonl,
                    seq: seq as u64,
                    at_ms: e.at_ms,
                    turn: e.turn,
                    event: e.event,
                })
                .collect::<Vec<_>>()
        };
        let mut fold = UsageFold::default();
        let initial = fold.apply(None, &records(events)).unwrap();
        assert_eq!(
            initial.total_tokens, 22000,
            "duplicate snapshots never add twice"
        );
        assert_eq!(
            initial.input_tokens, 19000,
            "cached tokens are already included in input"
        );
        assert_eq!(initial.cache_read_tokens, 1000);
        assert_eq!(initial.context_tokens, Some(22000));
        assert_eq!(initial.context_window, Some(475000));
        assert_eq!(initial.model.as_deref(), Some("gpt-6.1-sol"));
        assert!(initial.cost_usd.is_none());
        assert!(source.read(&binding, &cursor).unwrap().0.is_empty());

        // Recreate both source and fold, carrying only the durable cursor and row.
        let source = CodexJsonl::with_root(&dir);
        let mut fold = UsageFold::resuming(Some(&initial));
        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap();
        let compacted = snapshot(30000, 3000, 5000);
        file.write_all(compacted.trim_end().as_bytes()).unwrap();
        assert!(
            source.read(&binding, &cursor).unwrap().0.is_empty(),
            "partial lines wait"
        );
        file.write_all(b"\n").unwrap();
        let (events, cursor) = source.read(&binding, &cursor).unwrap();
        let next = fold.apply(Some(&initial), &records(events)).unwrap();
        assert_eq!(next.total_tokens, 33000);
        assert_eq!(
            next.context_tokens,
            Some(5000),
            "compaction lowers occupancy"
        );
        assert_eq!(
            next.model, initial.model,
            "model survives the durable cursor"
        );
        // A rate-limit notification with no usage must leave the last reading alone.
        file.write_all(
            b"{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":null}}\n",
        )
        .unwrap();
        assert!(source.read(&binding, &cursor).unwrap().0.is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
