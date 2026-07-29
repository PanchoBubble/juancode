import XCTest
@testable import JuancodeServices

/// Parsing the failing-CI text `getFailedCheckLogs` returns into steps → folds →
/// lines. Pure — no `gh` is spawned.
final class ActionsLogTests: XCTestCase {
    /// gh's shape: `<job>\t<step>\t<timestamp> <line>`, wrapped in the per-run
    /// banner `getFailedCheckLogs` adds, with a fold, an error, a warning, a noise
    /// command, and a second step.
    private let sample = """
    ===== run 1234 (failed steps) =====
    build\tRun tests\t2026-07-29T09:41:02.1234567Z ##[group]Run pnpm test
    build\tRun tests\t2026-07-29T09:41:02.2000000Z pnpm test
    build\tRun tests\t2026-07-29T09:41:02.3000000Z ##[endgroup]
    build\tRun tests\t2026-07-29T09:41:09.0000000Z FAIL src/queue.test.ts
    build\tRun tests\t2026-07-29T09:41:09.5000000Z ##[error]Process completed with exit code 1.
    build\tLint\t2026-07-29T09:42:00.0000000Z ##[warning]2 warnings
    build\tLint\t2026-07-29T09:42:01.0000000Z ##[set-output]name=foo
    """

    func testParsesStepsFoldsAndSeverities() {
        let log = parseActionsLog(sample)
        XCTAssertFalse(log.truncated)
        XCTAssertEqual(log.sections.count, 2)

        let tests = log.sections[0]
        XCTAssertEqual(tests.runId, "1234")
        XCTAssertEqual(tests.job, "build")
        XCTAssertEqual(tests.step, "Run tests")
        XCTAssertTrue(tests.hasError)
        // The fold comes first, then the lines that followed `##[endgroup]`.
        XCTAssertEqual(tests.groups.count, 2)
        XCTAssertEqual(tests.groups[0].title, "Run pnpm test")
        XCTAssertTrue(tests.groups[0].foldable)
        XCTAssertEqual(tests.groups[0].lines.map(\.text), ["pnpm test"])
        XCTAssertFalse(tests.groups[0].hasError)
        XCTAssertFalse(tests.groups[1].foldable)
        XCTAssertEqual(tests.groups[1].lines.map(\.text),
                       ["FAIL src/queue.test.ts", "Process completed with exit code 1."])
        XCTAssertEqual(tests.groups[1].lines.map(\.severity), [.plain, .error])
        // The error line is reachable without opening a fold.
        XCTAssertEqual(tests.errorLines.map(\.text), ["Process completed with exit code 1."])

        // A new job/step in gh's prefix starts a new section.
        let lint = log.sections[1]
        XCTAssertEqual(lint.step, "Lint")
        XCTAssertFalse(lint.hasError)
        XCTAssertEqual(lint.groups[0].lines.map(\.severity), [.warning, .command])
        // Unknown commands keep their payload but read as noise, not content.
        XCTAssertEqual(lint.groups[0].lines[1].text, "name=foo")
    }

    func testParsesTimestampWithSevenFractionalDigits() {
        let log = parseActionsLog(sample)
        let stamp = log.sections[0].groups[0].lines[0].timestamp
        // 2026-07-29T09:41:02.200Z
        XCTAssertEqual(stamp?.timeIntervalSince1970 ?? 0, 1_785_318_062.2, accuracy: 0.001)
        // …and it is stripped from the text.
        XCTAssertEqual(log.sections[0].groups[0].lines[0].text, "pnpm test")
    }

    func testTruncationMarkerIsLifted() {
        let log = parseActionsLog("…(truncated)\nbuild\tRun tests\t2026-07-29T09:41:02Z oops")
        XCTAssertTrue(log.truncated)
        XCTAssertEqual(log.sections.count, 1)
        XCTAssertEqual(log.sections[0].groups[0].lines.map(\.text), ["oops"])
    }

