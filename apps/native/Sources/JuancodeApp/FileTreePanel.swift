import SwiftUI
import JuancodeCore
import JuancodeServices

// MARK: - File-tree sidebar (Files side-panel tab)
//
// A collapsible explorer of the selected session's effective worktree: the full
// gitignore-aware listing (`git ls-files` through the shared Quick Open index) folded
// into a directory tree, decorated live from the watched `git status --porcelain`
// snapshot. Clicking a file opens it in the session's editor pane; a dirty file can
// be revealed in the Changes panel. Expanded folders are remembered per worktree for
// the app run.

struct FileTreePanel: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    /// The session's effective worktree root (its linked worktree when it has one).
    let root: String

    private var tree: [FileTreeNode] { model.fileTreeByPath[root] ?? [] }
    private var loading: Bool { model.fileTreeLoading.contains(root) }

    /// Change decoration, keyed by worktree-relative path. Renames keep only the new
    /// path — that's the one the listing shows.
    private var statusByPath: [String: WorktreeStatusEntry] {
        Dictionary(model.worktreeStatus(root).map { ($0.path, $0) },
                   uniquingKeysWith: { a, _ in a })
    }

    /// Folders with changed descendants — the subtle rollup dot.
    private var changedDirs: Set<String> {
        changedAncestorDirIDs(statusByPath.keys)
    }

    /// Expanded-folder state lives on the model per worktree, so it survives tab and
    /// session switches within a run.
    private var expanded: Binding<Set<String>> {
        Binding(get: { model.fileTreeExpandedByPath[root] ?? [] },
                set: { model.fileTreeExpandedByPath[root] = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { model.startWatchingFileTree(sessionId, path: root) }
        .onDisappear { model.stopWatchingFileTree(sessionId) }
        .perfTrackBody()
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(.secondary)
            Text((root as NSString).lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
                .help(root)
            if loading { ProgressView().controlSize(.mini) }
            Spacer()
            Button { expanded.wrappedValue = [] } label: {
                Image(systemName: "rectangle.compress.vertical")
            }
            .buttonStyle(.borderless)
            .help("Collapse all folders")
            .disabled(expanded.wrappedValue.isEmpty)
            .clickCursor()
            Button { expanded.wrappedValue = directoryNodeIDs(tree) } label: {
                Image(systemName: "rectangle.expand.vertical")
            }
            .buttonStyle(.borderless)
            .help("Expand all folders")
            .disabled(tree.isEmpty)
            .clickCursor()
        }
        .font(.system(size: 10))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var content: some View {
        if tree.isEmpty {
            VStack {
                Spacer()
                Text(loading ? "Indexing files…" : "No tracked files in this worktree.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(tree) { node in
                        WorktreeTreeRows(
                            node: node,
                            depth: 0,
                            statusByPath: statusByPath,
                            changedDirs: changedDirs,
                            expanded: expanded,
                            openFile: { model.openEditorSession(sessionId, file: $0) },
                            revealChanges: { model.openChanges(for: sessionId) })
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(NSColor.textBackgroundColor).opacity(0.3))
        }
    }
}

/// Renders one worktree tree node and (for a folder) its children recursively. A
/// folder row toggles its expansion; a file row opens the file in the session's
/// editor pane. Mirrors the ChangesPanel's `FileTreeRows`, but decorated from the
/// live status snapshot instead of a diff.
private struct WorktreeTreeRows: View {
    let node: FileTreeNode
    let depth: Int
    let statusByPath: [String: WorktreeStatusEntry]
    let changedDirs: Set<String>
    @Binding var expanded: Set<String>
    let openFile: (String) -> Void
    let revealChanges: () -> Void

    var body: some View {
        if node.isDirectory {
            folderRow
            if expanded.contains(node.id), let kids = node.children {
                ForEach(kids) { child in
                    WorktreeTreeRows(node: child, depth: depth + 1,
                                     statusByPath: statusByPath, changedDirs: changedDirs,
                                     expanded: $expanded,
                                     openFile: openFile, revealChanges: revealChanges)
                }
            }
        } else {
            fileRow
        }
    }

    private var folderRow: some View {
        Button {
            if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: expanded.contains(node.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8)).foregroundStyle(.secondary).frame(width: 10)
                Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(node.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                if changedDirs.contains(node.id) {
                    Circle().fill(.orange.opacity(0.8)).frame(width: 5, height: 5)
                        .help("Contains uncommitted changes")
                }
                Spacer(minLength: 4)
            }
            .padding(.leading, indent).padding(.trailing, 8).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickCursor()
    }

    private var fileRow: some View {
        let entry = statusByPath[node.id]
        return Button {
            openFile(node.id)
        } label: {
            HStack(spacing: 5) {
                // Align file names with folder names (account for the chevron slot).
                Image(systemName: "doc")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(node.name)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(entry.map { statusColor($0) } ?? Color.primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let entry {
                    Text(statusGlyph(entry))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor(entry))
                        .help("Uncommitted — right-click to reveal in Changes")
                }
            }
            .padding(.leading, indent).padding(.trailing, 8).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickCursor()
        .contextMenu {
            Button("Open in editor session") { openFile(node.id) }
            if entry != nil {
                Button("Reveal in Changes") { revealChanges() }
            }
        }
    }

    private var indent: CGFloat { 8 + CGFloat(depth) * 14 }

    /// One-letter change badge from the porcelain codes: untracked wins, else the
    /// work-tree code, else the staged (index) code.
    private func statusGlyph(_ e: WorktreeStatusEntry) -> String {
        if e.untracked { return "U" }
        let c = e.workTree == " " ? e.index : e.workTree
        return String(c)
    }

    private func statusColor(_ e: WorktreeStatusEntry) -> Color {
        switch statusGlyph(e) {
        case "U", "A": return .green
        case "D": return .red
        case "R", "C": return .blue
        default: return .orange
        }
    }
}
