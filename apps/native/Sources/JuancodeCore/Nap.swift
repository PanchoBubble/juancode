import Foundation

/// The one way this app sleeps in async code.
///
/// `Task.sleep(for:tolerance:clock:)` is inlinable, so the compiler emits a
/// specialization of it into our binary — and that specialization aborts the process
/// inside `swift_task_dealloc` ("freed pointer was not the last allocation") on the
/// FIRST call, whichever one that happens to be. It reproduced on pristine HEAD, on a
/// clean-room build, with an empty database, with libghostty off, and with a
/// single-threaded cooperative pool, always ~5s after launch: whichever sleeper ran
/// first died, and fixing that one just moved the abort to the next. It does not
/// reproduce in a standalone `-O` binary with the same code shape, so it needs this
/// build's specialization to show up.
///
/// `Task.sleep(nanoseconds:)` is a different entry point and is unaffected, so every
/// sleep goes through here. Keeping it in one place is the point: a stray
/// `Task.sleep(for:)` anywhere in the app brings the crash straight back.
public enum Nap {
    /// Suspend for `duration`. Cancellation ends the sleep early and is swallowed,
    /// matching the `try? await Task.sleep(...)` these call sites replaced.
    public static func duration(_ duration: Duration) async {
        let (seconds, attoseconds) = duration.components
        guard seconds > 0 || attoseconds > 0 else { return }
        let whole = UInt64(clamping: seconds).multipliedReportingOverflow(by: 1_000_000_000)
        guard !whole.overflow else { try? await Task.sleep(nanoseconds: .max); return }
        let total = whole.partialValue.addingReportingOverflow(UInt64(clamping: attoseconds / 1_000_000_000))
        try? await Task.sleep(nanoseconds: total.overflow ? .max : total.partialValue)
    }

    /// Suspend for `milliseconds`.
    public static func ms(_ milliseconds: Int) async {
        guard milliseconds > 0 else { return }
        await duration(.milliseconds(milliseconds))
    }
}
