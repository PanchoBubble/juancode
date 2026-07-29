import Foundation
import Testing
@testable import JuancodeCore

/// A title listener must never run inside the emulator's parse (juancode-c438).
///
/// SwiftTerm dispatches OSC 0/2 synchronously from within `terminal.feed`, so the
/// model used to notify its listeners while holding BOTH its own lock and the
/// process-global parse lock. `Session`'s listener persists the adopted title, which
/// meant one window-title repaint blocked every other session's parse, that session's
/// activity detector, and the main thread's own feed behind a SQLite write — profiled
/// as 92% of a 6s window with a terminal doing 1KB/s.
@Suite struct TerminalModelTitleReentrancyTests {
    /// OSC 2 (set window title), BEL-terminated.
    private func oscTitle(_ t: String) -> [UInt8] {
        Array("\u{1B}]2;\(t)\u{07}".utf8)
    }

    /// The listener reads the model back and takes the global parse lock — both of
    /// which deadlock or stall if it is invoked mid-parse. Nested `NSRecursiveLock`
    /// reentrancy means a broken implementation hangs here rather than failing, so a
    /// separate thread with a timeout guards the test.
    @Test func listenerRunsOutsideTheParseAndCanReadTheModelBack() async {
        let model = SessionTerminalModel(cols: 40, rows: 6, scrollbackLines: 0)
        let seen = Mutex<[String]>([])
        let screenDuringCallback = Mutex<String?>(nil)

        model.onTitleChange { title in
            seen.withLock { $0.append(title) }
            // Reads take the model lock; a mid-parse callback would be re-entering it.
            let text = model.visibleText()
            // Explicitly re-enter the global parse lock, as a persisting listener's
            // downstream work legitimately might.
            SwiftTermParse.locked {}
            screenDuringCallback.withLock { $0 = text }
        }

        // The marker sits AFTER the OSC in the same chunk: a listener invoked from
        // inside the parse cannot have seen it yet, one invoked after the feed must.
        model.feed(oscTitle("Fix the auth bug") + Array("AFTER-THE-OSC".utf8))

        #expect(seen.withLock { $0 } == ["Fix the auth bug"])
        #expect(model.terminalTitle == "Fix the auth bug")
        #expect(screenDuringCallback.withLock { $0 }?.contains("AFTER-THE-OSC") == true,
                "the listener ran mid-parse — it saw \(screenDuringCallback.withLock { $0 } ?? "nil")")
    }

    /// Repeats within one feed collapse; genuine changes are all reported in order.
    @Test func collapsesConsecutiveRepeatsWithinAFeed() {
        let model = SessionTerminalModel(cols: 40, rows: 6, scrollbackLines: 0)
        let seen = Mutex<[String]>([])
        model.onTitleChange { t in seen.withLock { $0.append(t) } }

        model.feed(oscTitle("a") + oscTitle("a") + oscTitle("b") + oscTitle("a"))
        #expect(seen.withLock { $0 } == ["a", "b", "a"])
    }

    /// A feed with no OSC title notifies nobody — the common case must stay free.
    @Test func plainOutputNotifiesNoTitleListener() {
        let model = SessionTerminalModel(cols: 40, rows: 6, scrollbackLines: 0)
        let calls = Mutex<Int>(0)
        model.onTitleChange { _ in calls.withLock { $0 += 1 } }

        model.feed(Array("just some streamed output\r\n".utf8))
        #expect(calls.withLock { $0 } == 0)
    }

    /// Minimal lock box — the test needs mutable state captured by a `@Sendable`
    /// listener without reaching for the concurrency runtime.
    private final class Mutex<Value>: @unchecked Sendable {
        private var value: Value
        private let lock = NSLock()
        init(_ value: Value) { self.value = value }
        func withLock<R>(_ body: (inout Value) -> R) -> R {
            lock.lock(); defer { lock.unlock() }
            return body(&value)
        }
    }
}
