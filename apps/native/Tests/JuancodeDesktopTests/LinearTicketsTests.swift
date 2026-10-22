import XCTest
@testable import JuancodeDesktop

/// The right rail's Tickets panel (juancode-04u): the paged assigned-issues parser and
/// the IssueFilter it sends. No network.

final class ParseLinearTicketsTests: XCTestCase {
    private func parse(_ json: String) -> Result<LinearTicketPage, LinearTicketsError> {
        let raw = try! JSONDecoder().decode(RawTicketsForTest.self, from: Data(json.utf8))
        return parseLinearTickets(raw)
    }

    func testParsesAPageAndItsCursor() throws {
        let page = try parse("""
        {"data":{"viewer":{"assignedIssues":{
          "nodes":[
            {"id":"u1","identifier":"ENG-42","title":"Fix login","url":"https://linear.app/o/issue/ENG-42",
             "priority":2,"updatedAt":"2026-10-19T08:30:00.000Z","branchName":"juan/eng-42-fix-login",
             "state":{"name":"In Progress","type":"started","color":"#f2c94c"},"team":{"key":"ENG"}},
            {"title":"no id, dropped"}
          ],
          "pageInfo":{"hasNextPage":true,"endCursor":"c10"}
        }}}}
        """).get()
        XCTAssertEqual(page.tickets.count, 1)
        let t = page.tickets[0]
        XCTAssertEqual(t.identifier, "ENG-42")
        XCTAssertEqual(t.priority, 2)
        XCTAssertEqual(t.stateType, "started")
        XCTAssertEqual(t.stateColor, "#f2c94c")
        XCTAssertEqual(t.teamKey, "ENG")
        XCTAssertEqual(t.branchName, "juan/eng-42-fix-login")
        XCTAssertEqual(t.updatedAt, ISO8601DateFormatter().date(from: "2026-10-19T08:30:00Z"))
        XCTAssertTrue(page.hasNextPage)
        XCTAssertEqual(page.endCursor, "c10")
    }

    func testSurfacesTheFirstGraphQLError() {
        let r = parse(#"{"errors":[{"message":"Authentication required"}],"data":null}"#)
        XCTAssertEqual(r, .failure(.failed("Authentication required")))
    }

    func testMissingConnectionIsAFailure() {
        if case .success = parse(#"{"data":{"viewer":null}}"#) { XCTFail("expected a failure") }
    }
}

final class LinearTicketFilterTests: XCTestCase {
    func testScopeOnly() {
        let f = linearTicketFilter(scope: .open, search: "  ")
        XCTAssertEqual(f["state"] as? [String: [String: [String]]],
                       ["type": ["nin": ["completed", "canceled"]]])
        XCTAssertNil(f["or"])
    }

    func testSearchMatchesTitle() {
        let or = linearTicketFilter(scope: .todo, search: "login")["or"] as? [[String: Any]]
        XCTAssertEqual(or?.count, 1)
        XCTAssertEqual(or?[0]["title"] as? [String: String], ["containsIgnoreCase": "login"])
    }

    func testAnIdentifierAlsoMatchesTeamAndNumber() {
        let or = linearTicketFilter(scope: .open, search: "eng-42")["or"] as? [[String: Any]]
        XCTAssertEqual(or?.count, 2)
        XCTAssertEqual(or?[1]["number"] as? [String: Int], ["eq": 42])
        XCTAssertEqual(or?[1]["team"] as? [String: [String: String]], ["key": ["eqIgnoreCase": "eng"]])
    }
}
