import XCTest
import JuancodeCore
@testable import JuancodeDesktop

final class PythonHighlightTests: XCTestCase {
    private func kind(_ word: String, in line: String, tokens: [SyntaxToken]) -> SyntaxTokenKind? {
        guard let index = line.range(of: word)?.lowerBound else { return nil }
        return tokens.last { $0.range.contains(index) }?.kind
    }

    func testDefinitionsParametersCallsAndUnicode() throws {
        let lines = ["@router.get('/path')", "def résumé(user: User, count=1, *args, **kwargs):",
                     "    return service.fetch(user.name)"]
        let tokens = try XCTUnwrap(PythonHighlight.lines(lines))
        XCTAssertEqual(kind("résumé", in: lines[1], tokens: tokens[1]), .function)
        XCTAssertEqual(kind("user", in: lines[1], tokens: tokens[1]), .parameter)
        XCTAssertEqual(kind("count", in: lines[1], tokens: tokens[1]), .parameter)
        XCTAssertEqual(kind("args", in: lines[1], tokens: tokens[1]), .parameter)
        XCTAssertEqual(kind("User", in: lines[1], tokens: tokens[1]), .type)
        XCTAssertEqual(kind("service", in: lines[2], tokens: tokens[2]), .variable)
        XCTAssertEqual(kind("fetch", in: lines[2], tokens: tokens[2]), .function)
        XCTAssertEqual(kind("name", in: lines[2], tokens: tokens[2]), .property)
    }

    func testMultilineStringAndInterpolation() throws {
        let lines = ["\"\"\"A docstring", "if 404 and 'quoted' # still prose", "\"\"\"",
                     "result = f\"hello {user.name}\""]
        let tokens = try XCTUnwrap(PythonHighlight.lines(lines))
        XCTAssertEqual(kind("if", in: lines[1], tokens: tokens[1]), .string)
        XCTAssertEqual(kind("404", in: lines[1], tokens: tokens[1]), .string)
        XCTAssertEqual(kind("user", in: lines[3], tokens: tokens[3]), .variable)
        XCTAssertEqual(kind("name", in: lines[3], tokens: tokens[3]), .property)
    }

    func testDiffSidesAndHunksDoNotLeakStringState() {
        let diff = """
        @@ -1,3 +1,2 @@
        -\"\"\"old doc
        -return old
        -\"\"\"
        +def fresh(value):
        +    return value
        @@ -80,1 +79,1 @@
        -old = 1
        +new = 2
        """
        let hunks = parseUnifiedDiff(diff)
        let lines = hunks.flatMap(\.lines)
        let tokens = highlightDiff(hunks, path: "test.py")
        XCTAssertEqual(tokens.count, lines.count)
        XCTAssertEqual(kind("return", in: lines[1].text, tokens: tokens[1]), .string)
        XCTAssertEqual(kind("fresh", in: lines[3].text, tokens: tokens[3]), .function)
        XCTAssertEqual(kind("return", in: lines[4].text, tokens: tokens[4]), .keyword)
        XCTAssertEqual(kind("new", in: lines[6].text, tokens: tokens[6]), .variable)
    }

    func testEmptyAndOtherLanguages() throws {
        XCTAssertEqual(try XCTUnwrap(PythonHighlight.lines([])).count, 0)
        let hunks = parseUnifiedDiff("@@ -0,0 +1 @@\n+let value = 1")
        let tokens = highlightDiff(hunks, path: "test.swift")
        XCTAssertEqual(tokens[0].first?.kind, .keyword)
    }
}
