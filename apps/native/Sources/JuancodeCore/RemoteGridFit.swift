import Foundation

/// Sizing math for adopting a remote grid owner's dimensions into the native
/// pane (juancode-slz), Orca's "mobile fit override" translated to Ghostty.
///
/// While a web/phone viewer owns a session's pty grid and the native pane is
/// pool-hidden (juancode-073 released local ownership), the pty streams bytes
/// laid out for the *remote* grid. Leaving the frozen local surface at its old
/// pane-bounds grid would mis-wrap all of that state — the same corruption as a
/// raw scrollback replay. Instead the surface frame is resized TO the remote
/// grid so its reflow matches the pty exactly; take-back (reveal) restores the
/// pane fit and verifies with a drift-only repair (`Session.appliedGrid()`).
public enum RemoteGridFit {
    /// Whether `owner` is a remote viewer (web / phone) rather than the native
    /// app's own pane or nobody. Only a remote owner's grid is worth adopting —
    /// a local owner IS this surface, and an unclaimed grid has no driver.
    public static func isRemote(owner: String?) -> Bool {
        guard let owner else { return false }
        return owner != GridArbiter.localOwner
    }

    /// Sub-cell pixel pad added to the target frame so float error in the
    /// points→pixels round-trip can never drop a column/row (Ghostty computes
    /// its grid as `floor(px / cellPx)`; the pad keeps the floor at exactly
    /// (cols, rows) because the next boundary is a whole cell away).
    static let padPx = 1.0

    /// The surface frame size in points that makes Ghostty measure exactly
    /// (cols, rows), given its current cell metrics in pixels and the backing
    /// scale. Zero when any input is degenerate — the caller skips adoption
    /// (fallback: the frozen surface just never pushes local SIGWINCHes).
    public static func surfacePointSize(
        cols: Int, rows: Int,
        cellWidthPx: Int, cellHeightPx: Int,
        scale: Double
    ) -> (width: Double, height: Double) {
        guard cols > 0, rows > 0, cellWidthPx > 0, cellHeightPx > 0, scale > 0 else {
            return (width: 0, height: 0)
        }
        return (width: (Double(cols * cellWidthPx) + padPx) / scale,
                height: (Double(rows * cellHeightPx) + padPx) / scale)
    }
}
