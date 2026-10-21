import SwiftUI
import AppKit
import JuancodeCore
import JuancodeDesktop

/// The full-width diff-review panel (juancode-a5j): the session's diff with a file
/// tree beside it, comments on single lines or ranges, and every comment sent as one
/// review message into the session the window shows. A native port of the
/// `diff-review` Claude Code plugin, whose side pane Claude Code caps at ~61 columns;
/// here it takes the whole detail area.
///
/// The keyboard is vim's, with Space as leader — j/k with counts, gg/G, ⌃D/⌃U, ]c/[c
/// hunks, gt/gT files, V visual, gcc / gc to comment, ]d/[d comments, Enter edits,
/// dd/x deletes, ␣w sends, ␣n toggles the tree, ⌃H/⌃L move between tree and diff.
/// Keys arrive through `ReviewKeyCatcher`, an AppKit first responder, so ⌃-keys and
/// counts reach the panel intact and none of them leak into the pty underneath.
///
/// The pure half — rows, anchoring, the message, the key parser — is
/// `JuancodeCore/LineReview.swift`; loading and sending are `DiffReviewModel.swift`.
struct DiffReviewPanel: View {
    @Environment(AppModel.self) private var model
    let sessionId: String

    private enum Focus { case diff, tree }

    /// A cursor stop in the diff: a row (code line, hunk header or note) or a comment
    /// — plus the open comment editor, which is in the list (not drawn beside it) so
    /// the lazy stack sees it come and go.
    private enum Item: Hashable {
        case row(Int)
        case comment(String)
        case draft
    }

    /// A comment being written: over rows `from...to`, or replacing comment `editId`.
    private struct Draft: Equatable {
        /// Distinct per opened editor, so the editor knows to take the keyboard again.
        var serial: Int
        var from: Int
        var to: Int
        var editId: String?
        var text: String
    }

    @AppStorage("diffReview.treeShown") private var treeShown = true
    @AppStorage("diffReview.treeWidth") private var treeWidth: Double = 300

    @State private var focus: Focus = .diff
    @State private var selectedPath: String?
    @State private var collapsedDirs: Set<String> = []
    @State private var treeCursor: String?
    @State private var cursor: Item?
    /// The other end of a visual selection; non-nil means visual mode.
    @State private var anchor: Item?
    @State private var draft: Draft?
    @State private var draftSerial = 0
    @State private var parser = ReviewKeyParser()
    @State private var rendered: RenderedReviewFile?
    @State private var viewportHeight: CGFloat = 600
    /// Center the next cursor scroll (⌃D/⌃U, gg/G, file and hunk jumps).
    @State private var centerNextScroll = false
    @State private var keyToken = 0
    @State private var frames = RowFrameStore()

    private let rowHeight: CGFloat = 18
    private let dragSpace = "diff-review-lines"

    // MARK: - Derived

    private var review: DiffReviewModel { model.diffReview }
    private var snapshot: DiffReviewModel.Snapshot? { review.snapshot(sessionId) }
    private var files: [DiffFile] { snapshot?.files ?? [] }
    private var allComments: [ReviewComment] { review.comments(sessionId) }
    private var file: DiffFile? { files.first { $0.path == selectedPath } }
    private var fileComments: [ReviewComment] {
        guard let path = selectedPath else { return [] }
        return allComments.filter { $0.path == path }
    }
    private var treeRows: [ReviewTreeRow] { reviewTreeRows(files, collapsed: collapsedDirs) }
    private var fileOrder: [String] { reviewFileOrder(files) }
    private var isVisual: Bool { anchor != nil }

    /// The diff's cursor stops, top to bottom: comments whose line has left the diff,
    /// then each row followed by the comments that end on it. An open editor sits
    /// under the last line it covers, or in place of the comment it edits.
    private var items: [Item] {
        var out = stops
        guard let d = draft else { return out }
        if let id = d.editId, let at = out.firstIndex(of: .comment(id)) {
            out[at] = .draft
        } else if d.editId == nil, let at = out.firstIndex(of: .row(d.to)) {
            out.insert(.draft, at: at + 1)
        }
        return out
    }

