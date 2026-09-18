import Foundation

/// Timing for a sliding panel's open/close (the Oracle drawer).
///
/// A drawer that slides over a live terminal has two costs the user sees as one
/// "jumpy" open: the slide itself, and whatever the open path does to the terminal
/// while it is still moving — disk IO on main, a spawn that rebuilds the surface and
/// replays scrollback, a re-measured Ghostty grid as the pane comes back on screen.
/// Doing that work mid-slide repaints the TUI under a moving panel.
///
/// So the panel opens immediately and the terminal-disturbing work waits for the
/// slide plus a quiet beat. Pure arithmetic so the policy is testable without an app;
/// `OracleModel` is the executor.
public enum PanelSettle {
    /// The drawer's slide. Must match the dock's open/close animation duration.
    public static let slideMs = 160
    /// Quiet beat after the slide lands before deferred work runs.
    public static let debounceMs = 100

    /// How long the whole gate stays shut from the moment a slide starts.
    public static var windowMs: Int { slideMs + debounceMs }

    /// How long to wait before running work that would repaint the terminal, given
    /// how long ago the slide started. `nil` (no slide in flight) — or a slide that
    /// already settled — means run now, so acting on an already-open panel stays
    /// instant.
    public static func waitMs(sinceSlideStartMs: Int?) -> Int {
        guard let since = sinceSlideStartMs else { return 0 }
        return max(0, windowMs - since)
    }
}
