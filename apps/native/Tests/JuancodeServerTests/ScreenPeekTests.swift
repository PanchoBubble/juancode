import XCTest
import Hummingbird
import HummingbirdTesting
import NIOCore
import JuancodeCore
import JuancodePersistence
@testable import JuancodeServer

/// The one-shot rendered-screen read (juancode-tyd9): `GET /api/sessions/:id/screen`.
///
/// What is worth pinning is that this is NOT a byte log — it is the parsed grid, at the
/// width it was parsed at — and that its encoding is the stream's, so a client that can
/// decode a `screen` frame can decode a snapshot with the same code.
final class ScreenPeekTests: XCTestCase {
    private var dbPath: String!
    private var fakeAgent: String!

    override func setUpWithError() throws {
        dbPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-peek-\(UUID().uuidString).db")
        // A pty that stays up and needs no real CLI, so a session can be live while the
        // screen under test is fed deterministically through the model.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-peek-agent-\(UUID().uuidString).sh")
        try "#!/bin/bash\nstty -echo 2>/dev/null\nwhile IFS= read -r _; do :; done\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        fakeAgent = url.path
        setenv("JUANCODE_CLAUDE_BIN", url.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JUANCODE_CLAUDE_BIN")
        try? FileManager.default.removeItem(atPath: fakeAgent)
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + s) }
    }

    private static func model(cols: Int = 20, rows: Int = 4, scrollback: Int = 100)
        -> SessionTerminalModel {
        SessionTerminalModel(cols: cols, rows: rows, scrollbackLines: scrollback)
    }

    private static func feed(_ model: SessionTerminalModel, _ text: String) {
        model.feed(Array(text.utf8))
    }

    private static func json(_ res: TestResponse) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
    }

    private static func body(_ res: TestResponse) -> String {
        String(decoding: Data(res.body.readableBytesView), as: UTF8.self)
    }

    // MARK: - the projection itself

    func testSnapshotIsTheRedrawnScreenNotTheByteStream() {
        let model = Self.model()
        // A line written, then overwritten in place: a byte log replays both, the
        // rendered screen only ever shows the second.
        Self.feed(model, "first draft\r\n\u{1b}[Awrong      \r\u{1b}[Kright\r\n")
        let peek = ScreenPeek(model: model, scrollbackRows: 0)
        XCTAssertEqual(peek.text, "right")
        XCTAssertEqual(peek.snapshot.cols, 20)
        XCTAssertEqual(peek.snapshot.rows, 4)
        XCTAssertTrue(peek.history.isEmpty, "no history unless it was asked for")
    }

    func testScrollbackFlagPrependsHistoryAtNegativeRowIndices() {
        let model = Self.model(rows: 3)
        for i in 1...6 { Self.feed(model, "line \(i)\r\n") }

        let plain = ScreenPeek(model: model, scrollbackRows: 0)
        XCTAssertFalse(plain.text.contains("line 1"), "line 1 has scrolled off the grid")

        let withHistory = ScreenPeek(model: model, scrollbackRows: 100)
        XCTAssertTrue(withHistory.text.contains("line 1"))
        XCTAssertTrue(withHistory.text.hasSuffix(plain.text),
                      "history sits ABOVE the same visible screen")
        // History rows keep the visible grid at the indices the stream uses.
        let historyRows = withHistory.lines.filter { $0.row < 0 }
        XCTAssertEqual(historyRows.count, withHistory.history.count)
        XCTAssertEqual(historyRows.map(\.row), Array(-withHistory.history.count ... -1))
        XCTAssertEqual(withHistory.lines.filter { $0.row >= 0 }.map(\.row), [0, 1, 2])
    }

    func testScrollbackQueryReadsAsAFlagAndAsACount() {
        XCTAssertEqual(ScreenPeek.scrollbackRows(nil), 0)
        XCTAssertEqual(ScreenPeek.scrollbackRows("0"), 0)
        XCTAssertEqual(ScreenPeek.scrollbackRows("false"), 0)
        XCTAssertEqual(ScreenPeek.scrollbackRows(""),
                       SessionTerminalModel.defaultSeedScrollbackRows)
        XCTAssertEqual(ScreenPeek.scrollbackRows("1"),
                       SessionTerminalModel.defaultSeedScrollbackRows)
        XCTAssertEqual(ScreenPeek.scrollbackRows("40"), 40)
        XCTAssertEqual(ScreenPeek.scrollbackRows("99999", cap: 5000), 5000)
        XCTAssertFalse(ScreenPeek.flag(nil))
        XCTAssertFalse(ScreenPeek.flag("0"))
        XCTAssertTrue(ScreenPeek.flag(""))
        XCTAssertTrue(ScreenPeek.flag("1"))
    }

    /// The parity that makes one client decoder enough: the snapshot's visible rows are
    /// byte-for-byte the rows a `reset: true` screen frame carries for the same model.
    func testVisibleRowsEncodeExactlyLikeASubscribeScreenFrame() throws {
        let model = Self.model()
        Self.feed(model, "\u{1b}[31mred\u{1b}[0m plain\r\nsecond\r\n")

        final class Sink: @unchecked Sendable {
            private let lock = NSLock()
            private var _frames: [ServerMessage] = []
            var frames: [ServerMessage] { lock.withLock { _frames } }
            func send(_ m: ServerMessage) { lock.withLock { _frames.append(m) } }
        }
        let sink = Sink()
        let streamer = ScreenStreamer(sessionId: "s-1", model: model, autoFlush: false,
                                      isBackedUp: { false }, send: { [sink] in sink.send($0) })
        streamer.start()
        streamer.stop()

        guard case let .screen(_, reset, cols, rows, cx, cy, visible, alt, streamed)
            = sink.frames.first else { return XCTFail("no screen frame") }
        XCTAssertTrue(reset)

        let peek = ScreenPeek(model: model, scrollbackRows: 0)
        XCTAssertEqual(peek.lines, streamed, "snapshot rows == stream rows, segment for segment")
        XCTAssertEqual(peek.snapshot.cols, cols)
        XCTAssertEqual(peek.snapshot.rows, rows)
        XCTAssertEqual(peek.snapshot.cursorX, cx)
        XCTAssertEqual(peek.snapshot.cursorY, cy)
        XCTAssertEqual(peek.snapshot.cursorVisible, visible)
        XCTAssertEqual(peek.snapshot.isAlternateBuffer, alt)

        // And on the wire, not just in memory: the same JSON for the same rows.
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let fromPeek = try enc.encode(peek.lines)
        let fromFrame = try enc.encode(streamed)
        XCTAssertEqual(String(decoding: fromPeek, as: UTF8.self),
                       String(decoding: fromFrame, as: UTF8.self))
    }

    // MARK: - the route

    private func withServer(
        _ body: @escaping @Sendable (any TestClientProtocol, AppState) async throws -> Void
    ) async throws {
        let state = try AppState(dbPath: dbPath)
        let app = Application(router: JuancodeServer.buildRouter(state: state, webDist: nil))
        try await app.test(.router) { client in try await body(client, state) }
    }

    private static func exitedMeta(_ id: String) -> SessionMeta {
        SessionMeta(id: id, provider: .claude, cwd: "/tmp", title: "t", status: .exited,
                    exitCode: 0, createdAt: nowMs(), updatedAt: nowMs(), cliSessionId: nil,
                    skipPermissions: false, worktreePath: nil, usage: nil)
    }

    func testUnknownSessionIs404AndAReapedOneIs409() async throws {
        try await withServer { client, state in
            try await client.execute(uri: "/api/sessions/nope/screen", method: .get) { res in
                XCTAssertEqual(res.status, .notFound)
                XCTAssertEqual(Self.json(res)?["error"] as? String, "not found")
            }
            // A row that outlived its pty: the model died with the process, so there is
            // no last-known grid to hand back — say so rather than answer an empty one.
            state.store.insert(Self.exitedMeta("s-dead"))
            try await client.execute(uri: "/api/sessions/s-dead/screen", method: .get) { res in
                XCTAssertEqual(res.status, .conflict)
                XCTAssertTrue((Self.json(res)?["error"] as? String ?? "").contains("not running"))
            }
        }
    }

    func testLiveSessionServesTextAndJsonFromItsModel() async throws {
        try await withServer { client, state in
            let session = try state.registry.create(
                provider: .claude, cwd: FileManager.default.temporaryDirectory.path,
                cols: 40, rows: 6)
            defer { session.kill() }
            // Fed through the model directly so the assertion doesn't race the pty.
            session.terminalModel.feed(Array("\u{1b}[2J\u{1b}[Hhello from the grid\r\n".utf8))

            try await client.execute(uri: "/api/sessions/\(session.id)/screen", method: .get) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.headers[.contentType], "text/plain; charset=utf-8")
                XCTAssertTrue(Self.body(res).contains("hello from the grid"), Self.body(res))
            }
            try await client.execute(uri: "/api/sessions/\(session.id)/screen?json=1", method: .get) { res in
                XCTAssertEqual(res.status, .ok)
                let obj = Self.json(res)
                XCTAssertEqual(obj?["sessionId"] as? String, session.id)
                XCTAssertEqual(obj?["cols"] as? Int, 40)
                XCTAssertEqual(obj?["rows"] as? Int, 6)
                XCTAssertEqual(obj?["scrollback"] as? Int, 0)
                XCTAssertNotNil((obj?["cursor"] as? [String: Any])?["x"])
                let lines = obj?["lines"] as? [[String: Any]]
                XCTAssertEqual(lines?.count, 6, "every visible row, blank ones included")
                let texts = lines?.flatMap { ($0["segs"] as? [[String: Any]] ?? []) }
                    .compactMap { $0["text"] as? String }
                XCTAssertTrue((texts ?? []).joined().contains("hello from the grid"))
            }
        }
    }
}
