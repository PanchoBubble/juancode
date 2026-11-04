import Foundation

// Which Linear tickets the right rail's Tickets panel lists for the selected session.
//
// A repository is never matched to Linear by name: a folder called "web" says nothing
// about which team or project its work is filed under. The user maps a repository to
// one Linear team or project explicitly. Until they do, the panel says the repository
// is unmapped and offers that mapping and an explicit "All projects" view, rather than
// guessing and listing another project's tickets as if they were this one's. Tracked
// issues the user already started from a repository are offered as suggestions, but
// only become the mapping when the user picks one.

/// What a repository's Tickets are narrowed to.
public enum LinearTicketTarget: Codable, Hashable, Sendable, Identifiable {
    /// A team, by its key ("ENG"). Keys are unique in a workspace and are what the
    /// identifiers of its issues start with.
    case team(key: String, name: String)
    /// A project, by its id. Names are not unique.
    case project(id: String, name: String)

    /// Stable across renames, so a renamed team keeps its mapping and cached pages.
    public var identity: String {
        switch self {
        case .team(let key, _): "team:\(key.uppercased())"
        case .project(let id, _): "project:\(id)"
        }
    }
    public var id: String { identity }

    public var name: String {
        switch self {
        case .team(_, let name), .project(_, let name): name
        }
    }

    public var label: String {
        switch self {
        case .team(let key, let name): name.caseInsensitiveCompare(key) == .orderedSame ? "Team \(key)" : "Team \(name) (\(key))"
        case .project(_, let name): "Project \(name)"
        }
    }

    /// Whether a listed ticket belongs to this team or project.
    public func matches(_ ticket: LinearTicket) -> Bool {
        switch self {
        case .team(let key, _): ticket.teamKey.caseInsensitiveCompare(key) == .orderedSame
        case .project(let id, _): !id.isEmpty && ticket.projectId == id
        }
    }
}

/// A repository root as a mapping key: standardized, without a trailing slash.
public func linearMappingKey(_ root: String) -> String {
    var s = (root as NSString).standardizingPath
    while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
    return s
}

/// What the panel is showing, resolved from the view mode, the selected session's
/// repository and the saved mappings.
public enum LinearTicketsSource: Equatable, Sendable {
    /// Explicitly every project.
    case all
    /// The selected repository's mapped team or project.
    case project(root: String, target: LinearTicketTarget)
    /// The selected repository has no mapping. Nothing is fetched.
    case unmapped(root: String)
    /// Project view with no session selected. Nothing is fetched.
    case noProject

    /// The repository the panel is scoped to, when it is scoped to one.
    public var root: String? {
        switch self {
        case .project(let root, _), .unmapped(let root): root
        case .all, .noProject: nil
        }
    }
}

public func resolveLinearTicketsSource(showAll: Bool, root: String?,
                                       mappings: [String: LinearTicketTarget]) -> LinearTicketsSource {
    if showAll { return .all }
    guard let root else { return .noProject }
    let key = linearMappingKey(root)
    if let target = mappings[key] { return .project(root: key, target: target) }
    return .unmapped(root: key)
}

/// Everything a page of tickets depends on. Its `cacheKey` keys cached pages, so a
/// page is only ever shown for the query that fetched it.
public struct LinearTicketQuery: Hashable, Sendable {
    /// nil lists every project.
    public var target: LinearTicketTarget?
    public var scope: LinearTicketScope
    public var search: String

    public init(target: LinearTicketTarget?, scope: LinearTicketScope, search: String) {
        self.target = target; self.scope = scope; self.search = search
    }

    public var cacheKey: String { "\(target?.identity ?? "all")|\(scope.rawValue)|\(search)" }

    /// The query for `source`, or nil when the source fetches nothing.
    public static func of(_ source: LinearTicketsSource, scope: LinearTicketScope,
                          search: String) -> LinearTicketQuery? {
        switch source {
        case .all: LinearTicketQuery(target: nil, scope: scope, search: search)
        case .project(_, let target): LinearTicketQuery(target: target, scope: scope, search: search)
        case .unmapped, .noProject: nil
        }
    }
}

/// Where a ticket's "Work on" starts its session.
public enum LinearStartWork: Equatable, Sendable {
    case root(String)
    /// No session is selected and no mapping names the ticket's repository.
    case needsSession
    /// Several repositories are mapped to the ticket's team or project and the selected
    /// one is not among them, so picking one would be a guess.
    case ambiguous([String])

    public var root: String? { if case .root(let r) = self { r } else { nil } }
}

/// In a project view, the project's repository. In All projects, the repository mapped
/// to the ticket's team or project — the selected one when it is among them — and
/// otherwise the selected session's repository, as before mappings existed.
public func linearStartWork(for ticket: LinearTicket, source: LinearTicketsSource,
                            selectedRoot: String?,
                            mappings: [String: LinearTicketTarget]) -> LinearStartWork {
    if case .project(let root, let target) = source, target.matches(ticket) { return .root(root) }
    let selected = selectedRoot.map(linearMappingKey)
    let candidates = mappings.filter { $0.value.matches(ticket) }.map(\.key).sorted()
    if let selected, candidates.contains(selected) { return .root(selected) }
    if candidates.count == 1 { return .root(candidates[0]) }
    if candidates.count > 1 { return .ambiguous(candidates) }
    return selected.map(LinearStartWork.root) ?? .needsSession
}

/// Teams of issues the user already tracked from `root`, most-tracked first, as mapping
/// suggestions. Never applied on their own.
public func suggestedLinearTargets(root: String, trackedIssues: [TrackedIssue],
                                   known: [LinearTicketTarget] = []) -> [LinearTicketTarget] {
    let key = linearMappingKey(root)
    var counts: [String: Int] = [:]
    for issue in trackedIssues where linearMappingKey(issue.cwd) == key {
        guard let dash = issue.identifier.firstIndex(of: "-") else { continue }
        let team = issue.identifier[..<dash].uppercased()
        guard !team.isEmpty, team.allSatisfy({ $0.isLetter || $0.isNumber }) else { continue }
        counts[team, default: 0] += 1
    }
    return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { team, _ in
        known.first { $0.identity == "team:\(team)" } ?? .team(key: team, name: team)
    }
}
