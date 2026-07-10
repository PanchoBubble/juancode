import XCTest
import JuancodeCore
@testable import JuancodeServices

/// Unit tests for word-level intraline diffing behind the ChangesPanel.
final class DiffIntralineTests: XCTestCase {

    // MARK: - pairing

    func testPairsConsecutiveDeleteThenInsertRuns() {
        let lines = [
            DiffLine(kind: .context, oldLine: 1, newLine: 1, text: "keep"),
            DiffLine(kind: .delete, oldLine: 2, newLine: nil, text: "old-a"),
            DiffLine(kind: .delete, oldLine: 3, newLine: nil, text: "old-b"),
            DiffLine(kind: .insert, oldLine: nil, newLine: 2, text: "new-a"),
            DiffLine(kind: .insert, oldLine: nil, newLine: 3, text: "new-b"),
            DiffLine(kind: .context, oldLine: 4, newLine: 4, text: "tail"),
        ]
        let pairs = intralinePairs(lines)
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].delete, 1)
        XCTAssertEqual(pairs[0].insert, 3)
        XCTAssertEqual(pairs[1].delete, 2)
        XCTAssertEqual(pairs[1].insert, 4)
    }

    func testNoPairForPureInsertOrDelete() {
        let inserts = [
            DiffLine(kind: .context, oldLine: 1, newLine: 1, text: "a"),
            DiffLine(kind: .insert, oldLine: nil, newLine: 2, text: "b"),
        ]
        XCTAssertTrue(intralinePairs(inserts).isEmpty)
    }

    func testUnevenRunsPairUpToShorterCount() {
        let lines = [
            DiffLine(kind: .delete, oldLine: 1, newLine: nil, text: "x"),
            DiffLine(kind: .insert, oldLine: nil, newLine: 1, text: "y"),
            DiffLine(kind: .insert, oldLine: nil, newLine: 2, text: "z"),
        ]
        let pairs = intralinePairs(lines)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].delete, 0)
        XCTAssertEqual(pairs[0].insert, 1)
    }

    // MARK: - word ranges

    func testIdenticalLinesHaveNoRanges() {
        let (o, n) = intralineWordRanges(old: "same text", new: "same text")
        XCTAssertTrue(o.isEmpty)
        XCTAssertTrue(n.isEmpty)
    }

    func testSingleWordChangeHighlightsOnlyThatWord() {
        // "let x = 1" -> "let x = 2": only the trailing number differs.
        let old = "let x = 1"
        let new = "let x = 2"
        let (o, n) = intralineWordRanges(old: old, new: new)
        XCTAssertEqual(o, [8..<9])
        XCTAssertEqual(n, [8..<9])
    }

    func testEmptySideYieldsWholeOtherRange() {
        let (o1, n1) = intralineWordRanges(old: "", new: "abc")
        XCTAssertTrue(o1.isEmpty)
        XCTAssertEqual(n1, [0..<3])

        let (o2, n2) = intralineWordRanges(old: "abc", new: "")
        XCTAssertEqual(o2, [0..<3])
        XCTAssertTrue(n2.isEmpty)
    }

    func testInsertedWordInMiddle() {
        // "a c" -> "a b c": the inserted "b " is the changed span on the new side.
        let (o, n) = intralineWordRanges(old: "a c", new: "a b c")
        XCTAssertTrue(o.isEmpty)
        // new: indices 2..4 cover "b " (the inserted word plus its trailing space).
        XCTAssertEqual(n.count, 1)
        XCTAssertEqual(n[0].lowerBound, 2)
        XCTAssertTrue(n[0].contains(2))
    }

    func testLongLinesSkipToWholeRange() {
        let old = String(repeating: "a", count: 2100)
        let new = String(repeating: "b", count: 2100)
        let (o, n) = intralineWordRanges(old: old, new: new)
        XCTAssertEqual(o, [0..<2100])
        XCTAssertEqual(n, [0..<2100])
    }
}
