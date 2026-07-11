import Foundation
import Testing
@testable import JuancodeCore

/// A resumed session seeds its headless `SessionTerminalModel` with the prior
/// scrollback's replay bytes at init, so the model (and everything projected from
/// it — activity classification, screen-diff clients, local view seeds) reflects
/// the prior content before the revived CLI paints anything. The seed happens
/// before the detector and the OSC-title listener exist, so historical footers,
/// prompts, and OSC titles are rendered but never *acted on*. Spawns a real pty
/// through a fake resolver, as `SessionRegistryTests`.
@Suite struct SessionResumeSeedTests {
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

    private func env(script: String) -> SessionEnvironment {
        SessionEnvironment(
            resolver: FakeResolver(path: script),
            store: InMemorySessionStore(),
            discoverCodexId: { _, _ in nil }
        )
    }

    private func resumableMeta() -> SessionMeta {
        SessionMeta.adopting(provider: .claude, cliSessionId: "conv-1", cwd: cwd, startMs: 1)
    }

    @Test func resumedModelRendersPriorScrollback() throws {
        // Silent child: any prior content on the model came from the init seed.
        let s = try Session.resume(
            resumableMeta(), cols: 80, rows: 24,
            priorScrollback: Array("prior turn output\r\nsecond line\r\n".utf8),
            env: env(script: makeScript("cat\n")))
        defer { s.kill() }

        // The seed is synchronous in init — no waiting on pty output.
        let text = s.terminalModel.visibleText()
        #expect(text.contains("prior turn output"))
        #expect(text.contains("second line"))
    }

    @Test func resumedModelReestablishesAlternateScreenFromReplay() throws {
        // A persisted replay of an alt-screen TUI carries the synthetic resync
        // prefix; the seeded model must land in the alternate buffer with the
        // frame visible, exactly as a reattaching client's terminal would.
        let prior = Scrollback.altResync + Array("TUI FRAME".utf8)
        let s = try Session.resume(
            resumableMeta(), cols: 80, rows: 24, priorScrollback: prior,
            env: env(script: makeScript("cat\n")))
        defer { s.kill() }

        #expect(s.terminalModel.isAlternateBuffer)
        #expect(s.terminalModel.visibleText().contains("TUI FRAME"))
    }

    @Test func historicalOscTitleDoesNotClobberRestoredTitle() async throws {
        var meta = resumableMeta()
        meta.title = "Restored title"
        let prior = Array("\u{1b}]0;Old OSC title\u{07}old turn text\r\n".utf8)
        let s = try Session.resume(
            meta, cols: 80, rows: 24, priorScrollback: prior,
            env: env(script: makeScript("cat\n")))
        defer { s.kill() }

        // The model parsed the historical title, but the session never adopted it.
        #expect(s.terminalModel.terminalTitle == "Old OSC title")
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(s.meta.title == "Restored title")
    }

    @Test func liveOscTitleStillAdoptedAfterSeed() async throws {
        var meta = resumableMeta()
        meta.title = "Restored title"
        let prior = Array("\u{1b}]0;Old OSC title\u{07}old turn text\r\n".utf8)
        let script = makeScript("sleep 0.2\nprintf '\\033]0;Live OSC title\\007'\ncat\n")
        let s = try Session.resume(
            meta, cols: 80, rows: 24, priorScrollback: prior, env: env(script: script))
        defer { s.kill() }

        await poll { s.meta.title == "Live OSC title" }
        #expect(s.meta.title == "Live OSC title")
    }

    @Test func seededWorkingFooterDoesNotMakeResumedSessionBusy() async throws {
        // Session was killed mid-turn: its history ends in the working footer.
        // Unrelated live output (no "interrupt" in the bytes) must not let the
        // stale footer on the seeded screen classify the revived session busy.
        let prior = Array("doing things...\r\nesc to interrupt\r\n".utf8)
        let s = try Session.resume(
            resumableMeta(), cols: 80, rows: 24, priorScrollback: prior,
            env: env(script: makeScript("printf 'hello from resume\\n'\ncat\n")))
        defer { s.kill() }

        await poll { s.terminalModel.visibleText().contains("hello from resume") }
        // Past the settle window with the seeded footer still on screen: idle.
        try? await Task.sleep(nanoseconds: 800_000_000)
        #expect(s.activity == .idle)
    }

    @Test func seededPromptDoesNotMakeResumedSessionWaitInput() async throws {
        // History ends in a permission menu (answered before the kill); live
        // output carrying no prompt-gate token must not re-classify the seeded
        // menu as a live waitingInput prompt.
        let prior = Array("Do you want to proceed?\r\n\u{276f} 1. Yes\r\n".utf8)
        let s = try Session.resume(
            resumableMeta(), cols: 80, rows: 24, priorScrollback: prior,
            env: env(script: makeScript("printf 'hello\\n'\ncat\n")))
        defer { s.kill() }

        await poll { s.terminalModel.visibleText().contains("hello") }
        try? await Task.sleep(nanoseconds: 800_000_000)
        #expect(s.activity == .idle)
    }
}