    private var stops: [Item] {
        guard let rf = rendered else { return [] }
        let comments = fileComments
        let keys = Set(rf.rows.compactMap { $0.line.map(reviewLineKey) })
        var byKey: [String: [ReviewComment]] = [:]
        for c in comments { byKey[c.endKey, default: []].append(c) }
        var out: [Item] = comments.filter { !keys.contains($0.endKey) }.map { .comment($0.id) }
        for (i, row) in rf.rows.enumerated() {
            out.append(.row(i))
            if let line = row.line {
                for c in byKey[reviewLineKey(line)] ?? [] { out.append(.comment(c.id)) }
            }
        }
        return out
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            statusBar
        }
        .background(Color.appSurface)
        .background(ReviewKeyCatcher(token: keyToken &+ model.diffReviewFocusToken, enabled: draft == nil,
                                     onKey: handle).frame(width: 0, height: 0))
        .onAppear {
            if snapshot == nil { model.loadDiffReview(sessionId) }
            syncSelection()
        }
        .onChange(of: snapshot) { _, _ in syncSelection() }
        .onChange(of: draft == nil) { _, closed in if closed { keyToken &+= 1 } }
        .perfTrackBody()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble").foregroundStyle(.secondary)
            Text("Review").font(.system(size: 12, weight: .semibold))
            Picker("", selection: Binding(
                get: { review.base(sessionId) },
                set: { model.loadDiffReview(sessionId, base: $0); keyToken &+= 1 }
            )) {
                ForEach(ReviewBase.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("What to diff against")
            if let snapshot {
                Text(snapshot.label)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            if review.loading.contains(sessionId) { ProgressView().controlSize(.small) }
            Spacer(minLength: 8)
            if !files.isEmpty {
                let adds = files.reduce(0) { $0 + $1.additions }
                let dels = files.reduce(0) { $0 + $1.deletions }
                HStack(spacing: 6) {
                    Text("\(files.count) file\(files.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                    Text("+\(adds)").foregroundStyle(VimSyntaxPalette.diffAdd)
                    Text("−\(dels)").foregroundStyle(VimSyntaxPalette.diffRemove)
                }
                .font(.system(size: 11)).fixedSize()
            }
            Button { model.loadDiffReview(sessionId); keyToken &+= 1 } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh the diff (R)")
            .clickCursor()
            let count = allComments.count
            Button {
                model.sendDiffReview(sessionId)
                keyToken &+= 1
            } label: {
                Label(count == 0 ? "Send review" : "Send \(count) comment\(count == 1 ? "" : "s")",
                      systemImage: "paperplane")
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(count == 0 || review.sending.contains(sessionId))
            .help("Send every comment to the session as one review message (␣w)")
            .clickCursor()
            Button { model.closeDiffReview() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close the review (q) — comments are kept")
                .clickCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.appPanel)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let error = review.errors[sessionId], snapshot == nil {
            centered(error)
        } else if snapshot == nil {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading the diff…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if snapshot?.git == false {
            centered("Not a git repository — nothing to review.")
        } else if files.isEmpty {
            centered("No changes (\(snapshot?.label ?? "")).")
        } else {
            HStack(spacing: 0) {
                if treeShown {
                    treePane.frame(width: CGFloat(treeWidth))
                    DragResizeHandle(axis: .vertical, value: $treeWidth, min: 180, max: 640, invert: false)
                }
                diffPane.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func centered(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tree

    private var treePane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(treeRows) { row in
                        treeRow(row).id(row.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: treeCursor) { _, id in
                if let id, focus == .tree { proxy.scrollTo(id) }
            }
        }
        .background(Color.appPanel)
        .overlay(alignment: .top) {
            if focus == .tree { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
    }

    private func treeRow(_ row: ReviewTreeRow) -> some View {
        let isSelected = row.file?.path == selectedPath && row.file != nil
        let isCursor = focus == .tree && row.id == treeCursor
        let comments = row.file.map { f in allComments.filter { $0.path == f.path }.count } ?? 0
        return HStack(spacing: 5) {
            if row.isDirectory {
                Image(systemName: row.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8)).foregroundStyle(.secondary).frame(width: 10)
                Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(.secondary)
            } else if let f = row.file {
                Text(statusLetter(f.status))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusColor(f.status))
                    .frame(width: 10)
            }
            Text(row.name)
                .font(.system(size: 11.5, weight: row.isDirectory ? .medium : .regular,
                              design: row.isDirectory ? .default : .monospaced))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if comments > 0 {
                Text("●\(comments)").font(.system(size: 9.5)).foregroundStyle(Color.accentColor)
            }
            if row.additions > 0 {
                Text("+\(row.additions)").font(.system(size: 9.5)).foregroundStyle(VimSyntaxPalette.diffAdd)
            }
            if row.deletions > 0 {
                Text("−\(row.deletions)").font(.system(size: 9.5)).foregroundStyle(VimSyntaxPalette.diffRemove)
            }
        }
        .padding(.leading, 8 + CGFloat(row.depth) * 12)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(isSelected ? Color.appSelection : Color.clear)
        .overlay(alignment: .leading) {
            if isCursor { Rectangle().fill(Color.accentColor).frame(width: 2) }
        }
        .background(isCursor ? Color.appHairline(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            treeCursor = row.id
            if row.isDirectory {
                toggleDir(row.id)
                focus = .tree
            } else if let path = row.file?.path {
                openFile(path)
            }
            keyToken &+= 1
        }
        .clickCursor()
    }

    // MARK: - Diff

    @ViewBuilder
    private var diffPane: some View {
        VStack(spacing: 0) {
            if let file { fileHeader(file) }
            Divider()
            if let rf = rendered, rf.path == file?.path {
                diffLines(rf)
            } else {
                Text("Rendering…").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Parse + highlight off-main, once per file content.
        .task(id: file.map { "\($0.path)\u{0}\($0.diff)" }) {
            guard let file else { rendered = nil; return }
            let previous = rendered
            let generation = (previous?.generation ?? 0) &+ 1
            let out = await Task.detached(priority: .userInitiated) {
                RenderedReviewFile.compute(file, generation: generation)
            }.value
            guard !Task.isCancelled else { return }
            rendered = out
            frames.reset()
            restoreCursor(after: previous, in: out)
        }
    }

    private func fileHeader(_ file: DiffFile) -> some View {
        HStack(spacing: 8) {
            Text(statusLetter(file.status))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor(file.status))
            Text(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 6)
            if let at = fileOrder.firstIndex(of: file.path) {
                Text("\(at + 1)/\(fileOrder.count)").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Text("+\(file.additions)").font(.system(size: 10)).foregroundStyle(VimSyntaxPalette.diffAdd)
            Text("−\(file.deletions)").font(.system(size: 10)).foregroundStyle(VimSyntaxPalette.diffRemove)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.appBand)
    }

    private func diffLines(_ rf: RenderedReviewFile) -> some View {
        let list = items
        let positions = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($1, $0) })
        let selected = selectedRows(list, positions: positions)
        let byId = Dictionary(fileComments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let commentedKeys = Set(fileComments.map(\.endKey))
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(list, id: \.self) { item in
                        switch item {
                        case .row(let i):
                            let row = rf.rows[i]
                            ReviewRowView(
                                generation: rf.generation, index: i, row: row, text: rf.text[i],
                                isCursor: cursor == item && focus == .diff,
                                isSelected: selected.contains(i),
                                hasComment: row.line.map { commentedKeys.contains(reviewLineKey($0)) } ?? false)
                                .equatable()
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(dragSpace)) }
                                    action: { frames.set(i, $0) }
                                .contentShape(Rectangle())
                                .onTapGesture { click(row: i) }
                                .id(item)
                        case .draft:
                            if let d = draft { draftEditor(d).id(item) }
                        case .comment(let id):
                            if let c = byId[id] {
                                ReviewCommentBox(
                                    comment: c,
                                    isCursor: cursor == item && focus == .diff,
                                    isOrphan: rf.rows.allSatisfy { $0.line.map(reviewLineKey) != c.endKey },
                                    onSelect: { cursor = item; anchor = nil; focus = .diff; keyToken &+= 1 },
                                    onEdit: { cursor = item; beginEdit(c) },
                                    onDelete: { deleteComment(c.id) })
                                .id(item)
                            }
                        }
                    }
                }
                .padding(.bottom, 40)
                .coordinateSpace(name: dragSpace)
                .simultaneousGesture(dragSelect)
            }
            // A fresh scroll position per file: gt lands at the top of the next one.
            .id(rf.path)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .onChange(of: cursor) { _, item in
                guard let item else { return }
                if centerNextScroll {
                    centerNextScroll = false
                    proxy.scrollTo(item, anchor: .center)
                } else {
                    proxy.scrollTo(item)
                }
            }
            .onChange(of: draft?.serial) { _, serial in
                if serial != nil { proxy.scrollTo(Item.draft) }
            }
        }
    }

    /// The comment editor, right under the commented lines. Enter saves, ⇧Enter is a
    /// newline, Esc cancels.
    private func draftEditor(_ d: Draft) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(draftLabel(d)).font(.system(size: 10)).foregroundStyle(.secondary)
            ReviewDraftEditor(
                text: Binding(get: { draft?.text ?? "" }, set: { draft?.text = $0 }),
                focusToken: d.serial,
                onSubmit: saveDraft,
                onCancel: cancelDraft)
                .frame(height: 64)
                .background(Color.appPanel)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor.opacity(0.6)))
            HStack(spacing: 8) {
                Button("Comment") { saveDraft() }
                    .controlSize(.small)
                    .disabled((draft?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .clickCursor()
                Button("Cancel") { cancelDraft() }.controlSize(.small).clickCursor()
                Text("⏎ save · ⇧⏎ newline · esc cancel")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.appPanelElevated))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.35)))
        .padding(.leading, ReviewRowView.codeInset)
        .padding(.trailing, 16)
        .padding(.vertical, 4)
    }

