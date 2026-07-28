import Foundation

/// Process-wide serialization for SwiftTerm parsing.
///
/// SwiftTerm keeps global mutable state that its parser mutates with no internal
/// locking — most importantly `TinyAtom.map`, the OSC 8 hyperlink atom table
/// shared by EVERY `Terminal` instance in the process. juancode parses each pty
/// stream in more than one place, on different threads: the headless
/// `SessionTerminalModel` on the session workQueue, and each GUI `TerminalView`
/// (plus the editor / shell panes) on the main actor. Two feeds carrying an OSC 8
/// hyperlink then write that shared table concurrently and corrupt the Dictionary
/// — an abort inside `TinyAtom.lookup` ("unrecognized selector sent to <garbage>"),
/// the terminal crash-loop of juancode-9goj.
///
/// Every SwiftTerm `feed`/`resize` call in the app funnels through `locked`, so all
/// parsing is serialized regardless of which thread drives it. Acquire this AFTER
/// any per-instance model lock (`SessionTerminalModel.feed` takes its model lock
/// then this; GUI feeds take only this), so the lock order is fixed and no cycle
/// can form.
///
/// RECURSIVE on purpose: SwiftTerm calls its delegate synchronously *during* a
/// feed, and some of those callbacks re-enter a locked section on the SAME thread —
/// a GUI `feed` (holding this) processing a column-switch (DECCOLM) fires
/// `sizeChanged`, which resizes the session and so calls
/// `SessionTerminalModel.resize` → `SwiftTermParse.locked` again. A non-recursive
/// lock self-deadlocks there and freezes the main thread (the app then can't be
/// closed and needs SIGKILL). A recursive lock lets the same thread re-enter while
/// still blocking every OTHER thread, so cross-thread mutual exclusion — the whole
/// point of the race fix — is preserved.
public enum SwiftTermParse {
    private static let lock = NSRecursiveLock()

    @inline(__always)
    public static func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
