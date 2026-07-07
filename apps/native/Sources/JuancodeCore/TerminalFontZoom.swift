import Foundation

/// Terminal font-zoom math (juancode-fry), shared by every live terminal surface.
///
/// Zoom is a single GLOBAL level (all panes, the Oracle dock, and the bottom
/// terminal panel move together), stored as a signed integer number of 1pt steps
/// from the backend's default font size. Level 0 is the default appearance.
///
/// Ghostty applies a level LIVE via `performBindingAction("increase_font_size:1" /
/// "decrease_font_size:1")` on the existing surface (no rebuild, state preserved),
/// mirroring libghostty's own pinch-zoom loop — we emit one 1pt step per level of
/// delta rather than relying on an `:N` argument the library never exercises.
/// SwiftTerm applies it by setting its `font` to `points(forLevel:)`.
public enum TerminalFontZoom {
    /// Clamp bounds in steps from the default. With Ghostty's ~13pt default this is
    /// roughly a 9..24pt range — small enough to stay legible, wide enough to matter.
    public static let minLevel = -4
    public static let maxLevel = 11
    /// The default point size the level offsets from. Ghostty's built-in default is
    /// 13pt; SwiftTerm reads its live base font instead and only borrows this when it
    /// has no better anchor.
    public static let basePoints = 13.0

    public static let increaseAction = "increase_font_size:1"
    public static let decreaseAction = "decrease_font_size:1"

    public static func clamp(_ level: Int) -> Int { min(max(level, minLevel), maxLevel) }

    /// One step up, clamped. cmd-plus at the ceiling is a no-op (returns the same
    /// level), so the caller can skip emitting anything and the font never creeps
    /// past the clamp on repeated presses.
    public static func zoomedIn(_ level: Int) -> Int { clamp(level + 1) }
    public static func zoomedOut(_ level: Int) -> Int { clamp(level - 1) }

    /// The SwiftTerm point size for a level, offset from a base font size.
    public static func points(forLevel level: Int, base: Double = basePoints) -> Double {
        base + Double(clamp(level))
    }

    /// The Ghostty binding-action steps that move a surface from its currently
    /// applied level to `target` — one 1pt action per level of delta, in the right
    /// direction. Empty when nothing changed (already at target, or both clamp to the
    /// same bound). Both endpoints are clamped so an out-of-range applied value can
    /// never produce a runaway sequence.
    public static func bindingSteps(from current: Int, to target: Int) -> [String] {
        let delta = clamp(target) - clamp(current)
        guard delta != 0 else { return [] }
        return Array(repeating: delta > 0 ? increaseAction : decreaseAction, count: abs(delta))
    }
}
