import XCTest
import JuancodeCore
@testable import JuancodeServer

/// Thread-safe sink for a pty's bytes, so a test can wait on what the child said
/// without going through the connection it is asserting about.
private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    func append(_ more: [UInt8]) { lock.withLock { bytes += more } }
    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
}

/// The attach redraw (juancode-r5cf): what `ServerMessage.attached` carries is
/// reconstructed from PARSED VT state, not replayed off the retained byte log.
///
/// The thing worth pinning is the failure that motivated it: a byte log only reads
/// correctly at the width it was produced for, and a client is routinely a different
/// width. So every test here checks the redraw through a fresh terminal — parse it
/// back and compare the screen, which is the only question that matters — and the
/// width case checks it against the naive re-parse that garbles.
final class AttachReplayTests: XCTestCase {
    private var dbPath: String!
    private var fakeAgent: String!

    override func setUpWithError() throws {
        dbPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-attach-\(UUID().uuidString).db")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-attach-agent-\(UUID().uuidString).sh")
        try """
        #!/bin/bash
        stty -echo 2>/dev/null
        printf 'ready\\r\\n'
        while IFS= read -r line; do
          case "$line" in
          ECHO*) printf '%s\\r\\n' "${line#ECHO }" ;;
          EXIT*) exit 0 ;;
          esac
        done
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        fakeAgent = url.path
        setenv("JUANCODE_CLAUDE_BIN", url.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JUANCODE_CLAUDE_BIN")
        try? FileManager.default.removeItem(atPath: fakeAgent)
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + s) }
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Wait for the child to have said `text`, from either the live stream or what
    /// already landed before this sink existed.
    private func awaitText(_ session: Session, _ text: String) async {
        let heard = Heard()
        let off = session.subscribeOutput(replay: false) { heard.append($0) }
        defer { off() }
        await waitUntil {
            heard.text.contains(text)
                || session.terminalModel.visibleText().contains(text)
        }
    }

    private static func model(cols: Int = 40, rows: Int = 6, scrollback: Int = 200)
        -> SessionTerminalModel {
        SessionTerminalModel(cols: cols, rows: rows, scrollbackLines: scrollback)
    }

    /// Parse a replay string back through a terminal of the given size — what the
    /// receiving client does with it.
    private static func rendered(_ replay: String, cols: Int, rows: Int) -> SessionTerminalModel {
        let m = model(cols: cols, rows: rows)
        m.feed(Array(replay.utf8))
        return m
    }

    /// A byte log that only reads correctly at 10 columns: the text hard-wraps
    /// there, and the absolute cursor move that follows overwrites the START of the
    /// wrapped continuation. Re-parsed wider, nothing wraps, so the same move lands
    /// on a blank row instead and both lines come out wrong.
    private static let narrowLog = "0123456789ABCDE\u{1b}[2;1HXX"

    // MARK: - the width case

    func testStoredLogIsReplayedAtItsParseWidthNotTheClientS() {
        let log = Array(Self.narrowLog.utf8)

        // The control: what the client does today with a log and no recorded width.
        let naive = SessionTerminalModel.replaying(log, parsedCols: 20, parsedRows: 5)
        XCTAssertTrue(naive.visibleText().contains("ABCDE"),
                      "parsed at the wrong width the overwrite misses: the log is garbled")

        // The fix: replayed at the grid the store recorded, then presented at the
        // client's. The overwrite lands where the CLI meant it to.
        let replay = AttachReplay.stored(log, parsedAt: (cols: 10, rows: 5),
                                         presentedAt: (cols: 20, rows: 5))
        let screen = Self.rendered(replay, cols: 20, rows: 5).visibleText()
        XCTAssertTrue(screen.contains("XXCDE"), "got: \(screen)")
        XCTAssertFalse(screen.contains("ABCDE"), "got: \(screen)")
    }

    func testStoredReplayWithNoRecordedGridFallsBackToTheClientGrid() {
        // No recorded width is the pre-column row: the client's own grid is the only
        // guess available. The point of the assertion is that it still produces a
        // clean redraw rather than throwing the bytes at the client raw.
        let replay = AttachReplay.stored(Array(Self.narrowLog.utf8), parsedAt: nil,
                                         presentedAt: (cols: 20, rows: 5))
        XCTAssertFalse(replay.isEmpty)
        XCTAssertTrue(Self.rendered(replay, cols: 20, rows: 5).visibleText().contains("0123456789"))
    }

    // MARK: - what a byte log carried only by accident

    func testLiveReplayIsTheRenderedScreenNotTheByteStream() {
        let m = Self.model()
        // Written, then overwritten in place: a byte log replays both, the screen
        // only ever showed the second.
        m.feed(Array("first draft\r\n\u{1b}[Awrong      \r\u{1b}[Kright\r\n".utf8))

        let replay = AttachReplay.live(m)
        XCTAssertFalse(replay.contains("wrong"), "the redraw carries the screen, not its history")
        XCTAssertEqual(Self.rendered(replay, cols: 40, rows: 6).visibleText(), "right")
    }

    func testStylesSurviveTheRoundTrip() {
        let m = Self.model()
        // Bold red on a 256-colour background, then a plain run after it.
        m.feed(Array("\u{1b}[1;31;48;5;27mSTYLED\u{1b}[0m plain".utf8))

        let back = Self.rendered(AttachReplay.live(m), cols: 40, rows: 6)
        let row = back.styledVisibleLine(at: 0)
        XCTAssertEqual(row?.text, "STYLED plain")
        let styled = row?.cells.first
        XCTAssertEqual(styled?.fg, .ansi(1))
        XCTAssertEqual(styled?.bg, .ansi(27))
        XCTAssertTrue(styled?.style.contains(.bold) ?? false)
        // The run after the reset is plain again — the redraw does not smear the SGR.
        let plain = row?.cells[7]
        XCTAssertEqual(plain?.char, "p")
        XCTAssertEqual(plain?.fg, .default)
        XCTAssertTrue(plain?.style.isEmpty ?? false)
    }

    func testCursorPositionAndVisibilitySurviveTheRoundTrip() {
        let m = Self.model()
        m.feed(Array("hello\r\nworld\u{1b}[3;7H".utf8))
        XCTAssertEqual(m.cursorPosition.x, 6)
        XCTAssertEqual(m.cursorPosition.y, 2)

        let back = Self.rendered(AttachReplay.live(m), cols: 40, rows: 6)
        XCTAssertEqual(back.cursorPosition.x, 6)
        XCTAssertEqual(back.cursorPosition.y, 2)
        XCTAssertTrue(back.snapshot().cursorVisible)

        // A hidden cursor stays hidden — the mode is state, not decoration.
        m.feed(Array("\u{1b}[?25l".utf8))
        XCTAssertFalse(Self.rendered(AttachReplay.live(m), cols: 40, rows: 6).snapshot().cursorVisible)
    }

    func testWindowTitleSurvivesTheRoundTrip() {
        let m = Self.model()
        m.feed(Array("\u{1b}]2;claude — juancode\u{07}working".utf8))
        XCTAssertEqual(m.terminalTitle, "claude — juancode")

        let back = Self.rendered(AttachReplay.live(m), cols: 40, rows: 6)
        XCTAssertEqual(back.terminalTitle, "claude — juancode")
        XCTAssertEqual(back.visibleText(), "working")
    }

    func testAlternateBufferAndInputModesSurviveTheRoundTrip() {
        let m = Self.model()
        // A TUI's shape: alt screen, mouse reporting, application cursor keys,
        // bracketed paste. A client that misses these encodes input wrong.
        m.feed(Array("\u{1b}[?1049h\u{1b}[?1002h\u{1b}[?1h\u{1b}[?2004hTUI".utf8))

        let back = Self.rendered(AttachReplay.live(m), cols: 40, rows: 6)
        XCTAssertTrue(back.isAlternateBuffer)
        XCTAssertTrue(back.mouseReportingOn)
        XCTAssertTrue(back.applicationCursorKeys)
        XCTAssertTrue(back.bracketedPaste)
        XCTAssertEqual(back.visibleText(), "TUI")
    }

    // MARK: - history

    // MARK: - through the real attach path

    /// What conformance scenario 04 asserts, exercised in-process: a second client
    /// attaching to a LIVE session receives what it missed. The redraw replaces the
    /// byte log, so this is the check that it still carries the content — a client
    /// handed a correct-but-empty screen would be a regression the unit tests above
    /// cannot see.
    func testAttachToALiveSessionCarriesWhatTheClientMissed() async throws {
        let state = try AppState(dbPath: dbPath)
        let session = try state.registry.create(
            provider: .claude, cwd: FileManager.default.temporaryDirectory.path,
            cols: 80, rows: 24)
        defer { session.kill() }
        await awaitText(session, "ready")
        session.write("ECHO attach-marker\r")
        await awaitText(session, "attach-marker")

        let tap = ConnectionTap(state: state)
        await tap.conn.handle(.attach(sessionId: session.id, cols: 80, rows: 24))
        let attached = frames(await tap.drain(), ofType: "attached")
            .first { $0["sessionId"] as? String == session.id }
        let replay = try XCTUnwrap(attached?["scrollback"] as? String)
        XCTAssertTrue(replay.contains("attach-marker"), "got: \(replay)")
    }

    /// The other half, and conformance scenario 11's assertion: a session whose pty
    /// is gone still replays. Nothing is live to read, so this is the stored-log
    /// path — the one the recorded parse grid exists for.
    func testAttachToADeadSessionStillReplaysItsStoredScrollback() async throws {
        let state = try AppState(dbPath: dbPath)
        let session = try state.registry.create(
            provider: .claude, cwd: FileManager.default.temporaryDirectory.path,
            cols: 80, rows: 24)
        let id = session.id
        await awaitText(session, "ready")
        session.write("EXIT\r")
        await waitUntil { state.registry.get(id) == nil }
        XCTAssertNil(state.registry.get(id), "the fake agent never exited")
        XCTAssertNotNil(state.store.getScrollbackGrid(id),
                        "the parse grid is recorded at spawn, so a dead session has one")

        // Attach NARROWER than the session ran at: the width the client asks for is
        // exactly what used to garble a replayed log.
        let tap = ConnectionTap(state: state)
        await tap.conn.handle(.attach(sessionId: id, cols: 40, rows: 12))
        let all = await tap.drain()
        let attached = frames(all, ofType: "attached").first { $0["sessionId"] as? String == id }
        let replay = try XCTUnwrap(attached?["scrollback"] as? String)
        XCTAssertTrue(replay.contains("ready"), "got: \(replay)")
        XCTAssertFalse(frames(all, ofType: "exit").isEmpty, "the exit is re-stated")
    }

    // MARK: - history

    func testScrollbackHistoryRidesAboveTheRepaintedScreen() {
        let m = Self.model(rows: 3)
        for i in 1...8 { m.feed(Array("line \(i)\r\n".utf8)) }
        XCTAssertFalse(m.visibleText().contains("line 1"), "line 1 has scrolled off the grid")

        let back = Self.rendered(AttachReplay.live(m), cols: 40, rows: 3)
        XCTAssertEqual(back.visibleText(), m.visibleText())
        XCTAssertTrue(back.styledScrollbackTail(20).map(\.text).contains("line 1"),
                      "history the model retains reaches the client's scrollback")
    }
}
