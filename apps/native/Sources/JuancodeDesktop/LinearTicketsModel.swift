import Foundation
import Observation
import JuancodeCore

/// The Tickets panel's state (juancode-04u): Linear issues assigned to you, ten at a
/// time with more loading as you scroll, filtered by state and a search box, and scoped
/// to the selected session's repository or, explicitly, to every project.
///
/// Fetched at most once an hour on its own. Pages are cached per query — target,
/// state filter and search — in UserDefaults, so switching back to a project, or
/// relaunching inside that hour, shows its list without asking Linear again. A query
/// with no fresh page fetches straight away; refresh always does.
///
/// A result is only ever shown for the query that asked for it: a page that lands
/// after the repository, mapping, view, filter or search changed is cached under its
/// own query and never shown under another, and a next page lands only on the list
/// whose cursor asked for it.
@MainActor @Observable
public final class LinearTicketsModel {
    public typealias Fetch = @Sendable (LinearTicketQuery, _ first: Int, _ after: String?) async
        -> Result<LinearTicketPage, LinearTicketsError>
    public typealias FetchTargets = @Sendable () async -> Result<[LinearTicketTarget], LinearTicketsError>

    public private(set) var tickets: [LinearTicket] = []
    public private(set) var hasMore = false
    public private(set) var loading = false
    public private(set) var loadingMore = false
    public private(set) var error: LinearTicketsError?
    public private(set) var fetchedAt: Date?
    /// The workflow-state filter.
    public private(set) var scope: LinearTicketScope
    public private(set) var search: String
    /// The explicit All projects view.
    public private(set) var showAll: Bool
    /// The selected session's repository root.
    public private(set) var root: String?
    /// Repository root (see `linearMappingKey`) → its team or project.
    public private(set) var mappings: [String: LinearTicketTarget]

    /// Mapping choices, loaded when the mapping picker first opens.
    public private(set) var targets: [LinearTicketTarget] = []
    public private(set) var targetsLoading = false
    public private(set) var targetsError: LinearTicketsError?

    public var source: LinearTicketsSource {
        resolveLinearTicketsSource(showAll: showAll, root: root, mappings: mappings)
    }
    public var query: LinearTicketQuery? { LinearTicketQuery.of(source, scope: scope, search: search) }

    /// Where `ticket`'s "Work on" starts, given the list it is shown in.
    public func startWork(for ticket: LinearTicket) -> LinearStartWork {
        linearStartWork(for: ticket, source: source, selectedRoot: root, mappings: mappings)
    }

    @ObservationIgnored private var cursor: String?
    /// Bumped whenever the list on screen is replaced, so a next page that lands after
    /// that is dropped instead of appended to a different list.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var requestSerial = 0
    /// The newest top-of-list request per query, while it is in flight.
    @ObservationIgnored private var inFlight: [String: Int] = [:]
    @ObservationIgnored private var cache: [String: Entry]
    /// Last fetch attempt and failure per query, so the hourly refresh and the
    /// five-minute retry after a failure hold per query across switches.
    @ObservationIgnored private var attempts: [String: Date] = [:]
    @ObservationIgnored private var failures: [String: LinearTicketsError] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let fetchTargets: FetchTargets
    @ObservationIgnored private let now: @Sendable () -> Date

    public static let pageSize = 10
    public static let refreshInterval: TimeInterval = 60 * 60
    /// A failed fetch is retried sooner than the hourly refresh, but not every tick.
    public static let retryInterval: TimeInterval = 5 * 60
    /// Cached queries kept across relaunches, most recently fetched first.
    static let cacheLimit = 16
    static let scopeKey = "linear.tickets.scope"
    static let searchKey = "linear.tickets.search"
    static let showAllKey = "linear.tickets.allProjects"
    static let mappingsKey = "linear.tickets.repoTargets.v1"
    static let cacheKey = "linear.tickets.cache.v2"

    struct Entry: Codable, Equatable {
        var tickets: [LinearTicket]
        var hasMore: Bool
        var cursor: String?
        var fetchedAt: Date
    }

    public init(defaults: UserDefaults = .standard,
                fetch: @escaping Fetch = LinearTicketsModel.liveFetch,
                fetchTargets: @escaping FetchTargets = { await getLinearTargets() },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.fetch = fetch
        self.fetchTargets = fetchTargets
        self.now = now
        scope = defaults.string(forKey: Self.scopeKey).flatMap(LinearTicketScope.init(rawValue:)) ?? .open
        search = defaults.string(forKey: Self.searchKey) ?? ""
        showAll = defaults.bool(forKey: Self.showAllKey)
        mappings = defaults.data(forKey: Self.mappingsKey)
            .flatMap { try? JSONDecoder().decode([String: LinearTicketTarget].self, from: $0) } ?? [:]
        cache = defaults.data(forKey: Self.cacheKey)
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        for (key, entry) in cache { attempts[key] = entry.fetchedAt }
        show(fetchIfStale: false)
    }

    public static let liveFetch: Fetch = { q, first, after in
        await getAssignedTickets(scope: q.scope, search: q.search, first: first, after: after, target: q.target)
    }

    /// The refresh loop: a cheap tick that fetches only once the shown query's last
    /// fetch is an hour old (five minutes after a failure). Runs while the rail is up.
    public func run() async {
        while !Task.isCancelled {
            if !loading, let q = query, isStale(q) { await reload(keepLoaded: true) }
            await Nap.duration(.seconds(60))
        }
    }

