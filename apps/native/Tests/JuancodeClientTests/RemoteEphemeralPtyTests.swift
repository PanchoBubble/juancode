import XCTest
@testable import JuancodeClient

/// An ephemeral pane on a remote core is a pty handed out before it exists. These
/// tests are about that gap: what a pane may do inside it, what the daemon's answer
/// does to what was held, and what the pane hears when the answer never comes.
final class RemoteEphemeralPtyTests: XCTestCase {

    /// Frames the coordinator put on the wire, in order.
    private final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [[String: Any]] = []

        var sent: @Sendable ([String: Any]) -> Void {
            { [self] frame in lock.withLock { frames.append(frame) } }
        }

        var all: [[String: Any]] { lock.withLock { frames } }
        var types: [String] { all.map { $0["type"] as? String ?? "?" } }
        func first(_ type: String) -> [String: Any]? { all.first { $0["type"] as? String == type } }
        func ofType(_ type: String) -> [[String: Any]] { all.filter { $0["type"] as? String == type } }
    }

    private func requestId(_ wire: Wire) -> String {
        wire.first("openTerminal")?["requestId"] as? String ?? ""
    }

    // MARK: - The open

    func testOpeningATerminalAsksForOneAndCarriesACorrelatableRequestId() {
        let wire = Wire()
        let ptys = RemoteEphemeralPtys(send: wire.sent)
        let pty = ptys.openTerminal(cwd: "/tmp", cols: 80, rows: 24)

        let frame = wire.first("openTerminal")
        XCTAssertEqual(frame?["cwd"] as? String, "/tmp")
        XCTAssertEqual(frame?["cols"] as? Int, 80)
        XCTAssertEqual(frame?["rows"] as? Int, 24)
        XCTAssertFalse((frame?["requestId"] as? String ?? "").isEmpty)
        // The pane's handle is the client's own id, not the daemon's: the daemon has
        // not named the pty yet, and the pane has one from the first frame.
        XCTAssertFalse(pty.id.isEmpty)
    }

    func testOpeningAnEditorNamesTheFileAndTheDirectoryItIsConfinedTo() {
        let wire = Wire()
        let ptys = RemoteEphemeralPtys(send: wire.sent)
        _ = ptys.openEditor(cwd: "/tmp", file: "a.txt", cols: 100, rows: 30)

        let frame = wire.first("openEditor")
        XCTAssertEqual(frame?["cwd"] as? String, "/tmp")
        XCTAssertEqual(frame?["file"] as? String, "a.txt")
        XCTAssertEqual(frame?["cols"] as? Int, 100)
    }

    // MARK: - The gap before the ack

    /// The whole reason the pty is handed back early: a pane sizes itself and a user
    /// types into it while the shell is still being forked. Nothing may be lost, and
    /// the grid must go out before the bytes — text typed at the wrong width wraps
    /// wrong and never un-wraps.
    func testWhatThePaneDidBeforeTheAckIsFlushedGridFirst() {
        let wire = Wire()
        let ptys = RemoteEphemeralPtys(send: wire.sent)
        let pty = ptys.openTerminal(cwd: "/tmp", cols: 80, rows: 24)

        XCTAssertTrue(pty.resize(cols: 120, rows: 40))
        pty.write("ls\r")
        XCTAssertEqual(wire.types, ["openTerminal"], "nothing addressable exists yet")

        ptys.bindTerminal(requestId: requestId(wire), terminalId: "t1")
        XCTAssertEqual(wire.types, ["openTerminal", "resize", "input"])
        XCTAssertEqual(wire.first("resize")?["sessionId"] as? String, "t1")
        XCTAssertEqual(wire.first("resize")?["cols"] as? Int, 120)
        XCTAssertEqual(wire.first("input")?["data"] as? String, "ls\r")
    }

    func testAfterTheAckInputGoesStraightOutUnderTheDaemonsId() {
        let wire = Wire()
        let ptys = RemoteEphemeralPtys(send: wire.sent)
        let pty = ptys.openTerminal(cwd: "/tmp", cols: 80, rows: 24)
        ptys.bindTerminal(requestId: requestId(wire), terminalId: "t1")

        pty.write("a")
        pty.write("b")
        XCTAssertEqual(wire.ofType("input").compactMap { $0["data"] as? String }, ["a", "b"])
        XCTAssertEqual(wire.ofType("input").compactMap { $0["sessionId"] as? String }, ["t1", "t1"])
    }

    /// A pane closed before the ack still has to close the daemon's pty — otherwise
    /// the shell is a child nobody is reading, alive until the socket goes.
    func testAKillThatBeatsTheAckIsSentWhenTheIdLands() {
        let wire = Wire()
        let ptys = RemoteEphemeralPtys(send: wire.sent)
        let pty = ptys.openTerminal(cwd: "/tmp", cols: 80, rows: 24)

        pty.kill()
        XCTAssertEqual(wire.types, ["openTerminal"])

        ptys.bindTerminal(requestId: requestId(wire), terminalId: "t1")
        XCTAssertEqual(wire.first("kill")?["sessionId"] as? String, "t1")
    }

    // MARK: - Correlation

    /// The whole reason `terminalReady` carries a requestId. Two opens in flight,
    /// answered in the other order: each pane must get its own pty, and arrival order
    /// would have given them each other's.
    func testTwoOpensInFlightAreCorrelatedOnTheRequestIdNotOnArrivalOrder() {
        let wire = Wire()
        let ptys = RemoteEphemeralPtys(send: wire.sent)
        let first = ptys.openTerminal(cwd: "/a", cols: 80, rows: 24)
        let second = ptys.openTerminal(cwd: "/b", cols: 80, rows: 24)
        let ids = wire.ofType("openTerminal").compactMap { $0["requestId"] as? String }
        XCTAssertEqual(ids.count, 2)

        ptys.bindTerminal(requestId: ids[1], terminalId: "second")
        ptys.bindTerminal(requestId: ids[0], terminalId: "first")

        second.write("2")
        first.write("1")
        let routed = wire.ofType("input").map {
            ($0["sessionId"] as? String ?? "", $0["data"] as? String ?? "")
        }
        XCTAssertEqual(routed.map(\.0), ["second", "first"])
        XCTAssertEqual(routed.map(\.1), ["2", "1"])
    }

    // MARK: - Bytes back

    func testOutputAndExitAreRoutedByTheDaemonsIdAndOnlyToThatPane() {
        let wire = Wire()
        let ptys = RemoteEphemeralPtys(send: wire.sent)
        let pty = ptys.openTerminal(cwd: "/tmp", cols: 80, rows: 24)
        ptys.bindTerminal(requestId: requestId(wire), terminalId: "t1")

        let seen = Box<String>()
        pty.onOutput(replay: false) { seen.add(String(decoding: $0, as: UTF8.self)) }
        let exits = Box<Int>()
        pty.onExit { exits.add($0 ?? -1) }

        XCTAssertTrue(ptys.output("t1", bytes: Array("hello".utf8)))
        XCTAssertFalse(ptys.output("nobody", bytes: Array("x".utf8)),
                       "an id this client never opened is not ours to route")
        XCTAssertEqual(seen.all, ["hello"])

        XCTAssertTrue(ptys.exited("t1", code: 0))
        XCTAssertEqual(exits.all, [0])
        // The id is gone with the pane: a second exit for it is somebody else's frame.
        XCTAssertFalse(ptys.exited("t1", code: 0))
        XCTAssertEqual(exits.all, [0])
    }

    /// A dead pty's id names nothing in the daemon, and `input` for an unknown id is
    /// how a keystroke ends up wherever that id gets reused.
    func testWritingToAnExitedPaneSendsNothing() {
        let wire = Wire()
        let ptys = RemoteEphemeralPtys(send: wire.sent)
        let pty = ptys.openTerminal(cwd: "/tmp", cols: 80, rows: 24)
        ptys.bindTerminal(requestId: requestId(wire), terminalId: "t1")
        XCTAssertTrue(ptys.exited("t1", code: 0))

        pty.write("ls\r")
        XCTAssertTrue(wire.ofType("input").isEmpty)
    }

    // MARK: - Opens that do not land

    func testARefusedOpenEndsThePaneRatherThanLeavingItLookingLive() {
        let wire = Wire()
        let ptys = RemoteEphemeralPtys(send: wire.sent)
        let pty = ptys.openTerminal(cwd: "/nope", cols: 80, rows: 24)
        let exits = Box<Int>()
        pty.onExit { exits.add($0 ?? -1) }

        ptys.failOldestTerminal(reason: "Failed to open terminal: no such directory")
        XCTAssertEqual(exits.all, [-1])

        // And the pane is no longer a candidate for a later ack.
        ptys.bindTerminal(requestId: requestId(wire), terminalId: "t1")
        pty.write("x")
        XCTAssertTrue(wire.ofType("input").isEmpty)
    }

    /// The daemon's ephemeral ptys belong to the connection. A pane that outlived the
    /// socket is painting a shell that will never answer again.
    func testEveryPaneEndsWithTheConnectionWhetherOrNotItWasAcked() {
        let wire = Wire()
        let ptys = RemoteEphemeralPtys(send: wire.sent)
        let acked = ptys.openTerminal(cwd: "/a", cols: 80, rows: 24)
        ptys.bindTerminal(requestId: requestId(wire), terminalId: "t1")
        let pending = ptys.openTerminal(cwd: "/b", cols: 80, rows: 24)
        let editor = ptys.openEditor(cwd: "/a", file: "a.txt", cols: 80, rows: 24)

        let ended = Box<String>()
        acked.onExit { _ in ended.add("acked") }
        pending.onExit { _ in ended.add("pending") }
        editor.onExit { _ in ended.add("editor") }

        ptys.closeAll(reason: "socket closed")
        XCTAssertEqual(Set(ended.all), ["acked", "pending", "editor"])
        // And nothing of theirs is routed afterwards.
        XCTAssertFalse(ptys.output("t1", bytes: Array("x".utf8)))
    }

    func testAnEditorBindsInArrivalOrderSinceItsReadyFrameCarriesNoRequestId() {
        let wire = Wire()
        let ptys = RemoteEphemeralPtys(send: wire.sent)
        let pty = ptys.openEditor(cwd: "/tmp", file: "a.txt", cols: 80, rows: 24)

        ptys.bindEditor(editorId: "e1")
        pty.write(":q\r")
        XCTAssertEqual(wire.first("input")?["sessionId"] as? String, "e1")
    }
}

/// A thread-safe collector, since a pty's listeners fire on whatever thread fed it.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}
