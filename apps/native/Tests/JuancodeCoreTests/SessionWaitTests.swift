import XCTest
@testable import JuancodeCore

/// The wait primitive (juancode-9umy): block until the session's screen shows
/// text or its output goes quiet, with the four outcomes kept distinct.
///
/// Driven through `SessionWaitProbe`, so every case here is a real run of the
/// engine's loop against a scripted session — no pty, no CLI, no sleep budget
/// beyond a few hundred ms.
final class SessionWaitTests: XCTestCase {
    // MARK: - grid fixtures

    private static func row(_ s: String, cols: Int) -> TerminalRow {
        var cells = s.map { TerminalCell(char: $0, width: 1, fg: .default, bg: .default, style: []) }
        while cells.count < cols {
            cells.append(TerminalCell(char: " ", width: 1, fg: .default, bg: .default, style: []))
        }
        var text = s
        while text.last == " " { text.removeLast() }
        return TerminalRow(cells: cells, text: text)
    }

    private static func screen(_ lines: [String], cols: Int = 20) -> TerminalSnapshot {
        TerminalSnapshot(cols: cols, rows: lines.count,
                         lines: lines.map { row($0, cols: cols) },
                         cursorX: 0, cursorY: 0, cursorVisible: true, isAlternateBuffer: false)
    }

    /// A session whose liveness, last-output time and screen are functions of the
    /// clock, so a test states "the text lands 150ms in" without spawning anything.
    private struct Script: Sendable {
        var startedMs: Int
        var probe: SessionWaitProbe
    }

    private static func script(
        screenAt: @escaping @Sendable (_ elapsedMs: Int) -> TerminalSnapshot = { _ in SessionWaitTests.screen(["idle"]) },
        outputUntilMs: Int = 0,
        exitsAtMs: Int? = nil,
        scrollbackRows: @escaping @Sendable (_ elapsedMs: Int) -> Int = { _ in 0 },
        scrollbackTail: @escaping @Sendable (_ elapsedMs: Int, _ count: Int) -> [TerminalRow] = { _, _ in [] }
    ) -> Script {
        let started = nowMs()
        let elapsed: @Sendable () -> Int = { nowMs() - started }
        return Script(startedMs: started, probe: SessionWaitProbe(
            isRunning: { exitsAtMs.map { elapsed() < $0 } ?? true },
            // Output keeps arriving until `outputUntilMs`, then stops dead.
            lastOutputMs: { started + min(elapsed(), outputUntilMs) },
            screen: { screenAt(elapsed()) },
            scrollbackRows: { scrollbackRows(elapsed()) },
            scrollbackTail: { scrollbackTail(elapsed(), $0) }))
    }

    // MARK: - text

    func testTextAlreadyOnScreenMatchesImmediately() async {
        let s = Self.script(screenAt: { _ in Self.screen(["$ make", "build ok"]) })
        let outcome = await SessionWait.run(condition: .text("build ok"), timeoutMs: 1_000, probe: s.probe)
        XCTAssertEqual(outcome, .matched)
        XCTAssertLessThan(nowMs() - s.startedMs, 200)
    }

    func testTextAppearsAfterDelay() async {
        let s = Self.script(screenAt: { elapsed in
            Self.screen(elapsed < 150 ? ["$ make", "compiling"] : ["$ make", "build ok"])
        })
        let outcome = await SessionWait.run(condition: .text("build ok"), timeoutMs: 3_000, probe: s.probe)
        XCTAssertEqual(outcome, .matched)
        XCTAssertGreaterThanOrEqual(nowMs() - s.startedMs, 140)
    }

    func testTextNeverAppearsTimesOut() async {
        let s = Self.script(screenAt: { _ in Self.screen(["compiling"]) })
        let outcome = await SessionWait.run(condition: .text("build ok"), timeoutMs: 250, probe: s.probe)
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertGreaterThanOrEqual(nowMs() - s.startedMs, 240)
    }

    /// A needle the terminal wrapped across two rows still matches: the rows are
    /// flowed back together at full width.
    func testWrappedLineMatches() async {
        let s = Self.script(screenAt: { _ in Self.screen(["the quick brown fox", "jumps over"], cols: 19) })
        let outcome = await SessionWait.run(condition: .text("brown foxjumps"), timeoutMs: 200, probe: s.probe)
        XCTAssertEqual(outcome, .matched)
    }

    /// ...but two visually separate short lines are not silently joined into one.
    func testSeparateShortLinesAreNotJoined() async {
        let s = Self.script(screenAt: { _ in Self.screen(["foo", "bar"]) })
        let outcome = await SessionWait.run(condition: .text("foobar"), timeoutMs: 150, probe: s.probe)
        XCTAssertEqual(outcome, .timedOut)
    }

    func testNeedleSpanningLinesMatchesAcrossTheNewline() async {
        let s = Self.script(screenAt: { _ in Self.screen(["foo", "bar"]) })
        let outcome = await SessionWait.run(condition: .text("foo\nbar"), timeoutMs: 200, probe: s.probe)
        XCTAssertEqual(outcome, .matched)
    }

    /// Output that scrolled off the screen between two polls still matches: the
    /// engine re-reads the history rows that arrived since the last look.
    func testTextThatScrolledOffStillMatches() async {
        let s = Self.script(
            screenAt: { _ in Self.screen(["$ ", ""]) },
            scrollbackRows: { elapsed in elapsed < 150 ? 0 : 3 },
            scrollbackTail: { elapsed, count in
                guard elapsed >= 150 else { return [] }
                return Array(["one", "PASSED 42 tests", "three"].suffix(count)).map { Self.row($0, cols: 20) }
            })
        let outcome = await SessionWait.run(condition: .text("PASSED 42 tests"), timeoutMs: 3_000, probe: s.probe)
        XCTAssertEqual(outcome, .matched)
    }

