import SwiftUI
import JuancodeCore
import JuancodeDesktop

/// The app-wide Beads view: every project's bd tracker as a grid, one project as a
/// Jira-style board (status tiles, live sessions, filters, a column per status),
/// and one ticket in full. An overlay over the detail area like the GitHub view,
/// so the terminal panes underneath stay mounted. Esc and the ‹ button step back
/// one level at a time: ticket → board → projects → closed.
@MainActor @Observable
final class BeadsBoardModel {
    var project: String?
    var ticket: String?
    var filter = BeadsFilter()
    private(set) var closedByCwd: [String: [BeadsIssue]] = [:]
    private var details: [String: BeadsIssueDetail] = [:]
    private var missing: Set<String> = []

    func openProject(_ cwd: String) {
        if project != cwd { filter = BeadsFilter() }
        project = cwd
        ticket = nil
    }

    /// One level back; false when already at the root, so the caller closes the overlay.
    func back() -> Bool {
        if ticket != nil { ticket = nil; return true }
        if project != nil { project = nil; return true }
        return false
    }

    func closed(_ cwd: String) -> [BeadsIssue] { closedByCwd[cwd] ?? [] }

    func loadClosed(_ cwd: String) {
        Task { closedByCwd[cwd] = await getBeadsRecentlyClosed(cwd) }
    }

    private func key(_ cwd: String, _ id: String) -> String { cwd + "\u{0}" + id }
    func detail(_ cwd: String, _ id: String) -> BeadsIssueDetail? { details[key(cwd, id)] }
    func isMissing(_ cwd: String, _ id: String) -> Bool { missing.contains(key(cwd, id)) }

    func loadDetail(_ cwd: String, _ id: String) {
        let k = key(cwd, id)
        Task {
            if let d = await getBeadsDetail(cwd, id: id) { details[k] = d; missing.remove(k) }
            else if details[k] == nil { missing.insert(k) }
        }
    }
}

extension AppModel {
    func openBeads(project: String? = nil) {
        if let project { beadsBoard.openProject(project) }
        showingBeads = true
    }

    func toggleBeadsView() {
        if showingBeads { showingBeads = false } else { openBeads() }
    }

    func beadsBack() {
        if !beadsBoard.back() { showingBeads = false }
    }

    /// Projects whose tracker has loaded; the rest appear as their load lands.
    var beadsProjects: [String] {
        trackableFolders.filter { beads($0)?.available == true }
    }

    func loadAllBeads() {
        for cwd in trackableFolders where beads(cwd) == nil { loadBeads(cwd) }
    }

    /// Sessions with a live pty in `cwd` or any of its worktrees.
    func liveSessions(inProject cwd: String) -> [SessionMeta] {
        sessions.filter { !$0.archived && isLive($0.id) && repoRoot(forSession: $0) == cwd }
    }
}

