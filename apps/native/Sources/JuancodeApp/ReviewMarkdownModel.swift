import Foundation
import JuancodeCore
import cmark_gfm
import cmark_gfm_extensions

/// One preview per original diff row. Parse the whole hunk first so fences,
/// references and inline markup spanning source lines keep their Markdown context.
struct ReviewMarkdownLine: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case markdown(String)
        case code(String)
        case table([String])
        case blank
        case source(String)
    }

    var content: Content
    var indent = 0

    static func lines(in rows: [ReviewRow], deleted: Bool) -> [Int: Self] {
        var result: [Int: Self] = [:]
        var run: [Int] = []
        func flush() {
            guard !run.isEmpty else { return }
            let source = run.compactMap { rows[$0].line?.text }
            for (index, text) in source.enumerated() {
                result[run[index]] = Self(content: text.trimmingCharacters(in: .whitespaces).isEmpty
                    ? .blank : .source(text))
            }
            parse(source) { line, preview in
                guard run.indices.contains(line) else { return }
                result[run[line]] = preview
            }
            run.removeAll(keepingCapacity: true)
        }
        for (index, row) in rows.enumerated() {
            guard let line = row.line else { flush(); continue }
            if deleted ? line.kind != .insert : line.kind != .delete { run.append(index) }
        }
        flush()
        return result
    }

    private static func parse(_ source: [String], emit: (Int, Self) -> Void) {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return }
        defer { cmark_parser_free(parser) }
        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        let text = source.joined(separator: "\n")
        cmark_parser_feed(parser, text, text.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return }
        defer { cmark_node_free(document) }

        func visit(_ node: UnsafeMutablePointer<cmark_node>, indent: Int = 0, listDepth: Int = 0) {
            let type = String(cString: cmark_node_get_type_string(node))
            let start = Int(cmark_node_get_start_line(node)) - 1
            let end = Int(cmark_node_get_end_line(node)) - 1
            switch type {
            case "paragraph", "heading":
                let lines = inline(node)
                for (line, content) in lines {
                    var markdown = content
                    if type == "heading" {
                        markdown = String(repeating: "#", count: Int(cmark_node_get_heading_level(node))) + " " + markdown
                    }
                    if let parent = cmark_node_parent(node),
                       ["item", "tasklist"].contains(String(cString: cmark_node_get_type_string(parent))),
                       line == Int(cmark_node_get_start_line(parent)) - 1 {
                        // Keep ordered/task markers from the actual source; they are
                        // outside the inline AST and must not shift the comment anchor.
                        let prefix = source[line].prefix { $0.isWhitespace || $0 == "-" || $0 == "+" || $0 == "*" || $0.isNumber || $0 == "." || $0 == ")" }
                        let trimmed = source[line].trimmingCharacters(in: .whitespaces)
                        let task = trimmed.range(of: #"^[-+*] \[[ xX]\] "#, options: .regularExpression)
                        markdown = (task.map { String(trimmed[$0]) } ?? String(prefix).trimmingCharacters(in: .whitespaces) + " ") + markdown
                    }
                    emit(line, Self(content: .markdown(markdown), indent: indent))
                }
                // Setext heading underlines are syntax, but remain commentable.
                if type == "heading", end > start, lines[end] == nil { emit(end, Self(content: .blank)) }
            case "code_block":
                let literal = cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
                var length: Int32 = 0
                var offset: Int32 = 0
                var character: CChar = 0
                let fenced = cmark_node_get_fenced(node, &length, &offset, &character) != 0
                let first = start + (fenced ? 1 : 0)
                if fenced { emit(start, Self(content: .blank, indent: indent)) }
                let code = literal.split(separator: "\n", omittingEmptySubsequences: false)
                for (index, line) in code.enumerated() where first + index <= end {
                    // The final empty component belongs to the closing fence.
                    if index == code.count - 1 && line.isEmpty { continue }
                    emit(first + index, Self(content: .code(String(line)), indent: indent))
                }
                if fenced, end >= first + code.count - 1 { emit(end, Self(content: .blank, indent: indent)) }
            case "table":
                var row = cmark_node_first_child(node)
                while let current = row {
                    var cells: [String] = []
                    var cell = cmark_node_first_child(current)
                    while let currentCell = cell {
                        cells.append(inline(currentCell).sorted { $0.key < $1.key }.map(\.value).joined(separator: " "))
                        cell = cmark_node_next(currentCell)
                    }
                    emit(Int(cmark_node_get_start_line(current)) - 1, Self(content: .table(cells), indent: indent))
                    row = cmark_node_next(current)
                }
                if start + 1 <= end { emit(start + 1, Self(content: .blank, indent: indent)) }
            case "thematic_break": emit(start, Self(content: .markdown("---"), indent: indent))
            default:
                var child = cmark_node_first_child(node)
                while let current = child {
                    let extra = type == "block_quote" || (type == "list" && listDepth > 0) ? 1 : 0
                    visit(current, indent: indent + extra, listDepth: listDepth + (type == "list" ? 1 : 0))
                    child = cmark_node_next(current)
                }
            }
        }
        visit(document)
    }

    /// Project inline nodes onto their source lines, repeating their formatting
    /// around each fragment. In particular **multi-line emphasis** and reference
    /// links cannot be parsed correctly by parsing each raw line independently.
    private static func inline(_ node: UnsafeMutablePointer<cmark_node>) -> [Int: String] {
        let type = String(cString: cmark_node_get_type_string(node))
        let start = Int(cmark_node_get_start_line(node)) - 1
        if type == "softbreak" || type == "linebreak" { return [:] }
        if let literal = cmark_node_get_literal(node) {
            let text = String(cString: literal)
            let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
            var result: [Int: String] = [:]
            for (index, part) in parts.enumerated() {
                if type == "code" {
                    let fence = String(repeating: "`", count: max(1, part.split(whereSeparator: { $0 != "`" }).map(\.count).max().map { $0 + 1 } ?? 1))
                    result[start + index] = fence + " " + part + " " + fence
                } else {
                    result[start + index] = part.reduce(into: "") { out, char in
                        if #"\`*_{}[]<>()!#+-.|~"#.contains(char) { out.append("\\") }
                        out.append(char)
                    }
                }
            }
            return result
        }
        var result: [Int: String] = [:]
        var child = cmark_node_first_child(node)
        while let current = child {
            for (line, text) in inline(current) { result[line, default: ""] += text }
            child = cmark_node_next(current)
        }
        return result.mapValues { text in
            func wrapped(_ marker: String) -> String {
                let leading = text.prefix(while: \.isWhitespace)
                let trailing = text.reversed().prefix(while: \.isWhitespace).reversed()
                let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return text }
                return String(leading) + marker + body + marker + String(trailing)
            }
            switch type {
            case "strong": return wrapped("**")
            case "emph": return wrapped("*")
            case "strikethrough": return wrapped("~~")
            case "link", "image":
                let url = cmark_node_get_url(node).map { String(cString: $0) } ?? ""
                return (type == "image" ? "!" : "") + "[" + text + "](<" + url + ">)"
            default: return text
            }
        }
    }
}
