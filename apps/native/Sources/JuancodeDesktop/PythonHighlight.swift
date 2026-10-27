import Foundation
import JuancodeCore
import SwiftTreeSitter
import TreeSitterPython

/// Parse each side of each hunk independently. Omitted sections are not joined:
/// a string opened in one hunk must never swallow an unrelated later hunk.
/// Results align with the flattened diff rows; no parser crosses a task boundary.
public func highlightDiff(_ hunks: [DiffHunk], path: String) -> [[SyntaxToken]] {
    guard ["py", "pyi", "pyw"].contains((path as NSString).pathExtension.lowercased()) else {
        return hunks.flatMap(\.lines).map { highlightLine($0.text, path: path) }
    }
    return hunks.flatMap { hunk in
        var result = hunk.lines.map { highlightLine($0.text, path: path) }
        for oldSide in [true, false] {
            let indices = hunk.lines.indices.filter {
                oldSide ? hunk.lines[$0].kind != .insert : hunk.lines[$0].kind != .delete
            }
            let lines = indices.map { hunk.lines[$0].text }
            guard let tokens = PythonHighlight.lines(lines) else { continue }
            for (index, row) in indices.enumerated() { result[row] = tokens[index] }
        }
        return result
    }
}

enum PythonHighlight {
    // Compiled once and immutable. Keep the small UI-specific query in the binary
    // so packaged apps do not depend on locating a grammar resource bundle.
    static let language = Language(tree_sitter_python())
    static let query = try? Query(language: language, data: Data("""
    (identifier) @variable
    (attribute attribute: (identifier) @property)
    ((identifier) @type (#match? @type "^[A-Z]"))
    (type (identifier) @type)
    (class_definition name: (identifier) @type)
    (call function: (identifier) @function)
    (call function: (attribute attribute: (identifier) @function.method))
    (function_definition name: (identifier) @function)
    (decorator (identifier) @function)
    (parameters (identifier) @variable.parameter)
    (default_parameter name: (identifier) @variable.parameter)
    (typed_parameter (identifier) @variable.parameter)
    (typed_default_parameter name: (identifier) @variable.parameter)
    (list_splat_pattern (identifier) @variable.parameter)
    (dictionary_splat_pattern (identifier) @variable.parameter)
    (comment) @comment
    (string) @string
    (interpolation) @embedded
    (escape_sequence) @string.escape
    [(integer) (float)] @number
    [(none) (true) (false)] @keyword
    ["as" "assert" "async" "await" "break" "class" "continue" "def"
     "del" "elif" "else" "except" "finally" "for" "from" "global" "if"
     "import" "lambda" "nonlocal" "pass" "raise" "return" "try" "while"
     "with" "yield" "match" "case" "and" "or" "not" "in" "is"] @keyword
    "@" @function
    "->" @keyword
    """.utf8))

    /// UTF-16 is the parser's native Swift encoding. Convert clipped ranges back
    /// into indices of the original row strings, including non-ASCII identifiers.
    static func lines(_ lines: [String]) -> [[SyntaxToken]]? {
        guard !lines.isEmpty else { return [] }
        guard let query else { return nil }
        let source = lines.joined(separator: "\n")
        let parser = Parser()
        guard (try? parser.setLanguage(language)) != nil,
              let tree = parser.parse(source) else { return nil }
        let captures = query.execute(in: tree).resolve(with: .init(string: source)).highlights()
        var starts: [Int] = []
        var offset = 0
        for line in lines { starts.append(offset); offset += line.utf16.count + 1 }
        var result = Array(repeating: [SyntaxToken](), count: lines.count)
        for capture in captures {
            let range = capture.range
            // Find the first intersecting row without scanning the whole document
            // for every token (large newly-added files commonly have many tokens).
            var low = 0
            var high = starts.count
            while low < high {
                let mid = (low + high) / 2
                if starts[mid] <= range.location { low = mid + 1 } else { high = mid }
            }
            var row = max(0, low - 1)
            while row < lines.count && starts[row] < NSMaxRange(range) {
                let clipped = NSIntersectionRange(range, NSRange(location: starts[row], length: lines[row].utf16.count))
                if clipped.length > 0,
                   let indices = Range(NSRange(location: clipped.location - starts[row], length: clipped.length), in: lines[row]) {
                    result[row].append(SyntaxToken(range: indices, kind: kind(capture.name)))
                }
                row += 1
            }
        }
        return result
    }

    private static func kind(_ name: String) -> SyntaxTokenKind {
        switch name {
        case "variable.parameter": return .parameter
        case "variable": return .variable
        case "property": return .property
        case "type": return .type
        case "function", "function.method": return .function
        case "comment": return .comment
        case "string", "string.escape": return .string
        case "number": return .number
        case "keyword": return .keyword
        default: return .plain
        }
    }
}