    private func draftLabel(_ d: Draft) -> String {
        if let id = d.editId, let c = allComments.first(where: { $0.id == id }) {
            return "Edit comment on \(c.location)"
        }
        guard let rf = rendered, let path = selectedPath,
              let c = makeReviewComment(path: path, rows: rf.rows, from: d.from, to: d.to, text: "")
        else { return "Comment" }
        return "Comment on \(c.location)"
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(modeName)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(modeColor.opacity(0.25)))
                .foregroundStyle(modeColor)
            if !parser.pending.isEmpty {
                Text(parser.pending.replacingOccurrences(of: " ", with: "␣"))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            if let notice = review.notices[sessionId] {
                Text(notice.text)
                    .font(.system(size: 11))
                    .foregroundStyle(notice.isError ? Color.red : .secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Text("gcc comment · V select · ]c/[c hunk · gt/gT file · ]d/[d comment · dd delete · ␣w send · ␣n tree · q close")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.head)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(Color.appPanel)
    }

    private var modeName: String {
        if draft != nil { return "INSERT" }
        if focus == .tree { return "TREE" }
        return isVisual ? "VISUAL" : "NORMAL"
    }

    private var modeColor: Color {
        if draft != nil { return .green }
        if focus == .tree { return .blue }
        return isVisual ? .orange : .secondary
    }

    // MARK: - Selection sync

    /// Keep the selected file valid as the diff reloads; default to the first file in
    /// tree order.
    private func syncSelection() {
        let order = fileOrder
        if selectedPath == nil || !order.contains(selectedPath!) {
            selectedPath = order.first
            cursor = nil
            anchor = nil
            draft = nil
        }
        if treeCursor == nil || !treeRows.contains(where: { $0.id == treeCursor }) {
            treeCursor = selectedPath
        }
    }

    /// After a re-render: on the same file, keep the cursor on the same line (found
    /// again by its line key); on a new file, start at its first code line.
    private func restoreCursor(after previous: RenderedReviewFile?, in now: RenderedReviewFile) {
        if let previous, previous.path == now.path {
            if case .row(let i)? = cursor, previous.rows.indices.contains(i) {
                if let line = previous.rows[i].line,
                   let at = reviewRowIndex(forKey: reviewLineKey(line), in: now.rows) {
                    cursor = .row(at)
                } else {
                    cursor = .row(min(i, max(0, now.rows.count - 1)))
                }
            }
            if case .row(let i)? = anchor, !now.rows.indices.contains(i) { anchor = nil }
            if let d = draft, !now.rows.indices.contains(d.to) { draft = nil }
            return
        }
        anchor = nil
        draft = nil
        centerNextScroll = true
        cursor = now.rows.firstIndex { $0.line != nil }.map(Item.row) ?? (now.rows.isEmpty ? nil : .row(0))
    }

    private func openFile(_ path: String) {
        if path != selectedPath {
            selectedPath = path
            cursor = nil
            anchor = nil
            draft = nil
        }
        treeCursor = path
        focus = .diff
    }

    private func toggleDir(_ id: String) {
        if collapsedDirs.contains(id) { collapsedDirs.remove(id) } else { collapsedDirs.insert(id) }
    }

    // MARK: - Mouse

    private func click(row i: Int) {
        guard draft == nil else { return }
        focus = .diff
        anchor = nil
        parser.reset()
        cursor = .row(i)
        keyToken &+= 1
    }

    /// Press on a line and drag across others: the rows light up as a visual
    /// selection, and letting go opens the comment editor under them. A press that
    /// never leaves its row is a click, which the row's own tap handles.
    private var dragSelect: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(dragSpace))
            .onChanged { value in
                guard draft == nil,
                      let start = frames.row(at: value.startLocation),
                      let now = frames.row(at: value.location) else { return }
                guard now != start || anchor != nil else { return }
                focus = .diff
                anchor = .row(start)
                cursor = .row(now)
            }
            .onEnded { value in
                guard draft == nil, case .row(let start)? = anchor else { return }
                let now = frames.row(at: value.location) ?? start
                cursor = .row(now)
                if now == start { anchor = nil; keyToken &+= 1; return }
                openDraft()
            }
    }

    // MARK: - Keys

    private func handle(_ key: ReviewKey) -> Bool {
        // An editor is open but the keyboard is back here (a click elsewhere): Esc
        // still cancels it, and nothing else acts on the diff behind it.
        guard draft == nil else {
            if key == .escape { cancelDraft() }
            return true
        }
        guard let command = parser.feed(key, visual: isVisual && focus == .diff) else { return true }
        switch command {
        case .send:
            model.sendDiffReview(sessionId)
        case .toggleTree:
            treeShown.toggle()
            if !treeShown { focus = .diff }
        case .focusTree:
            treeShown = true
            focus = .tree
            treeCursor = selectedPath ?? treeCursor
        case .focusDiff:
            focus = .diff
        case .refresh:
            model.loadDiffReview(sessionId)
        default:
            if focus == .tree { treeCommand(command) } else { diffCommand(command) }
        }
        return true
    }

    private func diffCommand(_ command: ReviewKeyCommand) {
        let list = items
        guard !list.isEmpty else {
            if case .close = command { model.closeDiffReview() }
            if case .nextFile(let n) = command { stepFile(n) }
            if case .prevFile(let n) = command { stepFile(-n) }
            return
        }
        let at = cursor.flatMap { list.firstIndex(of: $0) } ?? 0
        let half = max(1, Int(viewportHeight / rowHeight / 2))
        switch command {
        case .down(let n): cursor = list[min(list.count - 1, at + n)]
        case .up(let n): cursor = list[max(0, at - n)]
        case .halfPageDown:
            centerNextScroll = true
            cursor = list[min(list.count - 1, at + half)]
        case .halfPageUp:
            centerNextScroll = true
            cursor = list[max(0, at - half)]
        case .top:
            centerNextScroll = true
            cursor = list[0]
        case .bottom:
            centerNextScroll = true
            cursor = list[list.count - 1]
        case .goToLine(let n):
            guard let rf = rendered else { return }
            let hit = rf.rows.firstIndex { ($0.line?.newLine ?? $0.line?.oldLine ?? -1) >= n }
            centerNextScroll = true
            cursor = .row(hit ?? max(0, rf.rows.count - 1))
        case .nextHunk(let n): jump(n, forward: true, in: list, from: at, where: isHunk)
        case .prevHunk(let n): jump(n, forward: false, in: list, from: at, where: isHunk)
        case .nextComment:
            if !jump(1, forward: true, in: list, from: at, where: isComment) { sayNoComments() }
        case .prevComment:
            if !jump(1, forward: false, in: list, from: at, where: isComment) { sayNoComments() }
        case .nextFile(let n): stepFile(n)
        case .prevFile(let n): stepFile(-n)
        case .toggleVisual:
            anchor = anchor == nil ? (cursor ?? list[at]) : nil
        case .comment:
            openDraft()
        case .activate:
            if case .comment(let id)? = cursor, let c = allComments.first(where: { $0.id == id }) {
                beginEdit(c)
            } else {
                openDraft()
            }
        case .deleteComment:
            deleteUnderCursor(list, at: at)
        case .escape:
            anchor = nil
        case .close:
            model.closeDiffReview()
        case .left, .right, .send, .toggleTree, .focusTree, .focusDiff, .refresh:
            break
        }
    }

    private func treeCommand(_ command: ReviewKeyCommand) {
        let rows = treeRows
        guard !rows.isEmpty else { return }
        let at = rows.firstIndex { $0.id == treeCursor } ?? 0
        let row = rows[at]
        switch command {
        case .down(let n): treeCursor = rows[min(rows.count - 1, at + n)].id
        case .up(let n): treeCursor = rows[max(0, at - n)].id
        case .halfPageDown: treeCursor = rows[min(rows.count - 1, at + 10)].id
        case .halfPageUp: treeCursor = rows[max(0, at - 10)].id
        case .top: treeCursor = rows[0].id
        case .bottom: treeCursor = rows[rows.count - 1].id
        case .activate, .comment:
            if row.isDirectory { toggleDir(row.id) } else if let p = row.file?.path { openFile(p) }
        case .right:
            if row.isDirectory {
                if row.isCollapsed { toggleDir(row.id) } else { treeCursor = rows[min(rows.count - 1, at + 1)].id }
            } else if let p = row.file?.path {
                selectedPath = p
            }
        case .left:
            if row.isDirectory, !row.isCollapsed {
                toggleDir(row.id)
            } else if let parent = rows[..<at].last(where: { $0.isDirectory && $0.depth < row.depth }) {
                treeCursor = parent.id
            }
        case .nextFile(let n): stepFile(n); treeCursor = selectedPath
        case .prevFile(let n): stepFile(-n); treeCursor = selectedPath
        case .escape, .close: focus = .diff
        default: break
        }
    }

    private func isHunk(_ item: Item) -> Bool {
        guard case .row(let i) = item, let rf = rendered, rf.rows.indices.contains(i),
              case .hunk = rf.rows[i] else { return false }
        return true
    }

    private func isComment(_ item: Item) -> Bool {
        if case .comment = item { return true }
        return false
    }

    /// Move the cursor to the `n`th stop matching `test` past `from`. False if none.
    @discardableResult
    private func jump(_ n: Int, forward: Bool, in list: [Item], from: Int,
                      where test: (Item) -> Bool) -> Bool {
        var at = from
        var moved = false
        for _ in 0..<max(1, n) {
            let range = forward ? Array((at + 1)..<list.count) : Array((0..<at).reversed())
            guard let hit = range.first(where: { test(list[$0]) }) else { break }
            at = hit
            moved = true
        }
        if moved {
            centerNextScroll = true
            cursor = list[at]
        }
        return moved
    }

    private func sayNoComments() {
        review.say("no comments in this file", isError: true, in: sessionId)
    }

    private func stepFile(_ by: Int) {
        let order = fileOrder
        guard !order.isEmpty else { return }
        let at = selectedPath.flatMap { order.firstIndex(of: $0) } ?? 0
        let next = order[min(order.count - 1, max(0, at + by))]
        let kept = focus
        if next != selectedPath { openFile(next) }
        focus = kept
    }

    /// The rows a new comment would cover: the visual selection, or the cursor's row.
    private func selectedRows(_ list: [Item], positions: [Item: Int]) -> Set<Int> {
        if let d = draft, d.editId == nil { return Set(min(d.from, d.to)...max(d.from, d.to)) }
        guard let anchor, let cursor, let a = positions[anchor], let c = positions[cursor] else { return [] }
        return Set(list[min(a, c)...max(a, c)].compactMap { if case .row(let i) = $0 { return i } else { return nil } })
    }

    // MARK: - Comments

    private func openDraft() {
        // On a comment, "comment here" means edit that one — the plugin's `openDraft`.
        if anchor == nil, case .comment(let id)? = cursor,
           let c = allComments.first(where: { $0.id == id }) {
            beginEdit(c)
            return
        }
        guard let rf = rendered, let path = selectedPath else { return }
        let list = items
        let positions = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($1, $0) })
        var rows = selectedRows(list, positions: positions)
        if rows.isEmpty, case .row(let i)? = cursor { rows = [i] }
        guard let lo = rows.min(), let hi = rows.max(),
              makeReviewComment(path: path, rows: rf.rows, from: lo, to: hi, text: "") != nil else {
            review.say("move onto a code line to comment", isError: true, in: sessionId)
            return
        }
        // The editor goes under the last CODE line of the range, where the comment
        // will render once saved.
        let last = (lo...hi).last { rf.rows[$0].line != nil } ?? hi
        draftSerial &+= 1
        draft = Draft(serial: draftSerial, from: lo, to: last, editId: nil, text: "")
        parser.reset()
    }

    private func beginEdit(_ c: ReviewComment) {
        guard let rf = rendered else { return }
        let at = reviewRowIndex(forKey: c.endKey, in: rf.rows) ?? 0
        draftSerial &+= 1
        draft = Draft(serial: draftSerial, from: at, to: at, editId: c.id, text: c.text)
        anchor = nil
        parser.reset()
    }

    private func saveDraft() {
        guard let d = draft else { return }
        let text = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { draft = nil; anchor = nil }
        guard !text.isEmpty else { return }
        if let id = d.editId {
            review.edit(id, text: text, in: sessionId)
            return
        }
        guard let rf = rendered, let path = selectedPath,
              let c = makeReviewComment(path: path, rows: rf.rows, from: d.from, to: d.to, text: text)
        else { return }
        review.add(c, to: sessionId)
        cursor = .row(d.to)
        let n = allComments.count
        review.say("\(n) comment\(n == 1 ? "" : "s") staged — ␣w sends", in: sessionId)
    }

    private func cancelDraft() {
        draft = nil
        anchor = nil
    }

    private func deleteComment(_ id: String) {
        review.delete(id, in: sessionId)
        if cursor == .comment(id), let rf = rendered,
           let c = allComments.first(where: { $0.id == id }) {
            cursor = reviewRowIndex(forKey: c.endKey, in: rf.rows).map(Item.row)
        }
        keyToken &+= 1
    }

    private func deleteUnderCursor(_ list: [Item], at: Int) {
        if case .comment(let id)? = cursor {
            // Land on the line the comment hung from.
            let above = list[..<at].last { if case .row = $0 { return true } else { return false } }
            review.delete(id, in: sessionId)
            cursor = above
            return
        }
        guard case .row(let i)? = cursor, let rf = rendered, let line = rf.rows[i].line,
              let c = fileComments.last(where: { $0.endKey == reviewLineKey(line) }) else {
            review.say("no comment on this line", isError: true, in: sessionId)
            return
        }
        review.delete(c.id, in: sessionId)
    }

    // MARK: - Status styling

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
        case .modified: return .orange
        case .added, .untracked: return VimSyntaxPalette.diffAdd
        case .deleted: return VimSyntaxPalette.diffRemove
        case .renamed: return .blue
        }
    }
}

