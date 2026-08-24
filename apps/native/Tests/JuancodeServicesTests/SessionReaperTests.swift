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

    /// The production sweep cadence. The streak is evidence gathered one sweep at
    /// a time, so tests that ask "would this be reaped" walk a real chain of
    /// samples at this interval rather than comparing two distant timestamps.
    private let sweepMs = 90_000

    /// An all-clear sample: idle, resumable, quiet tree, no recent input, no output.
    private func idleSample(
        activity: SessionActivity = .idle,
        resumable: Bool = true,
        queueEmpty: Bool = true,
        lastInputMs: Int? = nil,
        descendantCount: Int = 3,
        cpuTimeMs: Int = 10_000,
        transcriptSizeBytes: Int? = nil,
        lastOutputMs: Int? = nil,
        outputBytes: Int = 0,
        lastBusyMs: Int = 0,
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
            lastOutputMs: lastOutputMs ?? (t0 - windowMs),
            outputBytes: outputBytes,
            lastBusyMs: lastBusyMs,
            hasPendingToolUse: hasPendingToolUse,
            isProtected: isProtected
        )
    }

    /// Walk a sweep chain from `t0` to `t0 + spanMs`, feeding each sweep the sample
    /// `make(now)` returns and carrying the baseline forward exactly as the reaper
    /// does. Returns the last verdict, so a test asserts on the outcome of a real
    /// observed streak — the only way a session can now become eligible.
    private func walk(
        spanMs: Int,
        stepMs: Int? = nil,
        _ make: (Int) -> ReapSample
    ) -> SessionReapPolicy.Verdict {
        let step = stepMs ?? sweepMs
        var baseline: SessionReapPolicy.Baseline?
        var verdict: SessionReapPolicy.Verdict = .notIdle
        var now = t0
        while true {
            verdict = evaluate(make(now), baseline: baseline, nowMs: now)
            guard case .holding(let b) = verdict else { return verdict }
            baseline = b
            if now >= t0 + spanMs { return verdict }
            now += step
        }
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
        b.quietSamples = base.quietSamples + 1
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
        // A whole chain of quiet sweeps, one sweep short of the window.
        guard case .holding = walk(spanMs: windowMs - sweepMs, { _ in idleSample() }) else {
            return XCTFail("must still be holding before the window is served")
        }
    }

    func testAllClearForFullWindowIsEligible() {
        XCTAssertEqual(walk(spanMs: windowMs, { _ in idleSample() }), .eligible)
    }

    /// The window is elapsed time, which every session shares: one stalled sweep
    /// loop, one clock jump, one settings change and all of them cross it in the
    /// same instant — which is how 25 sessions were judged dormant in one second.
    /// Dormancy therefore also has to be *observed*, `minQuietSamples` times, and
    /// two samples an hour apart are two observations however wide the gap.
    func testWindowServedInTooFewObservedSweepsIsNotEligible() {
        let sparse = walk(spanMs: windowMs * 4, stepMs: windowMs * 2, { _ in idleSample() })
        guard case .holding(let b) = sparse else {
            return XCTFail("a session nobody watched must not be eligible: \(sparse)")
        }
        // Every stride is longer than maxSampleGapMs, so the streak keeps
        // re-anchoring and never accrues either the window or the evidence.
        XCTAssertEqual(b.quietSamples, 1)
    }

    /// The evidence rule on its own, with the gap rule held out of the way: a
    /// streak that has served the window but has only been *seen* twice is not
    /// eligible when three observations are required. Belt to the gap rule's
    /// braces — between them, no shared clock can make a session eligible without
    /// this reaper having watched that session in particular.
    func testTooFewObservationsHoldEvenWithTheWindowServed() {
        let base = SessionReapPolicy.Baseline(
            idleSinceMs: t0, descendantCount: 3, cpuTimeMs: 10_000,
            lastSampleMs: t0 + windowMs - 1_000, quietSamples: 2)
        let verdict = SessionReapPolicy.evaluate(
            idleSample(), baseline: base, nowMs: t0 + windowMs, windowMs: windowMs,
            minQuietSamples: 4)
        guard case .holding(let held) = verdict else {
            return XCTFail("three observations is not four: \(verdict)")
        }
        XCTAssertEqual(held.quietSamples, 3)
        // One more sweep and the same session, unchanged, is eligible.
        XCTAssertEqual(
            SessionReapPolicy.evaluate(idleSample(), baseline: held, nowMs: t0 + windowMs + 1_000,
                                       windowMs: windowMs, minQuietSamples: 4),
            .eligible)
    }

    /// The same clock, the same threshold, but the sweeps actually happened.
    func testEvidenceAccruesOneSweepAtATime() {
        var baseline: SessionReapPolicy.Baseline?
        for i in 0..<3 {
            guard case .holding(let b) = evaluate(idleSample(), baseline: baseline,
                                                  nowMs: t0 + i * sweepMs) else {
                return XCTFail("expected holding at sweep \(i)")
            }
            XCTAssertEqual(b.quietSamples, i + 1)
            baseline = b
        }
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
        XCTAssertEqual(walk(spanMs: windowMs, { _ in idleSample(transcriptSizeBytes: 4_096) }),
                       .eligible)
    }

    func testMissingTranscriptDoesNotBlock() {
        // Unlocatable transcript = no evidence of activity; the other signals guard.
        XCTAssertEqual(walk(spanMs: windowMs, { _ in idleSample(transcriptSizeBytes: nil) }),
                       .eligible)
    }

    // MARK: - output and the detector's memory are liveness, keystrokes are not

    /// The bug oracle-qb5 was filed for. A dispatched agent is typed at exactly
    /// once, when it is created; from then on it works for hours with no input at
    /// all. Keying idleness on input therefore reads "dormant" while it is at its
    /// busiest. What it *does* do is produce output — so a session streaming a
    /// tool's output survives the whole window with an ancient last keystroke.
    func testSessionProducingOutputWithNoInputSurvives() {
        let perSweep = 512 * 1024 // a tool streaming its log: ~5.8 KB/s over 90s
        let verdict = walk(spanMs: windowMs * 2) { now in
            idleSample(
                lastInputMs: t0 - windowMs, // dispatched, never typed at again
                lastOutputMs: now,
                outputBytes: ((now - t0) / self.sweepMs + 1) * perSweep
            )
        }
        guard case .holding(let b) = verdict else {
            return XCTFail("a session producing output is not dormant: \(verdict)")
        }
        // Re-anchored every sweep by the output, so it never accrues a streak.
        XCTAssertEqual(b.quietSamples, 1)
    }

    /// The other half: output that is only a TUI redrawing itself must NOT hold a
    /// session alive, or the reaper stops reaping and the machine goes back to
    /// swapping (the failure mode the old GUI idle sweep had, keyed on lastOutputMs).
    func testTrickleOfRepaintOutputStillReaps() {
        let perSweep = 4 * 1024 // ~45 B/s: a status line, not work
        XCTAssertEqual(
            walk(spanMs: windowMs) { now in
                idleSample(lastOutputMs: now,
                           outputBytes: ((now - t0) / self.sweepMs + 1) * perSweep)
            },
            .eligible)
    }

    /// `activity` is a snapshot: a turn can start and finish inside one 90s sweep
    /// gap, so the sample says idle while the session was working seconds ago.
    /// The detector's own latch is what carries that, and it restarts the streak.
    func testTurnBetweenTwoSweepsRestartsStreak() {
        let brieflyBusyAt = t0 + windowMs / 2
        let verdict = walk(spanMs: windowMs) { now in
            idleSample(lastBusyMs: now > brieflyBusyAt ? brieflyBusyAt : 0)
        }
        guard case .holding(let b) = verdict else {
            return XCTFail("a session that worked mid-window is not dormant: \(verdict)")
        }
        XCTAssertGreaterThan(b.idleSinceMs, brieflyBusyAt)
    }

    func testBusyLatchOlderThanTheStreakDoesNotBlock() {
        // It worked before the streak began — that is what "idle since" means.
        XCTAssertEqual(walk(spanMs: windowMs, { _ in idleSample(lastBusyMs: t0 - 1) }), .eligible)
    }

    // MARK: - exemptions

    func testUnresumableSessionIsExemptEvenAfterFullWindow() {
        // Codex discovers its id late; killing before capture loses the conversation.
        guard case .holding = walk(spanMs: windowMs * 2, { _ in idleSample(resumable: false) }) else {
            return XCTFail("an unresumable session must never be eligible")
        }
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
        guard case .holding = walk(spanMs: windowMs - 2 * sweepMs,
                                   { _ in idleSample(lastInputMs: t0 - 1000) }) else {
            return XCTFail("a keystroke younger than the window must hold")
        }
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

    /// Run the sweeps a real 90s-cadence reaper would run across `spanMs`, moving
    /// the fake clock between them, and return every id slept along the way. A
    /// single sweep with a jumped clock can no longer reap anything — dormancy is
    /// evidence gathered sweep by sweep — so integration tests drive the chain.
    @discardableResult
    private func runSweeps(
        _ reaper: SessionReaper, _ clock: Clock, spanMs: Int
    ) async -> [String] {
        var slept: [String] = []
        var elapsed = 0
        while elapsed <= spanMs {
            slept.append(contentsOf: await reaper.sweepOnce())
            clock.now += sweepMs
            elapsed += sweepMs
        }
        return slept
    }

    /// Captures the activity-log lines the reap path writes.
    private final class FakeLog: SessionActivityLogging, @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [(event: String, session: String, fields: [String: String])] = []
        func log(_ event: String, sessionId: String, project: String, fields: [String: String]) {
            lock.withLock { lines.append((event, sessionId, fields)) }
        }
        func all(_ event: String) -> [(event: String, session: String, fields: [String: String])] {
            lock.withLock { lines.filter { $0.event == event } }
        }
        func first(_ event: String, session: String) -> [String: String]? {
            lock.withLock { lines.first { $0.event == event && $0.session == session }?.fields }
        }
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

        // Sweeps across half the window: quiet, observed, but not yet served.
        var reaped = await runSweeps(reaper, clock, spanMs: windowMs / 2)
        XCTAssertEqual(reaped, [])
        XCTAssertTrue(session.isRunning)

        // Window served with every signal quiet: reaped, and the dormant flag is
        // persisted BEFORE the kill so the exited row reads as sleeping.
        reaped = await runSweeps(reaper, clock, spanMs: windowMs)
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
        let reaped = await runSweeps(reaper, clock, spanMs: windowMs * 2)
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
        // …and once the window has been served and observed, it sleeps.
        reaped = await runSweeps(reaper, clock, spanMs: windowMs)
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
        var reaped = await runSweeps(reaper, clock, spanMs: windowMs * 3)
        XCTAssertEqual(reaped, [])
        XCTAssertTrue(session.isRunning)
        XCTAssertNotEqual(store.get(session.id)?.dormant, true)

        // Navigate away and it is an ordinary candidate again — from a FRESH window,
        // not the streak it accrued while protected.
        await reaper.setProtectedIds([])
        reaped = await reaper.sweepOnce()
        XCTAssertEqual(reaped, [])
        reaped = await runSweeps(reaper, clock, spanMs: windowMs)
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
        var reaped = await runSweeps(reaper, clock, spanMs: windowMs - sweepMs)
        XCTAssertEqual(reaped, [])
        XCTAssertTrue(session.isRunning)

        reaped = await runSweeps(reaper, clock, spanMs: windowMs)
        XCTAssertEqual(reaped, [session.id])
    }
    // MARK: - the kill-time re-check (why a focused pane died anyway)

    /// A lock-guarded set the fake `isProtected` probe reads, so a test can change
    /// what is protected *synchronously* from inside a probe call — i.e. midway
    /// through a sweep.
    private final class ProtectionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<String> = []
        func set(_ ids: Set<String>) { lock.withLock { self.ids = ids } }
        func contains(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.withLock { n += 1; return n } }
        func reset() { lock.withLock { n = 0 } }
    }

    /// The second half of oracle-qb5: the focused pane was reaped even though
    /// `ReapSample.isProtected` existed. Protection being *sampled* is not enough —
    /// a sweep awaits a transcript stat per session, so the verdict for the first
    /// session is already stale by the time the loop reaches the kill, and anything
    /// that changed in between (you opened that pane, the agent started a turn, a
    /// message was queued) is invisible to it. So the kill re-checks.
    func testProtectionArrivingMidSweepStillSavesTheSession() async throws {
        let store = InMemorySessionStore()
        let queue = MessageQueue()
        let log = FakeLog()
        let registry = SessionRegistry(env: SessionEnvironment(
            resolver: FakeResolver(path: makeScript()),
            store: store,
            messageQueue: queue,
            discoverCliSessionId: { _, _, _ in nil },
            log: log
        ))
        let cwd = FileManager.default.temporaryDirectory.path
        let first = try registry.create(provider: .claude, cwd: cwd, cols: 80, rows: 24)
        defer { first.kill() }
        let second = try registry.create(provider: .claude, cwd: cwd, cols: 80, rows: 24)
        defer { second.kill() }
        await waitForIdle(first)
        await waitForIdle(second)

        let clock = Clock(nowMs())
        let protection = ProtectionBox()
        let stats = Counter()
        let armed = ProtectionBox() // reused as a flag holder
        let ids: Set<String> = [first.id, second.id]
        // The transcript stat is the sweep's suspension point. On the armed sweep,
        // protect everything while the second session is being stat'd — by then the
        // first session has already been sampled as unprotected and eligible.
        let probes = SessionReaperProbes(
            nowMs: { clock.now },
            descendantCount: { _ in 2 },
            treeCpuTimeMs: { _ in 100 },
            transcriptSizeBytes: { _, _ in
                if armed.contains("go"), stats.next() == 2 { protection.set(ids) }
                return nil
            },
            isProtected: { protection.contains($0) }
        )
        let reaper = SessionReaper(registry: registry, messageQueue: queue, probes: probes,
                                   windowMs: windowMs, maxLive: 0, log: log)

        // Serve the window with nothing protected, stopping one sweep short.
        let reaped = await runSweeps(reaper, clock, spanMs: windowMs - sweepMs)
        XCTAssertEqual(reaped, [])

        // Now the sweep that would kill them both — with protection landing inside it.
        stats.reset()
        armed.set(["go"])
        let lastSweep = await reaper.sweepOnce()
        XCTAssertEqual(lastSweep, [], "a protected session must not be reaped")
        XCTAssertTrue(first.isRunning)
        XCTAssertTrue(second.isRunning)
        // And the save is auditable: the one that got as far as the kill says why.
        let skips = log.all("reap_skipped")
        XCTAssertEqual(skips.count, 1)
        XCTAssertEqual(skips.first?.fields["veto"], "protected")
    }

    /// The same re-check, for work rather than focus: a message queued while the
    /// sweep is mid-flight means a delivery is imminent, and killing there strands it.
    func testMessageQueuedMidSweepStillSavesTheSession() async throws {
        let store = InMemorySessionStore()
        let queue = MessageQueue()
        let log = FakeLog()
        let registry = SessionRegistry(env: SessionEnvironment(
            resolver: FakeResolver(path: makeScript()),
            store: store,
            messageQueue: queue,
            discoverCliSessionId: { _, _, _ in nil },
            log: log
        ))
        let cwd = FileManager.default.temporaryDirectory.path
        let first = try registry.create(provider: .claude, cwd: cwd, cols: 80, rows: 24)
        defer { first.kill() }
        let second = try registry.create(provider: .claude, cwd: cwd, cols: 80, rows: 24)
        defer { second.kill() }
        await waitForIdle(first)
        await waitForIdle(second)

        let clock = Clock(nowMs())
        let stats = Counter()
        let armed = ProtectionBox()
        let probes = SessionReaperProbes(
            nowMs: { clock.now },
            descendantCount: { _ in 2 },
            treeCpuTimeMs: { _ in 100 },
            transcriptSizeBytes: { _, _ in
                if armed.contains("go"), stats.next() == 2 {
                    _ = queue.add(first.id, text: "one more thing")
                    _ = queue.add(second.id, text: "one more thing")
                }
                return nil
            }
        )
        let reaper = SessionReaper(registry: registry, messageQueue: queue, probes: probes,
                                   windowMs: windowMs, maxLive: 0, log: log)
        let served = await runSweeps(reaper, clock, spanMs: windowMs - sweepMs)
        XCTAssertEqual(served, [])

        stats.reset()
        armed.set(["go"])
        let lastSweep = await reaper.sweepOnce()
        XCTAssertEqual(lastSweep, [])
        XCTAssertTrue(first.isRunning)
        XCTAssertTrue(second.isRunning)
        XCTAssertEqual(log.all("reap_skipped").first?.fields["veto"], "queued")
    }

    // MARK: - no bulk sweeps

    /// 25 sessions died in the same second. Whatever judged them, one sweep must
    /// not be able to do that: the per-sweep budget caps it, and the rest keep
    /// their streaks and go one sweep later — a trickle a human can watch and stop.
    func testOneSweepNeverSleepsMoreThanItsBudget() async throws {
        let store = InMemorySessionStore()
        let queue = MessageQueue()
        let registry = SessionRegistry(env: SessionEnvironment(
            resolver: FakeResolver(path: makeScript()),
            store: store,
            messageQueue: queue,
            discoverCliSessionId: { _, _, _ in nil }
        ))
        let cwd = FileManager.default.temporaryDirectory.path
        var sessions: [Session] = []
        for _ in 0..<5 {
            sessions.append(try registry.create(provider: .claude, cwd: cwd, cols: 80, rows: 24))
        }
        defer { for s in sessions { s.kill() } }
        for s in sessions { await waitForIdle(s) }

        let clock = Clock(nowMs())
        let reaper = SessionReaper(
            registry: registry, messageQueue: queue, probes: quietProbes(clock: clock),
            windowMs: windowMs, maxLive: 0, maxSleepsPerSweep: 2)

        // Every one of them is equally, genuinely idle: the shared-threshold case.
        var perSweep: [Int] = []
        var slept: Set<String> = []
        for _ in 0...(windowMs / sweepMs + 4) {
            let batch = await reaper.sweepOnce()
            perSweep.append(batch.count)
            slept.formUnion(batch)
            clock.now += sweepMs
        }
        XCTAssertEqual(slept.count, 5, "all five are idle, so all five eventually sleep")
        XCTAssertLessThanOrEqual(perSweep.max() ?? 0, 2, "no sweep may exceed its budget")
        XCTAssertGreaterThanOrEqual(perSweep.filter { $0 > 0 }.count, 3,
                                    "five sessions at two per sweep is at least three sweeps")
    }

    // MARK: - the audit trail

    /// Every kill has to explain itself in `session-activity.log`, or the next
    /// occurrence costs another forensic session reconstructing the live set from
    /// spawn/exit events. One line, with the evidence that justified it.
    func testEveryReapWritesItsEvidence() async throws {
        let store = InMemorySessionStore()
        let queue = MessageQueue()
        let log = FakeLog()
        let registry = SessionRegistry(env: SessionEnvironment(
            resolver: FakeResolver(path: makeScript()),
            store: store,
            messageQueue: queue,
            discoverCliSessionId: { _, _, _ in nil },
            log: log
        ))
        let session = try registry.create(
            provider: .claude, cwd: FileManager.default.temporaryDirectory.path, cols: 80, rows: 24)
        defer { session.kill() }
        await waitForIdle(session)

        let clock = Clock(nowMs())
        let reaper = SessionReaper(
            registry: registry, messageQueue: queue, probes: quietProbes(clock: clock),
            windowMs: windowMs, maxLive: 0, log: log)
        let reaped = await runSweeps(reaper, clock, spanMs: windowMs)
        XCTAssertEqual(reaped, [session.id])

        guard let fields = log.first("dormant", session: session.id) else {
            return XCTFail("a reap with no log line is the bug this ticket is about")
        }
        XCTAssertEqual(fields["reason"], SessionSleepReason.idleReap.rawValue)
        XCTAssertEqual(fields["activity"], "idle")
        XCTAssertEqual(fields["windowMs"], "\(windowMs)")
        XCTAssertGreaterThanOrEqual(Int(fields["idleMs"] ?? "0") ?? 0, windowMs)
        XCTAssertGreaterThanOrEqual(Int(fields["samples"] ?? "0") ?? 0,
                                    SessionReapPolicy.defaultMinQuietSamples)
        for key in ["inputAgeMs", "outputAgeMs", "busyAgeMs", "descendants", "cpuMs",
                    "outputBytes", "toolOpen", "protected"] {
            XCTAssertNotNil(fields[key], "missing audit field \(key)")
        }
        // And the sweep itself is on the record, so a kill has a denominator.
        let sweeps = log.all("reap_sweep")
        XCTAssertFalse(sweeps.isEmpty)
        XCTAssertEqual(sweeps.last?.fields["reaped"], "1")
        XCTAssertEqual(sweeps.last?.fields["live"], "1")
    }

    /// A quit is not a reap. Both used to write the same bare `dormant` line, which
    /// is what made an interrupted bulk quit indistinguishable from the reaper
    /// having judged 25 sessions dormant.
    func testQuitSleepIsLabelledDifferentlyFromAReap() async throws {
        let log = FakeLog()
        let registry = SessionRegistry(env: SessionEnvironment(
            resolver: FakeResolver(path: makeScript()),
            store: InMemorySessionStore(),
            messageQueue: MessageQueue(),
            discoverCliSessionId: { _, _, _ in nil },
            log: log
        ))
        let session = try registry.create(
            provider: .claude, cwd: FileManager.default.temporaryDirectory.path, cols: 80, rows: 24)
        defer { session.kill() }
        await waitForIdle(session)

        session.markDormant(reason: .quit, audit: ["activity": session.activity.rawValue])
        XCTAssertEqual(log.first("dormant", session: session.id)?["reason"],
                       SessionSleepReason.quit.rawValue)
    }
}
