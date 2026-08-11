import Foundation
import JuancodeCore

/// The grid the Oracle dock's terminal surface last measured, persisted so a revive
/// that has no viewport of its own can still boot the CLI at the drawer's real size.
/// Written by the dock's live surface (`OracleModel.rememberDockGrid`); read here so
/// the server-side revive paths — which run nowhere near the view layer — share it.
public enum OracleDockGrid {
    private static let colsKey = "oracle.grid.cols"
    private static let rowsKey = "oracle.grid.rows"
    /// Smallest grid worth trusting — below this it's a collapsing drawer or a
    /// mid-animation frame, not a terminal anyone is reading (mirrors `TerminalGrid`).
    private static let minCols = 20
    private static let minRows = 10

    /// `defaults` is a test seam; production always uses `.standard`.
    public static func remember(cols: Int, rows: Int, in defaults: UserDefaults = .standard) {
        guard cols >= minCols, rows >= minRows else { return }
        defaults.set(cols, forKey: colsKey)
        defaults.set(rows, forKey: rowsKey)
    }

    /// The last measured dock grid, or nil before any dock surface has reported one.
    public static func stored(in defaults: UserDefaults = .standard) -> (cols: Int, rows: Int)? {
        let cols = defaults.integer(forKey: colsKey)
        let rows = defaults.integer(forKey: rowsKey)
        guard cols >= minCols, rows >= minRows else { return nil }
        return (cols, rows)
    }
}

/// The grid to resume `meta` at when the caller has no viewport to offer — a queued
/// message delivered from Telegram, a remote reply into a dead session, the launch
/// restore. A resumed CLI reprints its whole transcript at the boot grid, and that
/// reprint lands in scrollback wrapped for THAT size: boot it at a hardcoded default
/// and the pane stays narrow and short no matter how the surface is sized afterwards,
/// until a deep refresh reprints it. So each session gets the grid of the surface it
/// actually renders in — the dock for Oracle conversations, a main pane for the rest.
public func resumeGrid(for meta: SessionMeta,
                       defaults: UserDefaults = .standard) -> (cols: Int, rows: Int) {
    if meta.cwd == OraclePaths.controlDir, let dock = OracleDockGrid.stored(in: defaults) {
        return dock
    }
    return TerminalGrid.spawn
}
