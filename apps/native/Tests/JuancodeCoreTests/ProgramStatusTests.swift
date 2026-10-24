import Foundation
import Testing
@testable import JuancodeCore

struct ProgramStatusTests {
    @Test func wireCompatibilityAndPlainText() throws {
        #expect(ProgramStatusRecord.decode(nil) == nil)
        #expect(ProgramStatusRecord.decode([] as [Any]) == [])
        let records = try #require(ProgramStatusRecord.decode([
            ["id": "build/test", "state": "blocked", "kind": "auth", "app": "build",
             "msg": "<b>café</b>", "progress": 42, "futureField": "ignored"] as [String: Any]
        ]))
        #expect(records[0].summary == "build · blocked · 42% · <b>café</b>")
        #expect(records[0].title == nil)
        #expect(ProgramStatusRecord.decode([["state": "done"]]) == nil)
    }

    @Test func snapshotsReplayDeduplicateClearAndCancel() throws {
        let feed = ProgramStatusFeed()
        let received = Received()
        let cancel = feed.observe { received.add($0) }
        let records = try #require(ProgramStatusRecord.decode([["id": "", "state": "working"]]))
        feed.replace(records)
        feed.replace(records)
        #expect(received.count == 2)
        let late = Received()
        let stopLate = feed.observe { late.add($0) }
        #expect(late.last == records)
        feed.replace([])
        #expect(late.last == [])
        cancel(); stopLate()
        feed.replace(records)
        #expect(received.count == 3)
        #expect(late.count == 2)
    }
}
private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[ProgramStatusRecord]] = []
    func add(_ records: [ProgramStatusRecord]) { lock.lock(); defer { lock.unlock() }; values.append(records) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    var last: [ProgramStatusRecord]? { lock.lock(); defer { lock.unlock() }; return values.last }
}
