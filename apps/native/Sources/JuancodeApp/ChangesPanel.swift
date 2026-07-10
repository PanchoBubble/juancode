import SwiftUI
import AppKit
import JuancodeCore
import JuancodeServices

/// Native SwiftUI port of the web `ChangesPanel` (+ `GitActions`), re-laid-out as a
/// VS Code-style "Source Control" view (juancode-dxg): a resizable SIDE panel with a
/// directory FILE TREE of changed files on the left (hideable) and, on the right, a
/// GitHub-review-style list of ALL changed files' diffs — each card individually
/// collapsible (with collapse/expand-all), clicking a tree file scrolls to its card.
/// Inline line-range comments are staged
/// in-memory with a "Submit review" that injects them into the agent, and commit /
/// push / PR run via AppModel — all in-process (no WS hop), mirroring FolderPrs /
/// FolderIssues. An optional "Review with Claude" pass (juancode-7ha) runs the real
/// `claude` CLI over the diff and overlays its findings inline. A source switcher
/// (juancode-49w) points the same viewer at the working tree, the current branch vs
/// its base/merge-base, or an existing PR's diff (`gh pr diff`) — and surfaces a
/// failing PR's CI logs. This view is self-contained so the Changes/Issues tab
/// switcher (juancode-fmh) can host it as-is.
struct ChangesPanel: View {
    @Environment(AppModel.self) private var model
    let sessionId: String

    /// Free-text filter over changed-file paths.
    @State private var query = ""
    /// Directory node ids currently expanded in the tree.
    @State private var expanded: Set<String> = []
    /// Whether the tree's expansion has been seeded for the current file set.
    @State private var seededExpansion = false
    /// The path of the file selected in the tree (the diff list scrolls to it).
    @State private var selectedPath: String?
    /// Paths whose diff card is collapsed (GitHub-style per-file collapse). All
    /// files are shown; collapsing just folds a card to its header. Files start
    /// collapsed by default — see `syncSelectionAndExpansion`.
    @State private var collapsedFiles: Set<String> = []
    /// Paths that have already been given their default (collapsed) state, so a
    /// diff reload or source switch doesn't re-collapse cards the user reopened.
    @State private var collapseSeeded: Set<String> = []
    /// One-shot guard so the programmatic tree selection on load scrolls to the
    /// first card without expanding it (keeps "all collapsed by default" honest).
    @State private var suppressSelectExpand = false
    /// Per-file viewed-state: path → the content hash the file had when marked viewed.
    /// A file re-appears as unviewed only when ITS diff changed. Persisted per session.
    @State private var viewedHashes: [String: String] = [:]
    /// Whether the diff pane owns the keyboard (drives `AppModel.changesKeyboardActive`
    /// so j/k/n/p/space/v reach `.onKeyPress` instead of the sidebar monitor).
    @FocusState private var paneFocused: Bool
    /// The hunk the last n/p landed on, within the selected file — reset on file change.
    @State private var currentHunkIndex = 0
    /// Whether the commit-picker popover is open (juancode-5u2).
    @State private var showCommitPicker = false
    /// Persisted width of the tree pane in the split.
    @AppStorage("changes.treeWidth") private var treeWidth: Double = 260
    /// Whether the left file-tree pane is shown (toggled from the header).
    @AppStorage("changes.treeShown") private var treeShown: Bool = true

    /// All directory node ids for the current file set — the full set when every
    /// folder is expanded.
    private var allDirIDs: Set<String> { directoryNodeIDs(buildFileTree(visibleFiles)) }