struct BeadsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let board = model.beadsBoard
        VStack(spacing: 0) {
            header(board)
            Divider()
            Group {
                if let cwd = board.project, let id = board.ticket {
                    BeadsTicketView(cwd: cwd, id: id).id(cwd + id)
                } else if let cwd = board.project {
                    BeadsProjectView(cwd: cwd).id(cwd)
                } else {
                    BeadsProjectsGrid()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.appSurface)
        // The window key monitor in SwiftTermLive mirrors this for when a terminal
        // underneath still holds first responder.
        .onExitCommand { model.beadsBack() }
    }

    private func header(_ board: BeadsBoardModel) -> some View {
        HStack(spacing: 10) {
            if let cwd = board.project {
                Button { model.beadsBack() } label: {
                    Label(board.ticket == nil ? "Projects" : projectName(cwd), systemImage: "chevron.left")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Back (Esc)")
                .clickCursor()
            }
            Image(systemName: "checklist").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(board.ticket ?? board.project.map(projectName) ?? "Beads")
                    .font(.system(size: 14, weight: .semibold))
                if let cwd = board.project {
                    Text(board.ticket == nil ? cwd : projectName(cwd))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                } else {
                    Text("Every project's tracker").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("esc").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            Button { refresh(board) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh").clickCursor()
            Button { model.showingBeads = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Close").clickCursor()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func refresh(_ board: BeadsBoardModel) {
        guard let cwd = board.project else {
            for cwd in model.trackableFolders { model.loadBeads(cwd) }
            return
        }
        model.loadBeads(cwd)
        board.loadClosed(cwd)
        if let id = board.ticket { board.loadDetail(cwd, id) }
    }
}

private func projectName(_ cwd: String) -> String { (cwd as NSString).lastPathComponent }

private extension BeadsColumn {
    var tint: Color {
        switch self {
        case .todo: return .blue
        case .blocked: return .orange
        case .inProgress: return .purple
        case .inReview: return .teal
        case .done: return .green
        case .other: return .secondary
        }
    }
    var key: String {
        if case .other(let s) = self { return "other:" + s }
        return title
    }
}

private func priorityTint(_ p: Int) -> Color {
    switch p {
    case 0, 1: return .red
    case 2: return .orange
    default: return .secondary
    }
}

private struct Pill: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(tint.opacity(0.16))
            .foregroundStyle(tint)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct SectionLabel: View {
    let text: String
    var count: Int?
    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            if let count { Text("\(count)").font(.system(size: 10)).foregroundStyle(.tertiary) }
        }
    }
}

// MARK: - projects grid

private struct BeadsProjectsGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let projects = model.beadsProjects
        Group {
            if projects.isEmpty {
                ContentUnavailableView(
                    model.trackableFolders.contains { model.beads($0) == nil } ? "Loading trackers…" : "No trackers",
                    systemImage: "checklist",
                    description: Text("Projects with a .beads tracker show up here once a session runs in them."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                        ForEach(projects, id: \.self) { cwd in
                            BeadsProjectCard(cwd: cwd)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .onAppear { model.loadAllBeads() }
    }
}

private struct BeadsProjectCard: View {
    @Environment(AppModel.self) private var model
    let cwd: String
    @State private var hover = false

    var body: some View {
        let issues = model.beads(cwd)?.issues ?? []
        let counts = BeadsBoard.counts(issues)
        let live = model.liveSessions(inProject: cwd).count
        Button { model.openBeads(project: cwd) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(projectName(cwd)).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if live > 0 {
                        Label("\(live)", systemImage: "circle.fill")
                            .font(.system(size: 10)).foregroundStyle(.green)
                            .help("\(live) live session\(live == 1 ? "" : "s")")
                    }
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Text(cwd).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 12) {
                    ForEach(BeadsColumn.fixed, id: \.key) { col in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(counts[col] ?? 0)").font(.system(size: 15, weight: .semibold))
                                .foregroundStyle((counts[col] ?? 0) > 0 ? col.tint : .secondary)
                            Text(col.title).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hover ? 0.07 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .clickCursor()
    }
}

// MARK: - project board

private struct BeadsProjectView: View {
    @Environment(AppModel.self) private var model
    let cwd: String

    var body: some View {
        @Bindable var board = model.beadsBoard
        let result = model.beads(cwd)
        let open = result?.issues.filter { !$0.isClosed } ?? []
        let closed = board.closed(cwd)
        let counts = BeadsBoard.counts(open)
        let columns = BeadsBoard.columns(open: open, closed: closed, filter: board.filter)
        let sessions = model.liveSessions(inProject: cwd)
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 12) {
                tiles(counts: counts, open: open, closed: closed.count, live: sessions.count, proxy: proxy)
                if !sessions.isEmpty { sessionStrip(sessions) }
                filterBar(open: open, filter: $board.filter)
                if let r = result, !r.available {
                    ContentUnavailableView(r.error ?? "No tracker", systemImage: "exclamationmark.triangle")
                } else if result == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(columns, id: \.column.key) { col in
                                BeadsColumnView(cwd: cwd, column: col).id(col.column.key)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 14).padding(.top, 12)
        }
        .onAppear {
            model.loadBeads(cwd)
            board.loadClosed(cwd)
        }
    }

    private func tiles(counts: [BeadsColumn: Int], open: [BeadsIssue], closed: Int, live: Int,
                       proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            ForEach(BeadsColumn.fixed, id: \.key) { col in
                tile("\(counts[col] ?? 0)", col.title, tint: (counts[col] ?? 0) > 0 ? col.tint : .secondary) {
                    withAnimation { proxy.scrollTo(col.key, anchor: .leading) }
                }
            }
            tile("\(open.filter(\.ready).count)", "Ready", tint: .green, action: nil)
                .help("Open, with nothing blocking them")
            tile("\(closed)", "Recently done", tint: .green) {
                withAnimation { proxy.scrollTo(BeadsColumn.done.key, anchor: .leading) }
            }
            tile("\(live)", "Live sessions", tint: live > 0 ? .green : .secondary, action: nil)
        }
    }

    private func tile(_ value: String, _ label: String, tint: Color, action: (() -> Void)?) -> some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .semibold)).foregroundStyle(tint)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
        return Group {
            if let action {
                Button(action: action) { content.contentShape(Rectangle()) }
                    .buttonStyle(.plain).clickCursor()
            } else {
                content
            }
        }
    }

    private func sessionStrip(_ sessions: [SessionMeta]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Live sessions", count: sessions.count)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(sessions, id: \.id) { s in
                        Button { model.selection = s.id } label: {
                            HStack(spacing: 6) {
                                Circle().fill(activityTint(model.activity(s.id))).frame(width: 7, height: 7)
                                Text(s.title).font(.system(size: 12)).lineLimit(1)
                                Text(s.provider.rawValue).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(maxWidth: 280)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Go to \(s.title)")
                        .clickCursor()
                    }
                }
            }
        }
    }

    private func activityTint(_ a: SessionActivity?) -> Color {
        switch a {
        case .busy: return .blue
        case .waitingInput: return .orange
        default: return .green
        }
    }

    private func filterBar(open: [BeadsIssue], filter: Binding<BeadsFilter>) -> some View {
        let facets = BeadsBoard.facets(open)
        return HStack(spacing: 6) {
            TextField("Filter by id or title", text: filter.query)
                .textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(maxWidth: 220)
            ForEach(facets.priorities, id: \.self) { p in
                chip("P\(p)", on: filter.wrappedValue.priorities.contains(p)) {
                    filter.wrappedValue.priorities.formSymmetricDifference([p])
                }
            }
            Divider().frame(height: 14)
            ForEach(facets.types, id: \.self) { t in
                chip(t, on: filter.wrappedValue.types.contains(t)) {
                    filter.wrappedValue.types.formSymmetricDifference([t])
                }
            }
            if !filter.wrappedValue.isEmpty {
                Button("Clear") { filter.wrappedValue = BeadsFilter() }
                    .buttonStyle(.borderless).font(.system(size: 11)).clickCursor()
            }
            Spacer()
        }
    }

    private func chip(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 3.5)
                .background(Capsule().fill(on ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
                .foregroundStyle(on ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .clickCursor()
    }
}

private struct BeadsColumnView: View {
    let cwd: String
    let column: BeadsBoardColumn

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(column.column.tint).frame(width: 7, height: 7)
                Text(column.column.title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(column.issues.count)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            ScrollView {
                LazyVStack(spacing: 6) {
                    if column.issues.isEmpty {
                        Text("Nothing here").font(.system(size: 11)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                    }
                    ForEach(column.issues, id: \.id) { issue in
                        BeadsCard(cwd: cwd, issue: issue)
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 8)
            }
        }
        .frame(width: 270)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
    }
}

private struct BeadsCard: View {
    @Environment(AppModel.self) private var model
    let cwd: String
    let issue: BeadsIssue
    @State private var hover = false

    var body: some View {
        Button { model.beadsBoard.ticket = issue.id } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(issue.id).font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                    Pill(text: "P\(issue.priority)", tint: priorityTint(issue.priority))
                    Spacer(minLength: 0)
                    if issue.ready { Pill(text: "ready", tint: .green) }
                }
                Text(issue.title).font(.system(size: 12.5)).lineLimit(3)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Text(issue.issueType).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    if let parent = issue.parent {
                        Text("↑ \(parent)").font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    if issue.dependencyCount > 0 {
                        Label("\(issue.dependencyCount)", systemImage: "arrow.down.to.line")
                            .font(.system(size: 10)).foregroundStyle(.secondary).help("Depends on")
                    }
                    if issue.dependentCount > 0 {
                        Label("\(issue.dependentCount)", systemImage: "arrow.up.to.line")
                            .font(.system(size: 10)).foregroundStyle(.secondary).help("Needed by")
                    }
                }
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.appSurface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(hover ? 0.22 : 0.09)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            if !issue.isClosed {
                Button("Work on \(issue.id)") { model.workOnIssue(issue, cwd: cwd) }
            }
            Button("Copy id") { copy(issue.id) }
        }
        .clickCursor()
    }
}

private func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

// MARK: - ticket

private struct BeadsTicketView: View {
    @Environment(AppModel.self) private var model
    let cwd: String
    let id: String

    var body: some View {
        let board = model.beadsBoard
        let summary = (model.beads(cwd)?.issues ?? []).first { $0.id == id }
            ?? board.closed(cwd).first { $0.id == id }
        let detail = board.detail(cwd, id)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let d = detail {
                    head(d, summary: summary)
                    if !d.description.isEmpty {
                        section("Description") {
                            Text(d.description).font(.system(size: 13)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if !d.dependencies.isEmpty {
                        section("Depends on", count: d.dependencies.count) { relations(d.dependencies) }
                    }
                    if !d.dependents.isEmpty {
                        section("Needed by", count: d.dependents.count) { relations(d.dependents) }
                    }
                    if !d.comments.isEmpty {
                        section("Comments", count: d.comments.count) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(d.comments.enumerated()), id: \.offset) { _, c in
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(c.author).font(.system(size: 11, weight: .semibold))
                                            if let at = c.createdAt {
                                                Text(at, style: .relative).font(.system(size: 11)).foregroundStyle(.tertiary)
                                            }
                                        }
                                        Text(c.text).font(.system(size: 12.5)).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                } else if board.isMissing(cwd, id) {
                    ContentUnavailableView("Couldn't load \(id)", systemImage: "exclamationmark.triangle",
                                           description: Text("bd show found nothing for it in this project."))
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .onAppear { board.loadDetail(cwd, id) }
    }

    private func head(_ d: BeadsIssueDetail, summary: BeadsIssue?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Pill(text: "P\(d.priority)", tint: priorityTint(d.priority))
                Pill(text: d.status.replacingOccurrences(of: "_", with: " "),
                     tint: summary.map { BeadsColumn.of($0).tint } ?? .secondary)
                Pill(text: d.issueType)
                if summary?.ready == true { Pill(text: "ready", tint: .green) }
            }
            Text(d.title).font(.system(size: 18, weight: .semibold)).textSelection(.enabled)
            HStack(spacing: 12) {
                if let owner = d.owner { Text(owner) }
                if let at = d.updatedAt { Text("updated \(at, style: .relative) ago") }
                if let reason = d.closeReason { Text("closed: \(reason)") }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if let summary, !summary.isClosed {
                    Button("Work on it") { model.workOnIssue(summary, cwd: cwd) }
                        .help("Send this ticket to the project's focused session, or start one")
                        .clickCursor()
                }
                Button("Copy id") { copy(d.id) }.clickCursor()
            }
            .controlSize(.small)
        }
    }

    private func section<Content: View>(_ title: String, count: Int? = nil,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title, count: count)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
    }

    private func relations(_ list: [BeadsRelation]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(list) { r in
                Button { model.beadsBoard.ticket = r.id } label: {
                    HStack(spacing: 8) {
                        Text(r.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.accentColor)
                        Text(r.title).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        if !r.status.isEmpty { Pill(text: r.status.replacingOccurrences(of: "_", with: " ")) }
                        Text(r.type).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickCursor()
            }
        }
    }
}
