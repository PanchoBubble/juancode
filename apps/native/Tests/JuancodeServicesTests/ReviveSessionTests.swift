import XCTest
import JuancodeCore
@testable import JuancodeServices

/// Behavior of the shared lazy-revive helper (juancode-23m): id recovery, the
/// scrollback divider seed, idempotence for live sessions, and the failure
/// reasons callers surface over the wire. Spawns a real temp script through a
/// fake `BinaryResolver` (the `SessionRegistryTests` pattern), so no
/// claude/codex install is needed; the transcript scan is stubbed via the
/// `recoverId` seam.
final class ReviveSessionTests: XCTestCase {
    private struct FakeResolver: BinaryResolver {
        let path: String
        func command(for provider: ProviderId) -> String { path }
    }

    private var scripts: [String] = []

    override func tearDownWithError() throws {
        for p in scripts { try? FileManager.default.removeItem(atPath: p) }
        scripts = []
    }

    private func makeScript(_ body: String) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-revive-test-\(UUID().uuidString).sh")
        try! ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        scripts.append(url.path)
        return url.path
    }

    private func makeRegistry(store: InMemorySessionStore,
                              script: String = "printf 'READY\\n'\ncat\n") -> SessionRegistry {
        SessionRegistry(env: SessionEnvironment(
            resolver: FakeResolver(path: makeScript(script)),
            store: store,
            discoverCodexId: { _, _ in nil } // never block in tests
        ))
    }

    private var cwd: String { FileManager.default.temporaryDirectory.path }

    /// A persisted, exited session row like the ones `handleExit` leaves behind.
    private func exitedMeta(id: String = "revive-\(UUID().uuidString)",
                            cliSessionId: String?) -> SessionMeta {
        SessionMeta(
            id: id, provider: .claude, cwd: cwd, title: "test", status: .exited,
            exitCode: 0, createdAt: nowMs(), updatedAt: nowMs(),
            cliSessionId: cliSessionId, skipPermissions: false,
            worktreePath: nil, usage: nil
        )
    }

    private let noRecovery: @Sendable (ProviderId, String, Int, Set<String>) async -> String? =
        { _, _, _, _ in nil }

    func testUnknownIdFailsWithNotFound() async {
        let store = InMemorySessionStore()
        let result = await reviveSession("nope", registry: makeRegistry(store: store), store: store,
                                         recoverId: noRecovery)
        guard case .failure(.notFound) = result else {
            return XCTFail("expected .notFound, got \(result)")
        }
    }

    func testNoCliSessionIdAndNoRecoveryIsUnresumable() async {
        let store = InMemorySessionStore()
        let meta = exitedMeta(cliSessionId: nil)
        store.insert(meta)
        let result = await reviveSession(meta.id, registry: makeRegistry(store: store), store: store,
                                         recoverId: noRecovery)
        guard case .failure(.unresumable) = result else {
            return XCTFail("expected .unresumable, got \(result)")
        }
        XCTAssertEqual(ReviveFailure.unresumable.message,
                       "No prior CLI conversation could be found to resume this session.")
    }

    func testRecoversMissingIdPersistsItAndResumes() async {
        let store = InMemorySessionStore()
        let registry = makeRegistry(store: store)
        let meta = exitedMeta(cliSessionId: nil)
        store.insert(meta)

        let result = await reviveSession(meta.id, registry: registry, store: store,
                                         recoverId: { _, _, _, _ in "recovered-conv-1" })
        guard case let .success(session) = result else {
            return XCTFail("expected success, got \(result)")
        }
        defer { session.kill() }
        XCTAssertEqual(session.id, meta.id)
        XCTAssertTrue(session.isRunning)
        // The recovered id is persisted so the next revival skips the scan.
        XCTAssertEqual(store.get(meta.id)?.cliSessionId, "recovered-conv-1")
        XCTAssertNotNil(registry.get(meta.id))
    }

    func testSeedsPriorScrollbackWithResumeDivider() async {
        let store = InMemorySessionStore()
        let registry = makeRegistry(store: store)
        let meta = exitedMeta(cliSessionId: "conv-1")
        store.insert(meta)
        store.update(meta, scrollback: Array("OLD OUTPUT".utf8))

        let result = await reviveSession(meta.id, registry: registry, store: store,
                                         recoverId: noRecovery)
        guard case let .success(session) = result else {
            return XCTFail("expected success, got \(result)")
        }
        defer { session.kill() }
        let scroll = String(decoding: session.getScrollback(), as: UTF8.self)
        XCTAssertTrue(scroll.contains("OLD OUTPUT"))
        XCTAssertTrue(scroll.contains("── session resumed ──"))
    }

    func testAlreadyLiveSessionIsReturnedUntouched() async throws {
        let store = InMemorySessionStore()
        let registry = makeRegistry(store: store)
        let live = try registry.create(provider: .claude, cwd: cwd, cols: 80, rows: 24)
        defer { live.kill() }

        let result = await reviveSession(live.id, registry: registry, store: store,
                                         recoverId: noRecovery)
        guard case let .success(session) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertTrue(session === live)
    }
}
