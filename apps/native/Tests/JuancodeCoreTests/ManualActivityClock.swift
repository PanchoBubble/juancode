import Foundation
@testable import JuancodeCore

/// A virtual `ActivityClock`: nothing fires until a test advances time, so the
/// detector's settle and watchdog windows are exercised as *logic* rather than as a
/// race against wall clock. The suite used to pass real sleeps against a 60ms settle
/// window, which meant a loaded machine could run the settle before the assertion.
///
/// Deadlines still run on the queue they were scheduled on, so the detector keeps its
/// serial-queue discipline, and `advance` returns only once they have finished —
/// including anything that re-armed while draining.
final class ManualActivityClock: ActivityClock, @unchecked Sendable {
    private struct Pending {
        let dueMs: Int
        /// Tie-break so two deadlines with the same instant fire in schedule order.
        let seq: Int
        let queue: DispatchQueue
        let work: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var nowMs = 0
    private var seq = 0
    private var pending: [Pending] = []

    func now() -> Date {
        Date(timeIntervalSince1970: Double(lock.withLock { nowMs }) / 1000)
    }

    func schedule(after ms: Int, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) {
        lock.withLock {
            seq += 1
            pending.append(Pending(dueMs: nowMs + ms, seq: seq, queue: queue, work: work))
        }
    }

    /// Move virtual time forward by `ms`, running every deadline that comes due in
    /// order. Stale deadlines fire too and are dropped by the detector's own
    /// generation guard, exactly as they are in production.
    func advance(_ ms: Int) {
        let target = lock.withLock { nowMs + ms }
        while let item = takeNextDue(upTo: target) {
            item.queue.sync(execute: item.work)
        }
        lock.withLock { nowMs = target }
    }

    private func takeNextDue(upTo target: Int) -> Pending? {
        lock.withLock {
            let ordered = pending.indices.min {
                (pending[$0].dueMs, pending[$0].seq) < (pending[$1].dueMs, pending[$1].seq)
            }
            guard let i = ordered, pending[i].dueMs <= target else { return nil }
            nowMs = max(nowMs, pending[i].dueMs)
            return pending.remove(at: i)
        }
    }
}

extension ActivityDetector {
    /// Barrier: returns once every chunk and batch already fed has been processed on
    /// the detector's serial queue. Reading `activity` is what flushes it; the name is
    /// here so the intent reads at the call site.
    func drain() { _ = activity }
}