// MARK: - Render model

/// One file's review rows with their highlighted text, computed off-main. Equality is
/// a generation stamp, like `RenderedFileDiff`.
struct RenderedReviewFile: Equatable, Sendable {
    let generation: Int
    let path: String
    let rows: [ReviewRow]
    /// Index-aligned with `rows`: syntax colours + intraline washes for code lines,
    /// the plain text of headers and notes.
    let text: [AttributedString]

    static func == (a: Self, b: Self) -> Bool { a.generation == b.generation }

    /// Pure — safe to run in `Task.detached`.
    static func compute(_ file: DiffFile, generation: Int) -> RenderedReviewFile {
        let rows = reviewRows(for: file)
        // `RenderedFileDiff` already has the Changes panel's highlighting (syntax,
        // marker tint, word-level intraline); its lines are ours in the same order.
        let highlighted = RenderedFileDiff.compute(diff: file.diff, path: file.path, generation: 0).rendered
        var k = 0
        let text = rows.map { row -> AttributedString in
            switch row {
            case .hunk(let header): return AttributedString(header)
            case .note(let note): return AttributedString(note)
            case .line(let line):
                defer { k += 1 }
                guard k < highlighted.count else { return AttributedString(line.text) }
                // Drop the leading +/-/space marker: the row draws its own column.
                var s = highlighted[k]
                if !s.characters.isEmpty {
                    s.removeSubrange(s.startIndex..<s.index(afterCharacter: s.startIndex))
                }
                return s
            }
        }
        return RenderedReviewFile(generation: generation, path: file.path, rows: rows, text: text)
    }
}

