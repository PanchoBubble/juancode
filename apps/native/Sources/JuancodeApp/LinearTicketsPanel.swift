// The right rail's Tickets panel (juancode-04u): Linear issues assigned to you, scoped
// to the selected session's repository (juancode-18j.3) or, explicitly, every project.
// The state lives in `LinearTicketsModel` (JuancodeDesktop); this is its view.
//
// A repository lists tickets only once it is mapped to a Linear team or project. An
// unmapped one says so and offers the mapping and All projects, never a guess.

import AppKit
import SwiftUI
import JuancodeCore
import JuancodeDesktop

/// The rail owns one for as long as it is up, so the hourly refresh outlives a collapse.
typealias LinearTicketsStore = LinearTicketsModel

struct LinearTicketsRail: View {
    @Environment(AppModel.self) private var model
    let store: LinearTicketsStore
    /// The selected session's repository root: what the panel is scoped to.
    let root: String?
    @State private var draft = ""
    @State private var pickingTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            scopeBar
            Divider().padding(.vertical, 2)
            content
            Spacer(minLength: 0)
        }
        .onAppear { draft = store.search }
        // Before the next frame, so the list never sits under the wrong repository.
        .onChange(of: root, initial: true) { store.setRoot(root) }
        // Debounced: a search per keystroke would spend Linear's rate limit on "l", "lo"…
        .task(id: draft) {
            await Nap.duration(.milliseconds(400))
            guard !Task.isCancelled else { return }
            store.setSearch(draft)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(LinearTicketScope.allCases) { s in
                    Button { store.setScope(s) } label: {
                        if s == store.scope { Label(s.label, systemImage: "checkmark") } else { Text(s.label) }
                    }
                }
            } label: {
                Text(store.scope.label).font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Which workflow states to list")
            .clickCursor()

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("Search", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !draft.isEmpty {
                    Button { draft = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .clickCursor()
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.06)))

            if store.loading { ProgressView().controlSize(.mini) }
            Button { Task { await store.reload(keepLoaded: true) } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(store.loading || store.query == nil)
            .help(store.fetchedAt.map { "Updated \(relativeTime(Int($0.timeIntervalSince1970 * 1000))). Refresh now" }
                  ?? "Refresh now")
            .clickCursor()
        }
        .padding(.horizontal, 10).padding(.top, 4)
    }

    /// Which tickets these are: this repository's team or project, or All projects.
    private var scopeBar: some View {
        HStack(spacing: 4) {
            Menu {
                Button { store.setShowAll(false) } label: {
                    let title = root.map { "This project (\(folderName($0)))" } ?? "This project"
                    if !store.showAll { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
                Button { store.setShowAll(true) } label: {
                    if store.showAll { Label("All projects", systemImage: "checkmark") } else { Text("All projects") }
                }
                if let root {
                    Divider()
                    Button("Map \(folderName(root)) to a Team or Project…") { pickingTarget = true }
                    if store.mappings[linearMappingKey(root)] != nil {
                        Button("Remove Mapping for \(folderName(root))") { store.setMapping(nil, for: root) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: store.showAll ? "globe" : "folder").font(.system(size: 9))
                    Text(scopeLabel).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
            .help("Whose tickets these are")
            .clickCursor()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.top, 3)
        .popover(isPresented: $pickingTarget, arrowEdge: .leading) {
            if let root {
                LinearTargetPicker(store: store, root: root,
                                   suggestions: suggestedLinearTargets(root: root, trackedIssues: model.trackedIssuesList,
                                                                       known: store.targets)) {
                    pickingTarget = false
                }
            }
        }
    }

    private var scopeLabel: String {
        switch store.source {
        case .all: "All projects"
        case .project(let root, let target): "\(folderName(root)) · \(target.label)"
        case .unmapped(let root): "\(folderName(root)) · not mapped"
        case .noProject: "No session selected"
        }
    }

    @ViewBuilder private var content: some View {
        switch store.source {
        case .noProject:
            VStack(alignment: .leading, spacing: 6) {
                note("Select a session to see its project's tickets.")
                allProjectsButton
            }
        case .unmapped(let root):
            VStack(alignment: .leading, spacing: 6) {
                note("\(folderName(root)) isn't mapped to a Linear team or project yet, so its tickets can't be told apart from other projects'.")
                HStack(spacing: 8) {
                    Button("Choose Team or Project…") { pickingTarget = true }
                        .controlSize(.small).clickCursor()
                    allProjectsButton
                }
                .padding(.horizontal, 10)
            }
        case .all, .project:
            list
        }
    }

    private var allProjectsButton: some View {
        Button("Show All Projects") { store.setShowAll(true) }
            .controlSize(.small)
            .padding(.horizontal, root == nil ? 10 : 0)
            .clickCursor()
    }

    @ViewBuilder private var list: some View {
        if let error = store.error, store.tickets.isEmpty {
            note(error.message)
        } else if store.tickets.isEmpty {
            note(store.loading ? "Loading…" : store.search.isEmpty
                 ? "No \(store.scope.label.lowercased()) tickets assigned to you\(scopeSuffix)."
                 : "No tickets match “\(store.search)”\(scopeSuffix).")
        } else {
            if let error = store.error {
                Text(error.message)
                    .font(.system(size: 10)).foregroundStyle(.red)
                    .lineLimit(2).help(error.message)
                    .padding(.horizontal, 10).padding(.bottom, 2)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.tickets) { LinearTicketRow(ticket: $0, start: store.startWork(for: $0)) }
                    if store.hasMore {
                        // Scrolling this into view is what asks for the next page.
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.mini)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .onAppear { Task { await store.loadMore() } }
                    }
                }
                .padding(.horizontal, 4)
            }
            .reportsRailOverflow()
        }
    }

    private var scopeSuffix: String {
        if case .project(_, let target) = store.source { return " in \(target.name)" }
        return ""
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func folderName(_ path: String) -> String { (path as NSString).lastPathComponent }

/// Pick the Linear team or project a repository's Tickets list. Suggestions come from
/// issues already tracked from it; nothing is mapped until one is clicked.
private struct LinearTargetPicker: View {
    let store: LinearTicketsStore
    let root: String
    let suggestions: [LinearTicketTarget]
    let done: () -> Void
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Map \(folderName(root)) to")
                .font(.system(size: 12, weight: .semibold))
            TextField("Filter teams and projects", text: $filter)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !shownSuggestions.isEmpty {
                        section("Suggested from issues tracked here", shownSuggestions)
                    }
                    section("Teams", shown.filter { if case .team = $0 { true } else { false } })
                    section("Projects", shown.filter { if case .project = $0 { true } else { false } })
                    if store.targetsLoading {
                        ProgressView().controlSize(.small).padding(6)
                    } else if let e = store.targetsError {
                        Text(e.message).font(.system(size: 11)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
                        Button("Retry") { Task { await store.loadTargets(force: true) } }.controlSize(.small)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(10)
        .frame(width: 280)
        .task { await store.loadTargets() }
    }

    private var current: LinearTicketTarget? { store.mappings[linearMappingKey(root)] }
    private func matching(_ t: LinearTicketTarget) -> Bool {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || t.label.localizedCaseInsensitiveContains(q)
    }
    private var shownSuggestions: [LinearTicketTarget] { suggestions.filter(matching) }
    private var shown: [LinearTicketTarget] {
        let suggested = Set(suggestions.map(\.identity))
        return store.targets.filter { !suggested.contains($0.identity) && matching($0) }
    }

    @ViewBuilder private func section(_ title: String, _ targets: [LinearTicketTarget]) -> some View {
        if !targets.isEmpty {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .padding(.top, 6).padding(.bottom, 2)
            ForEach(targets) { t in
                Button {
                    store.setMapping(t, for: root)
                    store.setShowAll(false)
                    done()
                } label: {
                    HStack {
                        Text(t.label).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 4)
                        if t.identity == current?.identity { Image(systemName: "checkmark").font(.system(size: 10)) }
                    }
                    .padding(.vertical, 3).padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickCursor()
            }
        }
    }
}

/// One ticket: state dot, id, title, priority and age. Click opens it in Linear; on
/// hover the age gives way to a "Work on" button.
private struct LinearTicketRow: View {
    @Environment(AppModel.self) private var model
    let ticket: LinearTicket
    /// Where "Work on" starts, resolved from the list this row is shown in.
    let start: LinearStartWork
    @State private var hovering = false
    /// Briefly true after the hover copy button, which then shows a checkmark.
    @State private var copied = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Circle()
                    .strokeBorder(stateColor, lineWidth: 1.5)
                    .background(Circle().fill(stateColor.opacity(ticket.stateType == "started" ? 0.5 : 0)))
                    .frame(width: 9, height: 9)
                    .help(ticket.stateName)
                Text(ticket.identifier)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(ticket.title)
                    .font(.system(size: 12))
                    .lineLimit(1).truncationMode(.tail)
                if let chain {
                    ChainBadge(chain: chain, member: ChainMemberRef(kind: .linear, ref: ticket.identifier),
                               compact: true)
                }
                Spacer(minLength: 4)
                priority
                if hovering {
                    copyLinkButton
                    workOnButton
                } else if let at = ticket.updatedAt {
                    Text(relativeTime(Int(at.timeIntervalSince1970 * 1000)))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .lineLimit(1).fixedSize()
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.09 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
        .help("\(ticket.identifier) · \(ticket.stateName)\n\(ticket.title)")
        .clickCursor()
        .contextMenu {
            Button("Open in Linear", action: open)
            Button(workOnHelp, action: workOn).disabled(start.root == nil)
            if model.supportsChains { chainMenu }
            Divider()
            Button("Copy ID") { copy(ticket.identifier) }
            Button("Copy Link") { copy(ticket.url) }
            if !ticket.branchName.isEmpty {
                Button("Copy Branch Name") { copy(ticket.branchName) }
            }
        }
    }

    private var chain: Chain? { model.chain(of: .linear, ref: ticket.identifier) }

    /// Tag the ticket into an active chain, start one named after it, or untag it.
    private var chainMenu: some View {
        Menu(chain.map { "Chain: \($0.name)" } ?? "Add to Chain") {
            ForEach(model.chains.active) { c in
                Button {
                    Task { await model.setChain(c.slug, forTicket: ticket) }
                } label: {
                    if c.slug == chain?.slug { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                }
            }
            if !model.chains.active.isEmpty { Divider() }
            Button("New Chain “\(ticket.identifier)”") {
                Task { await model.startChain(forTicket: ticket) }
            }
            if let chain {
                Button("Open Chain") {
                    model.openChain(slug: chain.slug)
                }
                Button("Remove from Chain") { Task { await model.setChain(nil, forTicket: ticket) } }
            }
        }
    }

    private var copyLinkButton: some View {
        Button {
            copy(ticket.url)
            copied = true
            Task {
                await Nap.duration(.seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "link").font(.system(size: 9))
                .frame(width: 18, height: 16)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied ? Color.green : Color.secondary)
        .help(copied ? "Copied" : "Copy link to \(ticket.identifier)")
        .clickCursor()
    }

    private var workOnButton: some View {
        Button(action: workOn) {
            Image(systemName: "play.fill").font(.system(size: 9))
                .frame(width: 18, height: 16)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(start.root == nil ? 0.08 : 0.2)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(start.root == nil ? Color.secondary : Color.accentColor)
        .disabled(start.root == nil)
        .help(workOnHelp)
        .clickCursor()
    }

    private var workOnHelp: String {
        switch start {
        case .root(let root): "Work on \(ticket.identifier) in \(folderName(root))"
        case .needsSession: "Select a session to work on \(ticket.identifier) in its project"
        case .ambiguous(let roots):
            "\(roots.map(folderName).joined(separator: ", ")) are all mapped to this ticket's team or project. Select a session in one of them to work on \(ticket.identifier)"
        }
    }

    private func workOn() {
        guard let root = start.root else { return }
        model.workOnLinearTicket(ticket, cwd: root)
    }

    @ViewBuilder private var priority: some View {
        switch ticket.priority {
        case 1:
            Image(systemName: "exclamationmark.square.fill")
                .font(.system(size: 10)).foregroundStyle(.orange).help("Urgent")
        case 2, 3, 4:
            Image(systemName: "cellularbars", variableValue: Double(5 - ticket.priority) / 3)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .help(ticket.priority == 2 ? "High" : ticket.priority == 3 ? "Medium" : "Low")
        default:
            EmptyView()
        }
    }

    private var stateColor: Color { Color(linearHex: ticket.stateColor) ?? .secondary }

    private func open() {
        if let url = URL(string: ticket.url) { NSWorkspace.shared.open(url) }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

private extension Color {
    /// "#rrggbb", as Linear sends a workflow state's colour.
    init?(linearHex hex: String) {
        let s = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255,
                  green: Double((v >> 8) & 0xff) / 255,
                  blue: Double(v & 0xff) / 255)
    }
}

/// The seed prompt for a session started from a ticket's "Work on".
func linearTicketPrompt(_ t: LinearTicket) -> String {
    var s = "Please help me work on Linear ticket \(t.identifier) \"\(t.title)\": \(t.url)"
    if !t.branchName.isEmpty { s += " (Linear's branch name: \(t.branchName))" }
    return s + " — start by reading the ticket and its comments."
}
