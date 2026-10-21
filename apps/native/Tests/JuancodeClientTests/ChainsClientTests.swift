import Hummingbird
import HummingbirdTesting
import HummingbirdWebSocket
import JuancodeCore
import XCTest

@testable import JuancodeClient

/// Chains on the client (juancode-dbo.1): the book a client keeps by applying the
/// daemon's frames, and the writes that go out correlated and come back answered.
///
/// The wire half runs over a real socket against a stand-in daemon that answers the
/// way `juancoded` does — a `chainResult` to the asker, then the chain whole on the
/// change stream — because what goes wrong with a surface like this is a frame that
/// never went out or an answer read as somebody else's.
final class ChainsClientTests: XCTestCase {

    // MARK: - The book

    func testTheBookConvergesWhateverOrderTheWholeFramesArriveIn() {
        var book = ChainBook()
        let a = Chain(slug: "a", members: [ChainMember(kind: .session, ref: "s-1")])
        book.upsert(a)
        // The snapshot arriving after a change it already includes changes nothing.
        book.replace(with: [a, Chain(slug: "b")])
        book.upsert(a)
        XCTAssertEqual(book.chains.map(\.slug), ["a", "b"])
        XCTAssertEqual(book.chain(forSession: "s-1")?.slug, "a")

        // A move is two whole chains, and the book follows the last one for each slug.
        book.upsert(Chain(slug: "b", members: [ChainMember(kind: .session, ref: "s-1")]))
        book.upsert(Chain(slug: "a"))
        XCTAssertEqual(book.chain(forSession: "s-1")?.slug, "b")
        XCTAssertNil(book.chain(of: .beads, ref: "s-1"), "a ref is only itself under its kind")

        book.upsert(Chain(slug: "a", state: .inactive, closedAt: 5))
        XCTAssertEqual(book.active.map(\.slug), ["b"])
        book.remove(slug: "b")
        XCTAssertNil(book.chain(forSession: "s-1"))
        XCTAssertNil(book["b"])
    }

