import Foundation

/// The chain detail view's decisions: which group a member sits in, what a search
/// matches, and the order rows come out in. Pure over rows the app has already
/// described (title, project, status from its own stores), so the grouping and the
/// filter are tested without a model.

/// The detail view's sections, in the order they are drawn. Oracles are sessions on
/// the wire; they get their own group because they are steered differently.
public enum ChainDetailGroup: String, CaseIterable, Sendable {
    case sessions
    case oracles
    case prs
    case tickets

    public var title: String {
        switch self {
        case .sessions: return "Sessions"
        case .oracles: return "Oracles"
        case .prs: return "Pull Requests"
        case .tickets: return "Tickets"
        }
    }

    /// The group a member belongs in. `isOracle` answers for a session id.
    public static func of(_ member: ChainMember, isOracle: (String) -> Bool) -> ChainDetailGroup {
        switch member.kind {
        case .session: return isOracle(member.ref) ? .oracles : .sessions
        case .trackedPr: return .prs
        case .beads, .linear: return .tickets
        }
    }
}

/// One member as the detail view lists it.
public struct ChainDetailRow: Sendable, Equatable, Identifiable {
    public var member: ChainMember
    public var group: ChainDetailGroup
    public var title: String
    public var project: String?
    public var status: String?
    /// Epoch ms of the item's last known activity, when it has one.
    public var lastActivity: Int?
    /// Anything else a search should find it by (provider, branch, ...).
    public var keywords: [String]

    public init(member: ChainMember, group: ChainDetailGroup, title: String,
                project: String? = nil, status: String? = nil, lastActivity: Int? = nil,
                keywords: [String] = []) {
        self.member = member
        self.group = group
        self.title = title
        self.project = project
        self.status = status
        self.lastActivity = lastActivity
        self.keywords = keywords
    }

    public var id: ChainMemberRef { member.memberRef }

    /// When it last did something, else when it joined the chain.
    public var activityAt: Int { lastActivity ?? member.addedAt }
}

/// One group's rows, as drawn.
public struct ChainDetailSection: Sendable, Equatable, Identifiable {
    public var group: ChainDetailGroup
    public var rows: [ChainDetailRow]

    public var id: ChainDetailGroup { group }
}

public enum ChainDetail {
    /// Does `row` match `query`? Every whitespace-separated word must appear,
    /// ignoring case and diacritics, in one of its title, ref, project, status or
    /// keywords. An empty query matches everything.
    public static func matches(_ row: ChainDetailRow, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let fields = [row.title, row.member.ref, row.project ?? "", row.status ?? ""] + row.keywords
        return words.allSatisfy { word in
            fields.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// The rows matching `query`, grouped in `ChainDetailGroup` order with empty
    /// groups left out, each group most recently active first (ties in join order).
    public static func sections(_ rows: [ChainDetailRow], query: String) -> [ChainDetailSection] {
        let order = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let kept = rows.filter { matches($0, query: query) }
        return ChainDetailGroup.allCases.compactMap { group in
            let inGroup = kept.filter { $0.group == group }.sorted { a, b in
                if a.activityAt != b.activityAt { return a.activityAt > b.activityAt }
                return order[a.id, default: 0] < order[b.id, default: 0]
            }
            return inGroup.isEmpty ? nil : ChainDetailSection(group: group, rows: inGroup)
        }
    }
}
