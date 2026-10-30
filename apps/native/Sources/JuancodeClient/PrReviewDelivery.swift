import Foundation

/// Agent delivery for a PR review. A URL address is never a working directory
/// from which an agent can be spawned; it needs an explicit recipient or tracker.
public enum PrReviewDelivery: Equatable, Sendable {
    case session(String)
    case trackLocal
    case chooseSession

    public static func resolve(cwd: String, chosenSessionId: String?,
                               trackedSessionId: String?) -> Self {
        if let id = chosenSessionId, !id.isEmpty { return .session(id) }
        if let id = trackedSessionId, !id.isEmpty { return .session(id) }
        return PrAddress.isRemote(cwd: cwd) ? .chooseSession : .trackLocal
    }
}