/// Row frames in the diff's coordinate space, for hit-testing a drag. A reference
/// type on purpose: frames change on every scroll, and recording them must not
/// re-render the panel.
@MainActor
final class RowFrameStore {
    private var frames: [Int: CGRect] = [:]

    func set(_ row: Int, _ frame: CGRect) { frames[row] = frame }
    func reset() { frames = [:] }

    /// The row under `point`, else the nearest one by height (a drag past the ends or
    /// over a comment box).
    func row(at point: CGPoint) -> Int? {
        if let hit = frames.first(where: { $0.value.minY <= point.y && point.y < $0.value.maxY }) {
            return hit.key
        }
        return frames.min { abs($0.value.midY - point.y) < abs($1.value.midY - point.y) }?.key
    }
}

// MARK: - Rows

/// One diff row: old and new line numbers, a ● when a comment hangs from it, the
/// +/- marker and the highlighted code. Equatable on what changes its look, so a
/// cursor move redraws two rows, not the file.
private struct ReviewRowView: View, Equatable {
    let generation: Int
    let index: Int
    let row: ReviewRow
    let text: AttributedString
    let isCursor: Bool
    let isSelected: Bool
    let hasComment: Bool

    /// Where code starts — comment boxes and the editor line up with it.
    static let codeInset: CGFloat = 4 + 44 + 44 + 14 + 14

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.generation == b.generation && a.index == b.index && a.isCursor == b.isCursor
            && a.isSelected == b.isSelected && a.hasComment == b.hasComment
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Rectangle()
                .fill(isCursor ? Color.accentColor : Color.clear)
                .frame(width: 3)
                .padding(.trailing, 1)
            switch row {
            case .hunk:
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color.accentColor.opacity(0.8))
                    .padding(.leading, 88 + 28)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .note:
                Text(text)
                    .font(.system(size: 11)).italic()
                    .foregroundStyle(.secondary)
                    .padding(.leading, 88 + 28)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .line(let line):
                number(line.oldLine)
                number(line.newLine)
                Text(hasComment ? "●" : " ")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 14)
                Text(marker(line.kind))
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(markerColor(line.kind))
                    .frame(width: 14, alignment: .leading)
                Text(text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minHeight: 18)
        .background(background)
        .overlay(isSelected ? Color.accentColor.opacity(0.20) : Color.clear)
        .overlay(isCursor ? Color.appHairline(0.07) : Color.clear)
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 40, alignment: .trailing)
            .padding(.trailing, 4)
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

    private func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .insert: return "+"
        case .delete: return "-"
        case .context: return " "
        }
    }

    private func markerColor(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .insert: return VimSyntaxPalette.diffAdd
        case .delete: return VimSyntaxPalette.diffRemove
        case .context: return .secondary
        }
    }
}

