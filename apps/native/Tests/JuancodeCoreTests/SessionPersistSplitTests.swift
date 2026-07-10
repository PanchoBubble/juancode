import Foundation
import Testing
@testable import JuancodeCore

/// Wiring for the split write path (juancode-5qw.1): a live session's metadata edits
/// (rename / archive / usage) go through the meta-only store method and never rewrite
/// the scrollback column or re-tokenize its FTS row, while streamed output still
/// persists. Spawns a real pty through a fake resolver, as `SessionRegistryTests`.
@Suite struct SessionPersistSplitTests {
    struct FakeResolver: BinaryResolver {
        let path: String
        func command(for provider: ProviderId) -> String { path }
    }

    /// Counts each write-path so tests can assert which one a given edit took.
    /// Delegates the actual storage to an in-memory store so reads still work.
    final class CountingStore: SessionStore, @unchecked Sendable {
        private let backing = InMemorySessionStore()
        private let lock = NSLock()
        private(set) var fullUpdates = 0
        private(set) var metaUpdates = 0
        private(set) var scrollbackFlushes = 0

        func insert(_ meta: SessionMeta) { backing.insert(meta) }
        func update(_ meta: SessionMeta, scrollback: [UInt8]) {
            lock.withLock { fullUpdates += 1 }
            backing.update(meta, scrollback: scrollback)
        }
        func updateMeta(_ meta: SessionMeta, reindexTitleFts: Bool) {
            lock.withLock { metaUpdates += 1 }
            backing.updateMeta(meta, reindexTitleFts: reindexTitleFts)
        }
        func updateScrollback(_ id: String, scrollback: [UInt8], updatedAt: Int) {
            lock.withLock { scrollbackFlushes += 1 }
            backing.updateScrollback(id, scrollback: scrollback, updatedAt: updatedAt)
        }
        func setCliSessionId(_ id: String, cliSessionId: String) {
            backing.setCliSessionId(id, cliSessionId: cliSessionId)
        }
        func setTitle(_ id: String, title: String) { backing.setTitle(id, title: title) }
        func setArchived(_ id: String, archived: Bool) { backing.setArchived(id, archived: archived) }
        func getScrollback(_ id: String) -> [UInt8]? { backing.getScrollback(id) }

        var counts: (full: Int, meta: Int, scroll: Int) {
            lock.withLock { (fullUpdates, metaUpdates, scrollbackFlushes) }
        }
    }

    private func makeScript(_ body: String) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-test-\(UUID().uuidString).sh")
        try! ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func env(script: String, store: SessionStore) -> SessionEnvironment {
        SessionEnvironment(
            resolver: FakeResolver(path: script),
            store: store,
            scrollbackLimit: 256 * 1024,
            discoverCodexId: { _, _ in nil }
        )
    }

    private func poll(_ timeout: TimeInterval = 3.0, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private var cwd: String { FileManager.default.temporaryDirectory.path }

    @Test func renameTakesMetaOnlyPathAndPreservesScrollback() async throws {
        let store = CountingStore()
        let reg = SessionRegistry(env: env(script: makeScript("printf 'READY\\n'\ncat\n"), store: store))
        let s = try reg.create(provider: .codex, cwd: cwd, cols: 80, rows: 24)
        defer { s.kill() }

        await poll { s.getScrollback().count > 0 }
        let storeScrollBefore = store.getScrollback(s.id)
        let before = store.counts

        s.setTitle("A deliberate name")

        // The rename hit the meta-only path — no extra full/scrollback write.
        #expect(store.counts.meta == before.meta + 1)
        #expect(store.counts.full == before.full)
        #expect(store.counts.scroll == before.scroll)
        // Persisted scrollback column is untouched by the rename.
        #expect(s.meta.title == "A deliberate name")
        #expect(store.getScrollback(s.id) == storeScrollBefore)
    }

    @Test func exitDoesAFullFlushSoContentIsSearchable() async throws {
        let store = CountingStore()
        let reg = SessionRegistry(
            env: env(script: makeScript("printf 'a distinctive marker\\n'\nexit 0\n"), store: store))
        let s = try reg.create(provider: .codex, cwd: cwd, cols: 80, rows: 24)

        await poll { !s.isRunning }
        // Exit funnels through the full (FTS-reindexing) write at least once.
        #expect(store.counts.full >= 1)
        #expect(store.getScrollback(s.id).map { String(decoding: $0, as: UTF8.self) }?.contains("distinctive") == true)
    }
}
