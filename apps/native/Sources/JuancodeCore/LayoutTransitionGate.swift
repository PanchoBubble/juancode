import Foundation

/// Terminal layout-transition gate (juancode-1th.2).
///
/// Opening/closing a side/bottom panel (or a fullscreen toggle) re-lays-out the
/// terminal through a burst of intermediate geometries. The resize throttle keeps
/// the pty in lockstep during a *drag* — which is right there — but for a discrete
/// transition lockstep is wrong: the CLI repaints for each intermediate grid
/// mid-stream and its incremental renderer leaves those garbled frames behind
/// until a manual resync (the "panel toggle garbles the TUI" bug).
///
/// The UI marks the transition here (`begin`) right before mutating the layout;
/// the terminal coordinators then hold every grid push that lands inside the
/// window and, once the layout settles, assert the final grid ONCE with a genuine
/// SIGWINCH so the TUI fully re-lays-out. A plain final resize isn't enough: a
/// net-zero transition (open then close) settles at the grid the pty already has,
/// so no SIGWINCH would fire and the garbled frames would stay on screen.
///
/// Thread-safe (its own lock) like `GridArbiter`, though in practice it's only
/// touched on the main thread.
public final class LayoutTransitionGate: @unchecked Sendable {
    /// The app-wide gate the panel toggles and terminal coordinators share — a
    /// panel transition reflows every terminal in the window, so one gate serves
    /// all coordinators.
    public static let shared = LayoutTransitionGate()

    private let lock = NSLock()
    private var deadline: DispatchTime = .now()

    public init() {}

    /// Mark a layout transition as in flight for `duration` — resize events that
    /// land inside this window are intermediate and must be held for the settle
    /// push. Repeated calls extend the window, never shorten it (an overlapping
    /// shorter transition must not cut a longer one short).
    public func begin(for duration: DispatchTimeInterval = .milliseconds(350)) {
        lock.withLock {
            let end = DispatchTime.now() + duration
            if end > deadline { deadline = end }
        }
    }

    /// Whether a transition is in flight right now.
    public var active: Bool { lock.withLock { DispatchTime.now() < deadline } }

    /// When the current window ends. `active` is this compared against now, which a
    /// test cannot assert on without racing the clock it is trying to describe; the
    /// window itself is the thing `begin` is specified in terms of.
    var windowEnd: DispatchTime { lock.withLock { deadline } }
}
