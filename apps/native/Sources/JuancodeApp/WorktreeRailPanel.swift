import SwiftUI
import AppKit
import JuancodeCore
import JuancodeClient
import JuancodeDesktop

// MARK: - Worktree viewer
//
// One place to inspect the selected session's checkout: Files (everything in it,
// changed or not) or Changes (what the chosen comparison says moved), and below the
// list one viewer for the selected file in File mode (its contents on disk now) or
// Diff mode (its change, with line comments that go to this session's agent).
//
// Scope is the checkout the session really works in (`AppModel.worktreeContext`),
// never the repo's main checkout. Navigation is remembered per checkout
// (`WorktreeViewModel`), so sessions sharing a checkout share it; comments, drafts
// and the send target are the selected session's (`DiffReviewModel`), so a shared
// checkout never routes one agent's feedback to another.
//
// Expand opens the full-width `DiffReviewPanel` for the same session on the same
// file and comparison; it reads and writes the same comments.

/// The Worktree viewer for the selected session, sized by its host (the right rail,
/// or the session side panel until the rail mounts it).
struct WorktreeRailPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let ctx = model.worktreeContext {
            // Keyed by session AND checkout: switching either starts the view state
            // (draft, folds, render) fresh, so nothing typed for one agent can be
            // saved onto another.
            WorktreeViewer(context: ctx)
                .id(ctx.sessionId + "\u{0}" + ctx.checkout)
        } else {
            Text("Select a session to inspect its worktree.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// The rail header's accessory: the selected checkout's live +/− under the current
/// comparison, quiet when there is nothing.
struct WorktreeRailAccessory: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let ctx = model.worktreeContext,
           let files = model.diffReview.snapshot(ctx.sessionId)?.files, !files.isEmpty {
            let add = files.reduce(0) { $0 + $1.additions }
            let del = files.reduce(0) { $0 + $1.deletions }
            HStack(spacing: 3) {
                Text("+\(compactCount(add))").foregroundStyle(.green)
                Text("−\(compactCount(del))").foregroundStyle(.red)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .help("\(files.count) changed file\(files.count == 1 ? "" : "s")")
        }
    }
}

private struct WorktreeViewer: View {
    @Environment(AppModel.self) private var model
    let context: WorktreeContext

    @AppStorage("worktree.listHeight") private var listHeight: Double = 220
    @State private var collapsedChangeDirs: Set<String> = []

    private var checkout: String { context.checkout }
    private var sessionId: String { context.sessionId }
    private var state: WorktreeViewState { model.worktreeViews.state(checkout) }
    private var review: DiffReviewModel { model.diffReview }
    private var snapshot: DiffReviewModel.Snapshot? { review.snapshot(sessionId) }
    private var changed: [DiffFile] { snapshot?.files ?? [] }
    private var meta: SessionMeta? { model.sessions.first { $0.id == sessionId } }
    private var tree: [FileTreeNode] { model.fileTreeByPath[checkout] ?? [] }
    private var watchKey: String { "worktree-viewer:" + sessionId }

    private var statusByPath: [String: WorktreeStatusEntry] {
        Dictionary(model.worktreeStatus(checkout).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            list
                .frame(height: CGFloat(listHeight))
            DragResizeHandle(axis: .horizontal, value: $listHeight, min: 80, max: 900, invert: false)
            WorktreeFileViewer(context: context)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if let asked = model.worktreeViews.requestedSection {
                model.worktreeViews.requestedSection = nil
                model.worktreeViews.update(checkout) { $0.section = asked }
            }
            model.startWatchingFileTree(watchKey, path: checkout)
            model.beginWorktreeLiveReview(sessionId, base: state.comparison)
            if let cwd = meta?.cwd { model.loadFolderGitState(cwd) }
        }
        .onDisappear {
            model.stopWatchingFileTree(watchKey)
            model.endWorktreeLiveReview(sessionId)
        }
        // An entry point (⌘C, the review badge) asking for a section while shown.
        .onChange(of: model.worktreeViews.requestedSection) { _, asked in
            guard let asked else { return }
            model.worktreeViews.requestedSection = nil
            model.worktreeViews.update(checkout) { $0.section = asked }
        }
        .onChange(of: changed.map(\.path)) { _, _ in keepSelectionListed() }
    }

    // MARK: Header

    private var branch: String? {
        model.folderGitState(checkout)?.branch ?? meta.flatMap { model.folderGitState($0.cwd)?.branch }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(branch ?? (checkout as NSString).lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                if review.loading.contains(sessionId) { ProgressView().controlSize(.mini) }
                Spacer(minLength: 4)
                if let meta, let pr = model.openPr(forSession: meta) {
                    Button { model.openGitHubForSession(meta) } label: {
                        Label("#\(pr.number)", systemImage: "arrow.triangle.pull")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("Open PR #\(pr.number) \"\(pr.title)\" for this branch")
                    .clickCursor()
                }
                Button { model.loadDiffReview(sessionId) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
                    .clickCursor()
                Button { model.expandWorktreeReview() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("Expand: full-width review of this worktree (⌘⇧D) — same comments and file")
                .clickCursor()
            }
            Text((checkout as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .help(checkout)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { state.section },
                                          set: { s in model.worktreeViews.update(checkout) { $0.section = s } })) {
                Text("Files").tag(WorktreeSection.files)
                Text(changed.isEmpty ? "Changes" : "Changes \(changed.count)").tag(WorktreeSection.changes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 4)
            Menu {
                ForEach(ReviewBase.allCases, id: \.self) { base in
                    Button {
                        model.setWorktreeComparison(base, context: context)
                    } label: {
                        if base == state.comparison { Label(base.title, systemImage: "checkmark") }
                        else { Text(base.title) }
                    }
                }
            } label: {
                Text(state.comparison.title).font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(snapshot?.label ?? "What Changes and Diff compare against")
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        switch state.section {
        case .files: filesList
        case .changes: changesList
        }
    }

    @ViewBuilder private var filesList: some View {
        if tree.isEmpty {
            note(model.fileTreeLoading.contains(checkout) ? "Indexing files…" : "No files in this worktree.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(tree) { node in
                        WorktreeTreeRows(
                            node: node, depth: 0,
                            statusByPath: statusByPath,
                            changedDirs: changedAncestorDirIDs(statusByPath.keys),
                            expanded: Binding(get: { model.fileTreeExpandedByPath[checkout] ?? [] },
                                              set: { model.fileTreeExpandedByPath[checkout] = $0 }),
                            selected: state.selectedPath,
                            select: select,
                            openInEditor: { openInEditor($0, line: nil) })
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder private var changesList: some View {
        if let error = review.errors[sessionId], snapshot == nil {
            note(error)
        } else if snapshot == nil {
            note("Loading changes…")
        } else if snapshot?.git == false {
            note("Not a git repository.")
        } else if changed.isEmpty {
            note("No changes (\(snapshot?.label ?? state.comparison.label())).")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(reviewTreeRows(changed, collapsed: collapsedChangeDirs)) { row in
                        ChangeRow(row: row, selected: row.file != nil && row.id == state.selectedPath,
                                  comments: review.comments(sessionId).filter { $0.path == row.id }.count) {
                            if row.file != nil {
                                select(row.id)
                            } else if collapsedChangeDirs.contains(row.id) {
                                collapsedChangeDirs.remove(row.id)
                            } else {
                                collapsedChangeDirs.insert(row.id)
                            }
                        }
                        .contextMenu {
                            if row.file != nil {
                                Button("Open in Editor") { openInEditor(row.id, line: nil) }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func select(_ path: String) {
        model.worktreeViews.update(checkout) { $0.select(path) }
    }

    /// In Changes, a selection that left the list (committed, reverted) moves to the
    /// first remaining change. Files keeps it: an unchanged file is still a file.
    private func keepSelectionListed() {
        guard state.section == .changes, snapshot != nil else { return }
        let listed = reviewFileOrder(changed)
        let next = worktreeSelection(remembered: state.selectedPath, listed: listed)
        if next != state.selectedPath, let next { select(next) }
    }

    private func openInEditor(_ path: String, line: Int?) {
        model.openEditorSession(sessionId, file: path, line: line, root: checkout)
    }
}

/// One Changes row: status letter, name, counts, a comment count when the session has
/// notes on the file.
private struct ChangeRow: View {
    let row: ReviewTreeRow
    let selected: Bool
    let comments: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let f = row.file {
                    Text(worktreeStatusLetter(f.status))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(worktreeStatusColor(f.status))
                        .frame(width: 10)
                    Text(row.name)
                        .font(.system(size: 11, design: .monospaced))
                        .strikethrough(f.status == .deleted)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Image(systemName: row.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(row.name).font(.system(size: 11, weight: .medium))
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 4)
                if comments > 0 {
                    Label("\(comments)", systemImage: "text.bubble")
                        .font(.system(size: 9)).foregroundStyle(Color.accentColor)
                }
                if row.file?.binary == true {
                    Text("bin").font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    if row.additions > 0 { Text("+\(compactCount(row.additions))").foregroundStyle(.green) }
                    if row.deletions > 0 { Text("−\(compactCount(row.deletions))").foregroundStyle(.red) }
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(.leading, 8 + CGFloat(row.depth) * 12).padding(.trailing, 8).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.18)
                        : hovering ? Color.appHairline(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .clickCursor()
    }
}

/// One Files node and, for an open folder, its children: the checkout's whole
/// listing decorated from the live `git status` snapshot. A file row selects it in the
/// viewer; double-click or the menu opens it in the session's editor.
struct WorktreeTreeRows: View {
    let node: FileTreeNode
    let depth: Int
    let statusByPath: [String: WorktreeStatusEntry]
    let changedDirs: Set<String>
    @Binding var expanded: Set<String>
    let selected: String?
    let select: (String) -> Void
    let openInEditor: (String) -> Void

    var body: some View {
        if node.isDirectory {
            folderRow
            if expanded.contains(node.id), let kids = node.children {
                ForEach(kids) { child in
                    WorktreeTreeRows(node: child, depth: depth + 1,
                                     statusByPath: statusByPath, changedDirs: changedDirs,
                                     expanded: $expanded, selected: selected,
                                     select: select, openInEditor: openInEditor)
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
        return Button { select(node.id) } label: {
            HStack(spacing: 5) {
                Image(systemName: "doc")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(node.name)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(entry.map(Self.color) ?? Color.primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let entry {
                    Text(Self.glyph(entry))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Self.color(entry))
                        .help("Uncommitted")
                }
            }
            .padding(.leading, indent).padding(.trailing, 8).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected == node.id ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickCursor()
        .simultaneousGesture(TapGesture(count: 2).onEnded { openInEditor(node.id) })
        .contextMenu {
            Button("Open in Editor") { openInEditor(node.id) }
        }
    }

    private var indent: CGFloat { 8 + CGFloat(depth) * 14 }

    /// Untracked wins, else the work-tree code, else the staged (index) code.
    static func glyph(_ e: WorktreeStatusEntry) -> String {
        if e.untracked { return "U" }
        return String(e.workTree == " " ? e.index : e.workTree)
    }

    static func color(_ e: WorktreeStatusEntry) -> Color {
        switch glyph(e) {
        case "U", "A": return .green
        case "D": return .red
        case "R", "C": return .blue
        default: return .orange
        }
    }
}

func worktreeStatusLetter(_ s: FileStatus) -> String {
    switch s {
    case .modified: return "M"
    case .added: return "A"
    case .deleted: return "D"
    case .renamed: return "R"
    case .untracked: return "U"
    }
}

func worktreeStatusColor(_ s: FileStatus) -> Color {
    switch s {
    case .added, .untracked: return .green
    case .deleted: return .red
    case .renamed: return .blue
    case .modified: return .orange
    }
}

// MARK: - Selected-file viewer

/// The selected file in File mode (current contents) or Diff mode (its change under
/// the checkout's comparison, with line comments for this session's agent).
private struct WorktreeFileViewer: View {
    @Environment(AppModel.self) private var model
    let context: WorktreeContext

    /// A comment being written over diff rows `from...to`.
    private struct Draft: Equatable {
        var from: Int
        var to: Int
        var text = ""
    }

    @State private var content: WorktreeFileContent?
    @State private var contentLines: [AttributedString] = []
    @State private var rendered: RenderedReviewFile?
    @State private var fullContext = false
    @State private var draft: Draft?
    /// The first visible File line / Diff row; persisted when the file or mode changes
    /// and when the viewer goes away, not on every scroll tick.
    @State private var topFileLine: Int?
    @State private var topDiffRow: Int?
    @FocusState private var draftFocused: Bool

    private var checkout: String { context.checkout }
    private var sessionId: String { context.sessionId }
    private var state: WorktreeViewState { model.worktreeViews.state(checkout) }
    private var review: DiffReviewModel { model.diffReview }
    private var path: String? { state.selectedPath }
    private var diffFile: DiffFile? {
        guard let path else { return nil }
        return review.snapshot(sessionId)?.files.first { $0.path == path }
    }
    private var comments: [ReviewComment] {
        guard let path else { return [] }
        return review.comments(sessionId).filter { $0.path == path }
    }
    private var statusEntry: WorktreeStatusEntry? {
        guard let path else { return nil }
        return model.worktreeStatus(checkout).first { $0.path == path }
    }
    private var sessionTitle: String {
        model.sessions.first { $0.id == sessionId }?.title ?? "this session"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let path {
                fileHeader(path)
                Divider()
                switch state.mode {
                case .file: fileBody
                case .diff: diffBody
                }
            } else {
                placeholder("Select a file to view it.")
            }
            sendBar
        }
        // A new file starts at its top (`WorktreeViewState.select`); the old one's
        // unsaved draft is staged on this session before it goes.
        .onChange(of: path) { _, _ in
            saveDraft()
            fullContext = false
            content = nil
            contentLines = []
            topFileLine = nil
            topDiffRow = nil
        }
        // File ⇄ Diff keeps the file and lands on the same line.
        .onChange(of: state.mode) { old, new in
            saveDraft()
            persistScroll(path: path, mode: old)
            restoreScroll(new)
        }
        .onDisappear {
            persistScroll(path: path, mode: state.mode)
            saveDraft()
        }
    }

    // MARK: Header

    private func fileHeader(_ path: String) -> some View {
        HStack(spacing: 6) {
            if let f = diffFile {
                Text(worktreeStatusLetter(f.status))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(worktreeStatusColor(f.status))
            }
            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1).truncationMode(.head)
                .help(path)
            Spacer(minLength: 4)
            if state.mode == .diff, diffFile != nil, review.snapshot(sessionId)?.base != .staged {
                Toggle(isOn: $fullContext) { Image(systemName: "arrow.up.and.down.text.horizontal") }
                    .toggleStyle(.button)
                    .buttonStyle(.borderless)
                    .help(fullContext ? "Show only the changed hunks" : "Expand context: the whole file around the changes")
            }
            Picker("", selection: Binding(get: { state.mode },
                                          set: { m in model.worktreeViews.update(checkout) { $0.mode = m } })) {
                Text("File").tag(WorktreeViewerMode.file)
                Text("Diff").tag(WorktreeViewerMode.diff)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button {
                model.openEditorSession(sessionId, file: path, line: topFileLine, root: checkout)
            } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                .buttonStyle(.borderless)
                .help("Open in the session's editor")
                .clickCursor()
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: File mode

    /// Reloads when the file, or anything git says about it, changes.
    private var fileTaskKey: String {
        let entry = statusEntry.map { "\($0.index)\($0.workTree)" } ?? "-"
        return [checkout, path ?? "", entry, String(diffFile?.diff.hashValue ?? 0)].joined(separator: "\u{0}")
    }

    @ViewBuilder private var fileBody: some View {
        Group {
            switch content {
            case nil:
                placeholder("Loading…")
            case .missing?:
                placeholder(diffFile?.status == .deleted || statusEntry != nil
                            ? "Deleted in the working tree. Diff shows what was removed."
                            : "This file is not on disk.")
            case .binary?:
                placeholder("Binary file — no text preview.")
            case .tooLarge(let lines)?:
                placeholder("Too large to show (\(lines) lines). Open it in the editor.")
            case .unavailable(let reason)?:
                placeholder("Couldn't read this file: \(reason)")
            case .text?:
                if contentLines.isEmpty { placeholder("Empty file.") } else { fileLines }
            }
        }
        .task(id: fileTaskKey) { await loadContent() }
    }

    private var fileLines: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(contentLines.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("\(i + 1)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 40, alignment: .trailing)
                            .padding(.trailing, 8)
                        Text(contentLines[i])
                            .font(.system(size: 11.5, design: .monospaced))
                            .fixedSize()
                    }
                    .frame(minHeight: 16)
                    .id(i + 1)
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 4)
        }
        .scrollPosition(id: $topFileLine, anchor: .top)
    }

    private func loadContent() async {
        guard let path else { content = nil; return }
        let status = diffFile?.status
        if status == .deleted {
            content = .missing
            contentLines = []
            return
        }
        let result: WorktreeFileContent
        do {
            let text = try await model.core.readFile(cwd: checkout, path: path)
            result = WorktreeFileContent.read(text)
        } catch {
            guard !Task.isCancelled else { return }
            let message = (error as? ChangesError)?.reason
                ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            result = WorktreeFileContent.failure(message, status: status)
        }
        guard !Task.isCancelled else { return }
        var lines: [AttributedString] = []
        if case .text(let text) = result {
            lines = await Task.detached(priority: .userInitiated) {
                var raw = text.components(separatedBy: "\n")
                if raw.last == "" { raw.removeLast() }
                return raw.map { VimSyntaxPalette.attributed($0.replacingOccurrences(of: "\t", with: "    "), path: path) }
            }.value
        }
        guard !Task.isCancelled else { return }
        let firstLoad = content == nil
        content = result
        contentLines = lines
        if firstLoad, let line = state.scrollLine, line <= lines.count, state.mode == .file {
            topFileLine = line
        }
    }

    // MARK: Diff mode

    @ViewBuilder private var diffBody: some View {
        let snapshot = review.snapshot(sessionId)
        if let error = review.errors[sessionId], snapshot == nil {
            placeholder(error)
        } else if snapshot == nil {
            placeholder("Loading the diff…")
        } else if snapshot?.git == false {
            placeholder("Not a git repository.")
        } else if let file = diffFile {
            if file.binary {
                placeholder("Binary file changed — no text diff.")
            } else {
                diffRows(file)
            }
        } else {
            placeholder("No changes to this file (\(snapshot?.label ?? state.comparison.label())). File shows its contents.")
        }
    }

    private func diffRows(_ file: DiffFile) -> some View {
        Group {
            if let rf = rendered, rf.path == file.path {
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let orphans = orphanComments(rf)
                        ForEach(orphans) { c in commentBox(c, orphan: true) }
                        ForEach(rf.rows.indices, id: \.self) { i in
                            WorktreeDiffRow(row: rf.rows[i], text: rf.text[i],
                                            hasComment: hasComment(rf.rows[i]),
                                            inDraft: draft.map { ($0.from...$0.to).contains(i) } ?? false)
                                .id(i)
                                .onTapGesture { tapRow(i, rows: rf.rows) }
                            if let d = draft, d.to == i { draftEditor(rf) }
                            ForEach(comments(endingAt: rf.rows[i])) { c in commentBox(c, orphan: false) }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.vertical, 4)
                }
                .scrollPosition(id: $topDiffRow, anchor: .top)
            } else {
                placeholder("Rendering…")
            }
        }
        .task(id: "\(file.path)\u{0}\(file.diff.hashValue)\u{0}\(fullContext)") { await render(file) }
    }

    private func render(_ file: DiffFile) async {
        var expanded: [ReviewRow]?
        if fullContext {
            do {
                let source = file.status == .deleted ? "" : try await model.core.readFile(cwd: checkout, path: file.path)
                expanded = try reviewExpandedRows(for: file, source: source)
            } catch {
                guard !Task.isCancelled else { return }
                fullContext = false
                review.say(error.localizedDescription, isError: true, in: sessionId)
                return
            }
        }
        guard !Task.isCancelled else { return }
        let rows = expanded
        let generation = (rendered?.generation ?? 0) &+ 1
        let out = await Task.detached(priority: .userInitiated) {
            RenderedReviewFile.compute(file, generation: generation, expandedRows: rows)
        }.value
        guard !Task.isCancelled else { return }
        let firstRender = rendered?.path != file.path
        rendered = out
        if let d = draft, !out.rows.indices.contains(d.to) { draft = nil }
        if firstRender, let line = state.scrollLine, state.mode == .diff {
            topDiffRow = out.rows.firstIndex { $0.line?.newLine == line || $0.line?.oldLine == line }
        }
    }

    private func hasComment(_ row: ReviewRow) -> Bool {
        guard let line = row.line else { return false }
        let key = reviewLineKey(line)
        return comments.contains { $0.endKey == key || $0.startKey == key }
    }

    private func comments(endingAt row: ReviewRow) -> [ReviewComment] {
        guard let line = row.line else { return [] }
        let key = reviewLineKey(line)
        return comments.filter { $0.endKey == key }
    }

    /// Comments whose line has left the diff: still the session's, still sent.
    private func orphanComments(_ rf: RenderedReviewFile) -> [ReviewComment] {
        let keys = Set(rf.rows.compactMap { $0.line.map(reviewLineKey) })
        return comments.filter { !keys.contains($0.endKey) }
    }

    /// Click a code line to comment on it; ⇧-click extends an open comment's range.
    private func tapRow(_ i: Int, rows: [ReviewRow]) {
        guard rows[i].line != nil else { return }
        if var d = draft, NSEvent.modifierFlags.contains(.shift) {
            d.from = min(d.from, i)
            d.to = max(d.to, i)
            draft = d
        } else {
            saveDraft()
            draft = Draft(from: i, to: i)
        }
        draftFocused = true
    }

    private func draftEditor(_ rf: RenderedReviewFile) -> some View {
        let location = path.flatMap { makeReviewComment(path: $0, rows: rf.rows, from: draft?.from ?? 0,
                                                         to: draft?.to ?? 0, text: "")?.location } ?? ""
        return VStack(alignment: .leading, spacing: 4) {
            Text("Comment on \(location) for \(sessionTitle)")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { draft?.text ?? "" }, set: { draft?.text = $0 }))
                .font(.system(size: 12))
                .frame(minHeight: 44, maxHeight: 120)
                .focused($draftFocused)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.appHairline(0.2)))
            HStack {
                Spacer()
                Button("Cancel") { draft = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveDraft() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled((draft?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.appPanel))
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    /// Stage the open draft as one of this session's review comments. Nothing typed is
    /// lost: leaving the file, the mode or the viewer saves it the same way.
    private func saveDraft() {
        guard let d = draft, let path, let rf = rendered, rf.path == path else { draft = nil; return }
        draft = nil
        let text = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let c = makeReviewComment(path: path, rows: rf.rows, from: d.from, to: d.to, text: text)
        else { return }
        review.add(c, to: sessionId)
    }

    private func commentBox(_ c: ReviewComment, orphan: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: c.isForGitHub ? "arrow.triangle.pull" : "text.bubble")
                .font(.system(size: 10)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.location + (orphan ? " · line left the diff" : ""))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Text(c.text).font(.system(size: 12)).textSelection(.enabled)
            }
            Spacer(minLength: 4)
            Button { review.delete(c.id, in: sessionId) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete this comment")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08)))
        .padding(.horizontal, 8).padding(.vertical, 2)
    }

    // MARK: Send

    /// Staged comments go to the selected session — the one this viewer is keyed by —
    /// as one review message, exactly as the full-width review sends them.
    @ViewBuilder private var sendBar: some View {
        let staged = review.comments(sessionId)
        let notice = review.notices[sessionId]
        if !staged.isEmpty || notice != nil {
            Divider()
            HStack(spacing: 8) {
                if let notice {
                    Text(notice.text)
                        .font(.system(size: 11))
                        .foregroundStyle(notice.isError ? Color.red : Color.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                if !staged.isEmpty {
                    Button {
                        saveDraft()
                        model.sendDiffReview(sessionId)
                    } label: {
                        Text("Send \(staged.count) to \(sessionTitle)").lineLimit(1)
                    }
                    .disabled(review.sending.contains(sessionId))
                    .help("Send every staged comment as one review message into this session's prompt")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
    }

    // MARK: Scroll memory

    private func restoreScroll(_ mode: WorktreeViewerMode) {
        guard let line = state.scrollLine else { return }
        switch mode {
        case .file: topFileLine = line <= contentLines.count ? line : nil
        case .diff:
            topDiffRow = rendered?.path == path
                ? rendered?.rows.firstIndex { $0.line?.newLine == line || $0.line?.oldLine == line } : nil
        }
    }

    private func persistScroll(path: String?, mode: WorktreeViewerMode) {
        guard let path else { return }
        let line: Int?
        switch mode {
        case .file: line = topFileLine
        case .diff:
            line = topDiffRow.flatMap { i in
                rendered?.rows.indices.contains(i) == true ? rendered?.rows[i].line.flatMap { $0.newLine ?? $0.oldLine } : nil
            }
        }
        model.worktreeViews.update(checkout) { s in
            guard s.selectedPath == path else { return }
            s.scrollLine = line
        }
    }
}

/// One diff row in the viewer: line numbers, marker, highlighted code.
private struct WorktreeDiffRow: View, Equatable {
    let row: ReviewRow
    let text: AttributedString
    let hasComment: Bool
    let inDraft: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            switch row {
            case .hunk, .note:
                Text(text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.accentColor.opacity(0.8))
                    .padding(.leading, 6).padding(.vertical, 2)
            case .line(let line):
                number(line.oldLine)
                number(line.newLine)
                Text(hasComment ? "●" : " ")
                    .font(.system(size: 9)).foregroundStyle(Color.accentColor).frame(width: 10)
                Text(line.kind == .insert ? "+" : line.kind == .delete ? "-" : " ")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(line.kind == .insert ? VimSyntaxPalette.diffAdd
                                     : line.kind == .delete ? VimSyntaxPalette.diffRemove : .secondary)
                    .frame(width: 12, alignment: .leading)
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
        .background(background)
        .overlay(inDraft ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 34, alignment: .trailing)
            .padding(.trailing, 3)
    }

    private var background: Color {
        switch row {
        case .hunk: return Color.appBand
        case .note: return .clear
        case .line(let l):
            switch l.kind {
            case .insert: return Color.green.opacity(0.11)
            case .delete: return Color.red.opacity(0.11)
            case .context: return .clear
            }
        }
    }
}
