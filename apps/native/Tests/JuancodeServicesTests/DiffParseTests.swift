import XCTest
import JuancodeCore
@testable import JuancodeServices

/// Unit tests for the pure unified-diff parser + review-prompt composer backing the
/// native ChangesPanel (juancode-3bq). No git here — only string parsing.
final class DiffParseTests: XCTestCase {

    // MARK: - parseUnifiedDiff

    func testEmptyDiffYieldsNoHunks() {
        XCTAssertTrue(parseUnifiedDiff("").isEmpty)
        XCTAssertTrue(parseUnifiedDiff("diff --git a/x b/x\nindex 0..1 100644\n").isEmpty)
    }

    func testParsesLineNumbersAndKinds() {
        let diff = """
        diff --git a/f.txt b/f.txt
        index 111..222 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1,3 +1,4 @@
         one
        -two
        +TWO
        +two-and-a-half
         three
        """
        let hunks = parseUnifiedDiff(diff)
        XCTAssertEqual(hunks.count, 1)
        let lines = hunks[0].lines
        // context "one" at old 1 / new 1
        XCTAssertEqual(lines[0].kind, .context)
        XCTAssertEqual(lines[0].oldLine, 1)
        XCTAssertEqual(lines[0].newLine, 1)
        XCTAssertEqual(lines[0].text, "one")
        // delete "two" at old 2, no new
        XCTAssertEqual(lines[1].kind, .delete)
        XCTAssertEqual(lines[1].oldLine, 2)
        XCTAssertNil(lines[1].newLine)
        // insert "TWO" at new 2, no old
        XCTAssertEqual(lines[2].kind, .insert)
        XCTAssertNil(lines[2].oldLine)
        XCTAssertEqual(lines[2].newLine, 2)
        // insert "two-and-a-half" at new 3
        XCTAssertEqual(lines[3].kind, .insert)
        XCTAssertEqual(lines[3].newLine, 3)
        // context "three" at old 3 / new 4
        XCTAssertEqual(lines[4].kind, .context)
        XCTAssertEqual(lines[4].oldLine, 3)
        XCTAssertEqual(lines[4].newLine, 4)
    }

    func testAnchorPrefersNewSideForInsertsAndContext() {
        let insert = DiffLine(kind: .insert, oldLine: nil, newLine: 7, text: "x")
        XCTAssertEqual(insert.anchor?.side, .new)
        XCTAssertEqual(insert.anchor?.line, 7)
        let delete = DiffLine(kind: .delete, oldLine: 5, newLine: nil, text: "x")
        XCTAssertEqual(delete.anchor?.side, .old)
        XCTAssertEqual(delete.anchor?.line, 5)
        let context = DiffLine(kind: .context, oldLine: 3, newLine: 9, text: "x")
        XCTAssertEqual(context.anchor?.side, .new)
        XCTAssertEqual(context.anchor?.line, 9)
    }

    func testIgnoresNoNewlineMarkerAndHandlesMultipleHunks() {
        let diff = """
        @@ -1,1 +1,1 @@
        -a
        \\ No newline at end of file
        +a
        \\ No newline at end of file
        @@ -10,2 +10,2 @@
         keep
        -drop
        +DROP
        """
        let hunks = parseUnifiedDiff(diff)
        XCTAssertEqual(hunks.count, 2)
        // First hunk: the "\ No newline" markers are skipped, leaving one - and one +.
        XCTAssertEqual(hunks[0].lines.map(\.kind), [.delete, .insert])
        // Second hunk starts numbering at 10.
        XCTAssertEqual(hunks[1].lines[0].oldLine, 10)
        XCTAssertEqual(hunks[1].lines[0].newLine, 10)
        XCTAssertEqual(hunks[1].lines[1].oldLine, 11) // delete "drop"
        XCTAssertEqual(hunks[1].lines[2].newLine, 11) // insert "DROP"
    }

    // MARK: - parseMultiFileDiff (PR diffs, juancode-49w)

