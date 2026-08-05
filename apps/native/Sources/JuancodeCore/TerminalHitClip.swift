import CoreGraphics

/// Hit-test clipping for a terminal pane that SwiftUI has translated off-screen.
///
/// Opening the bottom shell panel moves the session terminal UP by the panel's height
/// with a pure `.offset` — no frame change, so the pty never reflows. SwiftUI clips the
/// overflow with `.clipped()`, but that is a layer mask: AppKit's `hitTest` walks real
/// view frames and knows nothing about it, so the pane's NSView keeps swallowing every
/// click in the strip it now covers (the session header's Refresh / terminal / panel
/// buttons). The pane fixes that by rejecting points inside the top band of its own
/// bounds — exactly the region the translation pushed above the visible area.
public enum TerminalHitClip {
    /// Whether `point` (in the view's own coordinates) falls in the translated-away
    /// top band and should therefore fall through to whatever is drawn underneath.
    public static func rejects(point: CGPoint, bounds: CGRect, flipped: Bool,
                               topInset: CGFloat) -> Bool {
        guard topInset > 0 else { return false }
        return flipped ? point.y < bounds.minY + topInset : point.y > bounds.maxY - topInset
    }
}
