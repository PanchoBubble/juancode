// The bottom half of the right rail, under the Oracles: the GitHub PR queue, and
// beside it a Diff tab summarising the main checkout's uncommitted changes.
//
// The queue was a toolbar badge with the list behind a popover. The rail is always
// on screen, so the queue can be too: the same list, chips and row actions, with no
// click in front of them.

import SwiftUI
import JuancodeCore
import JuancodeClient

struct GitHubQueueRail: View {
    @Environment(AppModel.self) private var model
    /// Shared with the old popover's key, so the chip you lived on carries over.
    @AppStorage("github.queue.filter") private var filterRaw = ViewerPrSlice.all.rawValue
    @AppStorage("github.rail.tab") private var tabRaw = Tab.prs.rawValue
    /// Owned here rather than by the Diff tab, so the tab label can show +/− while
    /// the PR list is the one on screen.
    @State private var diffStore = RepoDiffStore()
    @Namespace private var tabIndicator

    enum Tab: String, CaseIterable, Identifiable {
        case prs, diff
        var id: String { rawValue }
        var label: String { self == .prs ? "PRs" : "Diff" }
    }

    private var tab: Tab { Tab(rawValue: tabRaw) ?? .prs }
    private var root: String? {
        guard let id = model.selection,
              let meta = model.sessions.first(where: { $0.id == id }) else { return nil }
        return model.repoRoot(forSession: meta)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            ZStack(alignment: .top) {
                if tab == .diff {
                    RepoDiffRail(store: diffStore, root: root)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    GitHubQueueBadge.GitHubQueuePopover(
                        slice: Binding(get: { ViewerPrSlice(rawValue: filterRaw) ?? .all },
                                       set: { filterRaw = $0.rawValue }),
                        showing: .constant(true),
                        listMaxHeight: nil)
                        // Floored to one search a minute inside `refreshViewerPrs`; the
                        // model's own timer keeps it fresh after that.
                        .onAppear { model.refreshViewerPrs() }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.appSurface)
        .task(id: root) { await diffStore.load(root: root, model: model, rewatch: true) }
        .onDisappear { diffStore.stopWatching() }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { t in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { tabRaw = t.rawValue }
                } label: {
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Text(t.label)
                                .font(.system(size: 12, weight: tab == t ? .semibold : .regular))
                                .foregroundStyle(tab == t ? .primary : .secondary)
                            if t == .diff { diffPreview }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        ZStack {
                            Rectangle().fill(.clear).frame(height: 2)
                            if tab == t {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                                    .matchedGeometryEffect(id: "indicator", in: tabIndicator)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickCursor()
            }
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private var diffPreview: some View {
        if let files = diffStore.diff?.files, !files.isEmpty {
            let add = files.reduce(0) { $0 + $1.additions }
            let del = files.reduce(0) { $0 + $1.deletions }
            HStack(spacing: 3) {
                Text("+\(compactCount(add))").foregroundStyle(.green)
                Text("−\(compactCount(del))").foregroundStyle(.red)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .opacity(tab == .diff ? 1 : 0.75)
        }
    }
}

/// The selected session's main-checkout diff, kept warm by a file watcher, and the
/// git writes the Diff tab offers on it. Writes go through the selected session
/// (the core's git frames are session-scoped) with `cwd` naming the main checkout,
/// which the core accepts because it is one of that session's worktrees.
@MainActor @Observable
final class RepoDiffStore {
    struct Note: Equatable { var ok: Bool; var text: String }

    var diff: DiffResult?
    var gitState: GitState?
    var loading = false
    var error: String?
    var busy = false
    var note: Note?
    @ObservationIgnored private var watch: WorktreeWatchToken?
    @ObservationIgnored private let watcher = WorktreeWatcherRegistry()
    @ObservationIgnored private var root: String?

    func stopWatching() { watch = nil }

    func load(root: String?, model: AppModel, rewatch: Bool) async {
        self.root = root
        guard let root else { diff = nil; gitState = nil; watch = nil; return }
        if rewatch {
            diff = nil
            gitState = nil
            note = nil
            watch = watcher.watch(path: root) { [weak self] in
                Task { @MainActor in await self?.load(root: root, model: model, rewatch: false) }
            }
        }
        if let reason = model.core.unavailableReason(.changes) {
            error = reason
            return
        }
        loading = true
        defer { loading = false }
        do {
            let result = try await model.core.diff(cwd: root)
            let state = try? await model.core.gitState(cwd: root)
            // The selection may have moved on while git ran.
            guard root == self.root else { return }
            diff = result
            gitState = state
            error = nil
        } catch {
            self.error = "Couldn't read the diff: \(error.localizedDescription)"
        }
    }

    /// Discard each file's uncommitted change: a tracked file is restored from HEAD,
    /// a new one deleted (the core's `revert_file`). One file at a time, so a folder's
    /// blast radius is exactly the files the tree listed under it.
    func discard(_ files: [DiffFile], model: AppModel) async {
        guard let root, let sid = model.selection, !files.isEmpty else { return }
        busy = true
        defer { busy = false }
        var failed: String?
        for f in files {
            do {
                _ = try await model.core.revert(sessionId: sid, cwd: root, path: f.path, hunkIndex: nil)
            } catch {
                failed = "\(f.path): \(Self.message(error))"
                break
            }
        }
        note = failed.map { Note(ok: false, text: $0) }
            ?? Note(ok: true, text: files.count == 1 ? "Discarded \(files[0].path)" : "Discarded \(files.count) files")
        await load(root: root, model: model, rewatch: false)
    }

    /// Stage everything in the checkout and commit it.
    func commit(message: String, model: AppModel) async -> Bool {
        guard let root, let sid = model.selection else { return false }
        busy = true
        defer { busy = false }
        do {
            let r = try await model.core.commitAll(sessionId: sid, cwd: root, message: message)
            note = Note(ok: true, text: "Committed \(r.sha) · \(r.subject)")
            await load(root: root, model: model, rewatch: false)
            return true
        } catch {
            note = Note(ok: false, text: Self.message(error))
            return false
        }
    }

    func draftMessage(model: AppModel) async -> String? {
        guard let root, let sid = model.selection else { return nil }
        busy = true
        defer { busy = false }
        do {
            return try await model.core.draftCommitMessage(sessionId: sid, cwd: root)
        } catch {
            note = Note(ok: false, text: Self.message(error))
            return nil
        }
    }

    func push(model: AppModel) async {
        guard let root, let sid = model.selection else { return }
        busy = true
        defer { busy = false }
        do {
            let r = try await model.core.push(sessionId: sid, cwd: root)
            note = Note(ok: true, text: "Pushed \(r.branch).")
        } catch {
            note = Note(ok: false, text: Self.message(error))
        }
        await load(root: root, model: model, rewatch: false)
    }

    /// Open a PR for the checkout's branch; gh pushes it first.
    func createPr(title: String, body: String, draft: Bool, model: AppModel) async -> PrCreateResult? {
        guard let root else { return nil }
        guard let reads = model.core.github else {
            note = Note(ok: false, text: model.core.unavailableReason(.github) ?? "This core cannot open pull requests.")
            return nil
        }
        busy = true
        defer { busy = false }
        do {
            let r = try await reads.createPr(cwd: root, title: title, body: body, draft: draft)
            note = Note(ok: true, text: r.created ? "Pull request created." : "A PR already exists for this branch.")
            model.refreshViewerPrs()
            await load(root: root, model: model, rewatch: false)
            return r
        } catch {
            note = Note(ok: false, text: Self.message(error))
            return nil
        }
    }

    private static func message(_ error: Error) -> String {
        if let e = error as? GitHubError { return e.message }
        if let e = error as? ChangesError { return e.reason }
        return error.localizedDescription
    }
}

/// `git diff` of the selected session's main checkout (not its worktree) as a
/// folder tree with +/− counts and a GitHub-style diffstat bar per row. A click
/// opens the file in the session's in-place editor tab at its first changed line,
/// rooted in that checkout; right-click discards a file's or folder's changes.
private struct RepoDiffRail: View {
    @Environment(AppModel.self) private var model
    let store: RepoDiffStore
    let root: String?
    /// Folder ids folded shut. Folders start open: the point is to see the files.
    @State private var collapsed: Set<String> = []
    @State private var pendingDiscard: DiscardRequest?

    private var diff: DiffResult? { store.diff }
    private var loading: Bool { store.loading }
    private var error: String? { store.error }

    /// What the confirmation is about to throw away.
    struct DiscardRequest: Identifiable {
        let id: String
        let name: String
        let isFolder: Bool
        let files: [DiffFile]
        var newFiles: Int { files.filter { $0.status == .untracked }.count }
        var onlyNew: Bool { newFiles == files.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let files = diff?.files, !files.isEmpty, root != nil {
                RepoDiffActions(store: store)
            }
            Divider().padding(.vertical, 2)
            content
        }
        .confirmationDialog(discardTitle, isPresented: discardShown, titleVisibility: .visible,
                            presenting: pendingDiscard) { req in
            Button(req.onlyNew ? "Delete" : "Discard Changes", role: .destructive) {
                pendingDiscard = nil
                Task { await store.discard(req.files, model: model) }
            }
            Button("Cancel", role: .cancel) { pendingDiscard = nil }
        } message: { req in
            Text(discardMessage(req))
        }
    }

    private var discardShown: Binding<Bool> {
        Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } })
    }

    private var discardTitle: String {
        guard let req = pendingDiscard else { return "" }
        if req.isFolder { return "Discard every change in \(req.name)?" }
        return req.onlyNew ? "Delete \(req.name)?" : "Discard changes to \(req.name)?"
    }

    private func discardMessage(_ req: DiscardRequest) -> String {
        let restored = req.files.count - req.newFiles
        var parts: [String] = []
        if restored > 0 { parts.append("\(restored) file\(restored == 1 ? "" : "s") restored to the last commit") }
        if req.newFiles > 0 { parts.append("\(req.newFiles) new file\(req.newFiles == 1 ? "" : "s") deleted") }
        let what = req.isFolder ? parts.joined(separator: ", ") + ". " : ""
        return what + "This can't be undone."
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(root.map { ($0 as NSString).lastPathComponent } ?? "No session")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .help(root ?? "")
            if let branch = store.gitState?.branch {
                Text(branch)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let files = diff?.files, !files.isEmpty {
                Text("+\(files.reduce(0) { $0 + $1.additions })")
                    .foregroundStyle(.green)
                Text("−\(files.reduce(0) { $0 + $1.deletions })")
                    .foregroundStyle(.red)
            }
            Spacer()
            if loading || store.busy { ProgressView().controlSize(.mini) }
            Button { Task { await store.load(root: root, model: model, rewatch: false) } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh")
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 10).padding(.top, 2)
    }

    @ViewBuilder private var content: some View {
        if root == nil {
            note("Select a session to see its repo's changes.")
        } else if let error {
            note(error)
        } else if let diff, !diff.git {
            note("Not a git repository.")
        } else if let files = diff?.files {
            if files.isEmpty {
                note("Working tree clean.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleRows(buildDiffTree(files))) { item in
                            RepoDiffRow(node: item.node, depth: item.depth,
                                        collapsed: collapsed.contains(item.node.id),
                                        onTap: { frame in tap(item.node, from: frame) },
                                        onDiscard: { requestDiscard(item.node) },
                                        onOpen: { if let f = item.node.file { open(f, from: .zero) } })
                        }
                        if diff?.truncatedFiles == true {
                            note("More files changed than shown.")
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
        Spacer(minLength: 0)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .fixedSize(horizontal: false, vertical: true)
    }

    private struct TreeRow: Identifiable {
        let node: DiffTreeNode
        let depth: Int
        var id: String { node.id }
    }

    private func visibleRows(_ nodes: [DiffTreeNode], depth: Int = 0) -> [TreeRow] {
        nodes.flatMap { n -> [TreeRow] in
            let me = TreeRow(node: n, depth: depth)
            guard n.isFolder, !collapsed.contains(n.id) else { return [me] }
            return [me] + visibleRows(n.children, depth: depth + 1)
        }
    }

    private func tap(_ n: DiffTreeNode, from frame: CGRect) {
        if let f = n.file {
            open(f, from: frame)
        } else if collapsed.contains(n.id) {
            collapsed.remove(n.id)
        } else {
            collapsed.insert(n.id)
        }
    }

    private func requestDiscard(_ n: DiffTreeNode) {
        let files = n.file.map { [$0] } ?? leafFiles(n)
        guard !files.isEmpty else { return }
        pendingDiscard = DiscardRequest(id: n.id, name: n.isFolder ? n.id + "/" : n.name,
                                        isFolder: n.isFolder, files: files)
    }

    private func leafFiles(_ n: DiffTreeNode) -> [DiffFile] {
        n.children.flatMap { c in c.file.map { [$0] } ?? leafFiles(c) }
    }

    private func open(_ f: DiffFile, from frame: CGRect) {
        guard let root, let id = model.selection else { return }
        model.editorSpawn.launch(from: frame, title: f.path)
        model.openEditorSession(id, file: f.path, line: firstChangedLine(f), root: root)
    }

    /// The new-side line of the first change, so the editor lands on it. A pure
    /// deletion has no new line of its own; the context line above it stands in.
    private func firstChangedLine(_ f: DiffFile) -> Int? {
        guard let hunk = parseUnifiedDiff(f.diff).first else { return nil }
        var lastContext: Int?
        for line in hunk.lines {
            switch line.kind {
            case .context: lastContext = line.newLine
            case .insert: return line.newLine
            case .delete: return lastContext ?? line.oldLine
            }
        }
        return lastContext
    }
}

/// One tree row: hover highlight, click to open (or fold), right-click to discard.
private struct RepoDiffRow: View {
    let node: DiffTreeNode
    let depth: Int
    let collapsed: Bool
    let onTap: (CGRect) -> Void
    let onDiscard: () -> Void
    let onOpen: () -> Void

    @State private var hovering = false
    /// The row's global frame, for the editor's spawn flight. A reference so a scroll
    /// updating it never re-renders the row.
    @State private var frame = FrameBox()

    private final class FrameBox { var rect: CGRect = .zero }

    var body: some View {
        let deleted = node.file?.status == .deleted
        Button { onTap(frame.rect) } label: {
            HStack(spacing: 5) {
                indentGuides(depth)
                if let f = node.file {
                    Text(statusLetter(f.status))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor(f.status))
                        .frame(width: 10)
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                        .foregroundStyle(hovering ? .primary : .secondary)
                    Text(node.name)
                        .font(.system(size: 12))
                        .strikethrough(deleted)
                        .foregroundStyle(deleted ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: collapsed ? "folder.fill" : "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor.opacity(hovering ? 1 : 0.8))
                    Text(node.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 4)
                if node.file?.binary == true {
                    Text("bin").font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    if node.additions > 0 { Text("+\(compactCount(node.additions))").foregroundStyle(.green) }
                    if node.deletions > 0 { Text("−\(compactCount(node.deletions))").foregroundStyle(.red) }
                    DiffStatBar(additions: node.additions, deletions: node.deletions)
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(.horizontal, 4).padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.09 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(deleted)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.rect = $0 }
        .help(node.file.map { deleted ? "\($0.path) was deleted" : "Open \($0.path) in the editor" } ?? node.id)
        .contextMenu { menu }
    }

    @ViewBuilder private var menu: some View {
        if let f = node.file {
            if f.status != .deleted {
                Button("Open in Editor") { onOpen() }
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(f.path, forType: .string)
            }
            Divider()
            if f.status == .untracked {
                Button("Delete File…", role: .destructive) { onDiscard() }
            } else {
                Button("Discard Changes…", role: .destructive) { onDiscard() }
            }
        } else {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.id, forType: .string)
            }
            Divider()
            Button("Discard Changes in Folder…", role: .destructive) { onDiscard() }
        }
    }

    /// One faint vertical rule per level, so siblings line up under their folder.
    private func indentGuides(_ depth: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<depth, id: \.self) { _ in
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 1)
                    .padding(.leading, 5).padding(.trailing, 6)
            }
        }
    }

    private func statusLetter(_ s: FileStatus) -> String {
        switch s {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "U"
        }
    }

    private func statusColor(_ s: FileStatus) -> Color {
        switch s {
        case .modified, .renamed: return .orange
        case .added, .untracked: return .green
        case .deleted: return .red
        }
    }
}

/// Commit / Push / PR for the checkout the Diff tab shows.
private struct RepoDiffActions: View {
    @Environment(AppModel.self) private var model
    let store: RepoDiffStore

    @State private var showCommit = false
    @State private var showPr = false
    @State private var message = ""
    @State private var prTitle = ""
    @State private var prBody = ""
    @State private var prDraft = false
    @State private var prResult: PrCreateResult?

    private var state: GitState? { store.gitState }
    private var detached: Bool { state?.detached ?? false }
    private var hasRemote: Bool { state?.remote ?? false }
    /// A PR from the default branch has nothing to merge into; gh would refuse anyway.
    private var onTrunk: Bool { ["main", "master"].contains(state?.branch ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { showCommit.toggle(); showPr = false } label: {
                    Label("Commit", systemImage: "checkmark.circle")
                }
                .popover(isPresented: $showCommit, arrowEdge: .bottom) { commitForm }
                .help("Stage every change in this checkout and commit")

                if (state?.ahead ?? 0) > 0, hasRemote, !detached {
                    Button { Task { await store.push(model: model) } } label: {
                        Label("Push \(state?.ahead ?? 0)", systemImage: "arrow.up.circle")
                    }
                    .disabled(store.busy)
                }

                Button {
                    if prTitle.isEmpty, let b = state?.branch { prTitle = humanizeBranch(b) }
                    showPr.toggle(); showCommit = false
                } label: {
                    Label("Create PR", systemImage: "arrow.triangle.pull")
                }
                .disabled(!hasRemote || detached || onTrunk)
                .popover(isPresented: $showPr, arrowEdge: .bottom) { prForm }
                .help(onTrunk ? "On \(state?.branch ?? "main"): switch to a branch to open a PR"
                      : !hasRemote ? "No remote to open a PR against" : "Push this branch and open a PR")
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(.system(size: 11))
            .clickCursor()

            if let note = store.note {
                Text(note.text)
                    .font(.system(size: 10))
                    .foregroundStyle(note.ok ? .green : .red)
                    .lineLimit(2).help(note.text)
            }
        }
        .padding(.horizontal, 10).padding(.top, 4)
    }

    private var commitForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $message)
                .font(.system(size: 12))
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button("✨ Generate") {
                    Task { if let m = await store.draftMessage(model: model) { message = m } }
                }
                .disabled(store.busy)
                .clickCursor()
                Spacer()
                Button("Commit all") {
                    Task {
                        if await store.commit(message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                                              model: model) {
                            message = ""
                            showCommit = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.busy || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .clickCursor()
            }
            .controlSize(.small)
            Text("Stages every change (git add -A) then commits on \(state?.branch ?? "the current branch").")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(12).frame(width: 320)
    }

    private var prForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let r = prResult {
                Text(r.created ? "Pull request opened." : "A PR already exists for this branch.")
                    .font(.system(size: 12))
                Link(r.url, destination: URL(string: r.url) ?? URL(string: "https://github.com")!)
                    .font(.system(size: 11)).lineLimit(1)
                Button("Done") { prResult = nil; showPr = false }.controlSize(.small).clickCursor()
            } else {
                TextField("PR title", text: $prTitle)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                TextEditor(text: $prBody)
                    .font(.system(size: 12))
                    .frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                HStack {
                    Toggle("Draft", isOn: $prDraft).toggleStyle(.checkbox).font(.system(size: 11))
                    Spacer()
                    Button("Create PR") {
                        Task {
                            prResult = await store.createPr(title: prTitle, body: prBody,
                                                            draft: prDraft, model: model)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.busy || prTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    .clickCursor()
                }
                .controlSize(.small)
                Text((state?.dirty ?? false)
                     ? "Uncommitted changes stay out of the PR: commit them first."
                     : "Pushes the branch first, then opens the PR.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(width: 320)
    }
}

/// Five blocks split green/red by the share of added vs removed lines, as GitHub
/// draws a diffstat: a glance at whether a file grew, shrank or was reworked.
private struct DiffStatBar: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        let total = additions + deletions
        let green = total == 0 ? 0 : Int((Double(additions) / Double(total) * 5).rounded())
        let red = total == 0 ? 0 : 5 - green
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < green ? Color.green : i < green + red ? Color.red : Color.secondary.opacity(0.25))
                    .frame(width: 5, height: 5)
            }
        }
    }
}
