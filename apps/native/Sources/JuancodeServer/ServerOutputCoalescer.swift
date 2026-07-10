import Foundation

/// Per-connection coalescer + bounded buffer for the server→client `output` path
/// (juancode-5qw.7). The server side twin of the local view's
/// `TerminalFeedCoalescer` (juancode-kdn): instead of turning every pty chunk into
/// its own `ServerMessage.output` frame (a fresh String decode + JSON encode on an
/// unbounded stream), it batches a session's bytes and flushes one frame per tick.
///
/// It also bounds the buffer so a slow/stalled remote client (a phone on a tunnel)
/// can't grow server memory without limit — the same failure family as the
/// juancode-agy memory exhaustion. Two mechanisms combine:
///
///  - **Gating on writer backpressure.** While the connection's send gate reports
///    it's backed up (the writer task can't drain fast enough because the socket
///    is stalled), the tick does NOT emit — bytes accumulate here, where they
///    coalesce, rather than piling onto the send stream.
///  - **Hard byte cap.** If the accumulated bytes cross `maxBytes`, the buffer is
///    dropped and every buffered session is flagged for resync. On the next tick
///    that drains (once the client is reading again) the connection repaints the
///    session from fresh scrollback instead of replaying a stream with a gap.
///
/// The resync is expressed by re-sending the existing `attached` frame (see
/// `WebSocketConnection.resync`), so no new wire message is introduced.
final class ServerOutputCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    /// Coalesced bytes awaiting flush, keyed by session/pty id.
    private var pending: [String: [UInt8]] = [:]
    /// Flush order — a session is appended on its first buffered chunk.
    private var order: [String] = []
    /// Sessions whose bytes were dropped on overflow and must repaint from
    /// scrollback instead of the incremental stream.
    private var resyncNeeded: Set<String> = []
    private var totalBytes = 0
    private var scheduled = false
    private var stopped = false

    private let tick: DispatchTimeInterval
    private let maxBytes: Int
    private let autoFlush: Bool
    private let queue = DispatchQueue(label: "com.juancode.ws-output-coalesce")

    /// True while the connection's writer can't keep up — bytes should buffer here
    /// rather than be flushed onto the (unbounded) send stream.
    private let isBackedUp: @Sendable () -> Bool
    /// Emit one coalesced output frame for a session. Runs off the coalescer lock.
    private let emitOutput: @Sendable (_ sessionId: String, _ bytes: [UInt8]) -> Void
    /// Repaint a session that overflowed (dropped bytes). Set by the owning
    /// connection after init. Runs off the coalescer lock.
    var onResync: (@Sendable (_ sessionId: String) -> Void)?

    /// - Parameters:
    ///   - tickMs: flush cadence; one frame per session per tick (~16-80ms).
    ///   - maxBytes: hard cap on buffered bytes before a drop-and-resync.
    ///   - autoFlush: when true (production) `append` arms a timer that drains the
    ///     buffer; tests pass false and drive `flushTick()` directly for determinism.
    init(tickMs: Int = 30,
         maxBytes: Int = 4 << 20,
         autoFlush: Bool = true,
         isBackedUp: @escaping @Sendable () -> Bool,
         emitOutput: @escaping @Sendable (_ sessionId: String, _ bytes: [UInt8]) -> Void) {
        self.tick = .milliseconds(tickMs)
        self.maxBytes = maxBytes
        self.autoFlush = autoFlush
        self.isBackedUp = isBackedUp
        self.emitOutput = emitOutput
    }

    /// Append a session's pty bytes (any thread). Coalesces with anything already
    /// buffered for that session and arms a flush. On crossing `maxBytes` the whole
    /// buffer is dropped and every buffered session is flagged for resync.
    func append(_ sessionId: String, _ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        // Already overflowed and awaiting resync: the repaint replays full
        // scrollback, so incremental bytes are redundant — drop them.
        if resyncNeeded.contains(sessionId) {
            scheduleTimerLocked()
            return
        }
        if pending[sessionId] == nil { order.append(sessionId) }
        pending[sessionId, default: []].append(contentsOf: bytes)
        totalBytes += bytes.count
        if totalBytes > maxBytes {
            for id in order { resyncNeeded.insert(id) }
            pending.removeAll(keepingCapacity: true)
            order.removeAll(keepingCapacity: true)
            totalBytes = 0
        }
        scheduleTimerLocked()
    }

    /// Flush one session's buffered bytes immediately (used to keep output ordered
    /// before an `exit` frame). No-op while backed up — the bytes stay buffered and
    /// will drop-and-resync if the stall persists.
    func flushSession(_ sessionId: String) {
        guard !isBackedUp() else { return }
        var out: [UInt8]?
        var doResync = false
        lock.lock()
        if resyncNeeded.remove(sessionId) != nil {
            doResync = true
        } else if let b = pending[sessionId], !b.isEmpty {
            out = b
        }
        if let b = pending.removeValue(forKey: sessionId) { totalBytes -= b.count }
        order.removeAll { $0 == sessionId }
        lock.unlock()
        if doResync { onResync?(sessionId) }
        else if let out { emitOutput(sessionId, out) }
    }

    /// Forget a session entirely (on unsubscribe/close), dropping its buffer.
    func forget(_ sessionId: String) {
        lock.lock()
        if let b = pending.removeValue(forKey: sessionId) { totalBytes -= b.count }
        order.removeAll { $0 == sessionId }
        resyncNeeded.remove(sessionId)
        lock.unlock()
    }

    /// Stop all further flushes and drop the buffer (connection teardown).
    func stop() {
        lock.lock()
        stopped = true
        pending.removeAll(); order.removeAll(); resyncNeeded.removeAll()
        totalBytes = 0
        lock.unlock()
    }

    /// Currently buffered byte count — test introspection.
    var bufferedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return totalBytes
    }

    // MARK: - internals

    private func scheduleTimerLocked() {
        guard autoFlush, !scheduled, !stopped else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + tick) { [weak self] in self?.flushTick() }
    }

    /// Drain the buffer: emit one frame per buffered session, or repaint sessions
    /// flagged for resync. While backed up it emits nothing and re-arms so the
    /// buffered bytes flush once the client is reading again. Internal so tests can
    /// drive it deterministically.
    func flushTick() {
        lock.lock()
        scheduled = false
        if stopped { lock.unlock(); return }
        if isBackedUp() {
            if !pending.isEmpty || !resyncNeeded.isEmpty { scheduleTimerLocked() }
            lock.unlock()
            return
        }
        let resyncIds = Array(resyncNeeded)
        var toEmit: [(String, [UInt8])] = []
        for id in order where !resyncNeeded.contains(id) {
            if let b = pending[id], !b.isEmpty { toEmit.append((id, b)) }
        }
        pending.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        resyncNeeded.removeAll()
        totalBytes = 0
        lock.unlock()
        for id in resyncIds { onResync?(id) }
        for (id, b) in toEmit { emitOutput(id, b) }
    }
}