    private var diff: DiffResult? { model.diff(sessionId) }
    private var loading: Bool { model.diffLoading.contains(sessionId) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            reviewBanner
            ciBanner
            content
            if !model.comments(sessionId).isEmpty {
                Divider()
                submitBar
            }
        }
        .onAppear {
            if diff == nil { model.loadChanges(sessionId) }
            // Populate the source switcher's PR list for this folder.
            if let cwd = model.sessionCwd(sessionId) { model.loadPrs(cwd) }
            // Live-refresh the diff on external edits only while the panel is open.
            model.startWatchingChanges(sessionId)
            // Seeing the panel clears the review nudge regardless of how it opened.
            model.markChangesViewed(sessionId)
            viewedHashes = loadViewedHashes()
        }
        .onDisappear {
            model.stopWatchingChanges(sessionId)
            model.changesKeyboardActive = false
        }
        .onChange(of: diff) { _, _ in syncSelectionAndExpansion() }
        .onChange(of: paneFocused) { _, focused in model.changesKeyboardActive = focused }
        .onChange(of: selectedPath) { _, _ in currentHunkIndex = 0 }
        .perfTrackBody()
    }

    // MARK: - Diff source (working tree / base branch / PR) — juancode-49w

    private var currentSource: AppModel.ChangesSource { model.changesSource(sessionId) }

    private var sourceLabel: String {
        switch currentSource {
        case .workingTree: return "Working tree"
        case .base: return "vs " + (model.changesBaseLabel(sessionId) ?? "base")
        case .pr(let pr): return "PR #\(pr.number)"
        case .commit(let sha, let subject): return "Commit \(sha.prefix(7)) – \(subject)"
        }
    }

    private var sourceIcon: String {
        switch currentSource {
        case .workingTree: return "pencil"
        case .base: return "arrow.triangle.branch"
        case .pr: return "arrow.triangle.pull"
        case .commit: return "smallcircle.filled.circle"
        }
    }

    /// The sha of the commit currently shown, when the source is a commit.
    private var currentCommitSha: String? {
        if case .commit(let sha, _) = currentSource { return sha }
        return nil
    }

    /// Dropdown to point the viewer at the working tree, the base branch, or any
    /// open PR. The PR section is populated from the folder's `loadPrs` cache.
    @ViewBuilder private var sourceMenu: some View {
        let prs = (model.sessionCwd(sessionId).flatMap { model.prs($0) })?.prs ?? []
        Menu {
            Button { model.setChangesSource(sessionId, .workingTree) } label: {
                sourceItemLabel("Working tree", selected: currentSource == .workingTree)
            }
            Button { model.setChangesSource(sessionId, .base) } label: {
                sourceItemLabel("Against base branch", selected: currentSource == .base)
            }
            Divider()
            Button {
                model.loadRecentCommits(sessionId)
                showCommitPicker = true
            } label: {
                sourceItemLabel("Commit…", selected: currentCommitSha != nil)
            }
            if !prs.isEmpty {
                Section("Pull requests") {
                    ForEach(prs, id: \.number) { pr in
                        Button { model.setChangesSource(sessionId, .pr(pr)) } label: {
                            sourceItemLabel("#\(pr.number) \(pr.title)", selected: currentSource == .pr(pr))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: sourceIcon)
                Text(sourceLabel).lineLimit(1)
            }
            .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose what to diff: the working tree, the base branch, a PR, or a commit")
        .popover(isPresented: $showCommitPicker, arrowEdge: .bottom) {
            CommitPickerPopover(sessionId: sessionId, isPresented: $showCommitPicker)
        }
    }

    @ViewBuilder
    private func sourceItemLabel(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    // MARK: - PR CI logs banner (juancode-49w)

    /// When viewing a PR whose CI is red, offer to pull its failing-step logs
    /// (`gh run view --log-failed`) inline — read CI logs without leaving juancode.
    @ViewBuilder private var ciBanner: some View {
        if case let .pr(pr) = currentSource, pr.checks == .failing {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text("CI failing on PR #\(pr.number)")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    if model.isLoadingPrCiLogs(sessionId) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(model.prCiLogs(sessionId) == nil ? "Show CI logs" : "Reload logs") {
                            model.loadPrCiLogs(sessionId, number: pr.number)
                        }
                        .controlSize(.small).clickCursor()
                    }
                }
                if let logs = model.prCiLogs(sessionId) {
                    ScrollView {
                        Text(logs)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.red.opacity(0.08))
        }
    }

    /// Keep the tree selection valid as the diff reloads, and expand all folders the
    /// first time we have a file set so the tree opens fully (IDE behaviour).
    private func syncSelectionAndExpansion() {
        let files = diff?.files ?? []
        if !seededExpansion, !files.isEmpty {
            expanded = directoryNodeIDs(buildFileTree(files))
            seededExpansion = true
        }
        // Every file starts collapsed the first time it appears (across reloads and
        // source switches), while respecting cards the user has since reopened.
        let newlySeen = files.map(\.path).filter { !collapseSeeded.contains($0) }
        if !newlySeen.isEmpty {
            collapsedFiles.formUnion(newlySeen)
            collapseSeeded.formUnion(newlySeen)
        }
        if files.isEmpty {
            selectedPath = nil
        } else if selectedPath == nil || !files.contains(where: { $0.path == selectedPath }) {
            // Programmatic selection: scroll to the first card but leave it collapsed.
            suppressSelectExpand = true
            selectedPath = files.first?.path
        }
        // Drop viewed entries for files no longer present so the store stays bounded.
        let pruned = prunedViewed(viewedHashes, keeping: files)
        if pruned.count != viewedHashes.count {
            viewedHashes = pruned
            saveViewedHashes()
        }
    }

    // MARK: - Viewed-state persistence

    private var viewedDefaultsKey: String { "changes.viewed.\(sessionId)" }

    private func loadViewedHashes() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: viewedDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private func saveViewedHashes() {
        if let data = try? JSONEncoder().encode(viewedHashes) {
            UserDefaults.standard.set(data, forKey: viewedDefaultsKey)
        }
    }

    /// Toggle a file's viewed-state at its current content hash and persist. Marking
    /// viewed also folds the card (GitHub-style) so remaining work stays in view.
    private func toggleViewed(_ file: DiffFile) {
        if isFileViewed(file, viewed: viewedHashes) {
            viewedHashes[file.path] = nil
        } else {
            viewedHashes = markingViewed(file, in: viewedHashes)
            collapsedFiles.insert(file.path)
        }
        saveViewedHashes()
    }

    /// Paths that open collapsed by default (generated / oversized) — "expand all"
    /// leaves these folded so a lockfile never floods the view.
    private var defaultCollapsedPaths: Set<String> {
        Set(visibleFiles.filter { isCollapsedByDefault($0) }.map(\.path))
    }

    // MARK: - Header (counts, filter, refresh, git actions)

    private var totals: (add: Int, del: Int) {
        (diff?.files ?? []).reduce((0, 0)) { ($0.0 + $1.additions, $0.1 + $1.deletions) }
    }

    /// The header degrades gracefully in a narrow panel: one row when there's room,
    /// otherwise the filter drops to its own row below the controls. Stats are
    /// fixed-size so they never wrap into a vertical "0 / fil / es" stack.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                headerControls
                Spacer(minLength: 8)
                filterField.frame(width: 150)
                headerActions
            }
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    headerControls
                    Spacer(minLength: 8)
                    headerActions
                }
                filterField.frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var headerControls: some View {
        Button { treeShown.toggle() } label: {
            Image(systemName: treeShown ? "sidebar.left" : "sidebar.squares.left")
        }
        .buttonStyle(.borderless)
        .help(treeShown ? "Hide the file tree" : "Show the file tree")
        .clickCursor()
        sourceMenu
        let paths = Set(visibleFiles.map(\.path))
        Button { collapsedFiles = paths } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
            .buttonStyle(.borderless)
            .help("Collapse all files")
            .disabled(paths.isEmpty || collapsedFiles.isSuperset(of: paths))
            .clickCursor()
        Button { collapsedFiles = defaultCollapsedPaths } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
            .buttonStyle(.borderless)
            .help("Expand all files (generated/large files stay folded)")
            .disabled(collapsedFiles == defaultCollapsedPaths)
            .clickCursor()
        if let files = diff?.files {
            HStack(spacing: 6) {
                Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Text("+\(totals.add)").foregroundStyle(.green)
                Text("−\(totals.del)").foregroundStyle(.red)
                let seen = viewedCount(files, viewed: viewedHashes)
                if seen > 0 {
                    Text("· \(seen)/\(files.count) viewed")
                        .foregroundStyle(seen == files.count ? .green : .secondary)
                }
                if diff?.truncatedFiles == true {
                    Text("(list capped)").foregroundStyle(.orange)
                }
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .fixedSize()
        }
    }

    private var filterField: some View {
        TextField("Filter files…", text: $query)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
    }

    @ViewBuilder private var headerActions: some View {
        Button(model.isReviewing(sessionId) ? "Reviewing…" : "Review with Claude") {
            model.runReview(sessionId)
        }
        .controlSize(.small)
        .disabled(model.isReviewing(sessionId))
        .help("Run Claude over this diff and overlay its findings")
        .clickCursor()
        Button("Refresh") { model.loadChanges(sessionId) }
            .controlSize(.small)
            .clickCursor()
        GitActionsView(sessionId: sessionId)
    }

    // MARK: - Review summary banner

    /// Header banner mirroring the web `ReviewSummary`: a spinner while running, an
    /// error line, or the model's summary + finding count once a result is cached.
    @ViewBuilder
    private var reviewBanner: some View {
        if model.isReviewing(sessionId) {
            reviewBannerBox(tint: ReviewSeverityStyle.accent) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Claude is reviewing the diff…")
                        .font(.system(size: 11)).foregroundStyle(ReviewSeverityStyle.accent)
                }
            }
        } else if let r = model.review(sessionId) {
            switch r.status {
            case .error:
                reviewBannerBox(tint: .red) {
                    Text("Review failed: \(r.error ?? "unknown error")")
                        .font(.system(size: 11)).foregroundStyle(.red)
                }
            case .empty:
                reviewBannerBox(tint: ReviewSeverityStyle.accent) {
                    Text("No changes to review.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            case .ok:
                reviewBannerBox(tint: ReviewSeverityStyle.accent) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("✨ Claude review")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(ReviewSeverityStyle.accent)
                            Text("\(r.findings.count) finding\(r.findings.count == 1 ? "" : "s") · \(reviewTimestamp(r.createdAt))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        if let summary = r.summary {
                            Text(summary)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private func reviewBannerBox<Content: View>(tint: Color, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(tint.opacity(0.08))
    }

    private func reviewTimestamp(_ msEpoch: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(msEpoch) / 1000)
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Content (tree + diff split)

    private var visibleFiles: [DiffFile] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let files = diff?.files ?? []
        return q.isEmpty ? files : files.filter { $0.path.lowercased().contains(q) }
    }

    private var tree: [FileTreeNode] { buildFileTree(visibleFiles) }

    /// Paths currently viewed — passed to the tree so reviewed files dim out and the
    /// remaining work stands out at a glance.
    private var viewedPaths: Set<String> {
        Set(visibleFiles.filter { isFileViewed($0, viewed: viewedHashes) }.map(\.path))
    }

    @ViewBuilder
    private var content: some View {
        if let err = model.changesError(sessionId), diff == nil {
            centered(err)
        } else if loading && diff == nil {
            // First load only — once a diff is cached it stays visible through a
            // refresh (stale-while-revalidate) instead of blanking to this state.
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(loadingMessage).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let d = diff, !d.git {
            centered("Not a git repository — nothing to diff.")
        } else if (diff?.files ?? []).isEmpty {
            centered(emptyMessage)
        } else {
            splitView
        }
    }

    private var loadingMessage: String {
        switch currentSource {
        case .workingTree: return "Loading changes…"
        case .base: return "Diffing against base…"
        case .pr(let pr): return "Loading PR #\(pr.number)…"
        case .commit(let sha, _): return "Loading commit \(sha.prefix(7))…"
        }
    }

    private var emptyMessage: String {
        switch currentSource {
        case .workingTree: return "No changes in the working tree."
        case .base: return "No changes vs \(model.changesBaseLabel(sessionId) ?? "base")."
        case .pr: return "This PR has no file changes."
        case .commit: return "This commit has no file changes."
        }
    }

    /// The resizable tree | diff split. A draggable divider sets the tree pane width
    /// (persisted via @AppStorage), clamped to a sensible range.
    private var splitView: some View {
        HStack(spacing: 0) {
            if treeShown {
                treePane
                    .frame(width: CGFloat(treeWidth))
                // Tree is on the left; dragging right grows it (non-inverted).
                DragResizeHandle(axis: .vertical, value: $treeWidth, min: 160, max: 520, invert: false)
            }
            diffPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { syncSelectionAndExpansion() }
    }

    // MARK: - Tree pane

    @ViewBuilder
    private var treePane: some View {
        if visibleFiles.isEmpty {
            Text("No files match “\(query)”.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(8)
        } else {
            VStack(spacing: 0) {
                treePaneHeader
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(tree) { node in
                            FileTreeRows(
                                node: node,
                                depth: 0,
                                viewedPaths: viewedPaths,
                                selectedPath: $selectedPath,
                                expanded: $expanded)
                        }
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color(NSColor.textBackgroundColor).opacity(0.3))
        }
    }

    /// Collapse-all / expand-all controls for the tree's directories. Disabled when
    /// there are no folders to act on (a flat file list).
    private var treePaneHeader: some View {
        let dirs = allDirIDs
        return HStack(spacing: 4) {
            Spacer()
            Button { expanded = [] } label: { Image(systemName: "rectangle.compress.vertical") }
                .buttonStyle(.borderless)
                .help("Collapse all folders")
                .disabled(dirs.isEmpty || expanded.isEmpty)
                .clickCursor()
            Button { expanded = dirs } label: { Image(systemName: "rectangle.expand.vertical") }
                .buttonStyle(.borderless)
                .help("Expand all folders")
                .disabled(dirs.isEmpty || expanded == dirs)
                .clickCursor()
        }
        .font(.system(size: 10))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Diff pane (all files, each collapsible — GitHub-review style)

    @ViewBuilder
    private var diffPane: some View {
        if visibleFiles.isEmpty {
            centered("No files match “\(query)”.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(visibleFiles, id: \.path) { file in
                            FileCard(
                                sessionId: sessionId,
                                file: file,
                                // Scope inline rendering to the source the comment was
                                // staged against — line numbers only line up there.
                                comments: model.comments(sessionId).filter {
                                    $0.file == file.path && $0.commitSha == currentCommitSha
                                },
                                findings: ReviewPresentation.findings(
                                    for: file.path, in: model.review(sessionId)?.findings ?? []),
                                collapsed: collapsedFiles.contains(file.path),
                                viewed: isFileViewed(file, viewed: viewedHashes),
                                selected: file.path == selectedPath,
                                onToggleCollapse: { toggleFileCollapse(file.path) },
                                onToggleViewed: { toggleViewed(file) },
                                onEdit: { model.openEditorOverlay(sessionId, file: file.path) },
                                collapsible: true)
                                .id(file.path)
                                .contextMenu {
                                    Button("Open in editor session") {
                                        model.openEditorSession(sessionId, file: file.path)
                                    }
                                    .disabled(file.status == .deleted)
                                }
                        }
                    }
                    .padding(10)
                }
                .focusable()
                .focused($paneFocused)
                .focusEffectDisabled()
                .onKeyPress { handleKey($0, proxy: proxy) }
                .onAppear { paneFocused = true }
                // Clicking a file in the tree scrolls to its card (and expands it).
                // The initial programmatic selection only scrolls — it leaves the
                // card collapsed so the panel opens fully folded.
                .onChange(of: selectedPath) { _, path in
                    guard let path else { return }
                    if suppressSelectExpand {
                        suppressSelectExpand = false
                    } else {
                        collapsedFiles.remove(path)
                    }
                    withAnimation { proxy.scrollTo(path, anchor: .top) }
                }
            }
        }
    }

    // MARK: - Keyboard navigation (j/k files, n/p hunks, space collapse, v viewed)

    private var selectedFile: DiffFile? { visibleFiles.first { $0.path == selectedPath } }

    private func handleKey(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        // Leave modified combos to the app shortcuts / menu (⌘C toggle, etc.).
        guard press.modifiers.isEmpty else { return .ignored }
        switch press.characters {
        case "j": moveFile(1); return .handled
        case "k": moveFile(-1); return .handled
        case "n": moveHunk(1, proxy: proxy); return .handled
        case "p": moveHunk(-1, proxy: proxy); return .handled
        case " ": toggleCollapseSelected(); return .handled
        case "v": markSelectedViewed(); return .handled
        default: return .ignored
        }
    }

    /// Move the selection to the next/prev file. Only scrolls (leaves the card folded)
    /// so j/k walk file headers fast; `space` expands the one you stop on.
    private func moveFile(_ delta: Int) {
        let files = visibleFiles
        let current = files.firstIndex { $0.path == selectedPath }
        guard let idx = steppedIndex(current: current, count: files.count, delta: delta) else { return }
        suppressSelectExpand = true
        selectedPath = files[idx].path
    }

    /// Step through the selected file's hunks, expanding it if needed and scrolling to
    /// the hunk anchor. Bounded by the file's `@@`-header count.
    private func moveHunk(_ delta: Int, proxy: ScrollViewProxy) {
        guard let path = selectedPath, let file = selectedFile else { return }
        let count = hunkCount(inDiff: file.diff)
        guard count > 0 else { return }
        let wasCollapsed = collapsedFiles.contains(path)
        collapsedFiles.remove(path)
        currentHunkIndex = steppedIndex(current: wasCollapsed ? nil : currentHunkIndex,
                                        count: count, delta: delta) ?? 0
        // A just-expanded card's hunk rows aren't laid out yet — scroll to the file
        // header this pass; the next n/p lands on the hunk anchor.
        let target = wasCollapsed ? path : "\(path)#hunk\(currentHunkIndex)"
        withAnimation { proxy.scrollTo(target, anchor: .top) }
    }

    private func toggleCollapseSelected() {
        guard let path = selectedPath else { return }
        toggleFileCollapse(path)
    }

    private func markSelectedViewed() {
        guard let file = selectedFile else { return }
        toggleViewed(file)
        moveFile(1)
    }

    private func toggleFileCollapse(_ path: String) {
        if collapsedFiles.contains(path) { collapsedFiles.remove(path) } else { collapsedFiles.insert(path) }
    }

    private func centered(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Submit-review bar

    /// The review basket bar (juancode-ck4): a count, a "Send to agent" that composes
    /// the annotations into one feedback prompt and steers it into the session (idle →
    /// runs now, busy → queued by the CLI), and a "Discard" that clears them.
    private var submitBar: some View {
        HStack {
            let n = model.comments(sessionId).count
            Text("\(n) comment\(n == 1 ? "" : "s")")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("Discard") { model.discardComments(sessionId) }
                .controlSize(.small)
                .clickCursor()
            Button("Send to agent") { model.submitReview(sessionId) }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(model.liveSession(sessionId) == nil)
                .help(model.liveSession(sessionId) == nil
                      ? "Session isn't live — start it to send review feedback"
                      : "Send the annotations to the agent as review feedback")
                .clickCursor()
        }
        .padding(10)
    }
}

// MARK: - Commit picker (juancode-5u2)

/// Searchable list of the session's recent commits, opened from the source menu's
/// "Commit…" entry. Picking a row points the panel at that commit's diff.
private struct CommitPickerPopover: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    @Binding var isPresented: Bool
    @State private var search = ""

    private var filtered: [RecentCommit] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.recentCommits(sessionId) }
        return model.recentCommits(sessionId).filter {
            $0.sha.lowercased().hasPrefix(q) || $0.subject.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search commits…", text: $search)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            if model.isLoadingRecentCommits(sessionId) && model.recentCommits(sessionId).isEmpty {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else if filtered.isEmpty {
                Text(search.isEmpty ? "No commits." : "No commits match “\(search)”.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { commit in
                            commitRow(commit)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(10)
        .frame(width: 400)
    }

    private func commitRow(_ commit: RecentCommit) -> some View {
        Button {
            model.setChangesSource(sessionId, .commit(sha: commit.sha, subject: commit.subject))
            isPresented = false
        } label: {
            HStack(spacing: 6) {
                Text(commit.shortSha)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(commit.subject)
                    .font(.system(size: 11)).lineLimit(1)
                if commit.aheadOfBase {
                    Text("ahead")
                        .font(.system(size: 9))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                        .help("Not on the base branch yet")
                }
                Spacer(minLength: 8)
                Text(commit.relativeAge)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .clickCursor()
    }
}

// MARK: - File card (header + hunks + inline comments)

private struct FileCard: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    let file: DiffFile
    let comments: [DiffComment]
    /// AI review findings for THIS file (already filtered by path), overlaid on
    /// their anchored line/side rows; unanchorable ones show in a strip up top.
    var findings: [ReviewFinding] = []
    let collapsed: Bool
    /// GitHub-style viewed-state: the file was reviewed at its current content.
    var viewed: Bool = false
    /// Whether this is the keyboard-selected file (thin accent rule down its side).
    var selected: Bool = false
    let onToggleCollapse: () -> Void
    var onToggleViewed: () -> Void = {}
    let onEdit: () -> Void
    /// When false (the side-by-side diff pane), the collapse chevron is hidden — the
    /// single selected file is always shown fully expanded.
    var collapsible: Bool = true

    /// The (side, line, endLine) range a new comment is being composed on, if any.
    /// A single-line click sets line == endLine; a drag-select widens the range.
    @State private var composing: ComposeAnchor?
    @State private var draft = ""

    /// Live drag-select state: the global flat-row index the drag started on, the
    /// index currently under the cursor, and the measured uniform row height. Non-nil
    /// only while a press-drag is in flight over the line stack.
    @State private var dragAnchorIndex: Int?
    @State private var dragCurrentIndex: Int?
    /// Reported frame of each flat diff row (global index → rect in the drag space),
    /// used to hit-test the drag cursor against actual row geometry.
    @State private var rowFrames: [Int: CGRect] = [:]

    /// Where comment composition is anchored. Mirrors the range data model (side +
    /// start line + end line) so a drag can populate a multi-line range.
    private struct ComposeAnchor: Equatable {
        let side: CommentSide
        let line: Int
        let endLine: Int
    }

    /// Identifies a coordinate space local to one file's diff line stack.
    private var dragSpace: String { "diff-lines-\(file.path)" }

    /// Parse + per-line syntax highlighting for this card, computed ONCE off-main
    /// (see the `.task` below) — never in a body evaluation. Before this, `hunks`
    /// was a computed property calling `parseUnifiedDiff` and every row re-ran the
    /// highlighter per render, so each drag-select tick re-parsed the whole diff —
    /// the panel's jank (juancode-it1). Kept across re-collapse so re-expanding is
    /// instant.
    @State private var renderedDiff: RenderedFileDiff?

    /// Whether this card has textual content that needs a render model at all.
    private var wantsRender: Bool { !file.binary && !file.truncated && !file.diff.isEmpty }

    /// Findings that can't be anchored onto a row in the current diff (file-level,
    /// or a line no longer present) — rendered in a strip under the header, mirroring
    /// the web `orphanFindings`.
    private var orphanFindings: [ReviewFinding] {
        // While the render model is still computing (a few ms), show nothing rather
        // than flashing every finding as an orphan.
        if wantsRender, renderedDiff == nil { return [] }
        let anchored = renderedDiff?.anchoredPairs ?? []
        return findings.filter { f in
            guard let line = f.line else { return true }
            return !anchored.contains("\(f.side.rawValue):\(line)")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            cardHeader
            if collapsed {
                // A folded generated/oversized file explains itself in one line so you
                // can skip it without expanding (expand-on-demand via the chevron).
                if let summary = collapseSummary(for: file) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text("Expand to view").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                }
            } else {
                if !orphanFindings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(orphanFindings.enumerated()), id: \.offset) { _, f in
                            FindingRow(finding: f)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(ReviewSeverityStyle.accent.opacity(0.05))
                }
                if file.binary {
                    note("Binary file — diff not shown.")
                } else if file.truncated {
                    note("Diff too large to display.")
                } else if let rd = renderedDiff {
                    if rd.hunks.isEmpty {
                        note("No textual changes.")
                    } else {
                        hunkBody(rd)
                    }
                } else if wantsRender {
                    // First compute in flight — single-digit ms off-main.
                    note("Rendering…")
                } else {
                    note("No textual changes.")
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor).opacity(0.4))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(selected ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.25),
                    lineWidth: selected ? 1.5 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // Recompute when the card is (or becomes) expanded and the diff text changes.
        // Collapsed cards never pay for a parse/highlight (they're the default state).
        .task(id: collapsed ? nil : file.diff) {
            guard !collapsed, wantsRender, renderedDiff?.source != file.diff else { return }
            let gen = (renderedDiff?.generation ?? 0) + 1
            let (diffText, path) = (file.diff, file.path)
            let out = await Task.detached(priority: .userInitiated) {
                RenderedFileDiff.compute(diff: diffText, path: path, generation: gen)
            }.value
            if !Task.isCancelled { renderedDiff = out }
        }
    }

    private var cardHeader: some View {
        HStack(spacing: 8) {
            Button(action: onToggleCollapse) {
                HStack(spacing: 6) {
                    if collapsible {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Text(file.status.rawValue)
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(statusColor)
                    Text(file.oldPath != nil ? "\(file.oldPath!) → \(file.path)" : file.path)
                        .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }
            }
            .buttonStyle(.plain)
            .disabled(!collapsible)
            .clickCursor()
            Spacer(minLength: 6)
            Text("+\(file.additions)").font(.system(size: 10)).foregroundStyle(.green)
            Text("−\(file.deletions)").font(.system(size: 10)).foregroundStyle(.red)
            Button(action: onToggleViewed) {
                Image(systemName: viewed ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundStyle(viewed ? Color.green : .secondary)
            }
            .buttonStyle(.borderless)
            .help(viewed ? "Marked viewed — click to unmark (v)" : "Mark viewed (v)")
            .clickCursor()
            Button(action: onEdit) {
                Image(systemName: "square.and.pencil").font(.system(size: 10))
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .disabled(file.status == .deleted)
            .help(file.status == .deleted ? "File was deleted" : "Open in your editor ($EDITOR)")
            .clickCursor()
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.secondary.opacity(0.08))
        // Viewed files read as "done" — dim the header so remaining work stands out.
        .opacity(viewed ? 0.55 : 1)
    }

    /// The diff rows, comments, and composer, laid out top-to-bottom. The whole stack
    /// is wrapped in a named coordinate space and carries a press-drag-release gesture:
    /// pressing a line and dragging across others highlights the spanned rows, and
    /// releasing opens the composer anchored to that range. A press with no drag falls
    /// through to the per-row tap (single-line comment), preserving 3bq's behavior.
    private func hunkBody(_ rd: RenderedFileDiff) -> some View {
        // Each flat row is addressed by its global index so frame reports and the
        // drag-select highlight share one index space.
        let hunkStartAt = rd.hunkFlatStarts.enumerated()
            .reduce(into: [Int: Int]()) { $0[$1.element] = $1.offset }
        return VStack(spacing: 0) {
            ForEach(rd.flatLines.indices, id: \.self) { idx in
                if let hunkK = hunkStartAt[idx] {
                    // Zero-height scroll target for n/p hunk navigation.
                    Color.clear.frame(height: 0).id("\(file.path)#hunk\(hunkK)")
                }
                let line = rd.flatLines[idx]
                DiffLineRow(
                    generation: rd.generation,
                    index: idx,
                    kind: line.kind,
                    oldLine: line.oldLine,
                    newLine: line.newLine,
                    side: line.anchor?.side,
                    anchorLine: line.anchor?.line,
                    text: rd.rendered[idx],
                    selected: isRowSelected(idx, side: line.anchor?.side, line: line.anchor?.line),
                    onComment: { side, ln in
                        beginCompose(ComposeAnchor(side: side, line: ln, endLine: ln))
                    })
                    // `.equatable()` is load-bearing: the closure field means SwiftUI
                    // can't memcmp-diff the row, so without it every row body re-runs
                    // on every drag tick. The explicit == compares (generation, index,
                    // selected) only — content changes always bump `generation`.
                    .equatable()
                    // Report this row's frame (in the stack's coordinate space) so the
                    // drag gesture can hit-test the cursor against actual row geometry —
                    // robust to the comments/composer interspersed below.
                    .background(rowFrameReporter(index: idx))
                if let a = line.anchor {
                    // AI review findings anchored to this exact line/side — shown above
                    // the human comments, visually distinct (severity color + title).
                    ForEach(Array(findings.filter { $0.side == a.side && $0.line == a.line }.enumerated()),
                            id: \.offset) { _, f in
                        FindingRow(finding: f)
                    }
                    // Existing comments whose range ENDS on this line (so a range comment
                    // shows once, under its last line — matching how it anchors).
                    ForEach(comments.filter { $0.side == a.side && $0.endLine == a.line }, id: \.id) { c in
                        CommentRow(comment: c) { model.deleteComment(sessionId, commentId: c.id) }
                    }
                    // The composer, if its range ends on this line.
                    if let comp = composing, comp.side == a.side, comp.endLine == a.line {
                        composer(comp)
                    }
                }
            }
        }
        .coordinateSpace(name: dragSpace)
        .onPreferenceChange(RowFramesKey.self) { rowFrames = $0 }
        // Simultaneous so a stationary press still reaches each row's single-line tap;
        // the gesture only takes over once the cursor actually crosses into another row.
        .simultaneousGesture(dragSelectGesture)
    }

    /// A clear backdrop that publishes this row's frame in the drag coordinate space.
    private func rowFrameReporter(index: Int) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: RowFramesKey.self,
                value: [index: geo.frame(in: .named(dragSpace))])
        }
    }

    /// Press-drag-release over the line stack. A non-zero `minimumDistance` is
    /// load-bearing: a zero-distance drag wins gesture arbitration on the first
    /// movement and starves the enclosing ScrollView, killing scroll over the diff.
    /// The threshold lets a scroll start reach the ScrollView while a deliberate
    /// click-drag (which spans rows, far past the threshold) still range-selects.
    /// Single-line clicks are handled separately by each row's own tap gesture.
    private var dragSelectGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(dragSpace))
            .onChanged { value in
                guard let start = rowIndex(at: value.startLocation),
                      let now = rowIndex(at: value.location) else { return }
                // Only engage range-select once the drag spans more than one row, so a
                // stationary press doesn't pre-empt the per-row single-line tap.
                if now != start || dragAnchorIndex != nil {
                    dragAnchorIndex = start
                    dragCurrentIndex = now
                }
            }
            .onEnded { value in
                defer { dragAnchorIndex = nil; dragCurrentIndex = nil }
                guard let start = dragAnchorIndex,
                      let now = rowIndex(at: value.location) ?? dragCurrentIndex,
                      start != now else { return }  // no drag → let the tap handle it
                beginRangeCompose(start: start, end: now)
            }
    }

    /// Hit-test a point (in the stack's coordinate space) against the reported row
    /// frames, returning the global index of the row it falls in, clamped to the ends.
    private func rowIndex(at point: CGPoint) -> Int? {
        guard !rowFrames.isEmpty else { return nil }
        // Exact containment first.
        if let hit = rowFrames.first(where: { $0.value.contains(point) }) { return hit.key }
        // Otherwise clamp to nearest by vertical position (drag overshot top/bottom).
        let sorted = rowFrames.sorted { $0.value.minY < $1.value.minY }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        if point.y <= first.value.minY { return first.key }
        if point.y >= last.value.maxY { return last.key }
        // Between rows (gaps from interspersed comments): pick the closest by midpoint.
        return sorted.min { abs($0.value.midY - point.y) < abs($1.value.midY - point.y) }?.key
    }

    /// True while a drag-select spans this flat row index, or while the composer is
    /// open on a range covering this row's anchor — the highlight must survive the
    /// drag ending so the commented-on lines stay visible under the comment box.
    private func isRowSelected(_ index: Int, side: CommentSide?, line: Int?) -> Bool {
        if let a = dragAnchorIndex, let c = dragCurrentIndex {
            return normalizedLineRange(anchor: a, current: c).contains(index)
        }
        if let comp = composing, let side, let line {
            return side == comp.side && (comp.line...comp.endLine).contains(line)
        }
        return false
    }

    private func beginCompose(_ anchor: ComposeAnchor) {
        composing = anchor
        draft = ""
    }

    /// Turn a flat-index drag range into a side+line range and open the composer.
    /// Anchors to the side+line of the range's two endpoints; if the endpoints land on
    /// different sides (e.g. a delete then an insert), falls back to the new side using
    /// whatever line numbers are available, normalized low→high.
    private func beginRangeCompose(start: Int, end: Int) {
        let range = normalizedLineRange(anchor: start, current: end)
        let rows = renderedDiff?.flatLines ?? []
        let anchors = range.compactMap { rows.indices.contains($0) ? rows[$0].anchor : nil }
        guard let first = anchors.first, let last = anchors.last else { return }
        // Prefer keeping both endpoints on one side; if they differ, take the new side.
        let side: CommentSide = first.side == last.side ? first.side : .new
        let lines = anchors.filter { $0.side == side }.map(\.line)
        guard let lo = lines.min(), let hi = lines.max() else {
            beginCompose(ComposeAnchor(side: first.side, line: first.line, endLine: first.line))
            return
        }
        beginCompose(ComposeAnchor(side: side, line: lo, endLine: hi))
    }

    private func composer(_ anchor: ComposeAnchor) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(commentRangeLabel(side: anchor.side, line: anchor.line, endLine: anchor.endLine))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.system(size: 12))
                .frame(height: 44)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button("Comment") { commitComposer(anchor) }
                    .controlSize(.small)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .clickCursor()
                Button("Cancel") { cancelComposer() }.controlSize(.small).clickCursor()
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        // Esc dismisses the open editor (juancode-ck4).
        .onExitCommand { cancelComposer() }
    }

    /// Stage the draft as a comment, capturing the annotated diff line(s) so the
    /// review composer can quote the highlighted hunk back to the agent.
    private func commitComposer(_ anchor: ComposeAnchor) {
        let quote = renderedDiff.map {
            quotedDiffLines($0.flatLines, side: anchor.side, from: anchor.line, through: anchor.endLine)
        }
        model.addComment(sessionId, file: file.path, side: anchor.side,
                         line: anchor.line, endLine: anchor.endLine, body: draft,
                         quote: (quote?.isEmpty ?? true) ? nil : quote)
        cancelComposer()
    }

    private func cancelComposer() {
        composing = nil
        draft = ""
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 5)
    }

    private var statusColor: Color {
        switch file.status {
        case .modified: return .orange
        case .added, .untracked: return .green
        case .deleted: return .red
        case .renamed: return .blue
        }
    }
}