    // MARK: inputs

    public func setRoot(_ r: String?) {
        let r = r.map(linearMappingKey)
        guard r != root else { return }
        root = r
        show()
    }

    public func setShowAll(_ all: Bool) {
        guard all != showAll else { return }
        showAll = all
        defaults.set(all, forKey: Self.showAllKey)
        show()
    }

    public func setScope(_ s: LinearTicketScope) {
        guard s != scope else { return }
        scope = s
        defaults.set(s.rawValue, forKey: Self.scopeKey)
        show()
    }

    public func setSearch(_ q: String) {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q != search else { return }
        search = q
        defaults.set(q, forKey: Self.searchKey)
        show()
    }

    /// Map `root` to `target`, or remove its mapping with nil.
    public func setMapping(_ target: LinearTicketTarget?, for root: String) {
        let key = linearMappingKey(root)
        guard mappings[key] != target else { return }
        mappings[key] = target
        if let data = try? JSONEncoder().encode(mappings) { defaults.set(data, forKey: Self.mappingsKey) }
        show()
    }

    public func loadTargets(force: Bool = false) async {
        guard !targetsLoading, force || targets.isEmpty else { return }
        targetsLoading = true
        let result = await fetchTargets()
        targetsLoading = false
        switch result {
        case .success(let t): targets = t; targetsError = nil
        case .failure(let e): targetsError = e
        }
    }

    // MARK: fetching

    /// Fetch the shown query from the top. `keepLoaded` asks for as many tickets as are
    /// already listed (up to 100), so a refresh doesn't snap a scrolled list back to ten.
    ///
    /// The page is cached under the query that asked for it, and shown only while that
    /// query is still the one on screen. A newer request for the same query supersedes
    /// this one outright.
    public func reload(keepLoaded: Bool) async {
        guard let q = query else { return }
        let key = q.cacheKey
        generation += 1
        requestSerial += 1
        let serial = requestSerial
        inFlight[key] = serial
        let first = keepLoaded ? min(max(Self.pageSize, tickets.count), 100) : Self.pageSize
        loadingMore = false
        if !keepLoaded {
            tickets = []
            hasMore = false
            cursor = nil
        }
        loading = true
        attempts[key] = now()
        let result = await fetch(q, first, nil)
        guard inFlight[key] == serial else { return }
        inFlight[key] = nil
        let shown = query == q
        switch result {
        case .success(let page):
            failures[key] = nil
            let entry = Entry(tickets: page.tickets, hasMore: page.hasNextPage, cursor: page.endCursor,
                              fetchedAt: now())
            store(key, entry)
            guard shown else { return }
            generation += 1
            loading = false
            apply(entry)
            error = nil
        case .failure(let e):
            failures[key] = e
            guard shown else { return }
            // A failed refresh keeps the last good list on screen; the error still shows.
            loading = false
            error = e
        }
    }

    /// The next page, when the list has been scrolled to its end. Appended only to the
    /// very list whose cursor asked for it.
    public func loadMore() async {
        guard hasMore, !loading, !loadingMore, let after = cursor, let q = query else { return }
        let gen = generation
        loadingMore = true
        let result = await fetch(q, Self.pageSize, after)
        guard gen == generation, query == q, cursor == after else { return }
        loadingMore = false
        switch result {
        case .success(let page):
            let have = Set(tickets.map(\.id))
            tickets += page.tickets.filter { !have.contains($0.id) }
            hasMore = page.hasNextPage
            cursor = page.endCursor
            error = nil
            store(q.cacheKey, Entry(tickets: tickets, hasMore: hasMore, cursor: cursor,
                                    fetchedAt: fetchedAt ?? now()))
        case .failure(let e):
            error = e
        }
    }

    // MARK: private

    /// Swap the list to the current query: its cached page or nothing, never the last
    /// query's. A loadMore still in flight for the old list is orphaned by the bump.
    private func show(fetchIfStale: Bool = true) {
        generation += 1
        loadingMore = false
        guard let q = query else {
            tickets = []; hasMore = false; cursor = nil; fetchedAt = nil; error = nil
            loading = false
            return
        }
        if let entry = cache[q.cacheKey] {
            apply(entry)
        } else {
            tickets = []; hasMore = false; cursor = nil; fetchedAt = nil
        }
        error = failures[q.cacheKey]
        loading = inFlight[q.cacheKey] != nil
        if fetchIfStale, !loading, isStale(q) {
            Task {
                guard self.query == q, self.inFlight[q.cacheKey] == nil else { return }
                await self.reload(keepLoaded: true)
            }
        }
    }

    private func apply(_ entry: Entry) {
        tickets = entry.tickets; hasMore = entry.hasMore; cursor = entry.cursor
        fetchedAt = entry.fetchedAt
    }

    private func isStale(_ q: LinearTicketQuery) -> Bool {
        let wait = failures[q.cacheKey] == nil ? Self.refreshInterval : Self.retryInterval
        return attempts[q.cacheKey].map { now().timeIntervalSince($0) >= wait } ?? true
    }

    private func store(_ key: String, _ entry: Entry) {
        cache[key] = entry
        if cache.count > Self.cacheLimit {
            let keep = cache.sorted { $0.value.fetchedAt > $1.value.fetchedAt }.prefix(Self.cacheLimit)
            cache = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: Self.cacheKey) }
    }
}