    func testAChainDecodesTheDaemonsShape() throws {
        let json = #"""
        {"slug":"auth-rewrite","state":"inactive","createdAt":1,"closedAt":2,
         "members":[{"kind":"tracked_pr","ref":"/repo#7","addedAt":3},
                    {"kind":"beads","ref":"juancode-dbo.1","title":"Chains core","url":"u","addedAt":4}]}
        """#
        let chain = try JSONDecoder().decode(Chain.self, from: Data(json.utf8))
        XCTAssertEqual(chain.state, .inactive)
        XCTAssertEqual(chain.closedAt, 2)
        XCTAssertEqual(chain.members.map(\.kind), [.trackedPr, .beads])
        XCTAssertEqual(chain.members[1].title, "Chains core")
        XCTAssertNil(chain.members[0].title)
    }

    // MARK: - The frames

    func testWritesGoOutCorrelatedAndTheBookFollowsTheChangeStream() async throws {
        let daemon = ChainDaemon()
        try await withChainDaemon(daemon) { core in
            XCTAssertTrue(core.supports(.chains))
            let log = BookLog()
            let cancel = core.subscribeChains { log.record($0) }
            try await log.settle { $0.chains.map(\.slug) == ["existing"] }

            try await core.createChain("auth-rewrite")
            try await log.settle { $0["auth-rewrite"] != nil }

            try await core.setChainMember(.session, ref: "s-1", slug: "auth-rewrite",
                                          title: nil, url: nil)
            try await log.settle { $0.chain(forSession: "s-1")?.slug == "auth-rewrite" }

            do {
                try await core.createChain("existing")
                XCTFail("a refusal must throw")
            } catch let error as ChainError {
                XCTAssertEqual(error.code, "chain-exists")
            }

            try await core.deleteChain("auth-rewrite")
            try await log.settle { $0["auth-rewrite"] == nil }

            let member = try XCTUnwrap(daemon.frames(ofType: "setChainMember").first)
            XCTAssertEqual(member["kind"] as? String, "session")
            XCTAssertEqual(member["ref"] as? String, "s-1")
            XCTAssertEqual(member["slug"] as? String, "auth-rewrite")
            XCTAssertNotNil(member["requestId"] as? String)
            XCTAssertEqual(daemon.frames(ofType: "subscribeChains").count, 1)
            cancel()
        }
    }

    /// A core that keeps no chains is sent nothing, hands a watcher an empty book, and
    /// refuses every write by name rather than pretending it landed.
    func testACoreWithoutTheCapabilityIsSentNothing() async throws {
        let daemon = ChainDaemon()
        daemon.capabilities = ["inputAck", "resizeAck", "screen"]
        try await withChainDaemon(daemon) { core in
            XCTAssertFalse(core.supports(.chains))
            XCTAssertNotNil(core.unavailableReason(.chains))
            let log = BookLog()
            _ = core.subscribeChains { log.record($0) }
            XCTAssertEqual(log.books.count, 1)
            XCTAssertTrue(try XCTUnwrap(log.books.first).isEmpty)
            do {
                try await core.createChain("a")
                XCTFail("must refuse")
            } catch let error as ChainError {
                XCTAssertEqual(error.code, "chain-unavailable")
            }
            await Nap.duration(.milliseconds(200))
            XCTAssertTrue(daemon.chainFrames.isEmpty)
        }
    }
}

// MARK: - The stand-in daemon

/// Answers the chain frames the way `juancoded` does: the book on subscribe, and for a
/// write a `chainResult` to the asker followed by the chain whole (or its removal).
private final class ChainDaemon: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [[String: Any]] = []
    private var book: [String: [String: Any]] = [
        "existing": ["slug": "existing", "state": "active", "createdAt": 1,
                     "closedAt": NSNull(), "members": []],
    ]

    var capabilities: [String] = ["inputAck", "resizeAck", "screen", "sessionMeta", "chains"]

    var frames: [[String: Any]] { lock.withLock { received } }

    var chainFrames: [[String: Any]] {
        frames.filter { ($0["type"] as? String)?.lowercased().contains("chain") == true }
    }

    func frames(ofType type: String) -> [[String: Any]] {
        frames.filter { $0["type"] as? String == type }
    }

    func replies(to frame: [String: Any]) -> [String] {
        lock.withLock {
            received.append(frame)
            let type = frame["type"] as? String ?? ""
            let slug = frame["slug"] as? String
            func result(_ op: String, _ error: String? = nil) -> String {
                var body: [String: Any] = ["type": "chainResult", "op": op, "ok": error == nil]
                body["requestId"] = frame["requestId"]
                body["slug"] = slug
                body["error"] = error
                return chainJSON(body)
            }
            switch type {
            case "subscribeChains":
                return [chainJSON(["type": "chains", "chains": Array(book.values)])]
            case "createChain":
                guard let slug else { return [] }
                if book[slug] != nil { return [result("create", "chain-exists")] }
                let chain: [String: Any] = ["slug": slug, "state": "active", "createdAt": 2,
                                            "closedAt": NSNull(), "members": []]
                book[slug] = chain
                return [result("create"), chainJSON(["type": "chain", "chain": chain])]
            case "setChainMember":
                guard let slug, var chain = book[slug] else {
                    return [result("setMember", "chain-not-found")]
                }
                chain["members"] = [["kind": frame["kind"] ?? "", "ref": frame["ref"] ?? "",
                                     "addedAt": 3]]
                book[slug] = chain
                return [result("setMember"), chainJSON(["type": "chain", "chain": chain])]
            case "deleteChain":
                guard let slug, book.removeValue(forKey: slug) != nil else {
                    return [result("delete", "chain-not-found")]
                }
                return [result("delete"), chainJSON(["type": "chainRemoved", "slug": slug])]
            default:
                return []
            }
        }
    }
}

/// Every book a watcher was handed, in order.
private final class BookLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ChainBook] = []

    func record(_ book: ChainBook) { lock.withLock { stored.append(book) } }
    var books: [ChainBook] { lock.withLock { stored } }

    /// Wait until the latest book satisfies `done`, so an assertion is not racing the
    /// socket; fail if it never does.
    func settle(_ done: (ChainBook) -> Bool) async throws {
        for _ in 0..<100 {
            if let last = books.last, done(last) { return }
            await Nap.duration(.milliseconds(30))
        }
        XCTFail("the book never settled: \(books.last.map { $0.chains.map(\.slug) } ?? [])")
    }
}

private func chainJSON(_ object: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(decoding: data, as: UTF8.self)
}

private func makeChainApplication(_ daemon: ChainDaemon) -> some ApplicationProtocol {
    let router = Router(context: BasicWebSocketRequestContext.self)
    router.ws("/ws") { inbound, outbound, _ in
        try await outbound.writeTextMessage(chainJSON([
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
        configuration: .init(address: .hostname("127.0.0.1", port: 0), serverName: "chain-daemon"))
}

private func withChainDaemon(
    _ daemon: ChainDaemon,
    _ body: @escaping @Sendable (RustCoreClient) async throws -> Void
) async throws {
    let mirrorPath = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("juancode-chains-\(UUID().uuidString).db")
    defer {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: mirrorPath + suffix)
        }
    }
    try await makeChainApplication(daemon).test(.live) { client in
        let port = try XCTUnwrap(client.port)
        let core = try await Task.detached {
            try RustCoreClient.connect(baseURL: "http://localhost:\(port)",
                                       mirrorPath: mirrorPath, timeout: 5)
        }.value
        defer { core.shutdown() }
        try await body(core)
    }
}
