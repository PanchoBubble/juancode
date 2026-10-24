import Foundation

/// Daemon-owned lifecycle evidence, shared with the sidecar. Unknown blocking
/// reasons stay `waiting`; acknowledging never sends input to a provider.
public struct AttentionItem: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let kind: String
    public let createdAt: Int64
    public let updatedAt: Int64
    public let acknowledged: Bool
    public let resolved: Bool
    public let source: String?

    public var isActionable: Bool {
        !resolved && (kind == "waiting" || !acknowledged)
    }
    public static func actionable(_ items: [AttentionItem]) -> [AttentionItem] {
        items.filter { $0.isActionable }.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
    }
    public var title: String {
        if source == "program" {
            switch kind {
            case "waiting": return "Program waiting for input"
            case "error": return "Program reported an error"
            case "completion": return "Program completed"
            default: return "Program needs attention"
            }
        }
        switch kind {
        case "waiting": return "Waiting for input"
        case "error": return "Session exited with an error"
        case "completion": return "Turn completed"
        default: return "Session needs attention"
        }
    }
}
