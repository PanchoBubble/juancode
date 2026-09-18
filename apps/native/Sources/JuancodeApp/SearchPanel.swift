import SwiftUI
import JuancodeCore

/// Search over persisted session history — the native analogue of the web
/// `SearchPanel.tsx`. Distinct from the sidebar's session-name filter: this asks
/// the core what its whole history mentions (the daemon's own store on the Rust
/// core, the local one on the Swift core), debounces the query, lists matching
/// sessions with a highlighted snippet, and selects the matched session on click.
/// Presented as a sheet from the sidebar toolbar's magnifying-glass button.
struct SearchPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Live text-field contents; debounced into `model.search` so we don't fire a
    /// query per keystroke (mirrors the web 200ms debounce).
    @State private var text = ""
    @State private var debounce: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var enabled: Bool { text.trimmingCharacters(in: .whitespaces).count >= 2 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search transcripts…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { scheduleSearch(immediate: true) }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Close")
                .clickCursor()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            content
        }
        .frame(width: 460, height: 420)
        .onChange(of: text) { scheduleSearch(immediate: false) }
        .onAppear { focused = true; text = model.searchQuery }
        .onDisappear { debounce?.cancel() }
    }

    @ViewBuilder private var content: some View {
        if !enabled {
            placeholder("Type at least 2 characters to search.")
        } else if model.searching && model.searchResults.isEmpty {
            placeholder("Searching…")
        } else if model.searchResults.isEmpty {
            placeholder("No transcript matches.")
        } else {
            List {
                ForEach(model.searchResults, id: \.meta.id) { hit in
                    SearchResultRow(hit: hit)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.openSearchHit(hit)
                            dismiss()
                        }
                }
            }
            .listStyle(.plain)
        }
    }

    private func placeholder(_ msg: String) -> some View {
        VStack {
            Spacer()
            Text(msg).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Debounce the query into `model.search`. `immediate` (onSubmit) skips the wait.
    private func scheduleSearch(immediate: Bool) {
        model.searchQuery = text
        debounce?.cancel()
        debounce = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { return }
            }
            model.search(text)
        }
    }
}

/// One search hit: session title + provider badge, with a highlighted snippet of
/// the matched scrollback below. Mirrors the web result button.
private struct SearchResultRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(hit.meta.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 6)
                Text(hit.meta.provider.rawValue)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if !hit.snippet.isEmpty {
                snippetText
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
        .help(hit.meta.cwd)
    }

    /// Build an AttributedString from the parsed snippet runs, emphasising the
    /// `[term]`-marked matches.
    private var snippetText: Text {
        var result = Text("")
        for run in parseSearchSnippet(hit.snippet) {
            if run.highlighted {
                result = result + Text(run.text).bold().foregroundColor(.orange)
            } else {
                result = result + Text(run.text)
            }
        }
        return result
    }
}
