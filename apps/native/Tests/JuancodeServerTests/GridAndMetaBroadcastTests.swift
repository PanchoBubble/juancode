import XCTest
import JuancodeCore
@testable import JuancodeServer

/// The two broadcasts a remote core needs and protocol v1 did not have: a session's
/// meta only ever arrived on `created`/`attached`, and nothing said who owned the
/// shared grid or that it had been released (`resizeAck` reaches only the client
/// that asked). Both are fan-outs, so what is worth pinning is that they reach a
/// SECOND connection, not just the one that acted.
final class GridAndMetaBroadcastTests: XCTestCase {
    private var dbPath: String!
    private var fakeAgent: String!

    override func setUpWithError() throws {
        dbPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-broadcast-\(UUID().uuidString).db")
        // A pty that stays alive and needs no real CLI. `TITLE <text>` makes it set
        // an OSC 2 window title, the way a real CLI names its own session.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-fake-agent-\(UUID().uuidString).sh")
        let script = """
        #!/bin/bash
        stty -echo 2>/dev/null
        printf 'ready\\n'
        while IFS= read -r line; do
          case "$line" in
          TITLE*) printf '\\033]2;%s\\007' "${line#TITLE }" ;;
          esac
        done
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        fakeAgent = url.path
        setenv("JUANCODE_CLAUDE_BIN", url.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JUANCODE_CLAUDE_BIN")
        try? FileManager.default.removeItem(atPath: fakeAgent)
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + s) }
    }

    /// One connection under test: the live object, plus a drain of everything it put
    /// on the wire. Built through `openConnection` so the handshake and the fan-out
    /// start in the same order the real socket does.
    private final class Tap {
        let conn: WebSocketConnection
        private let stream: AsyncStream<ServerMessage>
        private let cont: AsyncStream<ServerMessage>.Continuation

        init(state: AppState) {
            let (stream, cont) = AsyncStream<ServerMessage>.makeStream()
            self.stream = stream
            self.cont = cont
            conn = JuancodeServer.openConnection(state: state, gate: WSSendGate(cont: cont))
        }

        /// Close the connection and collect every frame it sent, as JSON objects.
        /// Closing is part of the contract under test: it releases the grids this
        /// client owned, which is the only way a release edge ever happens.
        func drain() async -> [[String: Any]] {
            conn.stopOutput()
            conn.close()
            cont.finish()
            var out: [[String: Any]] = []
            for await msg in stream {
                if let obj = try? JSONSerialization.jsonObject(
                    with: Data(msg.jsonString().utf8)) as? [String: Any] {
                    out.append(obj)
                }
            }
            return out
        }
    }

    private func liveSession(_ state: AppState) throws -> Session {
        try state.registry.create(provider: .claude,
                                  cwd: FileManager.default.temporaryDirectory.path,
                                  cols: 80, rows: 24)
    }

    private func frames(_ all: [[String: Any]], ofType type: String) -> [[String: Any]] {
        all.filter { ($0["type"] as? String) == type }
    }

    // MARK: - sessionMeta

    func testEveryMetaEditReachesASecondConnection() async throws {
        // Rename, archive flip and dormant flip all funnel through
        // `Session.persistMeta`, so one listener covers every edge rather than each
        // caller having to remember to broadcast.
        let state = try AppState(dbPath: dbPath)
        let session = try liveSession(state)
        defer { session.kill() }
        let a = Tap(state: state)
        let b = Tap(state: state)

        session.setTitle("renamed by hand")
        session.setArchived(true)
        session.markDormant()

        for (label, tap) in [("acting", a), ("observing", b)] {
            let metas = frames(await tap.drain(), ofType: "sessionMeta")
                .compactMap { $0["session"] as? [String: Any] }
            XCTAssertTrue(metas.contains { $0["title"] as? String == "renamed by hand" },
                          "\(label) connection missed the rename")
            XCTAssertTrue(metas.contains { $0["archived"] as? Bool == true },
                          "\(label) connection missed the archive flip")
            XCTAssertTrue(metas.contains { $0["dormant"] as? Bool == true },
                          "\(label) connection missed the dormant flip")
        }
    }

    func testSessionMetaCarriesTheSessionIdAndTheWholeRow() async throws {
        let state = try AppState(dbPath: dbPath)
        let session = try liveSession(state)
        defer { session.kill() }
        let tap = Tap(state: state)

        session.setTitle("whole row")

        let meta = frames(await tap.drain(), ofType: "sessionMeta").first
        XCTAssertEqual(meta?["sessionId"] as? String, session.id)
        let row = meta?["session"] as? [String: Any]
        // Replace-wholesale is the contract, so the frame has to be a complete row.
        XCTAssertEqual(row?["id"] as? String, session.id)
        XCTAssertEqual(row?["title"] as? String, "whole row")
        XCTAssertEqual(row?["provider"] as? String, "claude")
        XCTAssertNotNil(row?["status"])
        XCTAssertNotNil(row?["createdAt"])
    }

    func testCliWindowTitleReachesTheMetaFrame() async throws {
        // The title a client actually cares about is the one the CLI derives for
        // itself. Nothing calls a setter for it: an OSC 0/2 window title is parsed
        // out of the pty stream and adopted, so this is the only path that proves
        // the frame fires without a caller asking it to.
        let state = try AppState(dbPath: dbPath)
        let session = try liveSession(state)
        defer { session.kill() }
        let tap = Tap(state: state)

        session.write("TITLE osc-derived-title\r")
        let deadline = Date().addingTimeInterval(10)
        while session.meta.title != "osc-derived-title", Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(session.meta.title, "osc-derived-title",
                       "the pty never echoed the OSC title back into the model")

        let titles = frames(await tap.drain(), ofType: "sessionMeta")
            .compactMap { ($0["session"] as? [String: Any])?["title"] as? String }
        XCTAssertTrue(titles.contains("osc-derived-title"), "got titles: \(titles)")
    }

    // MARK: - gridChange

    func testGrantAndReleaseBothReachASecondConnection() async throws {
        let state = try AppState(dbPath: dbPath)
        let session = try liveSession(state)
        defer { session.kill() }
        let a = Tap(state: state)
        let b = Tap(state: state)
        let ownerId = a.conn.clientId

        await a.conn.handle(.resize(sessionId: session.id, cols: 100, rows: 30, seq: 1))

        // Draining `a` closes it, which releases the grid it just claimed — so `b`
        // sees the grant and then the release.
        let ackOwner = frames(await a.drain(), ofType: "resizeAck").first?["owner"] as? String
        XCTAssertEqual(ackOwner, ownerId, "the ack must name the owner, not just applied/denied")

        let changes = frames(await b.drain(), ofType: "gridChange")
        XCTAssertEqual(changes.count, 2, "expected a grant and a release, got \(changes)")
        XCTAssertEqual(changes.first?["owner"] as? String, ownerId)
        XCTAssertEqual(changes.first?["cols"] as? Int, 100)
        XCTAssertEqual(changes.first?["rows"] as? Int, 30)
        XCTAssertTrue(changes.last?["owner"] is NSNull,
                      "a release is a null owner, so the observer can fold its badge away")
    }

    func testAConnectionOpeningOnAnOwnedGridIsToldWhoOwnsIt() async throws {
        // Without the snapshot a client that arrives after the grant assumes the grid
        // is free until the owner happens to resize again, and renders a pane as
        // editable that it cannot actually drive.
        let state = try AppState(dbPath: dbPath)
        let session = try liveSession(state)
        defer { session.kill() }
        let a = Tap(state: state)
        await a.conn.handle(.resize(sessionId: session.id, cols: 110, rows: 32, seq: 1))

        let late = Tap(state: state)
        let snapshot = frames(await late.drain(), ofType: "gridChange").first
        XCTAssertEqual(snapshot?["owner"] as? String, a.conn.clientId)
        XCTAssertEqual(snapshot?["cols"] as? Int, 110)
        _ = await a.drain()
    }

    func testAnUnclaimedGridIsNotAnnouncedOnConnect() async throws {
        // Silence already means "nobody is driving": a client starts there, so a
        // null-owner snapshot per session would be noise on every connect.
        let state = try AppState(dbPath: dbPath)
        let session = try liveSession(state)
        defer { session.kill() }
        let tap = Tap(state: state)
        let sent = frames(await tap.drain(), ofType: "gridChange")
        XCTAssertTrue(sent.isEmpty, "got \(sent)")
    }

    func testADeniedResizeAckNamesTheClientToWaitFor() async throws {
        let state = try AppState(dbPath: dbPath)
        let session = try liveSession(state)
        defer { session.kill() }
        let a = Tap(state: state)
        let b = Tap(state: state)
        await a.conn.handle(.resize(sessionId: session.id, cols: 100, rows: 30, seq: 1))
        await b.conn.handle(.resize(sessionId: session.id, cols: 70, rows: 20, seq: 9))

        let ack = frames(await b.drain(), ofType: "resizeAck").first
        XCTAssertEqual(ack?["denied"] as? Bool, true)
        XCTAssertEqual(ack?["applied"] as? Bool, false)
        XCTAssertEqual(ack?["owner"] as? String, a.conn.clientId)
        _ = await a.drain()
    }

    func testHandshakeCarriesTheConnectionsOwnGridToken() async throws {
        // The handshake is the only place a client can learn its own ownership
        // token, and without it a `gridChange` owner is unreadable: the client can
        // see that somebody drives the grid but not whether that somebody is itself.
        let state = try AppState(dbPath: dbPath)
        let tap = Tap(state: state)
        let expected = tap.conn.clientId
        let handshake = await tap.drain().first
        XCTAssertEqual(handshake?["type"] as? String, "serverInfo")
        XCTAssertEqual(handshake?["clientId"] as? String, expected)
    }
}
