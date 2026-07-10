import XCTest
import JuancodeCore
@testable import JuancodeServer

/// Row → wire-segment compression for the rendered-screen stream (juancode-a2h.3).
final class ScreenWireTests: XCTestCase {
    private func cell(_ ch: Character, fg: TerminalColor = .default, bg: TerminalColor = .default,
                      style: TerminalCellStyle = []) -> TerminalCell {
        TerminalCell(char: ch, width: 1, fg: fg, bg: bg, style: style)
    }

    private func row(_ cells: [TerminalCell]) -> TerminalRow {
        TerminalRow(cells: cells, text: String(cells.map(\.char)))
    }

    func testMergesRunsOfIdenticalStyle() {
        let segs = ScreenWire.segments(row([
            cell("h", fg: .ansi(2)), cell("i", fg: .ansi(2)),
            cell("!", fg: .ansi(1), style: [.bold]),
        ]))
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].text, "hi")
        XCTAssertEqual(segs[0].fg, .ansi(2))
        XCTAssertEqual(segs[1].text, "!")
        XCTAssertEqual(segs[1].style, [.bold])
    }

    func testTrimsInvisibleTrailingBlanks() {
        let segs = ScreenWire.segments(row([
            cell("o"), cell("k"),
            // fg on a blank never shows — still trimmable.
            cell(" ", fg: .ansi(3)), cell(" "),
        ]))
        XCTAssertEqual(segs.map(\.text).joined(), "ok")
    }

    func testKeepsVisibleTrailingBlanks() {
        // A background-painted or decorated blank is visible — must survive.
        let painted = ScreenWire.segments(row([cell("x"), cell(" ", bg: .ansi(4))]))
        XCTAssertEqual(painted.map(\.text).joined(), "x ")
        let underlined = ScreenWire.segments(row([cell("x"), cell(" ", style: [.underline])]))
        XCTAssertEqual(underlined.map(\.text).joined(), "x ")
    }

    func testBlankRowIsEmpty() {
        XCTAssertEqual(ScreenWire.segments(row([cell(" "), cell(" ")])), [])
        XCTAssertEqual(ScreenWire.segments(TerminalRow(cells: [], text: "")), [])
    }

    func testChangedLinesReportsOnlyDifferingRows() {
        let mk = { (texts: [String]) -> TerminalSnapshot in
            TerminalSnapshot(
                cols: 10, rows: texts.count,
                lines: texts.map { t in TerminalRow(cells: t.map { self.cell($0) }, text: t) },
                cursorX: 0, cursorY: 0, cursorVisible: true, isAlternateBuffer: false)
        }
        let prev = mk(["aaa", "bbb", "ccc"])
        let next = mk(["aaa", "BBB", "ccc"])
        let changed = ScreenWire.changedLines(prev: prev, next: next)
        XCTAssertEqual(changed.map(\.row), [1])
        XCTAssertEqual(changed[0].segs.map(\.text).joined(), "BBB")
        XCTAssertTrue(ScreenWire.changedLines(prev: prev, next: prev).isEmpty)
    }
}