    func testUnterminatedGroupIsClosedAtTheStepBoundary() {
        let log = parseActionsLog("""
        a\tstep one\t2026-07-29T09:41:02Z ##[group]Never closed
        a\tstep one\t2026-07-29T09:41:03Z inside
        a\tstep two\t2026-07-29T09:41:04Z after
        """)
        XCTAssertEqual(log.sections.count, 2)
        XCTAssertEqual(log.sections[0].groups.count, 1)
        XCTAssertEqual(log.sections[0].groups[0].title, "Never closed")
        XCTAssertEqual(log.sections[0].groups[0].lines.map(\.text), ["inside"])
        XCTAssertEqual(log.sections[1].groups[0].lines.map(\.text), ["after"])
    }

    func testLinesWithoutGhPrefixOrTimestampSurvive() {
        // `gh run view --log` piped in raw, or a wrapped line: no job/step, no stamp.
        let log = parseActionsLog("just some output\nand more")
        XCTAssertEqual(log.sections.count, 1)
        XCTAssertEqual(log.sections[0].job, "")
        XCTAssertNil(log.sections[0].groups[0].lines[0].timestamp)
        XCTAssertEqual(log.sections[0].groups[0].lines.map(\.text), ["just some output", "and more"])
    }

    func testWorkflowCommandFormIsRecognised() {
        let log = parseActionsLog("a\tb\t2026-07-29T09:41:02Z ::error file=a.swift,line=2::bad thing")
        let line = log.sections[0].groups[0].lines[0]
        XCTAssertEqual(line.severity, .error)
        XCTAssertEqual(line.text, "bad thing")
    }

    /// The first line of a downloaded log really does start with a UTF-8 BOM,
    /// ahead of the timestamp (verified against a live `gh run view --log-failed`).
    func testUtf8BomOnTheFirstLineDoesNotBreakTheTimestamp() {
        let log = parseActionsLog(
            "Dependabot\tUNKNOWN STEP\t\u{FEFF}2026-07-28T13:37:35.7637778Z Current runner version")
        let line = log.sections[0].groups[0].lines[0]
        XCTAssertEqual(line.text, "Current runner version")
        XCTAssertNotNil(line.timestamp)
    }

    func testEmptyInputParsesToAnEmptyLog() {
        let log = parseActionsLog("")
        XCTAssertTrue(log.isEmpty)
        XCTAssertFalse(log.truncated)
    }

    // MARK: - ANSI

    func testAnsiSpansCarryForegroundAndBold() {
        let spans = ansiSpans("plain \u{1B}[1;31mFAIL\u{1B}[0m done")
        XCTAssertEqual(spans.map(\.text), ["plain ", "FAIL", " done"])
        XCTAssertEqual(spans.map(\.fg), [nil, 31, nil])
        XCTAssertEqual(spans.map(\.bold), [false, true, false])
    }

    func testAnsiExtendedColourArgumentsAreNotReadAsAttributes() {
        // `38;5;31` is a 256-colour index, not "bright" + red.
        let spans = ansiSpans("\u{1B}[38;5;31mx\u{1B}[0m")
        XCTAssertEqual(spans.map(\.text), ["x"])
        XCTAssertNil(spans[0].fg)
        XCTAssertFalse(spans[0].bold)
    }

    func testAnsiNonSgrSequencesAreDroppedWithoutEatingText() {
        // A cursor move and a clear-line, as CI progress bars emit.
        let spans = ansiSpans("\u{1B}[2K\u{1B}[1Gprogress")
        XCTAssertEqual(spans.map(\.text), ["progress"])
    }

    func testStripAnsiLeavesPlainText() {
        XCTAssertEqual(stripAnsi("\u{1B}[32mok\u{1B}[0m"), "ok")
        XCTAssertEqual(stripAnsi("nothing to strip"), "nothing to strip")
        // A truncated escape at the end drops rather than leaking control bytes.
        XCTAssertEqual(stripAnsi("tail\u{1B}[3"), "tail")
    }
}
