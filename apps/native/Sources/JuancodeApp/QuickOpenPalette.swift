import SwiftUI
import JuancodeCore
import JuancodeServices

// MARK: - Quick Open palette (juancode-dlr)
//
// A ⌘P fuzzy file-open palette scoped to the SELECTED session's effective worktree.
// The worktree is indexed via `git ls-files` (fast, gitignore-aware) and cached, so a
// 10k-file repo opens instantly; the FSEvents watcher keeps the index fresh. Ranking
// and match highlighting come from the pure `quickOpenResults`/`fuzzyMatchPath` core.
// Picking a file opens it in the session's editor pane (Return), inserts its path into
// the prompt (⌘Return), or — when the file is dirty — reveals it in the Changes panel
// (⌘⇧Return).

/// Presented as a sheet from `RootView`, toggled by `model.showingQuickOpen` (⌘P).
struct QuickOpenView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    private var results: [QuickOpenItem] {
        quickOpenResults(model.quickOpenFiles, query: query, limit: 200)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if results.isEmpty {
                empty
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 480)
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) { openInEditor(); return .handled }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onAppear { searchFocused = true }
    }

    // MARK: header / search

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Open a file in this session's worktree…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                .onSubmit { openInEditor() }
            if model.quickOpenLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { idx, item in
                        row(item, selected: idx == selectedIndex)
                            .id(idx)
                            .onTapGesture { selectedIndex = idx; openInEditor() }
                    }
                }
            }
            .onChange(of: selectedIndex) { _, i in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(i, anchor: .center) }
            }
        }
    }

    private func row(_ item: QuickOpenItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            highlighted(item.path, ranges: item.ranges)
                .font(.system(size: 13)).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 8)
            if model.quickOpenIsDirty(item.path) {
                Text("changed")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.orange.opacity(0.18))
                    .clipShape(Capsule())
                    .foregroundStyle(.orange)
                    .help("Uncommitted — ⌘⇧return reveals it in Changes")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .pointerCursor()
    }

    /// The path with matched offsets emphasized in the accent colour.
    private func highlighted(_ path: String, ranges: [Range<Int>]) -> Text {
        let chars = Array(path)
        guard !ranges.isEmpty else { return Text(path) }
        var hit = [Bool](repeating: false, count: chars.count)
        for r in ranges {
            for i in r where i >= 0 && i < chars.count { hit[i] = true }
        }
        var out = Text("")
        var i = 0
        while i < chars.count {
            let start = i
            let flag = hit[i]
            while i < chars.count, hit[i] == flag { i += 1 }
            let seg = Text(String(chars[start ..< i]))
            out = out + (flag ? seg.foregroundColor(.accentColor).bold() : seg)
        }
        return out
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Spacer()
            if model.quickOpenLoading {
                Text("Indexing files…").foregroundStyle(.secondary).font(.system(size: 12))
            } else if model.quickOpenFiles.isEmpty {
                Text("No files in this worktree.").foregroundStyle(.secondary).font(.system(size: 12))
            } else {
                Text("No files match \"\(query)\".").foregroundStyle(.secondary).font(.system(size: 12))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            PaletteKeyHint(key: "↑↓", label: "Navigate")
            PaletteKeyHint(key: "return", label: "Open in editor")
            PaletteKeyHint(key: "⌘ return", label: "Insert path")
            if let item = selected, model.quickOpenIsDirty(item.path) {
                PaletteKeyHint(key: "⌘⇧ return", label: "Reveal in Changes")
            }
            Spacer()
            Button("Close") { dismiss() }.clickCursor()
                .keyboardShortcut(.cancelAction)
            // Hidden accelerators for the secondary actions on the highlighted row.
            Button("") { insertPath() }
                .keyboardShortcut(.return, modifiers: .command)
                .frame(width: 0, height: 0).opacity(0)
            Button("") { revealInChanges() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .frame(width: 0, height: 0).opacity(0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .font(.system(size: 11))
    }

    // MARK: actions

    private var selected: QuickOpenItem? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = max(0, min(results.count - 1, selectedIndex + delta))
    }

    private func openInEditor() {
        guard let item = selected else { return }
        model.quickOpenInEditor(item.path)
        dismiss()
    }

    private func insertPath() {
        guard let item = selected else { return }
        model.quickOpenCopyPath(item.path)
        dismiss()
    }

    private func revealInChanges() {
        guard let item = selected, model.quickOpenIsDirty(item.path) else { return }
        model.quickOpenReveal(item.path)
        dismiss()
    }
}
