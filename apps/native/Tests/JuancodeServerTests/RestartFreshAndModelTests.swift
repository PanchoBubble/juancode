import XCTest
import JuancodeCore
@testable import JuancodeServer

/// The two desktop affordances protocol v1 could not express: restarting an exited
/// session as a brand-new conversation under the same id, and pinning the model a
/// spawn runs on. Both are driven through the real `handle` path, because what is
/// worth pinning is the frame's effect on the registry, not the decoder.
/// Thread-safe sink for a pty's bytes, so a test can wait on what the pty said
/// without going through the connection it is asserting about.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    func append(_ more: [UInt8]) { lock.withLock { bytes += more } }
    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
}

final class RestartFreshAndModelTests: XCTestCase {
    private var dbPath: String!
    private var fakeAgent: String!

    override func setUpWithError() throws {
        dbPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-restart-\(UUID().uuidString).db")
        // Echoes its own argv on demand, so a test can see which flags the spawn
        // actually used, and exits on command so a session can be brought to the
        // exited state a restart needs.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-fake-agent-\(UUID().uuidString).sh")
        let script = """
        #!/bin/bash
        stty -echo 2>/dev/null
        ARGV="$*"
        printf 'ready\\r\\n'
        while IFS= read -r line; do
          case "$line" in
          ARGS*) printf 'argv: %s\\r\\n' "$ARGV" ;;
          ECHO*) printf '%s\\r\\n' "${line#ECHO }" ;;
          EXIT*) exit 0 ;;
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

    private func waitUntil(_ timeout: TimeInterval = 10,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Wait for the fixture's banner. A command written before the script reaches
    /// its read loop is simply lost, which reads as a mysterious hang later.
    private func awaitReady(_ session: Session) async {
        let heard = Collected()
        let off = session.subscribeOutput(replay: false) { heard.append($0) }
        defer { off() }
        // Either the banner arrives now, or it already landed in scrollback before
        // this sink existed.
        await waitUntil {
            heard.text.contains("ready")
                || String(decoding: session.getScrollback(), as: UTF8.self).contains("ready")
        }
    }

    /// A session that has exited, with its row persisted, which is the only state a
    /// restart is defined for.
    private func exitedSession(_ state: AppState) async throws -> SessionMeta {
        let session = try state.registry.create(provider: .claude,
                                                cwd: FileManager.default.temporaryDirectory.path,
                                                cols: 80, rows: 24)
        let meta = session.meta
        await awaitReady(session)
        session.write("EXIT\r")
        await waitUntil { state.registry.get(meta.id) == nil }
        XCTAssertNil(state.registry.get(meta.id), "the fake agent never exited")
        return meta
    }

    // MARK: - restartFresh

    func testRestartFreshBringsTheSessionBackUnderTheSameIdWithANewConversation() async throws {
        let state = try AppState(dbPath: dbPath)
        let dead = try await exitedSession(state)
        XCTAssertNotNil(dead.cliSessionId, "claude pins its conversation id at spawn")
        let tap = ConnectionTap(state: state)

        await tap.conn.handle(.restartFresh(sessionId: dead.id, cols: 100, rows: 30))
        defer { state.registry.get(dead.id)?.kill() }

        let attached = frames(await tap.drain(), ofType: "attached")
            .first { $0["sessionId"] as? String == dead.id }
        let row = try XCTUnwrap(attached?["session"] as? [String: Any],
                                "a restart must answer `attached`, like a reactivate")
        XCTAssertEqual(row["id"] as? String, dead.id, "the juancode id and its pane survive")
        XCTAssertEqual(row["status"] as? String, "running")
        // The whole point of the frame: a NEW conversation, not the old one resumed.
        XCTAssertNotEqual(row["cliSessionId"] as? String, dead.cliSessionId)
    }

    func testRestartFreshStartsTheCliInsteadOfResumingIt() async throws {
        let state = try AppState(dbPath: dbPath)
        let dead = try await exitedSession(state)
        let tap = ConnectionTap(state: state)

        await tap.conn.handle(.restartFresh(sessionId: dead.id, cols: 80, rows: 24))
        let live = try XCTUnwrap(state.registry.get(dead.id), "the restart never spawned a pty")
        defer { live.kill() }
        await awaitReady(live)
        live.write("ARGS\r")
        await waitUntil { String(decoding: live.getScrollback(), as: UTF8.self).contains("argv:") }

        let argv = String(decoding: live.getScrollback(), as: UTF8.self)
        XCTAssertTrue(argv.contains("--session-id"), argv)
        XCTAssertFalse(argv.contains("--resume"), "a fresh restart must not resume: \(argv)")
    }

    func testRestartFreshOnALiveSessionIsRefusedRatherThanHonoured() async throws {
        // Restarting throws the running conversation away. A client that believes
        // the session is dead is told otherwise instead of losing it.
        let state = try AppState(dbPath: dbPath)
        let session = try state.registry.create(provider: .claude,
                                                cwd: FileManager.default.temporaryDirectory.path,
                                                cols: 80, rows: 24)
        defer { session.kill() }
        let tap = ConnectionTap(state: state)

        await tap.conn.handle(.restartFresh(sessionId: session.id, cols: 80, rows: 24))

        let all = await tap.drain()
        let error = frames(all, ofType: "error").first
        XCTAssertEqual(error?["sessionId"] as? String, session.id)
        XCTAssertTrue((error?["message"] as? String ?? "").contains("still running"),
                      "got: \(String(describing: error))")
        XCTAssertTrue(frames(all, ofType: "attached").isEmpty, "nothing was restarted")
    }

    func testRestartFreshForAnUnknownSessionAnswersAnError() async throws {
        let state = try AppState(dbPath: dbPath)
        let tap = ConnectionTap(state: state)

        await tap.conn.handle(.restartFresh(sessionId: "no-such-session", cols: 80, rows: 24))

        let error = frames(await tap.drain(), ofType: "error").first
        XCTAssertEqual(error?["sessionId"] as? String, "no-such-session")
        XCTAssertEqual(error?["message"] as? String, "Session not found")
    }

    // MARK: - the stale subscription both revive paths share

    func testReactivateAlsoReSubscribesToTheNewPty() async throws {
        // Same trap as a restart, on the frame that predates it: reviving builds a
        // new Session object under the old id, and this connection was still
        // holding the dead one's subscription, so `subscribe` no-oped and the
        // client was attached to a pty whose bytes never reached it.
        let state = try AppState(dbPath: dbPath)
        let session = try state.registry.create(provider: .claude,
                                                cwd: FileManager.default.temporaryDirectory.path,
                                                cols: 80, rows: 24)
        let id = session.id
        let tap = ConnectionTap(state: state)
        await tap.conn.handle(.attach(sessionId: id, cols: 80, rows: 24))
        await awaitReady(session)
        session.write("EXIT\r")
        await waitUntil { state.registry.get(id) == nil }
        XCTAssertNil(state.registry.get(id), "the fake agent never exited")

        await tap.conn.handle(.reactivate(sessionId: id, cols: 80, rows: 24))
        let live = try XCTUnwrap(state.registry.get(id), "the revive never spawned a pty")
        defer { live.kill() }
        // Read the revived pty directly, so the wait never depends on the thing
        // under test: the connection either mirrors these bytes or it does not.
        let heard = Collected()
        let off = live.subscribeOutput(replay: false) { heard.append($0) }
        defer { off() }
        await waitUntil { heard.text.contains("ready") }
        XCTAssertTrue(heard.text.contains("ready"), "the revived pty never printed its banner")

        let output = frames(await tap.drain(), ofType: "output")
            .compactMap { $0["data"] as? String }
            .joined()
        XCTAssertTrue(output.contains("ready"),
                      "the revived pty's bytes never reached the connection: \(output)")
    }

    // MARK: - create.model

    func testCreateCarriesThePinnedModelIntoTheSpawn() async throws {
        let state = try AppState(dbPath: dbPath)
        let tap = ConnectionTap(state: state)

        await tap.conn.handle(.create(provider: "claude",
                                      cwd: FileManager.default.temporaryDirectory.path,
                                      cols: 80, rows: 24, initialInput: nil,
                                      skipPermissions: nil, isolateWorktree: nil,
                                      model: "opus", preset: nil, dispatchId: nil))

        let created = frames(await tap.drain(), ofType: "created").first
        let id = try XCTUnwrap((created?["session"] as? [String: Any])?["id"] as? String)
        let live = try XCTUnwrap(state.registry.get(id))
        defer { live.kill() }
        await awaitReady(live)
        live.write("ARGS\r")
        await waitUntil { String(decoding: live.getScrollback(), as: UTF8.self).contains("argv:") }

        XCTAssertTrue(String(decoding: live.getScrollback(), as: UTF8.self).contains("--model opus"),
                      String(decoding: live.getScrollback(), as: UTF8.self))
    }

    func testCreateWithoutAModelLeavesTheCliOnItsOwnDefault() async throws {
        // The other half of the contract: the flag appears because the frame asked
        // for it, not because every spawn gets one.
        let state = try AppState(dbPath: dbPath)
        let tap = ConnectionTap(state: state)

        await tap.conn.handle(.create(provider: "claude",
                                      cwd: FileManager.default.temporaryDirectory.path,
                                      cols: 80, rows: 24, initialInput: nil,
                                      skipPermissions: nil, isolateWorktree: nil,
                                      model: "", preset: nil, dispatchId: nil))

        let created = frames(await tap.drain(), ofType: "created").first
        let id = try XCTUnwrap((created?["session"] as? [String: Any])?["id"] as? String)
        let live = try XCTUnwrap(state.registry.get(id))
        defer { live.kill() }
        await awaitReady(live)
        live.write("ARGS\r")
        await waitUntil { String(decoding: live.getScrollback(), as: UTF8.self).contains("argv:") }

        XCTAssertFalse(String(decoding: live.getScrollback(), as: UTF8.self).contains("--model"),
                       "an empty model must read as no pin at all")
    }
}
