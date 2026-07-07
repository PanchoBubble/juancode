import Foundation

/// Per-session pty grid arbitration (juancode-1th.1).
///
/// A session's pty is a single shared grid, but several clients may view it at
/// once (the native app's own terminal view + web + phone PWA), each at a
/// different size. Without arbitration every `attach`/`resize` wrote the grid
/// last-write-wins, so with two different-sized viewers the CLI TUI flapped back
/// and forth between their sizes.
///
/// This gives each session a single *controlling* owner: the first client to set
/// the grid claims it and holds it until it disconnects (`release`), at which
/// point the next client's request takes over. The in-process local native view
/// (`GridArbiter.localOwner`) preempts a remote owner, so the primary on-screen
/// surface always drives the grid. A non-owner's request is denied — the caller
/// renders the pty's actual grid as-is instead of fighting for it.
///
/// Thread-safe (its own lock), so `Session` can arbitrate from any queue. Mirrors
/// `apps/server/src/gridArbiter.ts`.
public final class GridArbiter: @unchecked Sendable {
    /// Reserved owner id for the in-process local view (the native app's own
    /// terminal). It preempts a remote owner so dragging the native window always
    /// wins the grid, per the "native app is the primary surface" policy. Mirrors
    /// `LOCAL_GRID_OWNER` in the TS twin.
    public static let localOwner = "__local__"

    private let lock = NSLock()
    private var owner: String?

    public init() {}

    /// Whether `owner` may drive the grid right now. Claims the grid when it's
    /// free or already held by `owner`, and lets the local view preempt a remote
    /// owner. Returns false when a different client owns the grid (denied).
    public func request(_ owner: String) -> Bool {
        lock.withLock {
            if self.owner == nil || self.owner == owner || owner == Self.localOwner {
                self.owner = owner
                return true
            }
            return false
        }
    }

    /// Release ownership held by `owner` (its client disconnected / its view was
    /// torn down) so the next client's request can claim the grid. No-op if
    /// `owner` isn't the current owner. Returns whether ownership was actually
    /// freed, so a caller can notify observers on the real transition only.
    @discardableResult
    public func release(_ owner: String) -> Bool {
        lock.withLock {
            guard self.owner == owner else { return false }
            self.owner = nil
            return true
        }
    }

    /// The current controlling owner, or nil when the grid is unclaimed.
    public var current: String? { lock.withLock { owner } }
}
