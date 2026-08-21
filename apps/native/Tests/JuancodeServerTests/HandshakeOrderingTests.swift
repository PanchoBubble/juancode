import XCTest
import JuancodeCore
@testable import JuancodeServer

/// `serverInfo` is frame 0, even for a connection opened while sessions are already
/// live. The activity fan-out used to start before the handshake was queued, so such
/// a connection read `activity` first and could not feature-detect before it had to
/// interpret a frame.
final class HandshakeOrderingTests: XCTestCase {
    private var dbPath: String!
    private var fakeAgent: String!

    override func setUpWithError() throws {
        dbPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-handshake-\(UUID().uuidString).db")
        // A pty that stays alive without needing a real CLI on this machine.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-fake-agent-\(UUID().uuidString).sh")
        try "#!/bin/bash\nprintf 'ready\\n'\ncat\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        fakeAgent = url.path
        setenv("JUANCODE_CLAUDE_BIN", url.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JUANCODE_CLAUDE_BIN")
        try? FileManager.default.removeItem(atPath: fakeAgent)
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + s) }
    }

    func testServerInfoIsFrameZeroWithALiveSession() async throws {
        let state = try AppState(dbPath: dbPath)
        let session = try state.registry.create(provider: .claude,
                                                cwd: FileManager.default.temporaryDirectory.path,
                                                cols: 80, rows: 24)
        defer { session.kill() }

        let (stream, cont) = AsyncStream<ServerMessage>.makeStream()
        let conn = JuancodeServer.openConnection(state: state, gate: WSSendGate(cont: cont))
        conn.stopOutput()
        conn.close()
        cont.finish()

        var types: [String] = []
        for await msg in stream {
            let obj = try JSONSerialization.jsonObject(with: Data(msg.jsonString().utf8))
            types.append(((obj as? [String: Any])?["type"] as? String) ?? "?")
        }
        XCTAssertEqual(types.first, "serverInfo",
                       "handshake must precede the activity fan-out, got: \(types)")
        XCTAssertTrue(types.contains("activity"),
                      "the live session is still announced, just after the handshake")
    }
}
