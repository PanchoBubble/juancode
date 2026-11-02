import Testing
@testable import JuancodeCore

@Suite struct ReviewNavigationTests {
    private func file(_ diff: String) -> DiffFile {
        DiffFile(path: "renamed.ts", oldPath: "old.ts", status: .renamed,
                 additions: 1, deletions: 1, binary: false, diff: diff, truncated: false)
    }

    @Test func expansionPreservesBothSideAnchorsAndFillsGaps() throws {
        let diff = "@@ -2,2 +2,3 @@\n two\n-old\n+new\n+extra\n@@ -6 +7 @@\n seven\n"
        let source = "one\ntwo\nnew\nextra\nfive\nsix\nseven\neight\n"
        let rows = try reviewExpandedRows(for: file(diff), source: source)
        let lines = rows.compactMap(\.line)
        #expect(lines.filter { $0.kind != .delete }.map(\.text) == source.split(separator: "\n").map(String.init))
        #expect(lines.first?.oldLine == 1)
        #expect(lines.last?.oldLine == 7)
        #expect(lines.last?.newLine == 8)
        #expect(lines.first { $0.text == "old" }.map(reviewLineKey) == "o3")
        #expect(lines.first { $0.text == "extra" }.map(reviewLineKey) == "n4")
        #expect(lines.first { $0.text == "five" }?.oldLine == 4)
        #expect(lines.filter { $0.kind == .context && $0.text.isEmpty }.isEmpty)
    }

    @Test func zeroCountHunksAndNoFinalNewline() throws {
        let added = try reviewExpandedRows(for: file("@@ -0,0 +1,2 @@\n+first\n+last\n"), source: "first\nlast")
        #expect(added.compactMap(\.line).map(\.newLine) == [1, 2])
        let deleted = try reviewExpandedRows(for: file("@@ -1,2 +0,0 @@\n-first\n-last\n"), source: "")
        #expect(deleted.compactMap(\.line).map(\.oldLine) == [1, 2])
        let removal = try reviewExpandedRows(for: file("@@ -2 +1,0 @@\n-removed\n"), source: "before\nafter\n")
        #expect(removal.compactMap(\.line).map(\.text) == ["before", "removed", "after"])
        #expect(removal.compactMap(\.line).last?.oldLine == 3)
    }

    @Test func mismatchedAndOverlappingSnapshotsAreRefused() {
        #expect(throws: ReviewContextError.self) {
            try reviewExpandedRows(for: file("@@ -2 +2 @@\n expected\n"), source: "one\nother\n")
        }
        #expect(throws: ReviewContextError.self) {
            try reviewExpandedRows(for: file("@@ -3 +2 @@\n two\n"), source: "one\ntwo\n")
        }
        #expect(throws: ReviewContextError.self) {
            try reviewExpandedRows(for: file("@@ -1 +1 @@\n one\n@@ -1 +1 @@\n one\n"), source: "one\n")
        }
    }

    @Test func tabsRetainDisplayAndAnchors() throws {
        let rows = try reviewExpandedRows(for: file("@@ -2 +2 @@\n \tinside\n"), source: "\toutside\n\tinside\n")
        #expect(rows.compactMap(\.line).map(\.text) == ["    outside", "    inside"])
        #expect(rows.compactMap(\.line).map(reviewLineKey) == ["n1", "n2"])
    }

    @Test func columnMotionsUseCharactersAndClampAtEnds() {
        #expect(reviewColumn(in: "", from: 12, command: .right) == 0)
        #expect(reviewColumn(in: "a👩🏽‍💻b", from: 1, command: .right) == 2)
        #expect(reviewColumn(in: "abc", from: 99, command: .left) == 1)
        #expect(reviewColumn(in: "abc", from: 0, command: .left) == 0)
        #expect(reviewColumn(in: "abc", from: 0, command: .lineEnd) == 2)
        #expect(reviewColumn(in: "abc", from: 2, command: .lineStart) == 0)
        #expect(reviewColumn(in: "abc", from: 1, command: .columns(Int.max)) == 2)
        #expect(reviewColumn(in: "abc", from: 1, command: .columns(Int.min)) == 0)
        #expect(reviewColumn(in: "foo.bar baz", from: 0, command: .wordForward(2)) == 4)
        #expect(reviewColumn(in: "foo.bar baz", from: 8, command: .wordBackward(2)) == 3)
        #expect(reviewColumn(in: "foo.bar baz", from: 0, command: .wordEnd(3)) == 6)
    }

    @Test func wordAndLineKeysKeepCountsSeparateFromZeroMotion() {
        var parser = ReviewKeyParser()
        #expect(parser.feed(.char("0"), visual: false) == .lineStart)
        #expect(parser.feed(.char("2"), visual: false) == nil)
        #expect(parser.feed(.char("w"), visual: false) == .wordForward(2))
        #expect(parser.feed(.char("$"), visual: false) == .lineEnd)
        #expect(parser.feed(.char("1"), visual: false) == nil)
        #expect(parser.feed(.char("0"), visual: false) == nil)
        #expect(parser.feed(.char("l"), visual: false) == .columns(10))
    }
}
