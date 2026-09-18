import XCTest
@testable import JuancodeCore

/// The wait primitive against a REAL pty (juancode-9umy). `SessionWaitTests`
/// covers the engine's decisions; this covers the wiring `Session.waitProbe`
/// depends on — that the text really comes off the parsed grid, that silence is
/// measured from the last pty byte, and that a child dying ends the wait.
final class SessionWaitLiveTests: XCTestCase {
    private struct FakeResolver: BinaryResolver {
        let path: String
        func command(for provider: ProviderId) -> String { path }
    }

    /// A script that prints `banner`, waits `delay` seconds, prints `then`, and
    /// finally sits quiet (or exits, with `exitAfter`).
    private func fakeCli(banner: String, delay: Double, then: String, exitAfter: Bool = false) -> String {
        let tail = exitAfter ? "exit 0" : "sleep 5"
        let body = """
        printf '\(banner)\\r\\n'
        sleep \(delay)
        printf '\(then)\\r\\n'
        \(tail)
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-wait-\(UUID().uuidString).sh")
        try! ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func session(_ script: String) throws -> Session {
        try Session.create(
            provider: .claude, cwd: FileManager.default.temporaryDirectory.path,
            cols: 80, rows: 24,
            env: SessionEnvironment(resolver: FakeResolver(path: script),
                                    store: InMemorySessionStore(),
                                    discoverCliSessionId: { _, _, _ in nil }))
    }

    func testWaitsForTextTheChildPrintsLater() async throws {
        let s = try session(fakeCli(banner: "booting", delay: 0.8, then: "BUILD OK"))
        defer { s.kill() }
        let started = nowMs()
        let outcome = await SessionWait.run(condition: .text("BUILD OK"), timeoutMs: 20_000, probe: s.waitProbe)
        XCTAssertEqual(outcome, .matched)
        XCTAssertGreaterThanOrEqual(nowMs() - started, 700)
    }

    /// Quiet is pty silence, nothing else: a window wider than the gap between the
    /// child's two bursts is reset by the second one and only closes after it.
    /// Anchored on the banner first, because until the child has been exec'd the
    /// session has legitimately produced nothing and is quiet by definition.
    func testIdleWindowIsResetByTheChildsSecondBurst() async throws {
        let s = try session(fakeCli(banner: "one", delay: 0.8, then: "two"))
        defer { s.kill() }
        let booted = await SessionWait.run(condition: .text("one"), timeoutMs: 20_000, probe: s.waitProbe)
        XCTAssertEqual(booted, .matched)

        let started = nowMs()
        let outcome = await SessionWait.run(condition: .idle(ms: 1_200), timeoutMs: 20_000, probe: s.waitProbe)
        XCTAssertEqual(outcome, .matched)
        // 0.8s until "two" lands, then a fresh 1.2s of quiet. A window the second
        // burst had not reset would have closed at ~1.2s.
        XCTAssertGreaterThanOrEqual(nowMs() - started, 1_500)
    }

    func testChildExitEndsTheWait() async throws {
        let s = try session(fakeCli(banner: "hello", delay: 0.3, then: "goodbye", exitAfter: true))
        defer { s.kill() }
        let outcome = await SessionWait.run(condition: .text("never printed"),
                                            timeoutMs: 20_000, probe: s.waitProbe)
        XCTAssertEqual(outcome, .sessionExited)
    }
}
