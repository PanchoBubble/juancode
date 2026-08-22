import XCTest
import JuancodeCore
@testable import JuancodeClient

/// The relay that serves 4280 for a rust launch, against a REAL `juancoded` and a
/// real pty — the four things the oracle sidecar does, driven the way the sidecar
/// drives them (an HTTP GET for the list, one WebSocket for create / input /
/// activity).
///
/// Opt-in and skipped otherwise, same terms as `RustCoreLiveTests`: it needs a
/// daemon, and a daemon spawns ptys. Boot one on its own port and its own data
/// dir, never against :4280 or :4281.
///
///     cargo build -p juancoded
///     JUANCODED_PORT=4390 \
///     JUANCODED_SOCKET=/tmp/juancoded-proxy-live.sock \
///     JUANCODED_DATA_DIR=/tmp/juancoded-proxy-live \
///     JUANCODE_CLAUDE_BIN=apps/wire-conformance/fixtures/fake-agent.sh \
///     ./apps/juancoded/target/debug/juancoded &
///
///     JUANCODE_RUST_LIVE_URL=http://127.0.0.1:4390 \
///     swift test --filter CoreProxyLiveTests
final class CoreProxyLiveTests: XCTestCase {
    /// Not 4280 (a developer's app) and not 4281 (their sidecar).
    private static let defaultPort = 4382

    /// One core and one bound port for the whole class: a server cannot rebind the
    /// same port per test method, and nothing here needs a fresh one.
    /// `nonisolated(unsafe)` because XCTest runs a class's methods serially, so the
    /// only writer is the first `setUp`.
    nonisolated(unsafe) private static var shared: (core: RustCoreClient, base: String)?

    private var core: RustCoreClient { Self.shared!.core }
    private var base: String { Self.shared!.base }

    override func setUpWithError() throws {
        guard let url = ProcessInfo.processInfo.environment["JUANCODE_RUST_LIVE_URL"],
              !url.isEmpty else {
            throw XCTSkip("set JUANCODE_RUST_LIVE_URL to a booted juancoded to run these")
        }
        if Self.shared == nil {
            let port = ProcessInfo.processInfo.environment["JUANCODE_PROXY_LIVE_PORT"]
                .flatMap(Int.init) ?? Self.defaultPort
            let mirrorPath = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("juancode-proxy-live-\(UUID().uuidString).db")
            let core = try RustCoreClient.connect(baseURL: url, mirrorPath: mirrorPath, timeout: 5)
            core.startProxyServer(host: "127.0.0.1", port: port)
            Self.shared = (core, "http://127.0.0.1:\(port)")
        }
        try waitForProxy()
    }

