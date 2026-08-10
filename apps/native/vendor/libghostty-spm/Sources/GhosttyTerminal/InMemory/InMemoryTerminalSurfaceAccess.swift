import Foundation
import GhosttyKit

/// Serializes host output while keeping the raw surface alive for each C call.
final class InMemoryTerminalSurfaceAccess: @unchecked Sendable {
    typealias Write = @Sendable (ghostty_surface_t, Data) -> Void
    typealias ProcessExit = @Sendable (ghostty_surface_t, UInt32, UInt64) -> Void

    private let condition = NSCondition()
    private let outputQueue = DispatchQueue(
        label: "com.lakr233.libghostty-spm.in-memory-output",
        qos: .userInitiated
    )
    private let write: Write
    private let processExit: ProcessExit

    private var surface: ghostty_surface_t?
    /// Invalidates work that was enqueued for a surface that has been replaced.
    private var generation: UInt64 = 0
    /// Prevents the caller from freeing a surface while a C operation uses it.
    private var activeOperations = 0
    /// juancode patch (juancode-o9h2): set once a drain wait has timed out, meaning
    /// an operation is wedged inside libghostty and will never decrement the count.
    /// The surface it holds must then be leaked rather than freed — see
    /// `waitForActiveOperations`.
    private var stalledOperations = false

    /// juancode patch: how long a teardown will wait for in-flight C operations
    /// before giving up. Healthy operations finish in microseconds; this only ever
    /// expires when one is wedged.
    private static let drainTimeout: TimeInterval = 0.5

    /// juancode patch: true once an operation has been abandoned as wedged. The
    /// surface is then unsafe to free (the stalled call may still touch it), so the
    /// caller must leak it.
    var hasStalledOperations: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stalledOperations
    }

    init(
        write: @escaping Write,
        processExit: @escaping ProcessExit
    ) {
        self.write = write
        self.processExit = processExit
    }

    func setSurface(_ surface: ghostty_surface_t?) {
        condition.lock()
        generation &+= 1
        self.surface = nil
        waitForActiveOperations()
        self.surface = surface
        condition.unlock()
    }

    @discardableResult
    func clearSurface(ifMatches expectedSurface: ghostty_surface_t?) -> Bool {
        condition.lock()
        guard surface == expectedSurface else {
            condition.unlock()
            return false
        }

        generation &+= 1
        surface = nil
        waitForActiveOperations()
        condition.unlock()
        return true
    }

    var currentSurface: ghostty_surface_t? {
        condition.lock()
        defer { condition.unlock() }
        return surface
    }

    @discardableResult
    func enqueueWrite(_ data: Data) -> Bool {
        guard let generation = currentGeneration else { return false }
        outputQueue.async { [self] in
            withSurface(generation: generation) { surface in
                write(surface, data)
            }
        }
        return true
    }

    @discardableResult
    func enqueueProcessExit(
        exitCode: UInt32,
        runtimeMilliseconds: UInt64
    ) -> Bool {
        guard let generation = currentGeneration else { return false }
        outputQueue.async { [self] in
            withSurface(generation: generation) { surface in
                processExit(surface, exitCode, runtimeMilliseconds)
            }
        }
        return true
    }

    func withCurrentSurface<Result>(
        _ operation: (ghostty_surface_t) -> Result
    ) -> Result? {
        condition.lock()
        guard let surface else {
            condition.unlock()
            return nil
        }
        activeOperations += 1
        condition.unlock()

        defer { finishOperation() }
        return operation(surface)
    }

    func waitForPendingOutput() {
        outputQueue.sync {}
    }

    private var currentGeneration: UInt64? {
        condition.lock()
        defer { condition.unlock() }
        return surface == nil ? nil : generation
    }

    private func withSurface(
        generation expectedGeneration: UInt64,
        _ operation: (ghostty_surface_t) -> Void
    ) {
        condition.lock()
        guard generation == expectedGeneration, let surface else {
            condition.unlock()
            return
        }
        activeOperations += 1
        condition.unlock()

        defer { finishOperation() }
        operation(surface)
    }

    private func finishOperation() {
        condition.lock()
        activeOperations -= 1
        if activeOperations == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    /// juancode patch (juancode-o9h2). Upstream waits forever:
    ///
    ///     while activeOperations > 0 { condition.wait() }
    ///
    /// A host write can wedge inside libghostty — its render/io loops park while a
    /// surface is occluded, and the Zig side then never completes the write — so the
    /// count never reaches zero. Because the only callers are `setSurface` and
    /// `clearSurface`, and `clearSurface` is reached from a view's `deinit` on the
    /// MAIN thread (inside a CoreAnimation commit), an unbounded wait freezes the
    /// whole app permanently. Observed twice: 3 Aug and 6 Aug 2026.
    ///
    /// Time out instead. On timeout we do NOT pretend the operation finished: the
    /// stalled call may still touch the surface, so `stalledOperations` latches and
    /// the caller leaks the surface rather than freeing it under a live C call.
    /// Leaking one surface per wedge beats freezing, and beats a use-after-free.
    private func waitForActiveOperations() {
        guard activeOperations > 0 else { return }
        let deadline = Date().addingTimeInterval(Self.drainTimeout)
        while activeOperations > 0 {
            // NSCondition.wait(until:) returns false once the deadline passes.
            guard condition.wait(until: deadline) else {
                stalledOperations = true
                // NSLog, not TerminalDebugLog: that logger is off by default and prints
                // to stdout, so the two freezes this patch exists for left no record of
                // whether the drain expired. This has to show up unconditionally.
                NSLog("juancode: libghostty drain timed out with \(activeOperations) wedged operation(s) — quarantining the surface")
                return
            }
        }
    }
}
