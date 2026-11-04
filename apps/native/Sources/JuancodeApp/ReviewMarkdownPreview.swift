import SwiftUI
import MarkdownUI
import JuancodeCore

/// Formatting never depends on hover or the review cursor. Every source row,
/// including blank lines and hidden delimiters, keeps its own comment target.
struct ReviewMarkdownLineView: View {
    let preview: ReviewMarkdownLine
    let line: DiffLine
    let selected: Bool
    let hasComment: Bool
    let highlighted: Bool
    let onComment: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button(action: onComment) {
                Image(systemName: hasComment ? "text.bubble.fill" : "plus.bubble")
                    .font(.system(size: 12))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .opacity(hovered || selected || hasComment ? 1 : 0)
            .help("Comment on line \(line.newLine ?? line.oldLine ?? 0)")
            .accessibilityLabel("Comment on line \(line.newLine ?? line.oldLine ?? 0)")
            content
                .padding(.leading, CGFloat(preview.indent) * 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .padding(.trailing, 12)
        .frame(minHeight: 22)
        .background(highlighted ? Color.yellow.opacity(0.2) : selected ? Color.accentColor.opacity(0.1) : Color.clear)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Color.accentColor).frame(width: 2) }
        }
        .onHover { hovered = $0 }
    }

    @ViewBuilder private var content: some View {
        switch preview.content {
        case .blank: Color.clear.frame(height: 18)
        case .markdown(let text): markdown(text)
        case .code(let text):
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 13, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .background(Color.primary.opacity(0.04))
        case .source(let text):
            Text(text).font(.system(size: 14, design: .monospaced))
        case .table(let cells):
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                    markdown(cell)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .overlay(Rectangle().stroke(Color.secondary.opacity(0.2)))
                }
            }
        }
    }

    private func markdown(_ text: String) -> some View {
        Markdown(text)
            .markdownTheme(.gitHub.text {
                ForegroundColor(.primary)
                BackgroundColor(nil)
                FontSize(16)
            })
            .markdownBlockStyle(\.paragraph) { configuration in configuration.label.markdownMargin(top: 0, bottom: 0) }
    }
}