    /// The server starts on a detached task, so give the port a moment to accept.
    private func waitForProxy() throws {
        let ready = expectation(description: "the relay is accepting")
        let base = base
        Task {
            for _ in 0..<50 {
                if let (_, res) = try? await URLSession.shared
                    .data(from: URL(string: base + "/api/health")!),
                   (res as? HTTPURLResponse)?.statusCode == 200 {
                    ready.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        wait(for: [ready], timeout: 10)
    }

    private func get(_ path: String) async throws -> (Int, Any?) {
        let (data, res) = try await URLSession.shared.data(from: URL(string: base + path)!)
        let body = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return ((res as? HTTPURLResponse)?.statusCode ?? -1, body)
    }

    /// Health says which core is behind the relay, so a report is never ambiguous.
    func testHealthNamesTheRustCore() async throws {
        let (status, body) = try await get("/api/health")
        XCTAssertEqual(status, 200)
        XCTAssertEqual((body as? [String: Any])?["core"] as? String, "rust")
    }

    /// One socket, the four things the sidecar needs: the daemon's handshake, a
    /// dispatch-shaped `create`, an `activity` edge, and typed input reaching the
    /// pty — with the session list and the delete going over REST alongside.
    func testTheSidecarsWholePathOverTheRelay() async throws {
        let sock = URLSession(configuration: .ephemeral)
            .webSocketTask(with: URL(string: base.replacingOccurrences(of: "http", with: "ws") + "/ws")!)
        sock.resume()
        defer { sock.cancel(with: .goingAway, reason: nil) }

        // 1. The handshake is the daemon's own, relayed untouched.
        let greeting = try await nextFrame(sock)
        XCTAssertEqual(greeting["type"] as? String, "serverInfo")
        XCTAssertEqual(greeting["protocolVersion"] as? Int, 1)

        // 2. A dispatch: the same `create` apps/oracle-mcp/src/dispatch.ts sends.
        let dispatchId = "live-\(UUID().uuidString.lowercased())"
        try await send(sock, ["type": "create", "provider": "claude", "cwd": NSTemporaryDirectory(),
                              "initialInput": "ECHO dispatched-over-the-relay",
                              "skipPermissions": true, "dispatchId": dispatchId])
        // `created` carries the whole session row, which is where dispatch.ts reads
        // the id from too.
        let created = try await waitFor(sock, type: "created")
        let id = try XCTUnwrap((created["session"] as? [String: Any])?["id"] as? String)

        // 3. The dispatch's prompt reached the pty. The daemon writes seeded input
        //    as-is, with no submitting Enter of its own, so send the CR the way the
        //    desktop's seeder does and watch the agent act on the line.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try await send(sock, ["type": "input", "sessionId": id, "data": "\r"])
        let seeded = try await waitForOutput(sock, sessionId: id,
                                             containing: "dispatched-over-the-relay")
        XCTAssertTrue(seeded, "the dispatch prompt reached the agent through the relay")

        // 4. The notification path. `PROMPT` makes the fake agent paint a question,
        //    which is the waiting_input edge the Telegram bridge pings on.
        try await send(sock, ["type": "input", "sessionId": id, "data": "PROMPT\r"])
        let activity = try await waitFor(sock, type: "activity", sessionId: id)
        XCTAssertEqual(activity["state"] as? String, "waiting_input")
        XCTAssertEqual(activity["notify"] as? Bool, true)
        print("relayed activity: \(activity)")

        // 5. The list the phone console and the Telegram formatter read.
        let ids = try await waitForListing(id)
        XCTAssertTrue(ids.contains(id), "the relayed session is in the list: \(ids)")

        // 6. Steering: the `input` frame oracle.ts's deliverReply writes, and the
        //    pty's bytes coming back the other way.
        try await send(sock, ["type": "input", "sessionId": id, "data": "ECHO steered-from-the-relay\r"])
        let echoed = try await waitForOutput(sock, sessionId: id, containing: "steered-from-the-relay")
        XCTAssertTrue(echoed)

        // 7. Delete, the one write the sidecar makes over REST.
        var request = URLRequest(url: URL(string: base + "/api/sessions/\(id)")!)
        request.httpMethod = "DELETE"
        let (_, deleteRes) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((deleteRes as? HTTPURLResponse)?.statusCode, 204)
        let (_, after) = try await get("/api/sessions")
        let remaining = (after as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        XCTAssertFalse(remaining.contains(id))
    }

    // MARK: - Frame plumbing

    private func send(_ sock: URLSessionWebSocketTask, _ body: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: body)
        try await sock.send(.string(String(decoding: data, as: UTF8.self)))
    }

    /// `receive()` has no deadline of its own, and a relay bug is exactly the case
    /// where nothing ever arrives. A watchdog that closes the socket is what ends
    /// the wait: cancelling the surrounding task would not.
    private func nextFrame(_ sock: URLSessionWebSocketTask,
                           deadline: TimeInterval = 10) async throws -> [String: Any] {
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            sock.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        let message = try await sock.receive()
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private func waitFor(_ sock: URLSessionWebSocketTask, type: String,
                         sessionId: String? = nil, limit: Int = 200) async throws -> [String: Any] {
        for _ in 0..<limit {
            let frame = try await nextFrame(sock)
            guard frame["type"] as? String == type else { continue }
            if let sessionId, frame["sessionId"] as? String != sessionId { continue }
            return frame
        }
        XCTFail("no \(type) frame arrived through the relay")
        return [:]
    }

    /// The mirror is fed by the app's own connection, not by the relayed one, so a
    /// session the sidecar created lands in the list a beat later.
    private func waitForListing(_ id: String, seconds: Int = 20) async throws -> [String] {
        var ids: [String] = []
        for _ in 0..<(seconds * 4) {
            let (_, list) = try await get("/api/sessions")
            ids = (list as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            if ids.contains(id) { return ids }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        print("mirror rows the desktop connection knows about: \(core.sessions().map(\.id))")
        return ids
    }

    private func waitForOutput(_ sock: URLSessionWebSocketTask, sessionId: String,
                               containing needle: String, limit: Int = 400) async throws -> Bool {
        for _ in 0..<limit {
            let frame = try await nextFrame(sock)
            guard frame["type"] as? String == "output",
                  frame["sessionId"] as? String == sessionId,
                  let data = frame["data"] as? String else { continue }
            if data.contains(needle) { return true }
            if let decoded = Data(base64Encoded: data),
               String(decoding: decoded, as: UTF8.self).contains(needle) { return true }
        }
        return false
    }
}
