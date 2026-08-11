import Foundation
import Testing
@testable import JuancodeCore

/// The routine store writes must not run on the queue that feeds the terminal model
/// and fans pty bytes to the attached views (juancode-mapj): a `dbQueue.write` is a
/// whole-ring UPDATE (plus an FTS re-tokenize for a full flush), serialized across
/// every session, so doing it inline parked one session's output behind another
/// session's disk write. The exit-time write is deliberately still synchronous.
@Suite struct SessionPersistOffThreadTests {
    struct FakeResolver: BinaryResolver {
        let path: String
        func command(for provider: ProviderId) -> String { path }
    }

    /// Records which dispatch queue each write path was invoked on.
    final class QueueRecordingStore: SessionStore, @unchecked Sendable {
        private let backing = InMemorySessionStore()
        private let lock = NSLock()
        private var scrollbackLabels: [String] = []
        private var fullLabels: [String] = []
        private var midTurnLabels: [String] = []

        func insert(_ meta: SessionMeta) { backing.insert(meta) }
        func update(_ meta: SessionMeta, scrollback: [UInt8]) {
            lock.withLock { fullLabels.append(Self.currentQueueLabel()) }
            backing.update(meta, scrollback: scrollback)
        }
        func updateMeta(_ meta: SessionMeta, reindexTitleFts: Bool) {
            backing.updateMeta(meta, reindexTitleFts: reindexTitleFts)
        }
        func updateScrollback(_ id: String, scrollback: [UInt8], updatedAt: Int) {
            lock.withLock { scrollbackLabels.append(Self.currentQueueLabel()) }
            backing.updateScrollback(id, scrollback: scrollback, updatedAt: updatedAt)
        }
        func setCliSessionId(_ id: String, cliSessionId: String) {
            backing.setCliSessionId(id, cliSessionId: cliSessionId)
        }
        func setTitle(_ id: String, title: String) { backing.setTitle(id, title: title) }
        func setArchived(_ id: String, archived: Bool) { backing.setArchived(id, archived: archived) }
        func getScrollback(_ id: String) -> [UInt8]? { backing.getScrollback(id) }
        func setMidTurn(_ id: String, _ midTurn: Bool) {
            lock.withLock { midTurnLabels.append(Self.currentQueueLabel()) }
            backing.setMidTurn(id, midTurn)
        }

        var scrollback: [String] { lock.withLock { scrollbackLabels } }
        var midTurn: [String] { lock.withLock { midTurnLabels } }
        var full: [String] { lock.withLock { fullLabels } }

        private static func currentQueueLabel() -> String {
            String(cString: __dispatch_queue_get_label(nil))
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

    private func poll(_ timeout: TimeInterval = 5.0, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private var cwd: String { FileManager.default.temporaryDirectory.path }

    /// A mid-burst crash-safety flush (past the byte threshold) is handed to the
    /// shared persist queue rather than run on the session's pty queue.
    @Test func midBurstScrollbackFlushRunsOffTheSessionQueue() async throws {
        let store = QueueRecordingStore()
        // Well past the 128KB write threshold, then stay alive so nothing exits.
        let script = makeScript("head -c 200000 </dev/zero | tr '\\0' x\ncat\n")
        let reg = SessionRegistry(env: env(script: script, store: store))
        let s = try reg.create(provider: .codex, cwd: cwd, cols: 80, rows: 24)
        defer { s.kill() }

        await poll { !store.scrollback.isEmpty }
        let labels = store.scrollback
        #expect(!labels.isEmpty, "the byte-threshold flush should have fired")
        #expect(labels.allSatisfy { $0 == "juancode.session.persist" },
                "scrollback flushes ran on \(labels) instead of the persist queue")
    }

    /// Exit is the one write we still take inline — the final row must be on disk
    /// before a quit can tear the process down.
    @Test func exitWriteStaysOnTheSessionQueue() async throws {
        let store = QueueRecordingStore()
        let reg = SessionRegistry(
            env: env(script: makeScript("printf 'bye\\n'\nexit 0\n"), store: store))
        let s = try reg.create(provider: .codex, cwd: cwd, cols: 80, rows: 24)

        await poll { !s.isRunning }
        await poll { !store.full.isEmpty }
        #expect(store.full.contains { $0 != "juancode.session.persist" },
                "the exit flush must not be deferred; saw \(store.full)")
    }
}
