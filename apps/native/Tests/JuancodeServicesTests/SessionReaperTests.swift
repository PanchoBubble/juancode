import XCTest
import JuancodeCore
@testable import JuancodeServices

/// The idle-reaper eligibility state machine (juancode-lgq): every independent
/// signal — detector state, message queue, process-tree shape, CPU delta,
/// transcript mtime, keystrokes, resumability — must hold for the full window
/// before a session is eligible, and any disturbance restarts the streak. Pure
/// policy tests plus a fake-pty integration pass over `SessionReaper.sweepOnce`
/// (the `ReviveSessionTests` pattern — a temp script through a fake resolver, so
/// no claude/codex install is needed).
final class SessionReaperTests: XCTestCase {
    private let windowMs = 30 * 60 * 1000
    private let t0 = 1_000_000_000_000 // an arbitrary epoch-ms anchor

    /// An all-clear sample: idle, resumable, quiet tree, no recent input.
    private func idleSample(
        activity: SessionActivity = .idle,
        resumable: Bool = true,
        queueEmpty: Bool = true,
        lastInputMs: Int? = nil,
        descendantCount: Int = 3,
        cpuTimeMs: Int = 10_000,
        transcriptMtimeMs: Int? = nil,
        isProtected: Bool = false
    ) -> ReapSample {
        ReapSample(
            activity: activity,
            resumable: resumable,
            queueEmpty: queueEmpty,
            lastInputMs: lastInputMs ?? (t0 - windowMs), // long before the streak
            descendantCount: descendantCount,
            cpuTimeMs: cpuTimeMs,
            transcriptMtimeMs: transcriptMtimeMs,
            isProtected: isProtected
        )
    }

    /// The baseline a first all-clear sweep at `t0` captures.
    private var baseAtT0: SessionReapPolicy.Baseline {
        SessionReapPolicy.Baseline(idleSinceMs: t0, descendantCount: 3, cpuTimeMs: 10_000)
    }

    private func evaluate(
        _ sample: ReapSample,
        baseline: SessionReapPolicy.Baseline?,
        nowMs: Int
    ) -> SessionReapPolicy.Verdict {
        SessionReapPolicy.evaluate(sample, baseline: baseline, nowMs: nowMs, windowMs: windowMs)
    }

    // MARK: - hard resets

    func testBusyIsNeverEligible() {
        XCTAssertEqual(evaluate(idleSample(activity: .busy), baseline: baseAtT0, nowMs: t0 + windowMs),
                       .notIdle)
    }

    func testWaitingInputIsNeverEligible() {
        // A pending permission menu isn't in the transcript until answered;
        // killing there aborts the tool call and resume won't re-render it.
        XCTAssertEqual(evaluate(idleSample(activity: .waitingInput), baseline: baseAtT0, nowMs: t0 + windowMs),
                       .notIdle)
    }

    func testNonEmptyQueueIsNeverEligible() {
        XCTAssertEqual(evaluate(idleSample(queueEmpty: false), baseline: baseAtT0, nowMs: t0 + windowMs),
                       .notIdle)
    }

    func testProtectedSessionIsNeverEligible() {
        XCTAssertEqual(evaluate(idleSample(isProtected: true), baseline: baseAtT0, nowMs: t0 + windowMs),
                       .notIdle)
    }

    func testDisabledWindowNeverTracks() {
        XCTAssertEqual(
            SessionReapPolicy.evaluate(idleSample(), baseline: nil, nowMs: t0, windowMs: 0),
            .notIdle
        )
    }

    // MARK: - streak lifecycle

    func testFirstIdleSweepCapturesBaseline() {
        XCTAssertEqual(evaluate(idleSample(), baseline: nil, nowMs: t0), .holding(baseAtT0))
    }

    func testIdleBeforeWindowServedHolds() {
        XCTAssertEqual(evaluate(idleSample(), baseline: baseAtT0, nowMs: t0 + windowMs - 1),
                       .holding(baseAtT0))
    }

    func testAllClearForFullWindowIsEligible() {
        XCTAssertEqual(evaluate(idleSample(), baseline: baseAtT0, nowMs: t0 + windowMs), .eligible)
    }

    // MARK: - OS ground truth restarts the streak

