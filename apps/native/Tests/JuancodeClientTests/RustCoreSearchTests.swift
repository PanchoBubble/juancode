import Hummingbird
import HummingbirdTesting
import HummingbirdWebSocket
import JuancodeCore
import XCTest

@testable import JuancodeClient

/// `RustCoreClient.searchSessions` over a real socket against a stand-in daemon.
///
/// The bug these exist for (juancode-rz4c) was not a wrong answer. Search worked, and
/// it worked over the wrong corpus: the mirror at `~/.juancode/data/juancode-rust.db`
/// only ever learns a session's bytes by attaching to it, so a session this Mac had
/// never opened — every dispatched one, and everything older than the switch to this
/// core — was in the index under its title and nothing else. The daemon held the
/// history the whole time and no frame asked for it.
///
/// So the assertions are about where the answer came from:
///
/// 1. A session the mirror has no text for is found by what was said in it, because
///    the daemon answered.
/// 2. A daemon that does not advertise the capability is not asked, and the mirror's
///    own hits are still returned — the old behaviour, not an empty list.
/// 3. A daemon that never answers costs the mirror's hits and not the search.
final class RustCoreSearchTests: XCTestCase {

    /// The whole ticket: two sessions in the daemon's list, neither with a byte of
    /// scrollback in this mirror, and the one the daemon matched comes back with the
    /// snippet the daemon cut.
    func testASessionThisMirrorHasNoTextForIsFoundByWhatWasSaidInIt() async throws {
        let daemon = SearchDaemon()
        daemon.hits = [("s-dispatched", "…the [reaper window] is thirty minutes…")]
        try await withSearchDaemon(daemon) { core in
            let hits = core.searchSessions("reaper window", limit: 50)
            XCTAssertEqual(hits.map(\.meta.id), ["s-dispatched"])
            XCTAssertEqual(hits.first?.snippet, "…the [reaper window] is thirty minutes…")
            // And the frame carried what the caller asked for, not a fixed page.
            let sent = try XCTUnwrap(daemon.frames(ofType: "searchSessions").first)
            XCTAssertEqual(sent["query"] as? String, "reaper window")
            XCTAssertEqual(sent["limit"] as? Int, 50)
        }
    }

    /// Recency across both stores, not the mirror's ranking and then the daemon's:
    /// interleaving two rankings is what would put every locally-opened session above
    /// every dispatched one.
    func testHitsFromBothStoresComeBackNewestFirst() async throws {
        let daemon = SearchDaemon()
        daemon.hits = [("s-older", "…the [reaper] sweep…")]
        try await withSearchDaemon(daemon) { core in
            // A row the mirror itself can match: written through the client, which is
            // the only path that puts scrollback in the mirror at all.
            let local = try XCTUnwrap(core.session("s-dispatched"))
            core.updateSession(local, scrollback: Array("the reaper is awake".utf8))

            let hits = core.searchSessions("reaper", limit: 50)
            XCTAssertEqual(hits.map(\.meta.id), ["s-dispatched", "s-older"],
                           "updatedAt 3000 before updatedAt 2000")
        }
    }

    /// A core that does not advertise the frame is not asked, and the search it had
    /// before still answers.
    func testACoreWithoutTheCapabilityIsNotAskedAndStillSearchesTheMirror() async throws {
        let daemon = SearchDaemon()
        daemon.capabilities = ["inputAck", "sessionList"]
        daemon.hits = [("s-older", "never sent")]
        try await withSearchDaemon(daemon) { core in
            let local = try XCTUnwrap(core.session("s-dispatched"))
            core.updateSession(local, scrollback: Array("the reaper is awake".utf8))

            let hits = core.searchSessions("reaper", limit: 50)
            XCTAssertEqual(hits.map(\.meta.id), ["s-dispatched"])
            XCTAssertTrue(daemon.frames(ofType: "searchSessions").isEmpty,
                          "a frame the core never advertised must not go out")
        }
    }

    /// Silence costs the daemon's half and nothing else. The search degrades to
    /// exactly what this client had before the frame existed.
    func testADaemonThatNeverAnswersStillLeavesTheMirrorsHits() async throws {
        let daemon = SearchDaemon()
        daemon.swallowSearch = true
        try await withSearchDaemon(daemon) { core in
            let local = try XCTUnwrap(core.session("s-dispatched"))
            core.updateSession(local, scrollback: Array("the reaper is awake".utf8))

            let started = Date()
            let hits = await Task.detached { core.searchSessions("reaper", limit: 50) }.value
            XCTAssertEqual(hits.map(\.meta.id), ["s-dispatched"])
            XCTAssertLessThan(Date().timeIntervalSince(started), 20,
                              "a search waits out its budget, it does not hang")
        }
    }