    func testParseMultiFileDiffEmptyAndHeaderless() {
        XCTAssertTrue(parseMultiFileDiff("").isEmpty)
        // No `diff --git` header → nothing parsed.
        XCTAssertTrue(parseMultiFileDiff("just some text\nno header here\n").isEmpty)
    }

    func testParseMultiFileDiffSplitsModifiedAddedDeleted() {
        let patch = """
        diff --git a/keep.txt b/keep.txt
        index 111..222 100644
        --- a/keep.txt
        +++ b/keep.txt
        @@ -1,2 +1,3 @@
         one
         two
        +three
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 000..333
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,1 @@
        +fresh
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index 444..000
        --- a/gone.txt
        +++ /dev/null
        @@ -1,1 +0,0 @@
        -remove me
        """
        let files = parseMultiFileDiff(patch)
        var byPath: [String: DiffFile] = [:]
        for f in files { byPath[f.path] = f }

        XCTAssertEqual(byPath.count, 3)
        XCTAssertEqual(byPath["keep.txt"]?.status, .modified)
        XCTAssertEqual(byPath["keep.txt"]?.additions, 1)
        XCTAssertEqual(byPath["keep.txt"]?.deletions, 0)
        XCTAssertNil(byPath["keep.txt"]?.oldPath)
        XCTAssertTrue(byPath["keep.txt"]?.diff.contains("@@ -1,2 +1,3 @@") ?? false)

        XCTAssertEqual(byPath["new.txt"]?.status, .added)
        XCTAssertEqual(byPath["new.txt"]?.additions, 1)

        XCTAssertEqual(byPath["gone.txt"]?.status, .deleted)
        XCTAssertEqual(byPath["gone.txt"]?.deletions, 1)
    }