/// Collects each diff row's frame (keyed by its global flat index) so the parent's
/// drag-select gesture can hit-test the cursor against real row geometry.
private struct RowFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Precomputed render model for one file's diff: parse + per-line syntax
/// highlighting done ONCE (off-main via `FileCard`'s `.task`), never in a body
/// evaluation. Equality is a generation stamp so SwiftUI diffing never walks the
/// line arrays or AttributedString contents.
struct RenderedFileDiff: Equatable, Sendable {
    /// Monotonic per-compute stamp; any content change comes from a new `compute`
    /// which bumps it, so rows can compare (generation, index) instead of text.
    let generation: Int
    /// The diff text this model was computed from — lets the card skip a recompute
    /// when a re-expand re-fires its `.task` over the same content.
    let source: String
    let hunks: [DiffHunk]
    /// Every visible diff line flattened to a single indexed list, so a drag offset
    /// can address any row regardless of which hunk it lives in.
    let flatLines: [DiffLine]
    /// The "side:line" pairs present in the diff — anchors findings vs orphans.
    let anchoredPairs: Set<String>
    /// Index-aligned with `flatLines`: tinted +/-/space marker + syntax colors, with
    /// word-level intraline changes background-tinted on paired delete/insert lines.
    let rendered: [AttributedString]
    /// The flat-line index at which each hunk begins — drives the n/p scroll anchors.
    let hunkFlatStarts: [Int]

