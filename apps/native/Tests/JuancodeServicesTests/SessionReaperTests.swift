import XCTest
import JuancodeCore
@testable import JuancodeServices

/// The idle-reaper eligibility state machine (juancode-lgq): every independent
/// signal — detector state, message queue, process-tree shape, CPU rate,
/// transcript size, keystrokes, resumability — must hold for the full window
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
        transcriptSizeBytes: Int? = nil,
        hasPendingToolUse: Bool = false,
        isProtected: Bool = false
    ) -> ReapSample {
        ReapSample(
            activity: activity,
            resumable: resumable,
            queueEmpty: queueEmpty,
            lastInputMs: lastInputMs ?? (t0 - windowMs), // long before the streak
            descendantCount: descendantCount,
            cpuTimeMs: cpuTimeMs,
            transcriptSizeBytes: transcriptSizeBytes,
            hasPendingToolUse: hasPendingToolUse,
            isProtected: isProtected
        )
    }

    /// The baseline a first all-clear sweep at `t0` captures.
    private var baseAtT0: SessionReapPolicy.Baseline {
        SessionReapPolicy.Baseline(idleSinceMs: t0, descendantCount: 3, cpuTimeMs: 10_000)
    }

    /// The `.holding` verdict for an intact streak: same anchor, but the sample
    /// point has advanced to this sweep (the CPU rate is measured sweep-to-sweep).
    private func holding(
        _ base: SessionReapPolicy.Baseline, sampledAt: Int, cpu: Int = 10_000
    ) -> SessionReapPolicy.Verdict {
        var b = base
        b.lastSampleMs = sampledAt
        b.lastSampleCpuMs = cpu
        return .holding(b)
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

    func testOpenToolCallIsNeverEligible() {
        // A delegated subagent past ActivityDetector's 30-min hold cap reads as
        // .idle while it is still running — the open call is its own veto.
        XCTAssertEqual(
            evaluate(idleSample(hasPendingToolUse: true), baseline: baseAtT0, nowMs: t0 + windowMs),
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
        let now = t0 + windowMs - 1
        XCTAssertEqual(evaluate(idleSample(), baseline: baseAtT0, nowMs: now),
                       holding(baseAtT0, sampledAt: now))
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

    func testCpuRateAboveBusyThresholdRestartsStreak() {
        // 60s of CPU across a 90s sweep = 67% of a core: real local compute.
        let sweep = 90_000
        let now = t0 + sweep
        let moved = 10_000 + 60_000
        XCTAssertEqual(
            evaluate(idleSample(cpuTimeMs: moved), baseline: baseAtT0, nowMs: now),
            .holding(.init(idleSinceMs: now, descendantCount: 3, cpuTimeMs: moved))
        )
    }

    func testCpuDeltaUnderTheFloorIsNeverBusy() {
        // Two sweeps landing close together: the rate divisor is tiny, so only the
        // floor stops jitter reading as work.
        let now = t0 + 100
        let sample = idleSample(cpuTimeMs: 10_000 + SessionReapPolicy.defaultCpuFloorMs - 1)
        XCTAssertEqual(evaluate(sample, baseline: baseAtT0, nowMs: now),
                       holding(baseAtT0, sampledAt: now, cpu: sample.cpuTimeMs))
    }

    /// Regression for juancode-ts9n. An idle CLI is not a quiet process: it keeps
    /// repainting its TUI at a measured ~6% of a core, forever. Under the old rule
    /// (absolute 5s of CPU since idle-entry) that spent the whole budget in ~90s
    /// and re-anchored the streak every sweep, so no session was ever reaped —
    /// 47 stayed live, 12.4GB of footprint, 20GB of swap. Walk the real sweep
    /// chain at that rate and require eligibility at the end of the window.
    func testIdleRepaintRateSurvivesTheWholeWindow() {
        let sweep = 90_000
        let permilleOfCore = 58 // 5.8% — the measured median
        var baseline: SessionReapPolicy.Baseline?
        var cpu = 10_000
        var now = t0
        var verdict: SessionReapPolicy.Verdict = .notIdle
        while now <= t0 + windowMs {
            verdict = evaluate(idleSample(cpuTimeMs: cpu), baseline: baseline, nowMs: now)
            if case .holding(let b) = verdict { baseline = b } else { break }
            now += sweep
            cpu += sweep * permilleOfCore / 1_000
        }
        XCTAssertEqual(verdict, .eligible)
    }

    func testTranscriptGrewSinceIdleEntryRestartsStreak() {
        // Thinking/delegation writes transcript records the screen doesn't show.
        let now = t0 + windowMs
        let base = SessionReapPolicy.Baseline(
            idleSinceMs: t0, descendantCount: 3, cpuTimeMs: 10_000, transcriptSizeBytes: 4_096)
        XCTAssertEqual(
            evaluate(idleSample(transcriptSizeBytes: 4_097), baseline: base, nowMs: now),
            .holding(.init(idleSinceMs: now, descendantCount: 3, cpuTimeMs: 10_000,
                           transcriptSizeBytes: 4_097))
        )
    }

    func testUnchangedTranscriptStaysEligible() {
        // The file is also touched on flushes that append no records — mtime moves,
        // size doesn't, and only size means the agent produced something.
        let base = SessionReapPolicy.Baseline(
            idleSinceMs: t0, descendantCount: 3, cpuTimeMs: 10_000, transcriptSizeBytes: 4_096)
        let sample = idleSample(transcriptSizeBytes: 4_096)
        XCTAssertEqual(evaluate(sample, baseline: base, nowMs: t0 + windowMs), .eligible)
    }

    func testMissingTranscriptDoesNotBlock() {
        // Unlocatable transcript = no evidence of activity; the other signals guard.
        XCTAssertEqual(evaluate(idleSample(transcriptSizeBytes: nil), baseline: baseAtT0,
                                nowMs: t0 + windowMs),
                       .eligible)
    }

    // MARK: - exemptions

    func testUnresumableSessionIsExemptEvenAfterFullWindow() {
        // Codex discovers its id late; killing before capture loses the conversation.
        XCTAssertEqual(evaluate(idleSample(resumable: false), baseline: baseAtT0, nowMs: t0 + windowMs),
                       holding(baseAtT0, sampledAt: t0 + windowMs))
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
        XCTAssertEqual(evaluate(sample, baseline: base, nowMs: t0 + windowMs - 2000),
                       holding(base, sampledAt: t0 + windowMs - 2000))
    }

    // MARK: - live-session cap

    private func candidate(_ id: String, _ lastActiveMs: Int, sleepable: Bool = true)
        -> SessionCapPolicy.Candidate {
        .init(id: id, lastActiveMs: lastActiveMs, sleepable: sleepable)
    }

    func testCapIsOffWhenUnderTheCeiling() {
        let live = [candidate("a", t0), candidate("b", t0 + 1)]
        XCTAssertEqual(SessionCapPolicy.surplus(live, maxLive: 5), [])
    }

    func testCapSleepsLeastRecentlyActiveFirst() {
        let live = [candidate("new", t0 + 300), candidate("old", t0), candidate("mid", t0 + 100)]
        XCTAssertEqual(SessionCapPolicy.surplus(live, maxLive: 2), ["old"])
    }

    func testCapSkipsBusySessionsButStillCountsThem() {
        // A busy session holds the RAM, so it counts toward the ceiling — but
        // sleeping it would kill live work, so it is never the one chosen.
        let live = [candidate("busy", t0, sleepable: false),
                    candidate("idle-old", t0 + 1),
                    candidate("idle-new", t0 + 2)]
        XCTAssertEqual(SessionCapPolicy.surplus(live, maxLive: 2), ["idle-old"])
    }

    func testCapNeverExceedsSleepableCandidates() {
        // Over cap but everything is working: stay over cap rather than kill work.
        let live = [candidate("a", t0, sleepable: false), candidate("b", t0 + 1, sleepable: false)]
        XCTAssertEqual(SessionCapPolicy.surplus(live, maxLive: 1), [])
    }

    func testCapDisabledAtZero() {
        let live = [candidate("a", t0), candidate("b", t0 + 1), candidate("c", t0 + 2)]
        XCTAssertEqual(SessionCapPolicy.surplus(live, maxLive: 0), [])
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
            transcriptSizeBytes: { _, _ in nil }
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
            discoverCliSessionId: { _, _, _ in nil }
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
            discoverCliSessionId: { _, _, _ in nil }
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

    // MARK: - settings-driven window (setIdleWindow)

    func testDisabledWindowSweepsNothing() async throws {
        let store = InMemorySessionStore()
        let queue = MessageQueue()
        let registry = SessionRegistry(env: SessionEnvironment(
            resolver: FakeResolver(path: makeScript()),
            store: store,
            messageQueue: queue,
            discoverCliSessionId: { _, _, _ in nil }
        ))
        let session = try registry.create(
            provider: .claude, cwd: FileManager.default.temporaryDirectory.path, cols: 80, rows: 24)
        defer { session.kill() }
        await waitForIdle(session)

        // 0 = the Settings toggle off: nothing is ever reaped, however long idle.
        let clock = Clock(nowMs())
        let reaper = SessionReaper(
            registry: registry, messageQueue: queue, probes: quietProbes(clock: clock),
            windowMs: 0)
        _ = await reaper.sweepOnce()
        clock.now += 24 * 60 * 60 * 1000
        let reaped = await reaper.sweepOnce()
        XCTAssertEqual(reaped, [])
        XCTAssertTrue(session.isRunning)
        XCTAssertNotEqual(store.get(session.id)?.dormant, true)
    }

    func testSetIdleWindowDrivesReapingLive() async throws {
        let store = InMemorySessionStore()
        let queue = MessageQueue()
        let registry = SessionRegistry(env: SessionEnvironment(
            resolver: FakeResolver(path: makeScript()),
            store: store,
            messageQueue: queue,
            discoverCliSessionId: { _, _, _ in nil }
        ))
        let session = try registry.create(
            provider: .claude, cwd: FileManager.default.temporaryDirectory.path, cols: 80, rows: 24)
        defer { session.kill() }
        await waitForIdle(session)

        // Born disabled (the persisted setting), enabled at runtime by Settings.
        let clock = Clock(nowMs())
        let reaper = SessionReaper(
            registry: registry, messageQueue: queue, probes: quietProbes(clock: clock),
            windowMs: 0)
        clock.now += windowMs
        var reaped = await reaper.sweepOnce()
        XCTAssertEqual(reaped, [])

        await reaper.setIdleWindow(minutes: windowMs / 60_000)
        // First enabled sweep only captures the baseline…
        reaped = await reaper.sweepOnce()
        XCTAssertEqual(reaped, [])
        XCTAssertTrue(session.isRunning)
        // …and once the window is served, the session is reaped to dormant.
        clock.now += windowMs
        reaped = await reaper.sweepOnce()
        XCTAssertEqual(reaped, [session.id])
        XCTAssertEqual(store.get(session.id)?.dormant, true)
    }

    // MARK: - never-sleep set (the open pane / the active Oracle)

    func testProtectedSessionSurvivesTheIdleWindow() async throws {
        let store = InMemorySessionStore()
        let queue = MessageQueue()
        let registry = SessionRegistry(env: SessionEnvironment(
            resolver: FakeResolver(path: makeScript()),
            store: store,
            messageQueue: queue,
            discoverCliSessionId: { _, _, _ in nil }
        ))
        let session = try registry.create(
            provider: .claude, cwd: FileManager.default.temporaryDirectory.path, cols: 80, rows: 24)
        defer { session.kill() }
        await waitForIdle(session)

        let clock = Clock(nowMs())
        let reaper = SessionReaper(
            registry: registry, messageQueue: queue, probes: quietProbes(clock: clock),
            windowMs: windowMs, maxLive: 0)
        await reaper.setProtectedIds([session.id])

        // Idle for days: the pane you have open (or the Oracle you are talking to)
        // is never slept, however long it sits.
        _ = await reaper.sweepOnce()
        clock.now += windowMs * 10
        var reaped = await reaper.sweepOnce()
        XCTAssertEqual(reaped, [])
        XCTAssertTrue(session.isRunning)
        XCTAssertNotEqual(store.get(session.id)?.dormant, true)

        // Navigate away and it is an ordinary candidate again — from a FRESH window,
        // not the streak it accrued while protected.
        await reaper.setProtectedIds([])
        reaped = await reaper.sweepOnce()
        XCTAssertEqual(reaped, [])
        clock.now += windowMs
        reaped = await reaper.sweepOnce()
        XCTAssertEqual(reaped, [session.id])
        XCTAssertEqual(store.get(session.id)?.dormant, true)
    }

    func testCapSkipsProtectedSessionAndSleepsTheNextOne() async throws {
        let store = InMemorySessionStore()
        let queue = MessageQueue()
        let registry = SessionRegistry(env: SessionEnvironment(
            resolver: FakeResolver(path: makeScript()),
            store: store,
            messageQueue: queue,
            discoverCliSessionId: { _, _, _ in nil }
        ))
        let cwd = FileManager.default.temporaryDirectory.path
        let openPane = try registry.create(provider: .claude, cwd: cwd, cols: 80, rows: 24)
        defer { openPane.kill() }
        let background = try registry.create(provider: .claude, cwd: cwd, cols: 80, rows: 24)
        defer { background.kill() }
        await waitForIdle(openPane)
        await waitForIdle(background)

        // Window off, cap at one: the LRU rule alone decides. The protected pane is
        // not a candidate at all — however stale it looks — so the cap reclaims the
        // background session to get back under the ceiling.
        let clock = Clock(nowMs())
        let reaper = SessionReaper(
            registry: registry, messageQueue: queue, probes: quietProbes(clock: clock),
            windowMs: 0, maxLive: 1)
        await reaper.setProtectedIds([openPane.id])
        let reaped = await reaper.sweepOnce()
        XCTAssertEqual(reaped, [background.id])
        XCTAssertTrue(openPane.isRunning)
        XCTAssertNotEqual(store.get(openPane.id)?.dormant, true)
    }

    func testDisablingMidStreakDropsTheBaseline() async throws {
        let store = InMemorySessionStore()
        let queue = MessageQueue()
        let registry = SessionRegistry(env: SessionEnvironment(
            resolver: FakeResolver(path: makeScript()),
            store: store,
            messageQueue: queue,
            discoverCliSessionId: { _, _, _ in nil }
        ))
        let session = try registry.create(
            provider: .claude, cwd: FileManager.default.temporaryDirectory.path, cols: 80, rows: 24)
        defer { session.kill() }
        await waitForIdle(session)

        let clock = Clock(nowMs())
        let reaper = SessionReaper(
            registry: registry, messageQueue: queue, probes: quietProbes(clock: clock),
            windowMs: windowMs)
        _ = await reaper.sweepOnce() // baseline captured

        // Toggle off, then back on past the original window: the old streak must
        // not survive the disabled gap — the session needs a fresh full window.
        await reaper.setIdleWindow(minutes: 0)
        _ = await reaper.sweepOnce()
        await reaper.setIdleWindow(minutes: windowMs / 60_000)
        clock.now += windowMs * 2
        var reaped = await reaper.sweepOnce()
        XCTAssertEqual(reaped, [])
        XCTAssertTrue(session.isRunning)

        clock.now += windowMs
        reaped = await reaper.sweepOnce()
        XCTAssertEqual(reaped, [session.id])
    }
}
