// The right rail's Tickets panel (juancode-04u): Linear issues assigned to you, ten
// at a time with more loading as you scroll, filtered by state and a search box.
//
// Fetched at most once an hour on its own. The last result is kept in UserDefaults,
// so relaunching the app inside that hour shows it without asking Linear again.
// Changing the filter, typing a search or pressing refresh fetches straight away.

import AppKit
import SwiftUI
import JuancodeCore
import JuancodeDesktop

@MainActor @Observable
final class LinearTicketsStore {
    var tickets: [LinearTicket] = []
    var hasMore = false
    var loading = false
    var loadingMore = false
    var error: LinearTicketsError?
    var fetchedAt: Date?
    private(set) var scope: LinearTicketScope
    private(set) var search: String

    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var attemptedAt: Date?
    /// Bumped by every reload, so a page that lands after the filter changed is dropped.
    @ObservationIgnored private var generation = 0

    static let pageSize = 10
    static let refreshInterval: TimeInterval = 60 * 60
    /// A failed fetch is retried sooner than the hourly refresh, but not every tick.
    static let retryInterval: TimeInterval = 5 * 60
    private static let scopeKey = "linear.tickets.scope"
    private static let searchKey = "linear.tickets.search"
    private static let cacheKey = "linear.tickets.cache.v1"

    private struct Cache: Codable {
        var scope: String
        var search: String
        var tickets: [LinearTicket]
        var hasMore: Bool
        var cursor: String?
        var fetchedAt: Date
    }

    init() {
        let d = UserDefaults.standard
        scope = d.string(forKey: Self.scopeKey).flatMap(LinearTicketScope.init(rawValue:)) ?? .open
        search = d.string(forKey: Self.searchKey) ?? ""
        if let data = d.data(forKey: Self.cacheKey),
           let c = try? JSONDecoder().decode(Cache.self, from: data),
           c.scope == scope.rawValue, c.search == search {
            tickets = c.tickets
            hasMore = c.hasMore
            cursor = c.cursor
            fetchedAt = c.fetchedAt
            attemptedAt = c.fetchedAt
        }
    }

    /// The refresh loop: a cheap tick that fetches only once the last fetch is an hour
    /// old (five minutes after a failure). Runs for as long as the rail is on screen.
    func run() async {
        while !Task.isCancelled {
            let wait = error == nil ? Self.refreshInterval : Self.retryInterval
            if attemptedAt.map({ Date().timeIntervalSince($0) >= wait }) ?? true {
                await reload(keepLoaded: true)
            }
            await Nap.duration(.seconds(60))
        }
    }

    func setScope(_ s: LinearTicketScope) {
        guard s != scope else { return }
        scope = s
        UserDefaults.standard.set(s.rawValue, forKey: Self.scopeKey)
        Task { await reload(keepLoaded: false) }
    }

    func setSearch(_ q: String) {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q != search else { return }
        search = q
        UserDefaults.standard.set(q, forKey: Self.searchKey)
        Task { await reload(keepLoaded: false) }
    }

    /// Fetch from the top. `keepLoaded` asks for as many tickets as are already listed
    /// (up to 100), so an hourly refresh doesn't snap a scrolled list back to ten.
    func reload(keepLoaded: Bool) async {
        generation += 1
        let gen = generation
        let first = keepLoaded ? min(max(Self.pageSize, tickets.count), 100) : Self.pageSize
        loadingMore = false
        if !keepLoaded {
            tickets = []
            hasMore = false
            cursor = nil
        }
        loading = true
        attemptedAt = Date()
        let result = await getAssignedTickets(scope: scope, search: search, first: first, after: nil)
        guard gen == generation else { return }
        loading = false
        switch result {
        case .success(let page):
            tickets = page.tickets
            hasMore = page.hasNextPage
            cursor = page.endCursor
            error = nil
            fetchedAt = Date()
            persist()
        case .failure(let e):
            // A failed refresh keeps the last good list on screen; the error still shows.
            error = e
        }
    }

    /// The next page, when the list has been scrolled to its end.
    func loadMore() async {
        guard hasMore, !loading, !loadingMore, let after = cursor else { return }
        let gen = generation
        loadingMore = true
        let result = await getAssignedTickets(scope: scope, search: search, first: Self.pageSize, after: after)
        guard gen == generation else { return }
        loadingMore = false
        switch result {
        case .success(let page):
            let have = Set(tickets.map(\.id))
            tickets += page.tickets.filter { !have.contains($0.id) }
            hasMore = page.hasNextPage
            cursor = page.endCursor
            error = nil
            persist()
        case .failure(let e):
            error = e
        }
    }

    private func persist() {
        guard let fetchedAt else { return }
        let c = Cache(scope: scope.rawValue, search: search, tickets: tickets, hasMore: hasMore,
                      cursor: cursor, fetchedAt: fetchedAt)
        if let data = try? JSONEncoder().encode(c) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }
}

struct LinearTicketsRail: View {
    let store: LinearTicketsStore
    /// The selected session's project: where "Work on" starts its session.
    let root: String?
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider().padding(.vertical, 2)
            content
            Spacer(minLength: 0)
        }
        .onAppear { draft = store.search }
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
            .disabled(store.loading)
            .help(store.fetchedAt.map { "Updated \(relativeTime(Int($0.timeIntervalSince1970 * 1000))). Refresh now" }
                  ?? "Refresh now")
            .clickCursor()
        }
        .padding(.horizontal, 10).padding(.top, 4)
    }

    @ViewBuilder private var content: some View {
        if let error = store.error, store.tickets.isEmpty {
            note(error.message)
        } else if store.tickets.isEmpty {
            note(store.loading ? "Loading…" : store.search.isEmpty
                 ? "No \(store.scope.label.lowercased()) tickets assigned to you."
                 : "No tickets match “\(store.search)”.")
        } else {
            if let error = store.error {
                Text(error.message)
                    .font(.system(size: 10)).foregroundStyle(.red)
                    .lineLimit(2).help(error.message)
                    .padding(.horizontal, 10).padding(.bottom, 2)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.tickets) { LinearTicketRow(ticket: $0, root: root) }
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

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One ticket: state dot, id, title, priority and age. Click opens it in Linear; on
/// hover the age gives way to a "Work on" button.
private struct LinearTicketRow: View {
    @Environment(AppModel.self) private var model
    let ticket: LinearTicket
    let root: String?
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
            Button(workOnHelp, action: workOn).disabled(root == nil)
            Divider()
            Button("Copy ID") { copy(ticket.identifier) }
            Button("Copy Link") { copy(ticket.url) }
            if !ticket.branchName.isEmpty {
                Button("Copy Branch Name") { copy(ticket.branchName) }
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
                    .fill(Color.accentColor.opacity(root == nil ? 0.08 : 0.2)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(root == nil ? Color.secondary : Color.accentColor)
        .disabled(root == nil)
        .help(workOnHelp)
        .clickCursor()
    }

    private var workOnHelp: String {
        guard let root else { return "Select a session to work on \(ticket.identifier) in its project" }
        return "Work on \(ticket.identifier) in \((root as NSString).lastPathComponent)"
    }

    private func workOn() {
        guard let root else { return }
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