    static func == (a: Self, b: Self) -> Bool { a.generation == b.generation }

    /// Pure — safe to run in `Task.detached`.
    static func compute(diff: String, path: String, generation: Int) -> RenderedFileDiff {
        let hunks = parseUnifiedDiff(diff)
        let flat = hunks.flatMap(\.lines)
        let pairs = Set(flat.compactMap { $0.anchor.map { "\($0.side.rawValue):\($0.line)" } })
        // Word-level changed spans per line, from each delete/insert pair in a hunk.
        var intraline: [Int: [Range<Int>]] = [:]
        for pair in intralinePairs(flat) {
            let (old, new) = intralineWordRanges(old: flat[pair.delete].text, new: flat[pair.insert].text)
            if !old.isEmpty { intraline[pair.delete] = old }
            if !new.isEmpty { intraline[pair.insert] = new }
        }
        // The leading +/-/space marker, tinted by diff kind, plus the line content
        // with per-language vim syntax colors layered on top. The marker keeps the
        // diff add/remove semantics legible; the content gets the warm vim palette.
        let rendered = flat.indices.map { idx -> AttributedString in
            let line = flat[idx]
            var out = AttributedString(marker(for: line.kind))
            out.foregroundColor = markerColor(for: line.kind)
            var content = VimSyntaxPalette.attributed(line.text, path: path)
            if let ranges = intraline[idx] {
                applyIntralineHighlight(&content, ranges: ranges, kind: line.kind)
            }
            out.append(content)
            return out
        }
        var starts: [Int] = []
        var acc = 0
        for h in hunks { starts.append(acc); acc += h.lines.count }
        return RenderedFileDiff(generation: generation, source: diff, hunks: hunks,
                                flatLines: flat, anchoredPairs: pairs, rendered: rendered,
                                hunkFlatStarts: starts)
    }

