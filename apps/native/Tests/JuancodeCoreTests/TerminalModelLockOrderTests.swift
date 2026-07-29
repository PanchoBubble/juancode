import Foundation
import Testing
@testable import JuancodeCore

/// Lock ORDER between the process-global SwiftTerm parse lock and a model's own lock
/// (juancode-c438 follow-up).
///
/// Two paths reach a `SessionTerminalModel` from different threads:
///
/// - a session's pty queue feeding it — `feed` takes the model lock, then the global
///   parse lock;
/// - the local pane's GUI feed on the main thread — it holds the global parse lock
///   (`SwiftTermParse.locked { tv.feed(...) }`) and, when SwiftTerm dispatches
///   `sizeChanged` from inside that parse, synchronously calls
///   `session.resizeLocal` → `SessionTerminalModel.resize`, which wants the model lock.
///
/// Opposite acquisition orders on the same two locks is a textbook AB-BA deadlock, and
/// a permanent one: the app hangs with no way out. Both orders must agree.
@Suite struct TerminalModelLockOrderTests {
    /// Reproduces the GUI side exactly: one thread holds the global parse lock and,
    /// still holding it, resizes the model — the `sizeChanged`-mid-parse path, which
    /// happens on that same thread — while a session's feed runs concurrently.
    ///
    /// The scenario runs on a helper thread so the test can time out; a regression
    /// leaves that thread wedged holding the global parse lock, which will hang other
    /// terminal tests too. That is the intended alarm: this deadlock hangs the app.
    @Test func aThreadHoldingTheParseLockCanStillResizeTheModel() {
        let model = SessionTerminalModel(cols: 80, rows: 24, scrollbackLines: 200)
        let feedEntered = DispatchSemaphore(value: 0)
        let scenarioDone = DispatchSemaphore(value: 0)

        Thread.detachNewThread {
            // Plays the local pane feeding its own SwiftTerm view.
            SwiftTermParse.locked {
                // Plays the session's pty queue feeding the headless model.
                Thread.detachNewThread {
                    feedEntered.signal()
                    model.feed(Array("streamed output".utf8))
                }
                feedEntered.wait()
                Thread.sleep(forTimeInterval: 0.05) // let the feed take its first lock
                // SwiftTerm dispatched sizeChanged from inside the parse above.
                model.resize(cols: 100, rows: 30)
            }
            scenarioDone.signal()
        }

        #expect(scenarioDone.wait(timeout: .now() + 2.0) == .success)
        #expect(model.cols == 100)
    }

    /// The same inversion in the other direction: a reader (the activity detector's
    /// screen read) must never be blocked by a parse that is itself waiting on the
    /// global lock held by someone else.
    @Test func aScreenReadIsNotBlockedByAFeedWaitingOnTheParseLock() {
        let model = SessionTerminalModel(cols: 80, rows: 24, scrollbackLines: 200)
        let feedEntered = DispatchSemaphore(value: 0)
        let readDone = DispatchSemaphore(value: 0)

        SwiftTermParse.locked {
            Thread.detachNewThread {
                feedEntered.signal()
                model.feed(Array("more output".utf8))
            }
            feedEntered.wait()
            Thread.sleep(forTimeInterval: 0.05)
            Thread.detachNewThread {
                _ = model.bottomText(20)
                readDone.signal()
            }
            // Times out if the detector's screen read is stuck behind a feed that is
            // itself queued on the parse lock.
            #expect(readDone.wait(timeout: .now() + 2.0) == .success)
        }
    }
}
