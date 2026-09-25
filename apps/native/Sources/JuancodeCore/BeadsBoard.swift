import Foundation

/// Pure logic behind the app-wide Beads view: a project's issues laid out as
/// Jira-style status columns, the filters over them, and the counts its summary
/// tiles show. SwiftUI-free so it is unit-testable.

/// One board column. The four fixed ones come first; any status bd reports that
/// none of them claims (deferred, hooked, …) gets a column of its own after them,
/// so nothing a tracker holds is silently left off the board.
public enum BeadsColumn: Hashable, Sendable {
    case todo, blocked, inProgress, inReview, done
    case other(String)

    public static let fixed: [BeadsColumn] = [.todo, .blocked, .inProgress, .inReview]

    public var title: String {
        switch self {
        case .todo: return "To do"
        case .blocked: return "Blocked"
        case .inProgress: return "In progress"
        case .inReview: return "In review"
        case .done: return "Done"
        case .other(let status): return status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// bd has no "blocked" status: an open issue waiting on a dependency is still
    /// `open`, so the `blocked` overlay is what moves it out of To do.
    public static func of(_ issue: BeadsIssue) -> BeadsColumn {
        switch issue.status {
        case "open": return issue.blocked ? .blocked : .todo
        case "in_progress": return .inProgress
        case "in_review": return .inReview
        case "closed": return .done
        default: return .other(issue.status)
        }
    }
}

public struct BeadsFilter: Equatable, Sendable {
    public var priorities: Set<Int> = []
    public var types: Set<String> = []
    public var query: String = ""

    public init(priorities: Set<Int> = [], types: Set<String> = [], query: String = "") {
        self.priorities = priorities; self.types = types; self.query = query
    }

    public var isEmpty: Bool {
        priorities.isEmpty && types.isEmpty
            && query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// An empty set means "any"; the query matches id or title, case-insensitively.
    public func matches(_ issue: BeadsIssue) -> Bool {
        if !priorities.isEmpty && !priorities.contains(issue.priority) { return false }
        if !types.isEmpty && !types.contains(issue.issueType) { return false }
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        return issue.id.localizedCaseInsensitiveContains(q)
            || issue.title.localizedCaseInsensitiveContains(q)
    }
}

public struct BeadsBoardColumn: Equatable, Sendable {
    public var column: BeadsColumn
    public var issues: [BeadsIssue]
}

public enum BeadsBoard {
    /// The board's columns, each sorted by priority then id. `closed` keeps the
    /// order it was given (bd returns it newest-closed first) and forms Done.
    /// The fixed columns and Done always appear, empty or not, so the layout does
    /// not jump as a filter narrows it.
    public static func columns(open: [BeadsIssue], closed: [BeadsIssue],
                               filter: BeadsFilter = BeadsFilter()) -> [BeadsBoardColumn] {
        var buckets: [BeadsColumn: [BeadsIssue]] = [:]
        var extras: [String] = []
        for issue in open where filter.matches(issue) {
            let col = BeadsColumn.of(issue)
            if col == .done { continue }
            if case .other(let s) = col, !extras.contains(s) { extras.append(s) }
            buckets[col, default: []].append(issue)
        }
        let order = BeadsColumn.fixed + extras.sorted().map(BeadsColumn.other)
        return order.map { BeadsBoardColumn(column: $0, issues: (buckets[$0] ?? []).sorted(by: BeadsGrouping.sort)) }
            + [BeadsBoardColumn(column: .done, issues: closed.filter(filter.matches))]
    }

    /// How many open issues each column holds, unfiltered: the summary tiles.
    public static func counts(_ open: [BeadsIssue]) -> [BeadsColumn: Int] {
        var out: [BeadsColumn: Int] = [:]
        for issue in open where !issue.isClosed { out[BeadsColumn.of(issue), default: 0] += 1 }
        return out
    }

    /// The priorities and types present, for the filter chips.
    public static func facets(_ issues: [BeadsIssue]) -> (priorities: [Int], types: [String]) {
        (Array(Set(issues.map(\.priority))).sorted(), Array(Set(issues.map(\.issueType))).sorted())
    }
}

// ── One issue in full (`bd show`) ────────────────────────────────────────────

public struct BeadsRelation: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var status: String
    /// bd's edge type: `blocks`, `parent-child`, `related`, …
    public var type: String

    public init(id: String, title: String, status: String, type: String) {
        self.id = id; self.title = title; self.status = status; self.type = type
    }
}

public struct BeadsComment: Codable, Sendable, Equatable {
    public var author: String
    public var text: String
    public var createdAt: Date?

    public init(author: String, text: String, createdAt: Date?) {
        self.author = author; self.text = text; self.createdAt = createdAt
    }
}

public struct BeadsIssueDetail: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var description: String
    public var status: String
    public var priority: Int
    public var issueType: String
    public var owner: String?
    public var updatedAt: Date?
    public var closeReason: String?
    public var dependencies: [BeadsRelation]
    public var dependents: [BeadsRelation]
    public var comments: [BeadsComment]

    public init(id: String, title: String, description: String, status: String, priority: Int,
                issueType: String, owner: String?, updatedAt: Date?, closeReason: String?,
                dependencies: [BeadsRelation], dependents: [BeadsRelation], comments: [BeadsComment]) {
        self.id = id; self.title = title; self.description = description; self.status = status
        self.priority = priority; self.issueType = issueType; self.owner = owner
        self.updatedAt = updatedAt; self.closeReason = closeReason
        self.dependencies = dependencies; self.dependents = dependents; self.comments = comments
    }
}