    /// Tint the changed character ranges of a line's content with the add/remove
    /// intraline background. Offsets are into the content (marker-free) character view.
    private static func applyIntralineHighlight(_ s: inout AttributedString, ranges: [Range<Int>],
                                                kind: DiffLine.Kind) {
        let bg = kind == .insert ? VimSyntaxPalette.intralineAdd : VimSyntaxPalette.intralineRemove
        let chars = s.characters
        for r in ranges {
            guard r.lowerBound < r.upperBound,
                  let lo = chars.index(chars.startIndex, offsetBy: r.lowerBound, limitedBy: chars.endIndex),
                  let hi = chars.index(chars.startIndex, offsetBy: r.upperBound, limitedBy: chars.endIndex)
            else { continue }
            s[lo..<hi].backgroundColor = bg
        }
    }

    private static func marker(for kind: DiffLine.Kind) -> String {
        switch kind {
        case .insert: return "+"
        case .delete: return "-"
        case .context: return " "
        }
    }

    private static func markerColor(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .insert: return VimSyntaxPalette.diffAdd
        case .delete: return VimSyntaxPalette.diffRemove
        case .context: return .secondary
        }
    }
}

/// One diff line. A single click on it starts a single-line comment on that side+line
/// (3bq behavior); a press-and-drag across rows is handled by the parent's gesture,
/// which sets `selected` to highlight the spanned lines.
///
/// Equatable so the `.equatable()` wrapper at the use site can skip unchanged rows
/// (the closure field defeats SwiftUI's memberwise diffing). `==` deliberately
/// compares only (generation, index, selected): comparing AttributedString contents
/// would be O(chars) per drag tick — as bad as the re-parse this replaced. Safe
/// because any content change comes via a new `RenderedFileDiff.compute`, which
/// bumps `generation`.
private struct DiffLineRow: View, Equatable {
    let generation: Int
    /// Global flat-row index in the card's line stack.
    let index: Int
    let kind: DiffLine.Kind
    let oldLine: Int?
    let newLine: Int?
    /// Flattened `DiffLine.anchor` (tuples don't sit well in Equatable fields).
    let side: CommentSide?
    let anchorLine: Int?
    /// Precomputed marker + syntax-highlighted content (see RenderedFileDiff).
    let text: AttributedString
    /// True while a drag-select spans this row — draws the selection overlay.
    let selected: Bool
    let onComment: (CommentSide, Int) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.generation == b.generation && a.index == b.index && a.selected == b.selected
    }

    var body: some View {
        HStack(spacing: 0) {
            gutter(oldLine)
            gutter(newLine)
            Text(text)
                .font(.system(size: 14, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
                .textSelection(.enabled)
        }
        .background(bgColor)
        // Selection overlay sits above the add/remove bg and below the syntax text,
        // so it reads as a distinct range highlight without recoloring the code.
        .overlay(selected ? Color.accentColor.opacity(0.22) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if let side, let anchorLine { onComment(side, anchorLine) }
        }
        .help("Click to comment on this line, or click-drag to select a range")
    }

    private func gutter(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 40, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var bgColor: Color {
        switch kind {
        case .insert: return Color.green.opacity(0.10)
        case .delete: return Color.red.opacity(0.10)
        case .context: return .clear
        }
    }
}

/// A staged inline comment row.
private struct CommentRow: View {
    let comment: DiffComment
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(commentRangeLabel(side: comment.side, line: comment.line, endLine: comment.endLine))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            Text(comment.body)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button { onDelete() } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Delete comment")
                .clickCursor()
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.08))
    }
}

