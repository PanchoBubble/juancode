import SwiftUI
import MarkdownUI
import JuancodeCore
import cmark_gfm
import cmark_gfm_extensions

/// A rendered block retains its original review row indices. Never infer source
/// positions from the rendered text: Markdown removes delimiters and joins lines.
struct ReviewMarkdownBlock: Equatable, Sendable {
    let rows: ClosedRange<Int>
    let markdown: String

    static func blocks(in rows: [ReviewRow], deleted: Bool) -> [ReviewMarkdownBlock] {
        var result: [ReviewMarkdownBlock] = []
        var run: [Int] = []
        func flush() {
            guard !run.isEmpty else { return }
            let text = run.compactMap { rows[$0].line?.text }.joined(separator: "\n")
            result += parse(text, sourceRows: run)
            run.removeAll(keepingCapacity: true)
        }
        for (index, row) in rows.enumerated() {
            guard let line = row.line else {
                flush()
                continue
            }
            if deleted ? line.kind != .insert : line.kind != .delete {
                run.append(index)
            }
        }
        flush()
        return result
    }

    private static func parse(_ source: String, sourceRows: [Int]) -> [ReviewMarkdownBlock] {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return [] }
        defer { cmark_parser_free(parser) }
        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }
        cmark_parser_feed(parser, source, source.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return [] }
        defer { cmark_node_free(document) }
        var result: [ReviewMarkdownBlock] = []
        var child = cmark_node_first_child(document)
        while let node = child {
            let start = Int(cmark_node_get_start_line(node)) - 1
            let end = Int(cmark_node_get_end_line(node)) - 1
            if start >= 0, end >= start, end < sourceRows.count,
               let normalized = cmark_render_commonmark(node, CMARK_OPT_DEFAULT, 0) {
                // Rendering the parsed node resolves reference links using the
                // whole run, including definitions appearing later in the hunk.
                defer { free(normalized) }
                result.append(Self(rows: sourceRows[start]...sourceRows[end],
                                   markdown: String(cString: normalized)))
            }
            child = cmark_node_next(node)
        }
        return result
    }
}

struct ReviewMarkdownBlockView: View {
    let block: ReviewMarkdownBlock
    let selected: Bool

    var body: some View {
        Markdown(block.markdown)
            .markdownTheme(.gitHub.text {
                ForegroundColor(.primary)
                BackgroundColor(nil)
                FontSize(16)
            })
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(selected ? Color.accentColor.opacity(0.10) : Color.clear)
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(Color.accentColor).frame(width: 2) }
            }
    }
}
