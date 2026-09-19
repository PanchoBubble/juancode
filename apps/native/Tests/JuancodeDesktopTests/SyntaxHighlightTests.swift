import XCTest
@testable import JuancodeDesktop

/// Unit tests for the pure single-line syntax tokenizer backing the native
/// ChangesPanel diff highlighting (juancode-idg). No SwiftUI here — only the
/// string + language -> [token] logic.
final class SyntaxHighlightTests: XCTestCase {

    /// Helper: tokenize and project to (kind, substring) pairs for easy assertion.
    private func tok(_ line: String, _ path: String) -> [(SyntaxTokenKind, String)] {
        highlightLine(line, path: path).map { ($0.kind, String(line[$0.range])) }
    }

    // MARK: - Strings

    func testSwiftString() {
        let r = tok("let x = \"hello\"", "f.swift")
        XCTAssertTrue(r.contains { $0 == (.keyword, "let") })
        XCTAssertTrue(r.contains { $0 == (.string, "\"hello\"") })
    }

    func testStringWithEscapedQuote() {
        let r = tok("\"a\\\"b\"", "f.swift")
        // The escaped quote does not terminate the string.
        XCTAssertEqual(r.first?.0, .string)
        XCTAssertEqual(r.first?.1, "\"a\\\"b\"")
    }

    func testTsTemplateAndSingleQuoteStrings() {
        XCTAssertTrue(tok("const a = 'x'", "f.ts").contains { $0 == (.string, "'x'") })
        XCTAssertTrue(tok("const a = `y`", "f.ts").contains { $0 == (.string, "`y`") })
    }

    // MARK: - Comments

    func testLineComment() {
        let r = tok("x = 1 // a note", "f.ts")
        XCTAssertTrue(r.contains { $0 == (.comment, "// a note") })
    }

    func testPythonHashComment() {
        let r = tok("x = 1  # note", "f.py")
        XCTAssertTrue(r.contains { $0 == (.comment, "# note") })
    }

    func testBlockCommentSingleLine() {
        let r = tok("a /* mid */ b", "f.swift")
        XCTAssertTrue(r.contains { $0 == (.comment, "/* mid */") })
    }

    func testUnterminatedBlockCommentRunsToEnd() {
        let r = tok("code /* open forever", "f.swift")
        XCTAssertTrue(r.contains { $0 == (.comment, "/* open forever") })
    }

    // MARK: - Numbers

    func testIntAndFloatAndHex() {
        XCTAssertTrue(tok("a = 42", "f.swift").contains { $0 == (.number, "42") })
        XCTAssertTrue(tok("a = 3.14", "f.swift").contains { $0 == (.number, "3.14") })
        XCTAssertTrue(tok("a = 0xFF", "f.swift").contains { $0 == (.number, "0xFF") })
    }

    // MARK: - Keywords / types by language

    func testSwiftKeywordsAndType() {
        let r = tok("func make() -> Widget { return nil }", "f.swift")
        XCTAssertTrue(r.contains { $0 == (.keyword, "func") })
        XCTAssertTrue(r.contains { $0 == (.keyword, "return") })
        XCTAssertTrue(r.contains { $0 == (.keyword, "nil") })
        XCTAssertTrue(r.contains { $0 == (.type, "Widget") })
    }

    func testTsKeywords() {
        let r = tok("export const fn = (): void => {}", "f.ts")
        XCTAssertTrue(r.contains { $0 == (.keyword, "export") })
        XCTAssertTrue(r.contains { $0 == (.keyword, "const") })
        XCTAssertTrue(r.contains { $0 == (.keyword, "void") })
    }

    func testPythonKeywords() {
        let r = tok("def f(): return None", "f.py")
        XCTAssertTrue(r.contains { $0 == (.keyword, "def") })
        XCTAssertTrue(r.contains { $0 == (.keyword, "return") })
        XCTAssertTrue(r.contains { $0 == (.keyword, "None") })
    }

    // MARK: - Plain identifiers emit no token

    func testPlainIdentifierNotTokenized() {
        // `myVar` is lowercase + not a keyword -> no span emitted for it.
        let r = tok("myVar = otherVar", "f.swift")
        XCTAssertFalse(r.contains { $0.1 == "myVar" })
        XCTAssertFalse(r.contains { $0.1 == "otherVar" })
    }

    // MARK: - Profiles / fallback

    func testJsonNoKeywordsButStrings() {
        let r = tok("{ \"k\": true }", "f.json")
        XCTAssertTrue(r.contains { $0 == (.string, "\"k\"") })
        XCTAssertTrue(r.contains { $0 == (.keyword, "true") })
    }

    func testUnknownExtensionFallbackStillHighlightsStructure() {
        // Unknown ext -> generic profile: strings/comments/numbers, no keywords.
        let r = tok("foo = \"bar\" // c", "f.unknownext")
        XCTAssertTrue(r.contains { $0 == (.string, "\"bar\"") })
        XCTAssertTrue(r.contains { $0 == (.comment, "// c") })
        XCTAssertFalse(r.contains { $0.0 == .keyword })
    }

    func testEmptyLineYieldsNoTokens() {
        XCTAssertTrue(highlightLine("", path: "f.swift").isEmpty)
    }

    func testProfileResolutionIsCaseInsensitive() {
        let r = tok("class X {}", "Foo.SWIFT")
        XCTAssertTrue(r.contains { $0 == (.keyword, "class") })
    }
}
