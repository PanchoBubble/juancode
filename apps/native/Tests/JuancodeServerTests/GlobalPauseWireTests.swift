import XCTest
import JuancodeCore
import JuancodePersistence
@testable import JuancodeServer

/// The `/ws` half of a global pause (juancode-tnxx): the frames, the set they
/// publish, and who they run through.
///
/// The ptys are not spawned here — a scenario in `apps/wire-conformance` measures
/// the real sleep-and-wake against a booted core. What this suite pins down is the
/// part a golden transcript cannot see: that both surfaces reach ONE book, and that
/// the frames go through whichever driver is installed rather than a second
/// implementation of the pause rule living in the WS layer.
final class GlobalPauseWireTests: XCTestCase {

    /// A driver that records what it was asked, standing in for the desktop's.
    private final class SpyDriver: GlobalPauseDriver, @unchecked Sendable {
        let book: GlobalPauseBook
        var pauses = 0
        var resumes = 0
        var sleeps: [String] = []

        init(book: GlobalPauseBook, sleeps: [String] = []) {
            self.book = book
            self.sleeps = sleeps
        }

        @discardableResult
        func pauseAll() async -> Int {
            pauses += 1
            book.record(sleeps)
            return sleeps.count
        }

        func resumeAll() async {
            resumes += 1
            book.take()
        }
    }

    /// Its own paused set per test: the real one is a file beside the core's rows,
    /// and a suite that shared it would measure the previous test's pause.
    private func makeState() throws -> AppState {
        AppState(store: try GRDBStore(inMemory: true), globalPauseStorage: .memory())
    }

    // MARK: - The book

    func testTheSetIsAUnionSoASecondPauseKeepsTheFirstOnesAsleep() {
        let book = GlobalPauseBook(storage: .memory())
        book.record(["a", "b"])
        book.record(["b", "c"])
        XCTAssertEqual(book.paused, ["a", "b", "c"])
    }

    func testTakeReadsAndClearsInOneStep() {
        let book = GlobalPauseBook(storage: .memory())
        book.record(["a", "b"])
        XCTAssertEqual(book.take(), ["a", "b"])
        XCTAssertTrue(book.paused.isEmpty)
        XCTAssertFalse(book.isPaused)
    }

    func testTakeOnAnEmptyBookNotifiesNobody() {
        let book = GlobalPauseBook(storage: .memory())
        let fired = Counter()
        book.onChange { _ in fired.bump() }
        _ = book.take()
        XCTAssertEqual(fired.value, 0, "a play with nothing paused is not a state change")
    }

    func testTheSetSurvivesANewBookOverTheSameStorage() {
        let storage = GlobalPauseBook.Storage.memory()
        GlobalPauseBook(storage: storage).record(["a"])
        // Quitting while paused is half of why anyone pauses: the next launch has to
        // still know what a play would revive.
        XCTAssertEqual(GlobalPauseBook(storage: storage).paused, ["a"])
    }

    // MARK: - The frames

    func testANewConnectionIsToldTheSetBeforeAnythingElseCanChangeIt() async throws {
        let state = try makeState()
        state.globalPause.record(["already-asleep"])
        let tap = ConnectionTap(state: state)
        let sent = await tap.drain()
        let states = frames(sent, ofType: "pauseState")
        XCTAssertEqual(states.first?["paused"] as? [String], ["already-asleep"],
                       "a client that connects mid-pause must start from the truth")
    }

    func testPauseAllRunsThroughTheInstalledDriverAndPublishesTheSet() async throws {
        let state = try makeState()
        let spy = SpyDriver(book: state.globalPause, sleeps: ["s1", "s2"])
        state.globalPause.driver = spy
        let tap = ConnectionTap(state: state)

        await tap.conn.handle(.pauseAll)

        XCTAssertEqual(spy.pauses, 1)
        XCTAssertEqual(state.globalPause.paused, ["s1", "s2"])
        let sent = await tap.drain()
        XCTAssertEqual(frames(sent, ofType: "pauseState").last?["paused"] as? [String], ["s1", "s2"])
    }

    func testResumeAllRunsThroughTheDriverAndPublishesTheClearedSet() async throws {
        let state = try makeState()
        let spy = SpyDriver(book: state.globalPause)
        state.globalPause.driver = spy
        state.globalPause.record(["s1"])
        let tap = ConnectionTap(state: state)

        await tap.conn.handle(.resumeAll)

        XCTAssertEqual(spy.resumes, 1)
        let sent = await tap.drain()
        XCTAssertEqual(frames(sent, ofType: "pauseState").last?["paused"] as? [String], [],
                       "the button stops reading paused the moment the play starts")
    }

    /// The acceptance criterion, as a test: a pause taken on one connection is the
    /// set the other one sees, because there is one book and not two tallies.
    func testAPauseOnOneConnectionReachesEveryOther() async throws {
        let state = try makeState()
        state.globalPause.driver = SpyDriver(book: state.globalPause, sleeps: ["s1"])
        let phone = ConnectionTap(state: state)
        let desktop = ConnectionTap(state: state)

        await phone.conn.handle(.pauseAll)

        let seenByDesktop = await desktop.drain()
        XCTAssertEqual(frames(seenByDesktop, ofType: "pauseState").last?["paused"] as? [String], ["s1"])
        _ = await phone.drain()
    }

    func testAPauseWithNoDriverChangesNothingRatherThanHalfHappening() async throws {
        let state = try makeState()
        state.globalPause.driver = nil
        let tap = ConnectionTap(state: state)
        await tap.conn.handle(.pauseAll)
        XCTAssertTrue(state.globalPause.paused.isEmpty)
        _ = await tap.drain()
    }

    // MARK: - The capability

    func testTheCapabilityIsAdvertisedNowThatTheFramesAreServed() {
        XCTAssertTrue(WireProtocol.capabilities.contains("globalPause"))
    }

    func testPauseStateSortsItsIdsSoTwoClientsCannotRenderTwoOrders() {
        let json = ServerMessage.pauseState(paused: ["c", "a", "b"]).jsonString()
        XCTAssertTrue(json.contains(#""paused":["a","b","c"]"#), json)
    }
}


/// A count a `@Sendable` listener may increment.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