    // MARK: - idle

    func testIdleMatchesOnceOutputStops() async {
        let s = Self.script(outputUntilMs: 0)
        let outcome = await SessionWait.run(condition: .idle(ms: 100), timeoutMs: 3_000, probe: s.probe)
        XCTAssertEqual(outcome, .matched)
        XCTAssertGreaterThanOrEqual(nowMs() - s.startedMs, 90)
    }

    /// The window is measured from the LAST byte, so output arriving mid-window
    /// pushes the match out rather than letting a stale window expire.
    func testIdleWindowResetsOnNewOutput() async {
        let s = Self.script(outputUntilMs: 250)
        let outcome = await SessionWait.run(condition: .idle(ms: 150), timeoutMs: 5_000, probe: s.probe)
        XCTAssertEqual(outcome, .matched)
        // 250ms of output + a fresh 150ms of quiet. A window that had not reset
        // would have matched at ~150ms.
        XCTAssertGreaterThanOrEqual(nowMs() - s.startedMs, 380)
    }

    func testIdleTimesOutWhileOutputKeepsComing() async {
        let s = Self.script(outputUntilMs: 10_000)
        let outcome = await SessionWait.run(condition: .idle(ms: 200), timeoutMs: 300, probe: s.probe)
        XCTAssertEqual(outcome, .timedOut)
    }

    // MARK: - liveness

    func testSessionExitsMidWait() async {
        let s = Self.script(screenAt: { _ in Self.screen(["running"]) }, outputUntilMs: 10_000, exitsAtMs: 120)
        let outcome = await SessionWait.run(condition: .text("never"), timeoutMs: 5_000, probe: s.probe)
        XCTAssertEqual(outcome, .sessionExited)
        XCTAssertLessThan(nowMs() - s.startedMs, 1_000)
    }

    /// A session that exits with the text already on screen matched — the
    /// condition is read before liveness, so the answer describes the screen
    /// rather than the corpse.
    func testExitWithTheTextOnScreenStillMatches() async {
        let s = Self.script(screenAt: { _ in Self.screen(["done: 0 failures"]) }, exitsAtMs: 0)
        let outcome = await SessionWait.run(condition: .text("0 failures"), timeoutMs: 500, probe: s.probe)
        XCTAssertEqual(outcome, .matched)
    }

    func testCancellationEndsTheWait() async {
        let s = Self.script(screenAt: { _ in Self.screen(["nothing"]) })
        let task = Task { await SessionWait.run(condition: .text("never"), timeoutMs: 60_000, probe: s.probe) }
        await Nap.ms(60)
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(nowMs() - s.startedMs, 5_000)
    }

    // MARK: - durations

    func testDurationGrammar() {
        XCTAssertEqual(WaitDuration.ms("500ms"), 500)
        XCTAssertEqual(WaitDuration.ms("2s"), 2_000)
        XCTAssertEqual(WaitDuration.ms("1m"), 60_000)
        XCTAssertEqual(WaitDuration.ms("4h"), 14_400_000)
        XCTAssertEqual(WaitDuration.ms("1d"), 86_400_000)
        XCTAssertEqual(WaitDuration.ms("1.5s"), 1_500)
        XCTAssertEqual(WaitDuration.ms(" 250 "), 250)
        XCTAssertNil(WaitDuration.ms("-1s"))
        XCTAssertNil(WaitDuration.ms("soon"))
        XCTAssertNil(WaitDuration.ms("2e3s"))
        XCTAssertNil(WaitDuration.ms(""))
    }

    // MARK: - request validation

    private func parse(text: String? = nil, idleMs: Int? = nil, idle: String? = nil,
                       timeoutMs: Int? = nil, timeout: String? = nil)
        -> Result<SessionWaitRequest, SessionWaitBadRequest> {
        SessionWaitParse.request(text: text, idleMs: idleMs, idle: idle,
                                 timeoutMs: timeoutMs, timeout: timeout)
    }

    func testRequestDefaultsAndParsing() throws {
        let text = try parse(text: "ready").get()
        XCTAssertEqual(text.condition, .text("ready"))
        XCTAssertEqual(text.timeoutMs, SessionWait.defaultTimeoutMs)

        let idle = try parse(idle: "2s", timeout: "1m").get()
        XCTAssertEqual(idle.condition, .idle(ms: 2_000))
        XCTAssertEqual(idle.timeoutMs, 60_000)

        // A timeout beyond the grammar's longest duration is clamped, not refused.
        XCTAssertEqual(try parse(idleMs: 1_000, timeoutMs: 99 * 86_400_000).get().timeoutMs,
                       SessionWait.maxTimeoutMs)
    }

    func testRequestRejectsAmbiguousOrEmptyConditions() {
        XCTAssertEqual(parse().failureReason, "text or idleMs required")
        XCTAssertEqual(parse(text: "").failureReason, "text or idleMs required")
        XCTAssertEqual(parse(text: "ready", idleMs: 2_000).failureReason,
                       "text and idleMs are mutually exclusive")
        XCTAssertEqual(parse(idleMs: -1).failureReason, "idleMs must not be negative")
        XCTAssertEqual(parse(text: "ready", timeoutMs: 0).failureReason, "timeoutMs must be positive")
        XCTAssertNotNil(parse(text: "ready", timeout: "soon").failureReason)
    }
}

private extension Result where Failure == SessionWaitBadRequest {
    var failureReason: String? {
        if case .failure(let bad) = self { return bad.reason }
        return nil
    }
}