    func testParseMultiFileDiffDetectsRename() {
        let patch = """
        diff --git a/old/name.txt b/new/name.txt
        similarity index 95%
        rename from old/name.txt
        rename to new/name.txt
        index 111..222 100644
        --- a/old/name.txt
        +++ b/new/name.txt
        @@ -1,1 +1,1 @@
        -hello
        +hello world
        """
        let files = parseMultiFileDiff(patch)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].status, .renamed)
        XCTAssertEqual(files[0].path, "new/name.txt")
        XCTAssertEqual(files[0].oldPath, "old/name.txt")
    }

    func testParseMultiFileDiffMarksBinaryWithZeroCounts() {
        let patch = """
        diff --git a/logo.png b/logo.png
        new file mode 100644
        index 000..abc
        Binary files /dev/null and b/logo.png differ
        """
        let files = parseMultiFileDiff(patch)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "logo.png")
        XCTAssertTrue(files[0].binary)
        XCTAssertEqual(files[0].additions, 0)
        XCTAssertEqual(files[0].deletions, 0)
        XCTAssertEqual(files[0].diff, "") // body dropped for binary
    }

    func testParseMultiFileDiffIgnoresLeadingPreamble() {
        // gh sometimes prefaces the patch with non-diff lines — they're skipped.
        let patch = """
        Some preamble line
        diff --git a/f.txt b/f.txt
        --- a/f.txt
        +++ b/f.txt
        @@ -1 +1 @@
        -a
        +b
        """
        let files = parseMultiFileDiff(patch)
        XCTAssertEqual(files.map(\.path), ["f.txt"])
        XCTAssertEqual(files[0].additions, 1)
        XCTAssertEqual(files[0].deletions, 1)
    }

    // MARK: - commentRangeLabel

    func testRangeLabel() {
        XCTAssertEqual(commentRangeLabel(side: .new, line: 10, endLine: 10), "L10")
        XCTAssertEqual(commentRangeLabel(side: .new, line: 10, endLine: 14), "L10–14")
        XCTAssertEqual(commentRangeLabel(side: .old, line: 10, endLine: 10), "L10 (old)")
    }

    // MARK: - drag-select hit-testing (juancode-eba)

    func testDiffLineIndexForOffsetMapsAndClamps() {
        // 5 rows, 20pt tall each: offset 0 → row 0, 25 → row 1, 99 → row 4.
        XCTAssertEqual(diffLineIndex(forOffset: 0, rowHeight: 20, count: 5), 0)
        XCTAssertEqual(diffLineIndex(forOffset: 25, rowHeight: 20, count: 5), 1)
        XCTAssertEqual(diffLineIndex(forOffset: 39, rowHeight: 20, count: 5), 1)
        XCTAssertEqual(diffLineIndex(forOffset: 40, rowHeight: 20, count: 5), 2)
        XCTAssertEqual(diffLineIndex(forOffset: 99, rowHeight: 20, count: 5), 4)
        // Overshoot top/bottom clamps into range.
        XCTAssertEqual(diffLineIndex(forOffset: -10, rowHeight: 20, count: 5), 0)
        XCTAssertEqual(diffLineIndex(forOffset: 9999, rowHeight: 20, count: 5), 4)
    }

    func testDiffLineIndexEdgeCases() {
        XCTAssertNil(diffLineIndex(forOffset: 10, rowHeight: 20, count: 0))
        XCTAssertNil(diffLineIndex(forOffset: 10, rowHeight: 0, count: 5))
    }

    func testNormalizedLineRangeOrdersEndpoints() {
        XCTAssertEqual(normalizedLineRange(anchor: 2, current: 6), 2...6)
        XCTAssertEqual(normalizedLineRange(anchor: 6, current: 2), 2...6) // upward drag
        XCTAssertEqual(normalizedLineRange(anchor: 4, current: 4), 4...4) // single line
    }

    func testRangeLabelReflectsDraggedRange() {
        // The label the range composer/comment shows for a 10→14 drag on the new side.
        XCTAssertEqual(commentRangeLabel(side: .new, line: 10, endLine: 14), "L10–14")
    }

    func testComposeReviewPromptReflectsRange() {
        let files = [diffFile("a.swift")]
        let ranged = DiffComment(id: "1", sessionId: "s", file: "a.swift", side: .new,
                                 line: 10, endLine: 14, body: "tidy this block", createdAt: 0)
        let out = composeReviewPrompt(files: files, comments: [ranged], finalNote: "")
        XCTAssertTrue(out.contains("- L10–14: tidy this block"))
    }

    // MARK: - composeReviewPrompt

    private func comment(_ file: String, _ line: Int, _ body: String, side: CommentSide = .new) -> DiffComment {
        DiffComment(id: UUID().uuidString, sessionId: "s", file: file, side: side,
                    line: line, endLine: line, body: body, createdAt: 0)
    }

    private func diffFile(_ path: String) -> DiffFile {
        DiffFile(path: path, oldPath: nil, status: .modified, additions: 0, deletions: 0,
                 binary: false, diff: "", truncated: false)
    }

    func testComposeGroupsByFileInDiffOrderWithNote() {
        let files = [diffFile("a.swift"), diffFile("b.swift")]
        let comments = [
            comment("b.swift", 5, "second file"),
            comment("a.swift", 20, "later line"),
            comment("a.swift", 3, "earlier line"),
        ]
        let out = composeReviewPrompt(files: files, comments: comments, finalNote: "  ship it  ")
        let expected = """
        Here are my review comments on the current working-tree changes:

        ### a.swift
        - L3: earlier line
        - L20: later line

        ### b.swift
        - L5: second file

        ship it
        """
        XCTAssertEqual(out, expected)
    }

    func testComposeIncludesCommentsForFilesNotInDiff() {
        let out = composeReviewPrompt(
            files: [], comments: [comment("ghost.swift", 1, "orphan")], finalNote: "")
        XCTAssertTrue(out.contains("### ghost.swift"))
        XCTAssertTrue(out.contains("- L1: orphan"))
        // No trailing blank line / note.
        XCTAssertFalse(out.hasSuffix("\n"))
    }

    func testComposeIndentsMultilineBodies() {
        let out = composeReviewPrompt(
            files: [diffFile("a")], comments: [comment("a", 1, "line one\nline two")], finalNote: "")
        XCTAssertTrue(out.contains("- L1: line one\n  line two"))
    }
}