    func testExtraChildRestartsStreak() {
        // A Bash tool / spawned subagent — the detector may say idle, the tree says no.
        let now = t0 + windowMs
        XCTAssertEqual(
            evaluate(idleSample(descendantCount: 4), baseline: baseAtT0, nowMs: now),
            .holding(.init(idleSinceMs: now, descendantCount: 4, cpuTimeMs: 10_000))
        )
    }

    func testVanishedChildRestartsStreak() {
        let now = t0 + windowMs
        XCTAssertEqual(
            evaluate(idleSample(descendantCount: 2), baseline: baseAtT0, nowMs: now),
            .holding(.init(idleSinceMs: now, descendantCount: 2, cpuTimeMs: 10_000))
        )
    }

    func testCpuDeltaPastEpsilonRestartsStreak() {
        let now = t0 + windowMs
        let moved = 10_000 + SessionReapPolicy.defaultCpuEpsilonMs + 1
        XCTAssertEqual(
            evaluate(idleSample(cpuTimeMs: moved), baseline: baseAtT0, nowMs: now),
            .holding(.init(idleSinceMs: now, descendantCount: 3, cpuTimeMs: moved))
        )
    }

    func testCpuDeltaWithinEpsilonStaysEligible() {
        // Idle MCP heartbeats burn a little CPU; within the epsilon isn't work.
        let sample = idleSample(cpuTimeMs: 10_000 + SessionReapPolicy.defaultCpuEpsilonMs)
        XCTAssertEqual(evaluate(sample, baseline: baseAtT0, nowMs: t0 + windowMs), .eligible)
    }

    func testTranscriptModifiedAfterIdleEntryRestartsStreak() {
        // Thinking/delegation writes transcript records the screen doesn't show.
        let now = t0 + windowMs
        XCTAssertEqual(
            evaluate(idleSample(transcriptMtimeMs: t0 + 1), baseline: baseAtT0, nowMs: now),
            .holding(.init(idleSinceMs: now, descendantCount: 3, cpuTimeMs: 10_000))
        )
    }

    func testTranscriptOlderThanIdleEntryStaysEligible() {
        let sample = idleSample(transcriptMtimeMs: t0 - 60_000)
        XCTAssertEqual(evaluate(sample, baseline: baseAtT0, nowMs: t0 + windowMs), .eligible)
    }

    func testMissingTranscriptDoesNotBlock() {
        // Unlocatable transcript = no evidence of activity; the other signals guard.
        XCTAssertEqual(evaluate(idleSample(transcriptMtimeMs: nil), baseline: baseAtT0,
                                nowMs: t0 + windowMs),
                       .eligible)
    }

    // MARK: - exemptions

    func testUnresumableSessionIsExemptEvenAfterFullWindow() {
        // Codex discovers its id late; killing before capture loses the conversation.
        XCTAssertEqual(evaluate(idleSample(resumable: false), baseline: baseAtT0, nowMs: t0 + windowMs),
                       .holding(baseAtT0))
    }

    func testKeystrokeDuringStreakRestartsIt() {
        // A half-typed, unsubmitted prompt is invisible to every other signal.
        let now = t0 + windowMs
        XCTAssertEqual(
            evaluate(idleSample(lastInputMs: t0 + 60_000), baseline: baseAtT0, nowMs: now),
            .holding(.init(idleSinceMs: now, descendantCount: 3, cpuTimeMs: 10_000))
        )
    }

    func testKeystrokeYoungerThanWindowHolds() {
        // Typed just before going idle: the streak is intact but the keystroke
        // itself must also age past the window.
        let base = SessionReapPolicy.Baseline(idleSinceMs: t0, descendantCount: 3, cpuTimeMs: 10_000)
        let sample = idleSample(lastInputMs: t0 - 1000)
        XCTAssertEqual(evaluate(sample, baseline: base, nowMs: t0 + windowMs - 2000), .holding(base))
    }

    // MARK: - sweep integration (fake pty + fake probes)

    private struct FakeResolver: BinaryResolver {
        let path: String
        func command(for provider: ProviderId) -> String { path }
    }

    private var scripts: [String] = []

    override func tearDownWithError() throws {
        for p in scripts { try? FileManager.default.removeItem(atPath: p) }
        scripts = []
    }

