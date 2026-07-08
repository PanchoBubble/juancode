import Foundation

/// Batches pty output chunks and flushes them to a terminal surface once per
/// main-runloop turn, rather than one `feed()` per chunk.
///
/// A pty callback fires on a background queue, typically as a burst of small
/// chunks while an agent redraws a full-screen TUI. Feeding each chunk with its
/// own `DispatchQueue.main.async` schedules one ANSI parse + grid reflow per
/// chunk on the main thread; with several sessions mounted at once (LivePanePool
/// keeps up to five) those bursts stack up and drop frames. Coalescing collapses
/// a burst into a single feed per frame, so the parse/reflow cost is paid once
/// over the concatenated bytes.
final class TerminalFeedCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var scheduled = false
    private let flush: @MainActor @Sendable (_ bytes: [UInt8]) -> Void

    /// `flush` runs on the main actor with the bytes accumulated for this turn.
    init(flush: @escaping @MainActor @Sendable (_ bytes: [UInt8]) -> Void) {
        self.flush = flush
    }

    /// Append a chunk (any thread). Schedules a single main-runloop drain when
    /// none is pending, so every chunk that lands before it runs coalesces.
    func append(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        buffer.append(contentsOf: bytes)
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        guard needsSchedule else { return }
        DispatchQueue.main.async { [weak self] in self?.drain() }
    }

    /// Runs on the main queue (dispatched from `append`). Swaps out the buffer
    /// under the lock, then feeds the concatenated bytes once.
    private func drain() {
        lock.lock()
        let out = buffer
        buffer.removeAll(keepingCapacity: true)
        scheduled = false
        lock.unlock()
        guard !out.isEmpty else { return }
        MainActor.assumeIsolated {
            PerfMonitor.recordFeed(out.count)
            flush(out)
        }
    }
}
