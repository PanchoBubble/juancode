import XCTest
import JuancodeCore
@testable import JuancodeServices

/// Unit tests for the session-template ordering/filtering math (juancode-a2r).
/// Pure — no pty, no UI, no clock.
final class SessionTemplateTests: XCTestCase {
    private func template(_ name: String, cwd: String = "/repo", updatedAt: Int) -> SessionTemplate {
        SessionTemplate(name: name, provider: .claude, cwd: cwd, createdAt: 0, updatedAt: updatedAt)
    }

    func testOrderedIsMostRecentlyEditedFirst() {
        let a = template("alpha", updatedAt: 10)
        let b = template("bravo", updatedAt: 30)
        let c = template("charlie", updatedAt: 20)
        XCTAssertEqual(orderedSessionTemplates([a, b, c]).map(\.name), ["bravo", "charlie", "alpha"])
    }

    func testEmptyQueryReturnsAllInOrder() {
        let a = template("alpha", updatedAt: 10)
        let b = template("bravo", updatedAt: 30)
        XCTAssertEqual(filteredSessionTemplates([a, b], query: "  ").map(\.name), ["bravo", "alpha"])
    }

    func testFuzzyMatchesNameAndFolder() {
        let api = template("API server", cwd: "/Users/me/work/api", updatedAt: 10)
        let web = template("Web app", cwd: "/Users/me/work/web", updatedAt: 20)
        // Matches by name subsequence.
        XCTAssertEqual(filteredSessionTemplates([api, web], query: "api").map(\.name), ["API server"])
        // Matches by folder path too.
        XCTAssertEqual(filteredSessionTemplates([api, web], query: "web").map(\.name), ["Web app"])
    }

    func testNoMatchIsEmpty() {
        let a = template("alpha", updatedAt: 10)
        XCTAssertTrue(filteredSessionTemplates([a], query: "zzz").isEmpty)
    }
}
