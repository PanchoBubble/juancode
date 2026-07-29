import XCTest
@testable import JuancodeServices

/// Byte-level line handling (`TranscriptChunk`) plus the remembered-offset reader
/// (`TranscriptReader`) behind the incremental title/usage polls (juancode-dfhg).
final class TranscriptCursorTests: XCTestCase {
    private static let tmp: String = {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-cursor-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    override class func tearDown() {
        try? FileManager.default.removeItem(atPath: tmp)
        super.tearDown()
    }

    private func path(_ name: String) -> String {
        (Self.tmp as NSString).appendingPathComponent("\(name)-\(UUID().uuidString).jsonl")
    }

    private func write(_ path: String, _ contents: String) {
        try! contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Append like a CLI does — in place, so the reader's offset stays meaningful.
    private func append(_ path: String, _ contents: String) {
        let handle = FileHandle(forWritingAtPath: path)!
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try! handle.write(contentsOf: Data(contents.utf8))
    }

    private func ids(_ data: String) -> [String] {
        var out: [String] = []
        _ = TranscriptChunk.forEachCompleteRecord(in: Data(data.utf8)) { rec in
            if let id = rec["id"] as? String { out.append(id) }
            return nil
        }
        return out
    }

    // MARK: - TranscriptChunk

    func testParsesCompleteLinesAndReportsBytesConsumed() {
        let data = Data("{\"id\":\"a\"}\n{\"id\":\"b\"}\n".utf8)
        var seen: [String] = []
        let consumed = TranscriptChunk.forEachCompleteRecord(in: data) { rec in
            seen.append(rec["id"] as! String)
            return nil
        }
        XCTAssertEqual(seen, ["a", "b"])
        XCTAssertEqual(consumed, data.count)
    }

    func testLeavesATrailingPartialLineUnconsumed() {
        // The CLI is mid-write: the second record has no newline yet.
        let complete = "{\"id\":\"a\"}\n"
        let data = Data((complete + "{\"id\":\"b\"").utf8)
        var seen: [String] = []
        let consumed = TranscriptChunk.forEachCompleteRecord(in: data) { rec in
            seen.append(rec["id"] as! String)
            return nil
        }
        XCTAssertEqual(seen, ["a"], "a half-written record must not be parsed")
        XCTAssertEqual(consumed, complete.utf8.count, "the partial line stays unconsumed")
    }

    func testToleratesBlankMalformedAndCrlfLines() {
        let data = "{\"id\":\"a\"}\r\n\n   \nnot json\n[1,2]\n{\"id\":\"b\"}\n"
        XCTAssertEqual(ids(data), ["a", "b"])
    }

    func testEarlyExitConsumesThroughTheStoppingRecord() {
        let data = Data("{\"id\":\"a\"}\n{\"id\":\"b\"}\n{\"id\":\"c\"}\n".utf8)
        var seen: [String] = []
        let consumed = TranscriptChunk.forEachCompleteRecord(in: data) { rec in
            let id = rec["id"] as! String
            seen.append(id)
            return id == "b" ? false : nil
        }
        XCTAssertEqual(seen, ["a", "b"])
        XCTAssertEqual(consumed, Data("{\"id\":\"a\"}\n{\"id\":\"b\"}\n".utf8).count)
    }

    func testEmptyDataConsumesNothing() {
        XCTAssertEqual(TranscriptChunk.forEachCompleteRecord(in: Data()) { _ in nil }, 0)
    }

    // MARK: - TranscriptReader

    /// The whole point: a second pass over a grown file parses only what was added.
    func testSecondPassSeesOnlyAppendedRecords() {
        let file = path("append")
        write(file, "{\"id\":\"a\"}\n")
        let reader = TranscriptReader()

        var first: [String] = []
        let s1 = reader.scan(file: file, namespace: "t") { rec in
            first.append(rec["id"] as! String); return nil
        }
        XCTAssertEqual(first, ["a"])
        XCTAssertTrue(s1.fromStart)
        XCTAssertEqual(s1.records, 1)

        append(file, "{\"id\":\"b\"}\n{\"id\":\"c\"}\n")
        var second: [String] = []
        let s2 = reader.scan(file: file, namespace: "t") { rec in
            second.append(rec["id"] as! String); return nil
        }
        XCTAssertEqual(second, ["b", "c"], "already-read records must not be replayed")
        XCTAssertFalse(s2.fromStart)
        XCTAssertEqual(s2.records, 2)
    }

    func testUnchangedFileScansNothing() {
        let file = path("quiet")
        write(file, "{\"id\":\"a\"}\n")
        let reader = TranscriptReader()
        reader.scan(file: file, namespace: "t") { _ in nil }

        var seen = 0
        let scan = reader.scan(file: file, namespace: "t") { _ in seen += 1; return nil }
        XCTAssertEqual(seen, 0)
        XCTAssertEqual(scan.records, 0)
        XCTAssertFalse(scan.fromStart)
        XCTAssertFalse(scan.missing)
    }

    /// A half-written record is picked up once its newline lands — exactly once.
    func testPartialRecordIsDeliveredOnceItCompletes() {
        let file = path("partial")
        write(file, "{\"id\":\"a\"}\n{\"id\":\"b\"")
        let reader = TranscriptReader()
        var seen: [String] = []
        reader.scan(file: file, namespace: "t") { rec in
            seen.append(rec["id"] as! String); return nil
        }
        XCTAssertEqual(seen, ["a"])

        append(file, "}\n")
        reader.scan(file: file, namespace: "t") { rec in
            seen.append(rec["id"] as! String); return nil
        }
        XCTAssertEqual(seen, ["a", "b"])
    }

    func testShrunkFileRestartsFromTheTop() {
        let file = path("rotate")
        write(file, "{\"id\":\"a\"}\n{\"id\":\"b\"}\n")
        let reader = TranscriptReader()
        reader.scan(file: file, namespace: "t") { _ in nil }

        // Rewritten shorter (rotated / replaced): the remembered offset is meaningless.
        write(file, "{\"id\":\"z\"}\n")
        var seen: [String] = []
        let scan = reader.scan(file: file, namespace: "t") { rec in
            seen.append(rec["id"] as! String); return nil
        }
        XCTAssertEqual(seen, ["z"])
        XCTAssertTrue(scan.fromStart, "callers must be told to discard accumulated state")
    }

    func testNamespacesKeepIndependentPositions() {
        let file = path("shared")
        write(file, "{\"id\":\"a\"}\n")
        let reader = TranscriptReader()
        reader.scan(file: file, namespace: "title") { _ in nil }

        var seen: [String] = []
        let scan = reader.scan(file: file, namespace: "usage") { rec in
            seen.append(rec["id"] as! String); return nil
        }
        XCTAssertEqual(seen, ["a"], "the usage namespace has its own offset")
        XCTAssertTrue(scan.fromStart)
    }

    func testMissingFileIsReportedAndScansNothing() {
        let scan = TranscriptReader().scan(file: path("gone"), namespace: "t") { _ in
            XCTFail("no records expected"); return nil
        }
        XCTAssertTrue(scan.missing)
        XCTAssertEqual(scan.records, 0)
        XCTAssertFalse(scan.fromStart)
    }

    func testForgetRereadsFromTheTop() {
        let file = path("forget")
        write(file, "{\"id\":\"a\"}\n")
        let reader = TranscriptReader()
        reader.scan(file: file, namespace: "t") { _ in nil }
        reader.forget(file: file, namespace: "t")

        var seen: [String] = []
        let scan = reader.scan(file: file, namespace: "t") { rec in
            seen.append(rec["id"] as! String); return nil
        }
        XCTAssertEqual(seen, ["a"])
        XCTAssertTrue(scan.fromStart)
    }

    func testOnStartFiresOnceBeforeAnyRecord() {
        let file = path("onstart")
        write(file, "{\"id\":\"a\"}\n{\"id\":\"b\"}\n")
        let reader = TranscriptReader()
        var events: [String] = []
        reader.scan(file: file, namespace: "t", onStart: { fromStart in
            events.append("start:\(fromStart)")
        }) { rec in
            events.append(rec["id"] as! String); return nil
        }
        XCTAssertEqual(events, ["start:true", "a", "b"])

        // Nothing appended: no records, and no start hook either.
        reader.scan(file: file, namespace: "t", onStart: { _ in
            XCTFail("onStart must not fire when there is nothing new")
        }) { _ in XCTFail("no records expected"); return nil }
    }
}
