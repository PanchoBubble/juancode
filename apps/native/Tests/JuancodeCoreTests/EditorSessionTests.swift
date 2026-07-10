import Foundation
import Testing
@testable import JuancodeCore

/// Tests for the "open editor" session (nvim/$EDITOR rooted in a session's
/// worktree). We spawn a real temp script as the editor so no nvim install is
/// needed — the same pattern as `SessionRegistryTests`.
@Suite struct EditorSessionTests {
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
            .appendingPathComponent("juancode-editor-test-\(UUID().uuidString).sh")
        try! ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func env(script: String, store: SessionStore = InMemorySessionStore()) -> SessionEnvironment {
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

    private var tmp: String { FileManager.default.temporaryDirectory.path }

    // MARK: - pure helpers

    @Test func effectiveCwdPrefersWorktreeThenCwd() {
        let base = SessionMeta(id: "a", provider: .claude, cwd: "/repo", title: "t",
                               status: .running, exitCode: nil, createdAt: 0, updatedAt: 0,
                               cliSessionId: nil, skipPermissions: false, worktreePath: nil, usage: nil)
        #expect(base.effectiveCwd == "/repo")
        var wt = base
        wt.worktreePath = "/repo-worktrees/x"
        #expect(wt.effectiveCwd == "/repo-worktrees/x")
    }

    @Test func resolveEditorCommandSplitsAndDefaults() {
        let (exe, args) = resolveEditorCommand("nvim")
        #expect((exe as NSString).lastPathComponent == "nvim")
        #expect(args.isEmpty)

        let (exe2, args2) = resolveEditorCommand("code -w")
        #expect((exe2 as NSString).lastPathComponent == "code")
        #expect(args2 == ["-w"])
    }

    /// A payload predating `kind`/`parentSessionId` must decode as an agent; a
    /// round-trip of an editor meta must preserve both fields.
    @Test func sessionMetaCodableBackCompat() throws {
        let legacy = """
        {"id":"x","provider":"claude","cwd":"/c","title":"t","status":"running",
         "createdAt":1,"updatedAt":1,"skipPermissions":false}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SessionMeta.self, from: legacy)
        #expect(decoded.kind == .agent)
        #expect(decoded.parentSessionId == nil)

        var editor = decoded
        editor.kind = .editor
        editor.parentSessionId = "parent-1"
        let round = try JSONDecoder().decode(
            SessionMeta.self, from: try JSONEncoder().encode(editor))
        #expect(round.kind == .editor)
        #expect(round.parentSessionId == "parent-1")
    }

    // MARK: - editor session behaviour

    /// `Session.editor` spawns through the real forkpty path, is `.editor` kind,
    /// links to its parent, roots in the parent's effective cwd, and is NOT
    /// persisted (so it never lands in the retention cap or disk-restore set).
    @Test func editorSessionIsEditorKindLinkedAndNotPersisted() async throws {
        let store = InMemorySessionStore()
        let script = makeScript("printf 'READY\\n'\ncat\n")
        var parent = SessionMeta(id: "parent-1", provider: .claude, cwd: "/orig", title: "t",
                                 status: .running, exitCode: nil, createdAt: 0, updatedAt: 0,
                                 cliSessionId: nil, skipPermissions: false,
                                 worktreePath: tmp, usage: nil)
        parent.worktreePath = tmp // effective cwd = the temp dir the script can run in

        let s = try Session.editor(parent: parent, executable: script, args: ["."],
                                   cols: 80, rows: 24, env: env(script: script, store: store))
        defer { s.kill() }

        #expect(s.meta.kind == .editor)
        #expect(s.meta.parentSessionId == "parent-1")
        #expect(s.meta.cwd == tmp)
        // Not persisted: no row inserted on create.
        #expect(store.meta(s.id) == nil)

        // Renders like any session — fan-out delivers the child's output.
        let sink = ByteSink()
        s.subscribeOutput { sink.add($0) }
        await poll { sink.text.contains("READY") }
        #expect(sink.text.contains("READY"))

        // Even after output churn, nothing is written back to the store.
        s.write("more\n")
        await poll { sink.text.contains("more") }
        #expect(store.meta(s.id) == nil)
    }

    /// `SessionRegistry.createEditor` resolves the editor from `JUANCODE_EDITOR`,
    /// tracks the live session, and opens the given file (as an absolute path under
    /// the worktree) — falling back to `.` when the file escapes the worktree.
    @Test func createEditorResolvesConfigTracksAndConfinesFile() async throws {
        let script = makeScript("printf 'ARGS[%s]\\n' \"$@\"\ncat\n")
        let saved = ProcessInfo.processInfo.environment["JUANCODE_EDITOR"]
        setenv("JUANCODE_EDITOR", script, 1)
        defer {
            if let saved { setenv("JUANCODE_EDITOR", saved, 1) } else { unsetenv("JUANCODE_EDITOR") }
        }

        let reg = SessionRegistry(env: env(script: script))
        let parent = SessionMeta(id: "parent-2", provider: .codex, cwd: tmp, title: "t",
                                 status: .running, exitCode: nil, createdAt: 0, updatedAt: 0,
                                 cliSessionId: nil, skipPermissions: false, worktreePath: nil, usage: nil)

        let inside = try reg.createEditor(parent: parent, file: "nested/thing.txt", cols: 80, rows: 24)
        defer { inside.kill() }
        #expect(reg.get(inside.id) != nil) // tracked live
        #expect(inside.meta.kind == .editor)
        let insideSink = ByteSink()
        inside.subscribeOutput { insideSink.add($0) }
        await poll { insideSink.text.contains("thing.txt") }
        #expect(insideSink.text.contains("ARGS[\(tmp)/nested/thing.txt]"))

        // A file outside the worktree is refused; the editor opens the directory.
        let outside = try reg.createEditor(parent: parent, file: "../escape.txt", cols: 80, rows: 24)
        defer { outside.kill() }
        let outsideSink = ByteSink()
        outside.subscribeOutput { outsideSink.add($0) }
        await poll { outsideSink.text.contains("ARGS[.]") }
        #expect(outsideSink.text.contains("ARGS[.]"))
    }
}
