import Foundation

/// What a session's terminal pane should render right now (juancode-p6tw).
///
/// The pane has four sources of content and only one of them is a live pty, so the
/// choice was previously spread across `if let session = liveSession(...)` branches
/// in the view — with the fallback being a raw scrollback replay. That replay feeds a
/// dead CLI's TUI escapes into a freshly-sized terminal, so an exited session opened
/// from the sidebar paints garbage for the second or two its auto-resume takes. The
/// decision lives here (pure, testable); `SessionContainer` is the thin renderer.
public enum SessionPanePhase: Equatable, Sendable {
    /// A live pty that has already emitted output — the normal case, render it.
    case live
    /// A live pty that hasn't written a byte yet: a fresh `claude`/`codex` spawn is a
    /// black rectangle until its TUI draws its first frame. The pane still mounts (it
    /// owns the pty and the keyboard focus); a hint floats over it.
    case booting
    /// No pty: a resume / fresh-start is in flight. Show a loading card INSTEAD of the
    /// replay, so the garbled history never renders.
    case resuming
    /// The agent was killed from the UI this run — a plain stopped card with a resume
    /// CTA (juancode-x46x).
    case stopped
    /// No pty and nothing in flight: the prior conversation couldn't be resumed, so the
    /// recorded scrollback is genuinely all there is to show.
    case replay
}

public enum SessionPaneState {
    /// Decide a pane's phase.
    ///
    /// - `isLive`: the registry still has a pty for this session.
    /// - `hasDrawn`: that pty has produced at least one byte (see `AppModel.drawnPanes`).
    /// - `isActivating`: an `openPersistedPane` resume/fresh-start is in flight.
    /// - `isStopped`: the agent was killed from the UI this run and not revived since.
    ///
    /// A live pty always wins: once the pty is back, whatever was in flight is done and
    /// any stale "stopped" flag is moot. `isActivating` outranks `isStopped` because
    /// reopening a killed pane revives it — the loading card is the more accurate
    /// story from the click onward.
    public static func phase(isLive: Bool, hasDrawn: Bool,
                             isActivating: Bool, isStopped: Bool) -> SessionPanePhase {
        if isLive { return hasDrawn ? .live : .booting }
        if isActivating { return .resuming }
        if isStopped { return .stopped }
        return .replay
    }
}