    private func makeScript() -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-reaper-test-\(UUID().uuidString).sh")
        try! "#!/bin/bash\nprintf 'READY\\n'\ncat\n".write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        scripts.append(url.path)
        return url.path
    }

    /// A settable fake clock the sweep reads through `probes.nowMs`.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Int
        init(_ now: Int) { _now = now }
        var now: Int {
            get { lock.withLock { _now } }
            set { lock.withLock { _now = newValue } }
        }
    }

    private func quietProbes(clock: Clock) -> SessionReaperProbes {
        SessionReaperProbes(
            nowMs: { clock.now },
            descendantCount: { _ in 2 },
            treeCpuTimeMs: { _ in 100 },
            transcriptMtimeMs: { _, _ in nil }
        )
    }

    private func waitForIdle(_ session: Session) async {
        for _ in 0..<100 where session.activity != .idle {
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(session.activity, .idle)
    }

    func testSweepReapsToDormantAndResumeClearsIt() async throws {
        let store = InMemorySessionStore()
        let queue = MessageQueue()
        let registry = SessionRegistry(env: SessionEnvironment(
            resolver: FakeResolver(path: makeScript()),
            store: store,
            messageQueue: queue,
            discoverCodexId: { _, _ in nil }
        ))
        let session = try registry.create(
            provider: .claude, cwd: FileManager.default.temporaryDirectory.path, cols: 80, rows: 24)
        defer { session.kill() }
        await waitForIdle(session)

        let clock = Clock(nowMs())
        let reaper = SessionReaper(
            registry: registry, messageQueue: queue, probes: quietProbes(clock: clock),
            windowMs: windowMs)

        // First sweep captures the baseline; nothing dies.
        var reaped = await reaper.sweepOnce()
        XCTAssertEqual(reaped, [])
        XCTAssertTrue(session.isRunning)

        // Mid-window sweep still holds.
        clock.now += windowMs / 2
        reaped = await reaper.sweepOnce()
        XCTAssertEqual(reaped, [])
        XCTAssertTrue(session.isRunning)

        // Window served with every signal quiet: reaped, and the dormant flag is
        // persisted BEFORE the kill so the exited row reads as sleeping.
        clock.now += windowMs / 2
        reaped = await reaper.sweepOnce()
        XCTAssertEqual(reaped, [session.id])
        XCTAssertEqual(store.get(session.id)?.dormant, true)

        // The normal exit path persists scrollback + exited status underneath.
        for _ in 0..<100 where store.get(session.id)?.status != .exited {
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(store.get(session.id)?.status, .exited)
        XCTAssertEqual(store.get(session.id)?.dormant, true)

        // Waking it through the shared revive path clears the flag.
        let revived = await reviveSession(session.id, registry: registry, store: store,
                                          recoverId: { _, _, _, _ in nil },
                                          needsFreshStart: { _ in false })
        guard case let .success(.resumed(awake)) = revived else {
            return XCTFail("expected revival, got \(revived)")
        }
        defer { awake.kill() }
        XCTAssertTrue(awake.isRunning)
        XCTAssertFalse(awake.meta.dormant)
        XCTAssertEqual(store.get(session.id)?.dormant, false)
    }

    func testSweepSparesSessionWithQueuedMessages() async throws {
        let store = InMemorySessionStore()
        let queue = MessageQueue()
        let registry = SessionRegistry(env: SessionEnvironment(
            resolver: FakeResolver(path: makeScript()),
            store: store,
            messageQueue: queue,
            discoverCodexId: { _, _ in nil }
        ))
        let session = try registry.create(
            provider: .claude, cwd: FileManager.default.temporaryDirectory.path, cols: 80, rows: 24)
        defer { session.kill() }
        await waitForIdle(session)

        let clock = Clock(nowMs())
        let reaper = SessionReaper(
            registry: registry, messageQueue: queue, probes: quietProbes(clock: clock),
            windowMs: windowMs)
        _ = await reaper.sweepOnce()

        // A queued message mid-window makes it ineligible even after the window.
        _ = queue.add(session.id, text: "follow-up")
        clock.now += windowMs
        let reaped = await reaper.sweepOnce()
        XCTAssertEqual(reaped, [])
        XCTAssertTrue(session.isRunning)
        XCTAssertNotEqual(store.get(session.id)?.dormant, true)
    }
}
