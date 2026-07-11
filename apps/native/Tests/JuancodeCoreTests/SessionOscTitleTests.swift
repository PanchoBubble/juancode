import Foundation
import Testing
@testable import JuancodeCore

/// The session adopts the CLI's own OSC 0/2 window title straight from the headless
/// model (`terminalModel.onTitleChange`): once the CLI names itself, that wins over
/// the transcript-derived poll, and a manual rename still beats both. Spawns a real
/// pty through a fake resolver, as `SessionRegistryTests`.
@Suite struct SessionOscTitleTests {
    struct FakeResolver: BinaryResolver {
        let path: String
        func command(for provider: ProviderId) -> String { path }
    }

    private func makeScript(_ body: String) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-test-\(UUID().uuidString).sh")
        try! ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func poll(_ timeout: TimeInterval = 3.0, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private var cwd: String { FileManager.default.temporaryDirectory.path }

    @Test func adoptsOscTitleAndPinsItAgainstTranscriptPoll() async throws {
        let script = makeScript("printf '\\033]0;CLI tab title\\007'\ncat\n")
        let env = SessionEnvironment(
            resolver: FakeResolver(path: script),
            store: InMemorySessionStore(),
            discoverCodexId: { _, _ in nil },
            deriveTitle: { _, _ in "Transcript title" }
        )
        // .claude pins the CLI session id, so the transcript poll is live too —
        // the OSC title must still win the final state.
        let s = try Session.create(provider: .claude, cwd: cwd, cols: 80, rows: 24, env: env)
        defer { s.kill() }

        await poll { s.meta.title == "CLI tab title" }
        #expect(s.meta.title == "CLI tab title")
    }

    @Test func manualRenameBeatsLaterOscTitle() async throws {
        let script = makeScript("sleep 0.4\nprintf '\\033]0;Late OSC title\\007'\ncat\n")
        let env = SessionEnvironment(
            resolver: FakeResolver(path: script),
            store: InMemorySessionStore(),
            discoverCodexId: { _, _ in nil }
        )
        let s = try Session.create(provider: .codex, cwd: cwd, cols: 80, rows: 24, env: env)
        defer { s.kill() }

        s.setTitle("Deliberate name")
        // Give the late OSC title time to arrive — it must not clobber the rename.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(s.meta.title == "Deliberate name")
    }
}
