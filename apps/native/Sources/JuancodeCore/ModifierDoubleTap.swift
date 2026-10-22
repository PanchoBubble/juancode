import Foundation

/// Recognises a double tap of a bare modifier key (⌃ ⌃ toggles vim sidebar nav).
///
/// Fed from a `flagsChanged`/`keyDown` monitor. A tap is the modifier going down and
/// back up alone; two taps within `window` seconds fire. Any other key or modifier in
/// between — i.e. the user actually *used* ⌃ for a chord like ⌃C — cancels the run,
/// so ordinary ⌃-shortcuts never trip it.
public struct ModifierDoubleTap: Sendable {
    public let window: TimeInterval
    private var down = false
    private var dirty = false
    private var lastTap: TimeInterval?

    public init(window: TimeInterval = 0.35) { self.window = window }

    /// The modifier set changed. `onlyTarget` is true when the target modifier is the
    /// only one held, `none` when nothing is held. Returns true when this release
    /// completes a double tap.
    public mutating func flagsChanged(onlyTarget: Bool, none: Bool, at t: TimeInterval) -> Bool {
        if onlyTarget {
            if !down { down = true; dirty = false }
            return false
        }
        guard down else { lastTap = nil; return false }
        down = false
        // Released to something other than "nothing" (e.g. ⌃ then ⇧): not a tap.
        guard none, !dirty else { lastTap = nil; return false }
        if let last = lastTap, t - last <= window {
            lastTap = nil
            return true
        }
        lastTap = t
        return false
    }

    /// A non-modifier key went down: whatever is in flight was a chord, not a tap.
    public mutating func keyDown() {
        dirty = down
        lastTap = nil
    }
}