/// A staged comment, inline under the line it ends on: a rounded box with where it
/// points and what it says.
private struct ReviewCommentBox: View {
    let comment: ReviewComment
    let isCursor: Bool
    /// Its line has left the diff (it is still sent).
    let isOrphan: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble.fill").font(.system(size: 9))
                        .foregroundStyle(Color.accentColor)
                    Text(comment.location)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    if isOrphan {
                        Text("line no longer in the diff").font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
                Text(comment.text)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: onEdit) { Image(systemName: "pencil").font(.system(size: 10)) }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Edit (⏎)")
                .clickCursor()
            Button(action: onDelete) { Image(systemName: "xmark").font(.system(size: 10)) }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Delete (dd)")
                .clickCursor()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.appPanelElevated))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(isCursor ? Color.accentColor : Color.appHairline(0.15), lineWidth: isCursor ? 1.5 : 1))
        .padding(.leading, ReviewRowView.codeInset)
        .padding(.trailing, 16)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - AppKit bridges

/// The panel's keyboard: an invisible first responder that turns key-downs into
/// `ReviewKey`s. AppKit rather than `.onKeyPress` so ⌃D/⌃H and friends arrive as
/// themselves, and so the window key monitor can recognise it and stand aside.
struct ReviewKeyCatcher: NSViewRepresentable {
    /// A change takes first responder.
    let token: Int
    /// False while the comment editor has the keyboard: don't take it back.
    let enabled: Bool
    let onKey: (ReviewKey) -> Bool

