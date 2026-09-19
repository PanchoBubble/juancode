import Foundation

/// Pure, SwiftUI-free syntax tokenizer for the native ChangesPanel diff
/// (juancode-idg). Splash (JohnSundell) was rejected because it is Swift-ONLY,
/// while this repo is multi-language (TS/JS/JSON/Swift/…); a TextMate/tree-sitter
/// grammar engine would be a heavyweight dependency for a per-line diff highlighter.
/// Instead this is a lightweight, dependency-free single-line tokenizer covering a
/// useful common subset — strings, line/block comments, numbers, and a per-language
/// keyword set — driven by the file extension. It produces typed token ranges that
/// the SwiftUI view maps to a warm vim-like color palette, layered on top of the
/// diff add/remove backgrounds. Being pure logic keeps it unit-testable here in the
/// service layer with no UI deps.
///
/// LIMITATIONS (by design):
///  - Single-line only: a `/* … */` block comment that spans lines is highlighted as
///    a comment only on lines where the opener is present; diffs rarely show whole
///    multi-line comment bodies and tracking cross-line state per hunk isn't worth
///    the complexity. Unterminated strings/comments run to end-of-line.
///  - No semantic awareness (scopes, types vs values): keyword matching is lexical.
///  - Unknown extensions fall back to a generic C-like profile (strings/comments/
///    numbers, no keywords), which is still useful across most code.

/// The kind of a highlighted token. The view maps each to a vim-like color.
public enum SyntaxTokenKind: Sendable, Equatable {
    case keyword
    case string
    case comment
    case number
    case type   // capitalized identifiers / type-ish words
    case plain
}

