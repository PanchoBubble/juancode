import Foundation

/// Remembers the last on-screen terminal grid (cols×rows) so a newly-spawned CLI
/// can boot already matching the visible terminal. Persisted in UserDefaults;
/// written by the live terminal panes as they resize.
///
/// Lives in core (not the app target) because the embedded WS server needs it too:
/// a remotely created session with no viewport of its own — an Oracle dispatch —
/// must boot at the desktop's real width, or the whole turn is printed narrow and
/// stays narrow in the scrollback no matter how the pane is sized afterwards.
public enum TerminalGrid {
    private static let key = "juancode.lastTerminalGrid"

    /// Smallest grid worth remembering: below this it's a collapsing panel or a
    /// mid-animation frame, not a terminal anyone is reading.
    static let minCols = 20
    static let minRows = 10

    public static func remember(cols: Int, rows: Int) {
        guard cols >= minCols, rows >= minRows else { return }
        UserDefaults.standard.set("\(cols),\(rows)", forKey: key)
    }

    /// The grid a new CLI should boot at. Falls back to a roomy default before any
    /// pane has reported a size.
    public static var spawn: (cols: Int, rows: Int) {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        return parse(raw) ?? (120, 40)
    }

    /// Parse a stored `"cols,rows"` pair, rejecting anything too small to be a real
    /// on-screen grid. Exposed for testing.
    public static func parse(_ raw: String) -> (cols: Int, rows: Int)? {
        let parts = raw.split(separator: ",").compactMap { Int($0) }
        guard parts.count == 2, parts[0] >= minCols, parts[1] >= minRows else { return nil }
        return (parts[0], parts[1])
    }
}