    final class Coordinator { var token: Int? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ReviewKeyCatcherView { ReviewKeyCatcherView() }

    func updateNSView(_ view: ReviewKeyCatcherView, context: Context) {
        view.onKey = onKey
        guard enabled, context.coordinator.token != token else { return }
        context.coordinator.token = token
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }
}

final class ReviewKeyCatcherView: NSView {
    var onKey: ((ReviewKey) -> Bool)?

    /// Catchers currently in a window — at most one per window, since the panel is.
    private static let all = NSHashTable<ReviewKeyCatcherView>.weakObjects()

    /// The open review panel's catcher in `window`, if it has one.
    static func mounted(in window: NSWindow) -> ReviewKeyCatcherView? {
        all.allObjects.first { $0.window === window }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Self.all.add(self) } else { Self.all.remove(self) }
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        // ⌘/⌥ combos are the menus' and the system's.
        guard !mods.contains(.command), !mods.contains(.option) else {
            super.keyDown(with: event)
            return
        }
        guard let key = Self.reviewKey(event, control: mods.contains(.control)) else { return }
        _ = onKey?(key)
    }

    static func reviewKey(_ event: NSEvent, control: Bool) -> ReviewKey? {
        switch event.keyCode {
        case 53: return .escape
        case 36, 76: return .enter
        case 125: return .down
        case 126: return .up
        case 123: return .left
        case 124: return .right
        case 116: return .pageUp
        case 121: return .pageDown
        case 115: return .home
        case 119: return .end
        default: break
        }
        if control {
            guard let c = event.charactersIgnoringModifiers?.lowercased().first else { return nil }
            return .ctrl(c)
        }
        guard let c = event.characters?.first else { return nil }
        return .char(c)
    }
}