/// A highlighted span over a line: a half-open UTF-16-agnostic character range
/// (`Range<String.Index>` into the *line text*) and its token kind.
public struct SyntaxToken: Sendable, Equatable {
    public let range: Range<String.Index>
    public let kind: SyntaxTokenKind
    public init(range: Range<String.Index>, kind: SyntaxTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// A per-language lexing profile: comment markers, string delimiters, and keywords.
struct LanguageProfile: Sendable {
    let lineComment: [String]
    let blockCommentOpen: String?
    let blockCommentClose: String?
    let stringDelimiters: [Character]
    /// True when a backslash escapes the next char inside a string (most C-likes).
    let stringEscapes: Bool
    let keywords: Set<String>
    /// When true, an identifier starting with an uppercase letter is tokenized as a
    /// `.type` (matches the vim convention of coloring type names).
    let capitalizedAsType: Bool
}

/// Resolve a `LanguageProfile` from a file path's extension. Pure + case-insensitive.
func languageProfile(forPath path: String) -> LanguageProfile {
    let ext = (path as NSString).pathExtension.lowercased()
    switch ext {
    case "swift":
        return LanguageProfile(
            lineComment: ["//"], blockCommentOpen: "/*", blockCommentClose: "*/",
            stringDelimiters: ["\""], stringEscapes: true,
            keywords: swiftKeywords, capitalizedAsType: true)
    case "ts", "tsx", "js", "jsx", "mjs", "cjs":
        return LanguageProfile(
            lineComment: ["//"], blockCommentOpen: "/*", blockCommentClose: "*/",
            stringDelimiters: ["\"", "'", "`"], stringEscapes: true,
            keywords: tsKeywords, capitalizedAsType: true)
    case "json", "jsonc":
        return LanguageProfile(
            lineComment: ext == "jsonc" ? ["//"] : [], blockCommentOpen: nil, blockCommentClose: nil,
            stringDelimiters: ["\""], stringEscapes: true,
            keywords: ["true", "false", "null"], capitalizedAsType: false)
    case "py":
        return LanguageProfile(
            lineComment: ["#"], blockCommentOpen: nil, blockCommentClose: nil,
            stringDelimiters: ["\"", "'"], stringEscapes: true,
            keywords: pyKeywords, capitalizedAsType: false)
    case "sh", "bash", "zsh":
        return LanguageProfile(
            lineComment: ["#"], blockCommentOpen: nil, blockCommentClose: nil,
            stringDelimiters: ["\"", "'"], stringEscapes: true,
            keywords: shKeywords, capitalizedAsType: false)
    case "rs":
        return LanguageProfile(
            lineComment: ["//"], blockCommentOpen: "/*", blockCommentClose: "*/",
            stringDelimiters: ["\""], stringEscapes: true,
            keywords: rustKeywords, capitalizedAsType: true)
    case "go":
        return LanguageProfile(
            lineComment: ["//"], blockCommentOpen: "/*", blockCommentClose: "*/",
            stringDelimiters: ["\"", "`"], stringEscapes: true,
            keywords: goKeywords, capitalizedAsType: true)
    default:
        // Generic C-like fallback: structure without language-specific keywords.
        return LanguageProfile(
            lineComment: ["//", "#"], blockCommentOpen: "/*", blockCommentClose: "*/",
            stringDelimiters: ["\"", "'"], stringEscapes: true,
            keywords: [], capitalizedAsType: false)
    }
}

/// Tokenize a SINGLE line of code into highlighted spans, in order, covering exactly
/// the non-plain regions (callers render gaps as plain text). Pure + allocation-light:
/// one left-to-right scan, O(n) in the line length.
public func highlightLine(_ line: String, path: String) -> [SyntaxToken] {
    highlightLine(line, profile: languageProfile(forPath: path))
}

/// Tokenize using an explicit profile (the testable core).
func highlightLine(_ line: String, profile: LanguageProfile) -> [SyntaxToken] {
    guard !line.isEmpty else { return [] }
    var tokens: [SyntaxToken] = []
    var i = line.startIndex
    let end = line.endIndex

    func isIdentStart(_ c: Character) -> Bool { c == "_" || c.isLetter }
    func isIdentBody(_ c: Character) -> Bool { c == "_" || c.isLetter || c.isNumber }

    while i < end {
        let c = line[i]

        // 1. Line comment: rest of the line.
        if let lc = matchPrefix(profile.lineComment, in: line, at: i) {
            _ = lc
            tokens.append(SyntaxToken(range: i..<end, kind: .comment))
            break
        }

        // 2. Block comment (single-line scope): consume to its close or end-of-line.
        if let open = profile.blockCommentOpen, line[i...].hasPrefix(open) {
            let start = i
            var j = line.index(i, offsetBy: open.count)
            if let close = profile.blockCommentClose, let r = line.range(of: close, range: j..<end) {
                j = r.upperBound
            } else {
                j = end
            }
            tokens.append(SyntaxToken(range: start..<j, kind: .comment))
            i = j
            continue
        }

        // 3. String literal.
        if profile.stringDelimiters.contains(c) {
            let start = i
            var j = line.index(after: i)
            while j < end {
                let cj = line[j]
                if profile.stringEscapes, cj == "\\" {
                    j = line.index(after: j)
                    if j < end { j = line.index(after: j) }
                    continue
                }
                if cj == c { j = line.index(after: j); break }
                j = line.index(after: j)
            }
            tokens.append(SyntaxToken(range: start..<j, kind: .string))
            i = j
            continue
        }

        // 4. Number (int/float/hex). Must start at a digit (a leading dot like `.5`
        //    is uncommon enough to skip; `0x`/`0b`/`1.5e3` are covered).
        if c.isNumber {
            let start = i
            var j = i
            while j < end {
                let cj = line[j]
                if cj.isNumber || cj == "." || cj == "_"
                    || ("a"..."f").contains(Character(cj.lowercased()))
                    || cj == "x" || cj == "o" || cj == "b" {
                    j = line.index(after: j)
                } else { break }
            }
            tokens.append(SyntaxToken(range: start..<j, kind: .number))
            i = j
            continue
        }

        // 5. Identifier / keyword / type.
        if isIdentStart(c) {
            let start = i
            var j = line.index(after: i)
            while j < end, isIdentBody(line[j]) { j = line.index(after: j) }
            let word = String(line[start..<j])
            if profile.keywords.contains(word) {
                tokens.append(SyntaxToken(range: start..<j, kind: .keyword))
            } else if profile.capitalizedAsType, let f = word.first, f.isUppercase {
                tokens.append(SyntaxToken(range: start..<j, kind: .type))
            }
            // else: plain identifier — emit nothing (rendered as plain text).
            i = j
            continue
        }

        // 6. Anything else (punctuation, whitespace): plain — skip one char.
        i = line.index(after: i)
    }
    return tokens
}

/// Return the matched prefix string from `candidates` at `idx`, or nil.
private func matchPrefix(_ candidates: [String], in line: String, at idx: String.Index) -> String? {
    for p in candidates where !p.isEmpty && line[idx...].hasPrefix(p) { return p }
    return nil
}

// MARK: - Keyword sets

private let swiftKeywords: Set<String> = [
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func",
    "import", "init", "inout", "internal", "let", "open", "operator", "private",
    "precedencegroup", "protocol", "public", "rethrows", "static", "struct", "subscript",
    "typealias", "var", "actor", "async", "await", "nonisolated", "isolated", "any",
    "some", "break", "case", "catch", "continue", "default", "defer", "do", "else",
    "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch",
    "where", "while", "as", "is", "nil", "self", "Self", "super", "throws", "true",
    "false", "try", "lazy", "weak", "unowned", "mutating", "nonmutating", "final",
    "indirect", "convenience", "override", "required", "dynamic", "optional", "get", "set",
]

private let tsKeywords: Set<String> = [
    "abstract", "any", "as", "asserts", "async", "await", "boolean", "break", "case",
    "catch", "class", "const", "continue", "debugger", "declare", "default", "delete",
    "do", "else", "enum", "export", "extends", "false", "finally", "for", "from",
    "function", "get", "if", "implements", "import", "in", "infer", "instanceof",
    "interface", "is", "keyof", "let", "namespace", "never", "new", "null", "number",
    "object", "of", "package", "private", "protected", "public", "readonly", "return",
    "satisfies", "set", "static", "string", "super", "switch", "symbol", "this", "throw",
    "true", "try", "type", "typeof", "undefined", "unique", "unknown", "var", "void",
    "while", "with", "yield", "let", "module", "require",
]

private let pyKeywords: Set<String> = [
    "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class",
    "continue", "def", "del", "elif", "else", "except", "finally", "for", "from",
    "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass",
    "raise", "return", "try", "while", "with", "yield", "match", "case", "self",
]

private let shKeywords: Set<String> = [
    "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case",
    "esac", "function", "in", "select", "return", "local", "export", "readonly", "echo",
    "set", "unset", "shift", "exit", "source", "alias", "declare", "trap",
]

private let rustKeywords: Set<String> = [
    "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
    "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
    "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super",
    "trait", "true", "type", "unsafe", "use", "where", "while",
]

private let goKeywords: Set<String> = [
    "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
    "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
    "return", "select", "struct", "switch", "type", "var", "nil", "true", "false",
]
