import XCTest
import JuancodeCore
import JuancodeServices
import JuancodePersistence
@testable import JuancodeServer

/// `PrTrackingEngine` persistence (juancode-b4m): the engine is the single owner
/// of the tracked-PR watch list, restoring from and persisting to the SQLite
/// `tracked_prs` table, with a one-time import of the legacy UserDefaults blob
/// (key absence = migrated).
final class PrTrackingEngineTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "juancode-engine-test-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private static let legacyKey = "juancode.trackedPrs.v1"

    /// A cwd that can't exist, so any poll's `gh` spawn fails at launch (→ nil
    /// activity) without ever reaching the network.
    private static func ghostCwd() -> String { "/nonexistent/juancode-\(UUID().uuidString)" }

    private static func samplePr(_ number: Int, cwd: String, nwo: String? = nil) -> TrackedPr {
        TrackedPr(number: number, title: "PR \(number)", branch: "feat-\(number)",
                  url: "https://github.com/owner/repo/pull/\(number)",
                  cwd: cwd, sessionId: "s-\(number)", repoNwo: nwo)
    }

    private static func seed(_ store: GRDBStore, _ prs: [TrackedPr]) throws {
        var payloads: [String: String] = [:]
        for pr in prs {
            payloads[pr.id] = String(decoding: try JSONEncoder().encode(pr), as: UTF8.self)
        }
        store.replaceTrackedPrPayloads(payloads)
    }

    private func makeEngine(store: GRDBStore,
                            debounce: Duration = .seconds(2)) throws -> PrTrackingEngine {
        PrTrackingEngine(registry: SessionRegistry(env: SessionEnvironment()),
                         store: store, legacyDefaultsSuite: suiteName,
                         webhookDebounce: debounce)
    }

    /// Thread-safe refresh counter for the probe seam.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func increment() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    func testRestoresFromStore() async throws {
        let store = try GRDBStore(inMemory: true)
        let cwd = Self.ghostCwd()
        let a = Self.samplePr(1, cwd: cwd), b = Self.samplePr(2, cwd: cwd)
        try Self.seed(store, [a, b])
        let engine = try makeEngine(store: store)
        let list = await engine.list()
        XCTAssertEqual(Set(list.map(\.id)), [a.id, b.id])
        XCTAssertNil(defaults.data(forKey: Self.legacyKey))
    }

    func testLegacyDefaultsImportHappensExactlyOnce() async throws {
        let pr = Self.samplePr(7, cwd: Self.ghostCwd())
        defaults.set(try JSONEncoder().encode([pr]), forKey: Self.legacyKey)

        // First init on an empty store: imports the defaults blob into the store
        // and removes the key (absence = migrated).
        let store = try GRDBStore(inMemory: true)
        let engine = try makeEngine(store: store)
        let list = await engine.list()
        XCTAssertEqual(list.map(\.id), [pr.id])
        XCTAssertEqual(Array(store.loadTrackedPrPayloads().keys), [pr.id])
        XCTAssertNil(defaults.data(forKey: Self.legacyKey))

        // A second init on a fresh empty store must NOT re-import: the marker is gone.
        let store2 = try GRDBStore(inMemory: true)
        let engine2 = try makeEngine(store: store2)
        let list2 = await engine2.list()
        XCTAssertTrue(list2.isEmpty)
        XCTAssertTrue(store2.loadTrackedPrPayloads().isEmpty)
    }

    func testStoreWinsOverLeftoverLegacyDefaults() async throws {
        // A non-empty store means migration already ran (or the engine has been
        // writing) — a stray defaults blob must not be merged in.
        let cwd = Self.ghostCwd()
        let stored = Self.samplePr(1, cwd: cwd)
        let stray = Self.samplePr(2, cwd: cwd)
        let store = try GRDBStore(inMemory: true)
        try Self.seed(store, [stored])
        defaults.set(try JSONEncoder().encode([stray]), forKey: Self.legacyKey)
        let engine = try makeEngine(store: store)
        let list = await engine.list()
        XCTAssertEqual(list.map(\.id), [stored.id])
    }

    func testUntrackPersistsThroughStore() async throws {
        let store = try GRDBStore(inMemory: true)
        let cwd = Self.ghostCwd()
        let a = Self.samplePr(1, cwd: cwd), b = Self.samplePr(2, cwd: cwd)
        try Self.seed(store, [a, b])
        let engine = try makeEngine(store: store)
        await engine.untrack(a.id)
        XCTAssertEqual(Array(store.loadTrackedPrPayloads().keys), [b.id])
        XCTAssertNil(defaults.data(forKey: Self.legacyKey))
    }

    // MARK: - webhook ingest (repo identity, matching, debounce)

    func testRepoNwoSurvivesPersistenceRoundtrip() async throws {
        let store = try GRDBStore(inMemory: true)
        let pr = Self.samplePr(4, cwd: Self.ghostCwd(), nwo: "acme/widgets")
        try Self.seed(store, [pr])
        let engine = try makeEngine(store: store)
        let list = await engine.list()
        XCTAssertEqual(list.first?.repoNwo, "acme/widgets")
    }

    func testFindByRepoNumberMatchesStoredNwoCaseInsensitively() async throws {
        let store = try GRDBStore(inMemory: true)
        let cwd = Self.ghostCwd()
        let a = Self.samplePr(1, cwd: cwd, nwo: "Acme/Widgets")
        let b = Self.samplePr(2, cwd: cwd, nwo: "acme/widgets")
        try Self.seed(store, [a, b])
        let engine = try makeEngine(store: store)
        let hits = await engine.findByRepoNumber("acme/WIDGETS", number: 1)
        XCTAssertEqual(hits.map(\.id), [a.id])
        let misses = await engine.findByRepoNumber("other/repo", number: 1)
        XCTAssertTrue(misses.isEmpty)
        let wrongNumber = await engine.findByRepoNumber("acme/widgets", number: 3)
        XCTAssertTrue(wrongNumber.isEmpty)
    }

    func testFindByRepoNumberFallsBackToPrUrlWhenNwoMissing() async throws {
        // A record persisted before repo identity existed (repoNwo nil, not yet
        // backfilled) still matches via the owner/name in its PR url.
        let store = try GRDBStore(inMemory: true)
        let pr = Self.samplePr(9, cwd: Self.ghostCwd())
        try Self.seed(store, [pr])
        let engine = try makeEngine(store: store)
        let hits = await engine.findByRepoNumber("Owner/Repo", number: 9)
        XCTAssertEqual(hits.map(\.id), [pr.id])
    }

    func testIngestWebhookIsNoOpForUntrackedRepo() async throws {
        let store = try GRDBStore(inMemory: true)
        let pr = Self.samplePr(5, cwd: Self.ghostCwd(), nwo: "owner/repo")
        try Self.seed(store, [pr])
        let engine = try makeEngine(store: store, debounce: .milliseconds(10))
        let counter = Counter()
        await engine.setRefreshProbe { _ in counter.increment() }
        let matched = await engine.ingestWebhook(repo: "somebody/else", number: 5)
        XCTAssertEqual(matched, 0)
        let wrongNumber = await engine.ingestWebhook(repo: "owner/repo", number: 6)
        XCTAssertEqual(wrongNumber, 0)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(counter.value, 0)
    }

    func testIngestWebhookCoalescesABurstIntoOneRefresh() async throws {
        let store = try GRDBStore(inMemory: true)
        let pr = Self.samplePr(5, cwd: Self.ghostCwd(), nwo: "owner/repo")
        try Self.seed(store, [pr])
        let engine = try makeEngine(store: store, debounce: .milliseconds(30))
        let counter = Counter()
        await engine.setRefreshProbe { _ in counter.increment() }
        // One push fires several webhook events back to back — one refresh.
        for _ in 0..<5 {
            let matched = await engine.ingestWebhook(repo: "owner/repo", number: 5)
            XCTAssertEqual(matched, 1)
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(counter.value, 1)
        // A later event (after the window) schedules its own refresh.
        await engine.ingestWebhook(repo: "OWNER/repo", number: 5)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(counter.value, 2)
    }

    func testUntrackCancelsAPendingWebhookRefresh() async throws {
        let store = try GRDBStore(inMemory: true)
        let pr = Self.samplePr(5, cwd: Self.ghostCwd(), nwo: "owner/repo")
        try Self.seed(store, [pr])
        let engine = try makeEngine(store: store, debounce: .milliseconds(50))
        let counter = Counter()
        await engine.setRefreshProbe { _ in counter.increment() }
        await engine.ingestWebhook(repo: "owner/repo", number: 5)
        await engine.untrack(pr.id)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(counter.value, 0)
    }

    func testPollOncePersistsThroughStoreNotDefaults() async throws {
        let store = try GRDBStore(inMemory: true)
        let pr = Self.samplePr(3, cwd: Self.ghostCwd())
        try Self.seed(store, [pr])
        let engine = try makeEngine(store: store)
        // Wipe the table out from under the engine; a poll pass re-persists the
        // in-memory watch list through the store — never through UserDefaults.
        store.replaceTrackedPrPayloads([:])
        await engine.pollOnce()
        XCTAssertEqual(Array(store.loadTrackedPrPayloads().keys), [pr.id])
        XCTAssertNil(defaults.data(forKey: Self.legacyKey))
    }
}