/// The comment editor: a plain NSTextView where Enter saves, ⇧Enter (or ⌥Enter) is a
/// newline and Esc cancels. Takes focus as soon as it is on screen.
private struct ReviewDraftEditor: NSViewRepresentable {
    @Binding var text: String
    /// A change takes the keyboard. SwiftUI may reuse this view for the next draft,
    /// so "focus when first made" is not enough.
    let focusToken: Int
    let onSubmit: () -> Void
    let onCancel: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ReviewDraftEditor
        var focusedToken: Int?
        init(_ parent: ReviewDraftEditor) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let view = note.object as? NSTextView else { return }
            parent.text = view.string
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    view.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let view = NSTextView(frame: .zero)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        view.delegate = context.coordinator
        view.font = .systemFont(ofSize: 12)
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 4, height: 4)
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        if context.coordinator.focusedToken != focusToken {
            context.coordinator.focusedToken = focusToken
            Self.focus(view, attempts: 20)
        }
    }

    /// Make `view` first responder once it is in a window — a LazyVStack can mount it
    /// a pass or two after it is made.
    private static func focus(_ view: NSTextView, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(attempts == 20 ? 0 : 50)) { [weak view] in
            guard let view else { return }
            if let window = view.window {
                let ok = window.makeFirstResponder(view)
                view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            } else if attempts > 0 {
                focus(view, attempts: attempts - 1)
            }
        }
    }
}
