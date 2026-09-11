//! Per-model price + context-window table.
//!
//! A mirror of `ModelPricing` in `apps/native/Sources/JuancodeCore/ModelPricing.swift`,
//! and it has to be a mirror rather than a reference: the seam that turns a raw model
//! id into dollars lives wherever the usage is folded, and each core folds its own.
//! The Swift copy reads the CLI transcript in `SessionUsage.swift`; this one reads the
//! `Usage` events `juancoded-transcripts` already emits. Neither can read the other's
//! table, so the numbers are kept in agreement by hand — and the doc comment on the
//! Swift side says the same thing from its end.
//!
//! Both halves are best-effort estimates from published rates: an unknown model yields
//! no price and no window, and a client then shows tokens only rather than a
//! confident-looking wrong figure.

/// One row of the table. `match` is a lowercase substring — the Swift side spells it
/// as a case-insensitive regex, but every pattern in the table is either a plain
/// substring or an alternation of them, so a substring test over the lowercased id
/// gives the identical answer without pulling `regex` into the daemon.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ModelPrice {
    pub matches: &'static [&'static str],
    pub input_per_mtok: f64,
    pub output_per_mtok: f64,
    pub context_window: i64,
}

/// Cache reads bill at ~0.1x input and cache writes at ~1.25x input (the default
/// 5-minute TTL).
pub const CACHE_READ_MULTIPLIER: f64 = 0.1;
pub const CACHE_WRITE_MULTIPLIER: f64 = 1.25;

/// Window of the long-context variants, which advertise it in the model id
/// (`claude-opus-5[1m]`).
pub const LONG_CONTEXT_WINDOW: i64 = 1_000_000;

/// Ordered most-specific first; the first match wins.
pub const TABLE: &[ModelPrice] = &[
    ModelPrice {
        matches: &["opus"],
        input_per_mtok: 5.0,
        output_per_mtok: 25.0,
        context_window: 200_000,
    },
    ModelPrice {
        matches: &["sonnet"],
        input_per_mtok: 3.0,
        output_per_mtok: 15.0,
        context_window: 200_000,
    },
    ModelPrice {
        matches: &["haiku"],
        input_per_mtok: 1.0,
        output_per_mtok: 5.0,
        context_window: 200_000,
    },
    ModelPrice {
        matches: &["fable", "mythos"],
        input_per_mtok: 10.0,
        output_per_mtok: 50.0,
        context_window: 200_000,
    },
];

/// Price row for a transcript model id, or `None` when we have no rate for it.
pub fn price(model: &str) -> Option<&'static ModelPrice> {
    let lower = model.to_ascii_lowercase();
    TABLE
        .iter()
        .find(|p| p.matches.iter().any(|m| lower.contains(m)))
}

/// The `[1m]` / `-1m` / `_1m` marker a long-context model id carries.
///
/// The Swift regex is `\[1m\]|[-_]1m(\b|$)`, so the bare-suffix form only counts when
/// what follows it is not another word character — `claude-opus-5-1m` is long-context
/// and a hypothetical `...-1mini` is not.
fn is_long_context(model: &str) -> bool {
    let lower = model.to_ascii_lowercase();
    if lower.contains("[1m]") {
        return true;
    }
    let bytes = lower.as_bytes();
    for (i, w) in bytes.windows(3).enumerate() {
        if (w[0] == b'-' || w[0] == b'_') && w[1] == b'1' && w[2] == b'm' {
            let after = bytes.get(i + 3);
            match after {
                None => return true,
                Some(c) if !c.is_ascii_alphanumeric() && *c != b'_' => return true,
                _ => {}
            }
        }
    }
    false
}

/// Estimated USD for one API request on `model`, or `None` when the model is unpriced
/// (the caller then reports tokens without a total).
pub fn turn_cost(
    model: &str,
    input: u64,
    output: u64,
    cache_read: u64,
    cache_write: u64,
) -> Option<f64> {
    let p = price(model)?;
    Some(
        (input as f64 * p.input_per_mtok
            + cache_read as f64 * p.input_per_mtok * CACHE_READ_MULTIPLIER
            + cache_write as f64 * p.input_per_mtok * CACHE_WRITE_MULTIPLIER
            + output as f64 * p.output_per_mtok)
            / 1_000_000.0,
    )
}

/// Tokens `model`'s context window holds, or `None` for a model we do not know. A
/// long-context variant overrides the family default.
pub fn context_window(model: &str) -> Option<i64> {
    let p = price(model)?;
    if is_long_context(model) {
        return Some(LONG_CONTEXT_WINDOW);
    }
    Some(p.context_window)
}

/// The default context warn line, also the sidecar's alert default. Mirrors
/// `ContextPressure.warnFraction`.
pub const CONTEXT_WARN_FRACTION: f64 = 0.8;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_table_matches_case_insensitively_on_the_family() {
        assert_eq!(price("claude-opus-5").unwrap().output_per_mtok, 25.0);
        assert_eq!(price("Claude-Sonnet-5").unwrap().input_per_mtok, 3.0);
        assert_eq!(
            price("claude-haiku-4-5-20251001").unwrap().input_per_mtok,
            1.0
        );
        assert_eq!(price("claude-fable-5-1").unwrap().output_per_mtok, 50.0);
        assert!(price("fake-model").is_none());
    }

    #[test]
    fn an_unpriced_model_has_neither_a_cost_nor_a_window() {
        assert!(turn_cost("fake-model", 100, 100, 0, 0).is_none());
        assert!(context_window("fake-model").is_none());
    }

    #[test]
    fn a_turn_is_priced_with_the_cache_multipliers() {
        // 1M input + 1M output on sonnet, plus 1M cache read and 1M cache write.
        let cost = turn_cost(
            "claude-sonnet-5",
            1_000_000,
            1_000_000,
            1_000_000,
            1_000_000,
        )
        .unwrap();
        assert!((cost - (3.0 + 15.0 + 0.3 + 3.75)).abs() < 1e-9, "{cost}");
    }

    #[test]
    fn the_long_context_marker_overrides_the_family_window() {
        assert_eq!(context_window("claude-sonnet-5"), Some(200_000));
        assert_eq!(context_window("claude-opus-5[1m]"), Some(1_000_000));
        assert_eq!(context_window("claude-sonnet-5-1m"), Some(1_000_000));
        assert_eq!(context_window("claude-sonnet-5_1m"), Some(1_000_000));
        // A word character after the marker is not the marker.
        assert_eq!(context_window("claude-sonnet-5-1mini"), Some(200_000));
    }
}
