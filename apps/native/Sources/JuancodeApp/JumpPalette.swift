import SwiftUI
import JuancodeCore
import JuancodeServices

// MARK: - Session jump palette (juancode-dr0)
//
// A ⌘K fuzzy jump palette over every session (worktree sessions included): type to
// filter across title / folder / branch, rows show the live agent-state glyph the
// sidebar rows use, needs-attention sessions sort first (see JumpPalette.swift in
// JuancodeCore for the pure ranking), Return switches to the highlighted session.
// Distinct from the transcript FTS in SearchPanel.swift — this jumps between
// sessions, it doesn't search inside them.

/// Presented as a sheet from `RootView`, toggled by `model.showingJumpPalette` (⌘K).
struct JumpPaletteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    /// Same population as the sidebar: own + discovered sessions in the workspace,
    /// minus the pinned Oracle session and (always) archived ones. A session can
    /// surface in both `sessions` and `externalSessions`, so dedupe by id (first
    /// wins) — otherwise the id→meta lookup below would trap on duplicate keys.
    private var visibleSessions: [SessionMeta] {
        var seen = Set<String>()
        return (model.sessions + model.externalSessions).filter { meta in
            guard meta.cwd != OraclePaths.controlDir,
                  Config.isUnderWorkspaceRoot(meta.cwd),
                  !meta.archived else { return false }
            return seen.insert(meta.id).inserted
        }
    }

    /// Ranked, filtered candidates — the pure core does the ordering; the query is
    /// matched against the title (double weight) and a folder/branch/path haystack,
    /// so typing a project or branch name surfaces its sessions.
    private var results: [SessionMeta] {
        let sessions = visibleSessions
        let byId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let candidates = sessions.map { meta in
            JumpCandidate(
                id: meta.id,
                title: meta.title,
                subtitle: "\(folderHint(meta)) \(meta.cwd)",
                key: SessionSortKey(
                    attention: sessionAttention(
                        live: model.isLive(meta.id),
                        activity: model.activity(meta.id),
                        unseenDone: model.unseenCompletions.contains(meta.id)),
                    updatedAt: meta.updatedAt,
                    createdAt: meta.createdAt))
        }
        return jumpResults(candidates, query: query).compactMap { byId[$0.id] }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if results.isEmpty {
                noMatches
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 460)
        // Keyboard-drive the list while the search field holds focus.
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) { activateSelection(); return .handled }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onAppear { searchFocused = true }
    }

    // MARK: header / search

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right.circle").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Jump to session, worktree, or folder…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                .onSubmit { activateSelection() }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { idx, meta in
                        row(meta, selected: idx == selectedIndex)
                            .id(idx)
                            .onTapGesture { selectedIndex = idx; activateSelection() }
                    }
                }
            }
            .onChange(of: selectedIndex) { _, i in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(i, anchor: .center) }
            }
        }
    }

    private func row(_ meta: SessionMeta, selected: Bool) -> some View {
        HStack(spacing: 10) {
            SessionStateGlyph(
                live: model.isLive(meta.id),
                activity: model.activity(meta.id),
                unseenDone: model.unseenCompletions.contains(meta.id),
                unread: model.unreadSessions.contains(meta.id),
                dormant: meta.dormant)
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.title.isEmpty ? "Untitled" : meta.title)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 3) {
                    if meta.worktreePath != nil {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Text(folderHint(meta))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if model.isExternal(meta.id) {
                Text("terminal")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
                    .foregroundStyle(.secondary)
                    .help("From your terminal — Return resumes it in juancode")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .pointerCursor()
    }

    /// Folder/worktree hint under the title: the owning project's name, plus the
    /// worktree branch (or worktree dir until the branch loads) for worktree rows.
    private func folderHint(_ meta: SessionMeta) -> String {
        let project = model.worktreeRepoRoots[meta.cwd] ?? projectCwd(for: meta.cwd)
        let name = (project as NSString).lastPathComponent
        guard meta.worktreePath != nil else { return name }
        let branch = model.folderGitState(meta.cwd)?.branch
            ?? (meta.cwd as NSString).lastPathComponent
        return "\(name) · \(branch)"
    }

    private var footer: some View {
        HStack(spacing: 16) {
            PaletteKeyHint(key: "↑↓", label: "Navigate")
            PaletteKeyHint(key: "return", label: "Open")
            Spacer()
            Button("Close") { dismiss() }.clickCursor()
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .font(.system(size: 11))
    }

    private var noMatches: some View {
        VStack(spacing: 6) {
            Spacer()
            Text(query.isEmpty ? "No sessions yet." : "No sessions match \"\(query)\".")
                .foregroundStyle(.secondary).font(.system(size: 12))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: actions

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = max(0, min(results.count - 1, selectedIndex + delta))
    }

    private func activateSelection() {
        guard results.indices.contains(selectedIndex) else { return }
        let meta = results[selectedIndex]
        if model.isExternal(meta.id) {
            model.importExternalSession(meta.id)
        } else {
            // Selecting a pooled session just flips its keep-alive pane visible
            // (juancode-073); no remount, no replay.
            model.selection = meta.id
        }
        model.flashFocusRim() // flash the landed pane's rim (juancode-vz1)
        dismiss()
    }
}

/// Small keycap + label pair for a palette footer — shared palette chrome, used by
/// the jump palette and the prompt-template palette.
struct PaletteKeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.18)).clipShape(RoundedRectangle(cornerRadius: 4))
            Text(label).foregroundStyle(.secondary)
        }
    }
}
