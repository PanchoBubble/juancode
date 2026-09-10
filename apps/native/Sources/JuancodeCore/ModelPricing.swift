import Foundation

/// Static per-model price + context-window table (juancode-lncw).
///
/// The table lives here, in the Swift core, deliberately. The transcript seam that
/// derives usage is Swift (`SessionUsage.swift` in JuancodeServices), so this is the
/// only place a raw model id has to become dollars or a window size. The sidecar
/// never sees a model id at all — it relays the figures already folded onto
/// `SessionMeta.usage` — so a second copy of these numbers over there could only
/// drift out of agreement with the one that does the arithmetic.
///
/// Both halves are best-effort estimates from published rates: an unknown model
/// yields no price and no window, and the UI then shows tokens only rather than a
/// confident-looking wrong figure.
public struct ModelPrice: Sendable, Equatable {
    /// Case-insensitive regex matched against the transcript's model id.
    public let match: String
    public let inputPerMTok: Double
    public let outputPerMTok: Double
    /// The model's default context window, in tokens.
    public let contextWindow: Int

    public init(match: String, inputPerMTok: Double, outputPerMTok: Double, contextWindow: Int) {
        self.match = match
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.contextWindow = contextWindow
    }
}

public enum ModelPricing {
    /// Cache reads bill at ~0.1× input and cache writes at ~1.25× input (the
    /// default 5-minute TTL).
    public static let cacheReadMultiplier = 0.1
    public static let cacheWriteMultiplier = 1.25

    /// Window of the long-context variants, which advertise it in the model id
    /// (`claude-opus-5[1m]`).
    public static let longContextWindow = 1_000_000

    /// Ordered most-specific first; the first match wins.
    public static let table: [ModelPrice] = [
        ModelPrice(match: "opus", inputPerMTok: 5, outputPerMTok: 25, contextWindow: 200_000),
        ModelPrice(match: "sonnet", inputPerMTok: 3, outputPerMTok: 15, contextWindow: 200_000),
        ModelPrice(match: "haiku", inputPerMTok: 1, outputPerMTok: 5, contextWindow: 200_000),
        ModelPrice(match: "fable|mythos", inputPerMTok: 10, outputPerMTok: 50,
                   contextWindow: 200_000),
    ]

    /// The `[1m]` / `-1m` marker a long-context model id carries.
    private static let longContextMarker = #"\[1m\]|[-_]1m(\b|$)"#

    /// Price row for a transcript model id, or nil when we have no rate for it.
    public static func price(for model: String) -> ModelPrice? {
        table.first { p in
            model.range(of: p.match, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Estimated USD for one API turn on `model`, or nil when the model is unpriced
    /// (the caller then reports tokens without a total).
    public static func turnCost(
        model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int
    ) -> Double? {
        guard let p = price(for: model) else { return nil }
        return (Double(input) * p.inputPerMTok
            + Double(cacheRead) * p.inputPerMTok * cacheReadMultiplier
            + Double(cacheWrite) * p.inputPerMTok * cacheWriteMultiplier
            + Double(output) * p.outputPerMTok) / 1_000_000
    }

    /// Tokens `model`'s context window holds, or nil for a model we don't know.
    /// A long-context variant overrides the family default.
    public static func contextWindow(for model: String) -> Int? {
        guard let p = price(for: model) else { return nil }
        if model.range(of: longContextMarker, options: [.regularExpression, .caseInsensitive])
            != nil {
            return longContextWindow
        }
        return p.contextWindow
    }
}

/// How close a session is to filling its context window (juancode-lncw). Only a
/// display/alert classification — nothing here compacts, trims or steers anything.
public enum ContextPressure: Sendable, Equatable {
    /// Unknown window, or comfortably below the warn line.
    case ok
    /// Past `warnFraction` but not yet at the wall.
    case warn
    /// At/over `criticalFraction` — the next turn is likely to hit auto-compaction.
    case critical

    /// The default context warn line, also the sidecar's alert default.
    public static let warnFraction = 0.8
    public static let criticalFraction = 0.95

    public static func of(_ fraction: Double?) -> ContextPressure {
        guard let fraction else { return .ok }
        if fraction >= criticalFraction { return .critical }
        if fraction >= warnFraction { return .warn }
        return .ok
    }
}
