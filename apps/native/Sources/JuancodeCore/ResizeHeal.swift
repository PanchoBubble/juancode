import Foundation

/// The decision half of the post-resize heal both terminal backends run
/// (juancode-8llo). A resize that lands while the CLI is streaming leaves the
/// surface holding bytes the CLI emitted for the *previous* grid, laid out at the
/// new one. Once the output goes quiet the pane repaints from the headless model
/// and, if it was streaming, forces one genuine SIGWINCH so the CLI re-lays-out too.
///
/// Only the state machine lives here; the quiet timer stays in each pane (it needs
/// the main-queue lifetime of the view). The subtleties this type owns:
///
/// - Re-arming while already armed must NOT re-clear `sawStream`: the streaming
///   signal has to survive a whole drag, not just the last resize event in it.
/// - `fire()` disarms *before* the caller heals, so the redraw bytes the heal
///   provokes don't arm the next heal into a loop.
/// - An idle resize needs no SIGWINCH flap — the CLI's own handler already
///   repainted cleanly, and a flap mid-stream is itself a garble source
///   (juancode-msnf). The screen repaint is still worth running: it costs one
///   parse and it is what clears a stale frame the CLI never redrew.
public struct ResizeHealPolicy: Sendable {
    /// A heal is pending, waiting for the CLI's output to go quiet.
    public private(set) var armed = false
    /// Output arrived while armed — i.e. the CLI was streaming through the resize,
    /// the case whose render is actually corruptible.
    public private(set) var sawStream = false

    public init() {}

    /// Arm the heal (or keep it armed). Returns true when this is a fresh arm, which
    /// is only informational — the caller schedules its quiet timer either way.
    @discardableResult
    public mutating func arm() -> Bool {
        guard !armed else { return false }
        armed = true
        sawStream = false
        return true
    }

    /// Note pty output. Returns whether the quiet timer should be pushed out (i.e. a
    /// heal is pending, so we only fire once the stream truly stops).
    @discardableResult
    public mutating func noteOutput() -> Bool {
        guard armed else { return false }
        sawStream = true
        return true
    }

    /// The quiet timer fired. Disarms and reports what the pane should do.
    public mutating func fire() -> ResizeHealAction {
        let wasStreaming = sawStream
        armed = false
        sawStream = false
        return ResizeHealAction(repaint: true, sigwinch: wasStreaming)
    }

    /// Drop a pending heal without acting (the pane was hidden or torn down).
    public mutating func disarm() {
        armed = false
        sawStream = false
    }
}

/// What a pane should do when its heal timer fires.
public struct ResizeHealAction: Equatable, Sendable {
    /// Repaint the surface from the headless model's parsed screen.
    public let repaint: Bool
    /// Also force one genuine SIGWINCH so the CLI itself re-lays-out.
    public let sigwinch: Bool
}

/// `ResizeHealPolicy` plus its quiet timer — the whole heal, ready to own from a
/// terminal pane. Both backends hold one of these: `arm()` on every grid apply,
/// `noteOutput()` on every chunk that reaches the surface, and `onQuiet` fires on the
/// MAIN queue once the CLI has been silent for `quietMs`.
///
/// Callable from any thread (`noteOutput` is on the pty's path) — the policy is
/// guarded by a lock rather than an actor, because the two panes that own one live in
/// different isolation worlds: Ghostty's coordinator is `@MainActor`, SwiftTerm's
/// conforms to a nonisolated SwiftTerm protocol and so can't be. What to *do* with
/// the action stays the pane's business.
public final class TerminalResizeHeal: @unchecked Sendable {
    private let lock = NSLock()
    private var policy = ResizeHealPolicy()
    private var work: DispatchWorkItem?
    private let quietDelay: DispatchTimeInterval
    private let onQuiet: @Sendable (ResizeHealAction) -> Void

    public init(quietMs: Int = 250, onQuiet: @escaping @Sendable (ResizeHealAction) -> Void) {
        self.quietDelay = .milliseconds(quietMs)
        self.onQuiet = onQuiet
    }

    /// A grid apply happened: heal once the output settles. Re-arming while already
    /// armed only reschedules the timer.
    public func arm() {
        // `arm()`'s "was a fresh arm" is informational (the timer is scheduled
        // either way), but it travels out through `withLock`'s return value, which
        // no `@discardableResult` on the policy covers.
        _ = lock.withLock { policy.arm() }
        schedule()
    }

    /// Output reached the surface. Pushes the quiet timer out while a heal is pending
    /// so we act only after the CLI genuinely stops emitting; a no-op otherwise.
    public func noteOutput() {
        guard lock.withLock({ policy.noteOutput() }) else { return }
        schedule()
    }

    /// Drop a pending heal (pane hidden or torn down).
    public func disarm() {
        lock.withLock {
            work?.cancel()
            work = nil
            policy.disarm()
        }
    }

    private func schedule() {
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let action = self.lock.withLock { () -> ResizeHealAction in
                self.work = nil
                return self.policy.fire()
            }
            self.onQuiet(action)
        }
        lock.withLock {
            work?.cancel()
            work = w
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + quietDelay, execute: w)
    }
}
