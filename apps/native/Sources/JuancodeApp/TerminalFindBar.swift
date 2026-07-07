import SwiftUI
import AppKit
import JuancodeCore

// MARK: - In-pane find bar (juancode-972)
//
// ⌘F over the visible terminal pane. Cross-session transcript FTS lives in
// SearchPanel.swift; THIS searches *inside* one pane's scrollback.
//
// Achievable level: neither terminal surface exposes a usable search/scroll API
// (libghostty has none; SwiftTerm keeps its SearchService internal), so we search
// the data we already own — `model.scrollback(id)` — stripped of ANSI by the pure
// `TerminalTextExtractor`. We can't scroll the GPU surface to a match, so instead
// of an in-surface highlight we surface the match count, prev/next navigation, and
// the current match's line rendered in context with the hit highlighted (and a
// copy button). Honest about the surface: it finds and shows, it can't jump the
// live viewport.

/// Overlaid on the visible session's terminal pane, top-trailing. Bound to
/// `model.showingFindBar`; the query/results are local @State keyed to `sessionId`.
struct TerminalFindBar: View {
    @Environment(AppModel.self) private var model
    let sessionId: String

    @State private var query = ""
    /// ANSI-stripped scrollback lines, snapshotted when the bar opens / reloads.
    @State private var lines: [String] = []
    @State private var matches: [TerminalMatch] = []
    @State private var current: Int?
    @FocusState private var fieldFocused: Bool

    private var currentMatch: TerminalMatch? {
        guard let current, matches.indices.contains(current) else { return nil }
        return matches[current]
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            bar
            if let match = currentMatch { context(match) }
        }
        .padding(10)
        .onAppear { reload() }
        .onChange(of: sessionId) { _, _ in query = ""; reload() }
        // A repeat ⌘F while open re-snapshots (catches new output) and refocuses.
        .onChange(of: model.findFocusToken) { _, _ in reload(); fieldFocused = true }
        .onChange(of: query) { _, _ in recompute() }
    }

    // MARK: bar

    private var bar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Find in scrollback", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 200)
                .focused($fieldFocused)
                .onSubmit { navigate(forward: true) }
            Text(countLabel)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
            Divider().frame(height: 16)
            Button { navigate(forward: false) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(matches.isEmpty)
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .help("Previous match (⇧return / ⌘⇧G)")
            .clickCursor()
            Button { navigate(forward: true) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(matches.isEmpty)
            .keyboardShortcut("g", modifiers: .command)
            .help("Next match (return / ⌘G)")
            .clickCursor()
            Button { model.closeFindBar() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
            .clickCursor()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        // Esc / return / shift-return work while the field holds focus.
        .onKeyPress(.escape) { model.closeFindBar(); return .handled }
        .onKeyPress(keys: [.return]) { press in
            navigate(forward: !press.modifiers.contains(.shift))
            return .handled
        }
    }

    private var countLabel: String {
        if query.isEmpty { return "" }
        if matches.isEmpty { return "No results" }
        let position = (current ?? 0) + 1
        return "\(position) of \(matches.count)"
    }

    // MARK: match context
    //
    // We can't scroll the terminal to the hit, so show the matched line (with its
    // scrollback line number) and highlight the match, plus a copy button.
    private func context(_ match: TerminalMatch) -> some View {
        let line = lines.indices.contains(match.line) ? lines[match.line] : ""
        return HStack(alignment: .top, spacing: 8) {
            Text("L\(match.line + 1)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(highlighted(line, match: match))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .frame(maxWidth: 360, alignment: .leading)
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(line, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Copy this line")
            .clickCursor()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }

    /// The matched line as an AttributedString with the hit range emphasized.
    /// Built by slicing the line's Characters into pre/match/post so offsets stay
    /// aligned with the extractor's Character-based match indices.
    private func highlighted(_ line: String, match: TerminalMatch) -> AttributedString {
        let chars = Array(line)
        let start = max(0, min(match.start, chars.count))
        let end = max(start, min(match.start + match.length, chars.count))
        var attr = AttributedString(String(chars[0..<start]))
        var hit = AttributedString(String(chars[start..<end]))
        hit.backgroundColor = .yellow.opacity(0.85)
        hit.foregroundColor = .black
        attr.append(hit)
        attr.append(AttributedString(String(chars[end..<chars.count])))
        return attr
    }

    // MARK: actions

    private func reload() {
        lines = TerminalTextExtractor.lines(fromANSI: model.scrollback(sessionId))
        fieldFocused = true
        recompute()
    }

    private func recompute() {
        matches = TerminalFind.matches(of: query, in: lines)
        current = matches.isEmpty ? nil : 0
    }

    private func navigate(forward: Bool) {
        current = TerminalFind.step(from: current, count: matches.count, forward: forward)
    }
}
