import SwiftUI
import JuancodeServices

/// The code an inline review comment hangs off, rendered from GitHub's `diffHunk`
/// right in the conversation timeline — the point being that a review can be read
/// end to end without opening github.com. Collapsed to the hunk's tail (the
/// commented line plus a little context above it, which is where the reviewer was
/// looking) with a click to unfold the rest.
///
/// Deliberately read-only and gesture-free: the click-to-comment diff rows live in
/// `ChangesPanel`'s Diff tab, and mixing that interaction into a comment card would
/// fight the card's own Reply affordance.
struct ReviewHunkView: View {
    /// GitHub's raw `@@ … @@` hunk for the comment.
    let diffHunk: String
    /// The commented file's path — only used to pick the syntax highlighter.
    let path: String

    /// Lines kept while collapsed. Four is enough to read a one-line note in
    /// context without the timeline turning into a diff view.
    private static let collapsedLines = 4

    @State private var expanded = false

    var body: some View {
        let hunk = reviewHunk(diffHunk, visible: expanded ? 0 : Self.collapsedLines)
        if !hunk.lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if hunk.hiddenAbove > 0 {
                    expandButton(hidden: hunk.hiddenAbove, collapse: false)
                } else if expanded {
                    expandButton(hidden: 0, collapse: true)
                }
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                    ReviewHunkLineRow(line: line, path: path)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1))
        }
    }

    /// The unfold control. Hidden lines are always *above* the shown tail, so it
    /// sits at the top of the box — the same place GitHub puts its expand arrows.
    private func expandButton(hidden: Int, collapse: Bool) -> some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: collapse ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8))
                Text(collapse ? "collapse" : "\(hidden) more line\(hidden == 1 ? "" : "s")")
                    .font(.system(size: 9))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickCursor()
    }
}

/// One line of a review comment's hunk: line-number gutter, then the tinted
/// +/-/space marker and the syntax-highlighted content, over an add/remove wash.
/// Mirrors `ChangesPanel`'s `DiffLineRow` at the GitHub panel's smaller type size,
/// minus the comment gestures and the drag-select overlays.
private struct ReviewHunkLineRow: View {
    let line: DiffLine
    let path: String

    var body: some View {
        HStack(spacing: 0) {
            Text((line.newLine ?? line.oldLine).map(String.init) ?? "")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .trailing)
                .padding(.trailing, 4)
            Text(content)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .background(background)
    }

    private var content: AttributedString {
        var out = AttributedString(marker)
        out.foregroundColor = markerColor
        out.append(VimSyntaxPalette.attributed(line.text, path: path))
        return out
    }

    private var marker: String {
        switch line.kind {
        case .insert: return "+"
        case .delete: return "-"
        case .context: return " "
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .insert: return VimSyntaxPalette.diffAdd
        case .delete: return VimSyntaxPalette.diffRemove
        case .context: return .secondary
        }
    }

    private var background: Color {
        switch line.kind {
        case .insert: return Color.green.opacity(0.10)
        case .delete: return Color.red.opacity(0.10)
        case .context: return .clear
        }
    }
}