    /// An id the daemon matched that this mirror has no row for is dropped rather than
    /// drawn: the caller renders a row per hit and has none to render.
    func testAHitWithNoRowInTheMirrorIsDropped() async throws {
        let daemon = SearchDaemon()
        daemon.hits = [("s-deleted", "…the [reaper]…"), ("s-older", "…the [reaper] sweep…")]
        try await withSearchDaemon(daemon) { core in
            XCTAssertEqual(core.searchSessions("reaper", limit: 50).map(\.meta.id), ["s-older"])
        }
    }
}

// MARK: - The stand-in daemon

/// Answers `listSessions` with two rows and `searchSessions` with whatever the test
/// put in `hits`. Each behaviour a test needs to bend is a switch rather than a
/// subclass, the way `QueueDaemon` does it.
private final class SearchDaemon: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [[String: Any]] = []

    var capabilities: [String] = ["inputAck", "resizeAck", "screen", "sessionMeta",
                                  "sessionList", "sessionSearch"]
    /// `(sessionId, snippet)` pairs to answer every search with.
    var hits: [(String, String)] = []
    /// Take the `searchSessions` and say nothing at all.
    var swallowSearch = false

    var frames: [[String: Any]] { lock.withLock { received } }
    func frames(ofType type: String) -> [[String: Any]] {
        frames.filter { $0["type"] as? String == type }
    }

    func replies(to frame: [String: Any]) -> [String] {
        lock.withLock { received.append(frame) }
        switch frame["type"] as? String {
        case "listSessions":
            return [searchJson(["type": "sessions", "sessions": [
                row(id: "s-dispatched", title: "dispatched work", updatedAt: 3000),
                row(id: "s-older", title: "older work", updatedAt: 2000),
            ]])]
        case "searchSessions":
            if swallowSearch { return [] }
            guard let requestId = frame["requestId"] as? String else { return [] }
            return [searchJson([
                "type": "searchResults",
                "requestId": requestId,
                "hits": hits.map { ["sessionId": $0.0, "snippet": $0.1] },
            ])]
        default:
            return []
        }
    }

    private func row(id: String, title: String, updatedAt: Int) -> [String: Any] {
        [
            "id": id, "provider": "claude", "cwd": "/tmp", "title": title,
            "status": "exited", "createdAt": 1000, "updatedAt": updatedAt,
            "skipPermissions": false, "archived": false, "dormant": false,
        ]
    }
}

private func searchJson(_ object: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(decoding: data, as: UTF8.self)
}

private func makeSearchApplication(_ daemon: SearchDaemon) -> some ApplicationProtocol {
    let router = Router(context: BasicWebSocketRequestContext.self)
    router.ws("/ws") { inbound, outbound, _ in
        try await outbound.writeTextMessage(searchJson([
            "type": "serverInfo", "protocolVersion": 1, "clientId": "test-client",
            "capabilities": daemon.capabilities,
        ]))
        for try await message in inbound.messages(maxSize: 1 << 20) {
            guard case .text(let text) = message,
                  let data = text.data(using: .utf8),
                  let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for line in daemon.replies(to: frame) { try await outbound.writeTextMessage(line) }
        }
    }
    return Application(
        router: Router(),
        server: .http1WebSocketUpgrade(webSocketRouter: router),
        configuration: .init(address: .hostname("127.0.0.1", port: 0), serverName: "search-daemon"))
}

private func withSearchDaemon(
    _ daemon: SearchDaemon,
    _ body: @escaping @Sendable (RustCoreClient) async throws -> Void
) async throws {
    let mirrorPath = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("juancode-search-\(UUID().uuidString).db")
    defer {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: mirrorPath + suffix)
        }
    }
    try await makeSearchApplication(daemon).test(.live) { client in
        let port = try XCTUnwrap(client.port)
        // `localhost` and not `127.0.0.1`: Hummingbird's live test server binds the
        // name, and on a machine whose `localhost` resolves to ::1 first a client
        // asking for the v4 literal is refused by a server that is up and listening.
        let core = try await Task.detached {
            try RustCoreClient.connect(baseURL: "http://localhost:\(port)",
                                       mirrorPath: mirrorPath, timeout: 5)
        }.value
        defer { core.shutdown() }
        try await body(core)
    }
}
