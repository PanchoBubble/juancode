import Foundation
import JuancodeCore

/// Streams one session's rendered screen to one connection: a full snapshot on
/// start, then row-diffs coalesced from the model's damage stream on an ~80ms
/// tick. The remote client renders rows directly — no client-side emulator — and
/// bandwidth is bounded by the diff rate (a busy TUI repainting the same rows
/// coalesces to at most one frame per tick), not the pty's output rate.
///
/// Read-only by construction: it only ever reads `SessionTerminalModel`
/// projections, so a screen viewer can never resize or otherwise disturb the pty
/// grid the desktop owns.
///
/// Diffs are computed against the last snapshot actually SENT, so a skipped tick
/// (writer backed up) loses nothing — the next drain emits one coalesced diff
/// covering everything since. That also bounds per-viewer memory at one snapshot.
final class ScreenStreamer: @unchecked Sendable {
    private let sessionId: String
    private let model: SessionTerminalModel
    private let tick: DispatchTimeInterval
    private let autoFlush: Bool
    private let isBackedUp: @Sendable () -> Bool
    private let send: @Sendable (ServerMessage) -> Void
    private let queue = DispatchQueue(label: "com.juancode.ws-screen")

    private let lock = NSLock()
    private var lastSent: TerminalSnapshot?
    private var dirty = false
    private var scheduled = false
    private var stopped = false
    private var cancelDamage: (() -> Void)?

    /// - Parameters:
    ///   - tickMs: diff cadence; at most one frame per tick.
    ///   - autoFlush: when true (production) damage arms a timer that flushes;
    ///     tests pass false and drive `flushTick()` directly for determinism.
    init(sessionId: String,
         model: SessionTerminalModel,
         tickMs: Int = 80,
         autoFlush: Bool = true,
         isBackedUp: @escaping @Sendable () -> Bool,
         send: @escaping @Sendable (ServerMessage) -> Void) {
        self.sessionId = sessionId
        self.model = model
        self.tick = .milliseconds(tickMs)
        self.autoFlush = autoFlush
        self.isBackedUp = isBackedUp
        self.send = send
    }

    /// Send the full current screen and start following the damage stream.
    func start() {
        let snap = model.snapshot()
        lock.withLock { lastSent = snap }
        send(frame(snap, reset: true, lines: ScreenWire.fullLines(snap)))
        let cancel = model.onDamage { [weak self] _ in self?.markDirty() }
        lock.withLock { cancelDamage = cancel }
    }

    /// Stop following damage and drop state. Idempotent; safe from any thread.
    func stop() {
        let cancel: (() -> Void)? = lock.withLock {
            stopped = true
            dirty = false
            let c = cancelDamage
            cancelDamage = nil
            return c
        }
        cancel?()
    }

    private func markDirty() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        dirty = true
        scheduleLocked()
    }

    private func scheduleLocked() {
        guard autoFlush, !scheduled, !stopped else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + tick) { [weak self] in self?.flushTick() }
    }

    /// Emit at most one frame covering everything since the last one. While the
    /// connection's writer is backed up it emits nothing and re-arms — the diff
    /// base doesn't advance, so nothing is lost. Internal so tests drive it
    /// deterministically; production reaches it via the damage-armed timer.
    func flushTick() {
        lock.lock()
        scheduled = false
        if stopped || !dirty {
            lock.unlock()
            return
        }
        if isBackedUp() {
            scheduleLocked()
            lock.unlock()
            return
        }
        dirty = false
        let prev = lastSent
        lock.unlock()

        let snap = model.snapshot()
        lock.withLock { lastSent = snap }
        // A geometry or buffer flip invalidates row indices — repaint wholesale.
        guard let prev,
              snap.cols == prev.cols, snap.rows == prev.rows,
              snap.isAlternateBuffer == prev.isAlternateBuffer else {
            send(frame(snap, reset: true, lines: ScreenWire.fullLines(snap)))
            return
        }
        let changed = ScreenWire.changedLines(prev: prev, next: snap)
        let cursorMoved = snap.cursorX != prev.cursorX || snap.cursorY != prev.cursorY
            || snap.cursorVisible != prev.cursorVisible
        guard !changed.isEmpty || cursorMoved else { return }
        send(frame(snap, reset: false, lines: changed))
    }

    private func frame(_ snap: TerminalSnapshot, reset: Bool, lines: [ScreenRowWire]) -> ServerMessage {
        .screen(sessionId: sessionId, reset: reset, cols: snap.cols, rows: snap.rows,
                cursorX: snap.cursorX, cursorY: snap.cursorY,
                cursorVisible: snap.cursorVisible, alt: snap.isAlternateBuffer,
                lines: lines)
    }
}
