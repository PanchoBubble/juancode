import Foundation

/// A projection of the loaded timeline; filtering never drops replies from a
/// retained thread or changes the IDs used by reply and resolution actions.
public enum PrConversationFilter: String, CaseIterable, Sendable {
    case all, reviews, comments, unresolved

    public var label: String {
        switch self {
        case .all: "All"
        case .reviews: "Reviews"
        case .comments: "Comments"
        case .unresolved: "Unresolved"
        }
    }

    public func apply(to items: [PrTimelineItem]) -> [PrTimelineItem] {
        items.compactMap { item in
            switch (self, item) {
            case (.all, _), (.reviews, .review), (.comments, .comment):
                return item
            case (.unresolved, .review(let review, let groups, let id, let createdAt)):
                let open = groups.filter { !$0.isResolved }
                guard !open.isEmpty else { return nil }
                return .review(review, threadGroups: open, id: id, createdAt: createdAt)
            default:
                return nil
            }
        }
    }

    /// Unresolved counts threads; the other filters count timeline entries.
    public func count(in items: [PrTimelineItem]) -> Int {
        let filtered = apply(to: items)
        guard self == .unresolved else { return filtered.count }
        return filtered.reduce(0) { total, item in
            if case .review(_, let groups, _, _) = item { return total + groups.count }
            return total
        }
    }
}
