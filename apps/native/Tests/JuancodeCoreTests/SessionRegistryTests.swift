import Foundation
import Testing
@testable import JuancodeCore

/// Integration tests for the pty host + fan-out (juancode-u34.2). We spawn a real
/// temp script through a fake `BinaryResolver`, so no claude/codex install needed.
@Suite struct SessionRegistryTests {
    struct FakeResolver: BinaryResolver {
        let path: String
        func command(for provider: ProviderId) -> String { path }
    }

    final class ByteSink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = [UInt8]()
        func add(_ b: [UInt8]) { lock.withLock { data += b } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    private func makeScript(_ body: String) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-test-\(UUID().uuidString).sh")
        try! ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func env(script: String, store: SessionStore = InMemorySessionStore()) -> SessionEnvironment {
        SessionEnvironment(
            resolver: FakeResolver(path: script),
            store: store,
            scrollbackLimit: 256 * 1024,
            discoverCodexId: { _, _ in nil } // never block in tests
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

    @Test func spawnsAndFansOutToManySubscribers() async throws {
        let reg = SessionRegistry(env: env(script: makeScript("printf 'READY\\n'\ncat\n")))
        let s = try reg.create(provider: .codex, cwd: cwd, cols: 80, rows: 24)
        defer { s.kill() }

        let a = ByteSink(), b = ByteSink()
        s.subscribeOutput { a.add($0) }
        s.subscribeOutput { b.add($0) }

        await poll { a.text.contains("READY") && b.text.contains("READY") }
        #expect(a.text.contains("READY"))
        #expect(b.text.contains("READY"))
    }

    @Test func lateSubscriberGetsScrollbackReplay() async throws {
        let reg = SessionRegistry(env: env(script: makeScript("printf 'READY\\n'\ncat\n")))
        let s = try reg.create(provider: .codex, cwd: cwd, cols: 80, rows: 24)
        defer { s.kill() }

        await poll { s.getScrollback().count > 0 }
        let late = ByteSink()
        s.subscribeOutput(replay: true) { late.add($0) }
        // Replay is synchronous on subscribe, so it's already here.
        #expect(late.text.contains("READY"))
    }

    @Test func keystrokesReachTheChild() async throws {
        let reg = SessionRegistry(env: env(script: makeScript("printf 'READY\\n'\ncat\n")))
        let s = try reg.create(provider: .codex, cwd: cwd, cols: 80, rows: 24)
        defer { s.kill() }

        let sink = ByteSink()
        s.subscribeOutput { sink.add($0) }
        await poll { sink.text.contains("READY") }
        s.write("ping\n")
        await poll { sink.text.contains("ping") } // pty echo + cat
        #expect(sink.text.contains("ping"))
    }

    /// A fire-and-forget programmatic paste (no `onResult`) must still reach the
    /// child. Regression guard for the optional-chaining footgun where
    /// `onResult?(runPasteDelivery(...))` short-circuited the whole expression when
    /// the callback was nil, so seed / queue-flush pastes never delivered.
    @Test func fireAndForgetPasteReachesTheChild() async throws {
        let reg = SessionRegistry(env: env(script: makeScript("printf 'READY\\n'\ncat\n")))
        let s = try reg.create(provider: .claude, cwd: cwd, cols: 80, rows: 24)
        defer { s.kill() }

        let sink = ByteSink()
        s.subscribeOutput { sink.add($0) }
        await poll { sink.text.contains("READY") }
        s.insert("PASTEPING") // no onResult — the nil-callback path
        await poll { sink.text.contains("PASTEPING") } // tty echo of the delivered paste
        #expect(sink.text.contains("PASTEPING"))
    }

    @Test func killTransitionsToExitedAndNotifies() async throws {
        let reg = SessionRegistry(env: env(script: makeScript("printf 'READY\\n'\ncat\n")))
        let s = try reg.create(provider: .codex, cwd: cwd, cols: 80, rows: 24)
        let exited = ByteSink() // reuse as a flag carrier
        s.onExit { _ in exited.add(Array("X".utf8)) }

        await poll { s.getScrollback().count > 0 }
        s.kill()
        await poll { !s.isRunning }
        #expect(!s.isRunning)
        #expect(s.meta.status == .exited)
        await poll { !exited.text.isEmpty }
        #expect(!exited.text.isEmpty)
    }

    @Test func exitCodeIsCaptured() async throws {
        let store = InMemorySessionStore()
        let reg = SessionRegistry(env: env(script: makeScript("printf 'bye\\n'\nexit 3\n"), store: store))
        let s = try reg.create(provider: .codex, cwd: cwd, cols: 80, rows: 24)
        let id = s.id

        // Status flips before persistNow() runs, so poll the persisted copy too.
        await poll { s.meta.exitCode == 3 && store.meta(id)?.exitCode == 3 }
        #expect(s.meta.exitCode == 3)
        #expect(store.meta(id)?.exitCode == 3)
    }

    @Test func registryTracksThenDropsOnExit() async throws {
        let reg = SessionRegistry(env: env(script: makeScript("printf 'done\\n'\n")))
        let s = try reg.create(provider: .codex, cwd: cwd, cols: 80, rows: 24)
        let id = s.id
        #expect(reg.get(id) != nil)

        await poll { reg.get(id) == nil }
        #expect(reg.get(id) == nil)
        #expect(reg.all().isEmpty)
    }

    @Test func claudePinsCliSessionIdAndStoreInsertsOnCreate() async throws {
        let store = InMemorySessionStore()
        // Claude's startArgs prepend --session-id <id>; the script ignores them.
        let reg = SessionRegistry(env: env(script: makeScript("printf 'hi\\n'\ncat\n"), store: store))
        let s = try reg.create(provider: .claude, cwd: cwd, cols: 80, rows: 24)
        defer { s.kill() }
        #expect(s.meta.cliSessionId == s.id) // pinned up front
        #expect(store.meta(s.id) != nil)     // inserted on create
    }

    @Test func adoptingExternalMetaResumesAndPersists() async throws {
        // Mirror the adopt path (juancode-iqi): build a row pointing at an existing
        // external CLI conversation, persist it, then resume it live with no prior
        // scrollback (the CLI reprints its own context).
        let store = InMemorySessionStore()
        let reg = SessionRegistry(env: env(script: makeScript("printf 'RESUMED\\n'\ncat\n"), store: store))
        let meta = SessionMeta.adopting(provider: .claude, cliSessionId: "ext-conv-1",
                                        cwd: cwd, startMs: 123_456)
        store.insert(meta)
        let s = try reg.resume(meta, cols: 80, rows: 24, priorScrollback: [])
        defer { s.kill() }

        #expect(s.meta.id == meta.id)
        #expect(s.meta.cliSessionId == "ext-conv-1")
        #expect(s.meta.status == .running)
        #expect(store.usedCliSessionIds().contains("ext-conv-1"))

        let sink = ByteSink()
        s.subscribeOutput(replay: true) { sink.add($0) }
        await poll { sink.text.contains("RESUMED") }
        #expect(sink.text.contains("RESUMED"))
    }

    /// A meta-field edit (rename here; the title/usage poll shares the path) must
    /// fan out to `onMetaChange` so the sidebar rebuilds instead of stranding the
    /// "Claude Code · <project>" fallback until an unrelated refresh.
    @Test func metaChangeFiresOnRename() async throws {
        let reg = SessionRegistry(env: env(script: makeScript("printf 'hi\\n'\ncat\n")))
        let s = try reg.create(provider: .codex, cwd: cwd, cols: 80, rows: 24)
        defer { s.kill() }

        let seen = ByteSink()
        s.onMetaChange { seen.add(Array($0.title.utf8)) }
        s.setTitle("Renamed")
        await poll { seen.text == "Renamed" }
        #expect(seen.text == "Renamed")

        // An unchanged rename is a no-op — no spurious fan-out.
        s.setTitle("Renamed")
        #expect(seen.text == "Renamed")
    }

    /// `restartFresh` boots a Claude session that couldn't be resumed as a brand-new
    /// live conversation: same juancode id + db row, but a *fresh* pinned CLI session
    /// id (never the old one, to dodge Claude's "session id already in use"), status
    /// back to running.
    @Test func restartFreshKeepsIdAndRepinsAFreshCliSession() async throws {
        let store = InMemorySessionStore()
        let reg = SessionRegistry(env: env(script: makeScript("printf 'FRESH\\n'\ncat\n"), store: store))
        let original = try reg.create(provider: .claude, cwd: cwd, cols: 80, rows: 24)
        let oldMeta = original.meta
        let oldCliId = oldMeta.cliSessionId
        original.kill()
        await poll { !original.isRunning }

        let s = try reg.restartFresh(oldMeta, cols: 80, rows: 24)
        defer { s.kill() }

        #expect(s.meta.id == oldMeta.id)                 // same pane / db row
        #expect(s.meta.status == .running)
        #expect(s.meta.cliSessionId != nil)              // still pinned (Claude)
        #expect(s.meta.cliSessionId != oldCliId)         // but a fresh id, not the old one
        #expect(s.meta.cliSessionId != oldMeta.id)       // and not the reused juancode id
        #expect(store.usedCliSessionIds().contains(s.meta.cliSessionId!))

        let sink = ByteSink()
        s.subscribeOutput(replay: true) { sink.add($0) }
        await poll { sink.text.contains("FRESH") }
        #expect(sink.text.contains("FRESH"))
    }

    @Test func onCreateFiresForNewSessions() async throws {
        let reg = SessionRegistry(env: env(script: makeScript("printf 'hi\\n'\ncat\n")))
        let seen = ByteSink()
        reg.onCreate { seen.add(Array($0.id.utf8)) }
        let s = try reg.create(provider: .codex, cwd: cwd, cols: 80, rows: 24)
        defer { s.kill() }
        #expect(seen.text == s.id)
    }
}