/// One AI review finding row (juancode-7ha) — used both inline (anchored to a diff
/// line) and in a file's orphan strip. Visually distinct from a human `CommentRow`:
/// a severity badge tinted by `ReviewSeverityStyle`, the title, the note, and a
/// "✨ Claude" tag. Mirrors the web `FindingItem`.
private struct FindingRow: View {
    let finding: ReviewFinding

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(finding.severity.rawValue.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(ReviewSeverityStyle.color(finding.severity))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .stroke(ReviewSeverityStyle.color(finding.severity).opacity(0.6)))
            VStack(alignment: .leading, spacing: 1) {
                if !finding.title.isEmpty {
                    Text(finding.title)
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                if !finding.note.isEmpty {
                    Text(finding.note)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            Text("✨ Claude")
                .font(.system(size: 9)).foregroundStyle(ReviewSeverityStyle.accent)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(ReviewSeverityStyle.accent.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .stroke(ReviewSeverityStyle.accent.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// Severity → color (+ the violet "Claude" accent) for the review overlay. Colors
/// live in the view layer, mirroring `VimSyntaxPalette`; the pure ordering lives in
/// `ReviewSeverity.rank` (JuancodeCore). Tuned to read well on the black app chrome
/// (no gray system backgrounds), paralleling the web `SEVERITY_STYLE`.
enum ReviewSeverityStyle {
    /// The "✨ Claude" accent — a violet matching the web review violets.
    static let accent = Color(red: 0.70, green: 0.55, blue: 0.95)

    static func color(_ severity: ReviewSeverity) -> Color {
        switch severity {
        case .critical: return Color(red: 0.95, green: 0.42, blue: 0.42)  // red
        case .high: return Color(red: 0.96, green: 0.58, blue: 0.30)      // orange
        case .medium: return Color(red: 0.92, green: 0.78, blue: 0.36)    // amber
        case .low: return Color(red: 0.45, green: 0.72, blue: 0.95)       // sky
        case .info: return .secondary
        }
    }
}

// MARK: - Git actions (commit / push / PR)

/// Commit / Push / PR controls for the changes panel header — the SwiftUI port of
/// the web `GitActions`. Operates on the session's cwd in-process via AppModel.
private struct GitActionsView: View {
    @Environment(AppModel.self) private var model
    let sessionId: String

    @State private var showCommit = false
    @State private var showPr = false
    @State private var message = ""
    @State private var prTitle = ""
    @State private var prBody = ""
    @State private var prDraft = false
    @State private var prResult: PrCreateResult?
    @State private var busy = false

    private var state: GitState? { model.gitState(sessionId) }
    private var note: AppModel.GitNote? { model.gitNoteBySession[sessionId] }

    var body: some View {
        if let s = state, !s.git {
            EmptyView()
        } else {
            HStack(spacing: 8) {
                if let note {
                    Text(note.text)
                        .font(.system(size: 10))
                        .foregroundStyle(note.ok ? .green : .red)
                        .lineLimit(1).frame(maxWidth: 180).help(note.text)
                }
                Button("Commit\(dirty ? " •" : "")") {
                    prefillBranch(); showCommit.toggle(); showPr = false
                }
                .controlSize(.small)
                .disabled(!dirty)
                .popover(isPresented: $showCommit, arrowEdge: .bottom) { commitForm }
                .clickCursor()

                Button(state?.ahead ?? 0 > 0 ? "Push \(state!.ahead)" : "Push") {
                    Task { busy = true; await model.push(sessionId); busy = false }
                }
                .controlSize(.small)
                .disabled(!canPush || busy)
                .clickCursor()

                Button("PR") {
                    prefillBranch(); showPr.toggle(); showCommit = false
                }
                .controlSize(.small)
                .disabled(!(state?.remote ?? false) || (state?.detached ?? false))
                .popover(isPresented: $showPr, arrowEdge: .bottom) { prForm }
                .clickCursor()
            }
        }
    }

    private var dirty: Bool { state?.dirty ?? false }
    private var canPush: Bool { (state?.remote ?? false) && (state?.ahead ?? 0) > 0 && !(state?.detached ?? false) }

    private func prefillBranch() {
        if prTitle.isEmpty, let b = state?.branch { prTitle = humanizeBranch(b) }
    }

    private var commitForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $message)
                .font(.system(size: 12))
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button("✨ Generate") {
                    Task {
                        busy = true
                        if let m = await model.generateCommitMessage(sessionId) { message = m }
                        busy = false
                    }
                }
                .controlSize(.small).disabled(busy)
                .clickCursor()
                Spacer()
                Button("Commit all") {
                    Task {
                        busy = true
                        await model.commit(sessionId, message: message)
                        busy = false
                        message = ""
                        showCommit = false
                    }
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || message.trimmingCharacters(in: .whitespaces).isEmpty)
                .clickCursor()
            }
            Text("Stages every change (git add -A) then commits.")
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
                            busy = true
                            prResult = await model.createPullRequest(
                                sessionId, title: prTitle, body: prBody, draft: prDraft)
                            busy = false
                        }
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || prTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    .clickCursor()
                }
                Text("Pushes the branch first, then opens the PR.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(width: 320)
    }
}

// MARK: - File tree (rows + resize handle)

/// Renders one tree node and (for a folder) its children recursively. A folder row
/// toggles its expansion; a file row selects itself so its diff shows on the right.
private struct FileTreeRows: View {
    let node: FileTreeNode
    let depth: Int
    let viewedPaths: Set<String>
    @Binding var selectedPath: String?
    @Binding var expanded: Set<String>

    var body: some View {
        if node.isDirectory {
            folderRow
            if expanded.contains(node.id), let kids = node.children {
                ForEach(kids) { child in
                    FileTreeRows(node: child, depth: depth + 1, viewedPaths: viewedPaths,
                                 selectedPath: $selectedPath, expanded: $expanded)
                }
            }
        } else if let file = node.file {
            fileRow(file)
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
                Spacer(minLength: 4)
            }
            .padding(.leading, indent).padding(.trailing, 8).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickCursor()
    }

    private func fileRow(_ file: DiffFile) -> some View {
        let selected = selectedPath == file.path
        let viewed = viewedPaths.contains(file.path)
        return Button {
            selectedPath = file.path
        } label: {
            HStack(spacing: 5) {
                // Align the file glyph with folder names (account for the chevron slot).
                Text(statusGlyph(file.status))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusColor(file.status))
                    .frame(width: 18)
                Text(node.name)
                    .font(.system(size: 11, design: .monospaced))
                    .strikethrough(viewed, color: .secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if viewed {
                    Image(systemName: "checkmark").font(.system(size: 8)).foregroundStyle(.green)
                } else {
                    if file.additions > 0 {
                        Text("+\(file.additions)").font(.system(size: 9)).foregroundStyle(.green)
                    }
                    if file.deletions > 0 {
                        Text("−\(file.deletions)").font(.system(size: 9)).foregroundStyle(.red)
                    }
                }
            }
            .padding(.leading, indent).padding(.trailing, 8).padding(.vertical, 3)
            .background(selected ? Color.accentColor.opacity(0.18) : .clear)
            .opacity(viewed ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickCursor()
    }

    private var indent: CGFloat { 8 + CGFloat(depth) * 14 }

    private func statusGlyph(_ s: FileStatus) -> String {
        switch s {
        case .modified: return "M"
        case .added, .untracked: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        }
    }

    private func statusColor(_ s: FileStatus) -> Color {
        switch s {
        case .modified: return .orange
        case .added, .untracked: return .green
        case .deleted: return .red
        case .renamed: return .blue
        }
    }
}

// MARK: - Vim-like syntax palette

/// Maps the pure `SyntaxToken` kinds from JuancodeServices to a warm vim-style color
/// palette (reminiscent of vim's default + common dark colorschemes) and builds the
/// per-line `AttributedString` the diff rows render (juancode-idg). Colors live here
/// in the view layer; the tokenizer stays SwiftUI-free and unit-testable.
enum VimSyntaxPalette {
    // Diff marker tints (kept separate from the bg so semantics stay legible).
    static let diffAdd = Color(red: 0.45, green: 0.78, blue: 0.42)
    static let diffRemove = Color(red: 0.88, green: 0.42, blue: 0.40)

    // Word-level intraline change tints — a stronger wash over the row's add/remove
    // background so the exact changed span pops without recoloring the syntax text.
    static let intralineAdd = Color.green.opacity(0.32)
    static let intralineRemove = Color.red.opacity(0.32)

    // Warm vim palette.
    static let keyword = Color(red: 0.88, green: 0.55, blue: 0.30)   // Statement — warm orange/brown
    static let string = Color(red: 0.78, green: 0.30, blue: 0.34)    // String — vim red/magenta
    static let comment = Color(red: 0.45, green: 0.62, blue: 0.95)   // Comment — vim blue
    static let number = Color(red: 0.78, green: 0.40, blue: 0.78)    // Constant — magenta/purple
    static let type = Color(red: 0.36, green: 0.74, blue: 0.62)      // Type — vim green/teal
    static let plain = Color.primary

    static func color(for kind: SyntaxTokenKind) -> Color {
        switch kind {
        case .keyword: return keyword
        case .string: return string
        case .comment: return comment
        case .number: return number
        case .type: return type
        case .plain: return plain
        }
    }

    /// Build a colored `AttributedString` for one line of code by overlaying the
    /// tokenizer's spans onto a plain base. Gaps between tokens render as `.plain`.
    static func attributed(_ text: String, path: String) -> AttributedString {
        var out = AttributedString(text)
        out.foregroundColor = plain
        guard !text.isEmpty else { return out }
        let chars = out.characters
        for token in highlightLine(text, path: path) {
            // Translate the String.Index range into the AttributedString character-view
            // index space by character offset (both share the same character sequence).
            let lower = text.distance(from: text.startIndex, to: token.range.lowerBound)
            let upper = text.distance(from: text.startIndex, to: token.range.upperBound)
            guard lower < upper,
                  let lo = chars.index(chars.startIndex, offsetBy: lower, limitedBy: chars.endIndex),
                  let hi = chars.index(chars.startIndex, offsetBy: upper, limitedBy: chars.endIndex)
            else { continue }
            out[lo..<hi].foregroundColor = color(for: token.kind)
        }
        return out
    }
}

/// Turn a branch like "juan/add-git-ctas" into a readable default PR title.
/// Mirrors the web `humanizeBranch`.
func humanizeBranch(_ branch: String) -> String {
    let tail = branch.split(separator: "/").last.map(String.init) ?? branch
    let words = tail.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    guard let first = words.first else { return branch }
    return first.uppercased() + words.dropFirst()
}
