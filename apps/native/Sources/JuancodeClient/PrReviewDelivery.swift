import Foundation

/// Agent delivery for a PR review. Without a chosen agent or an existing tracker,
/// the user must choose a recipient; sending review comments never starts tracking.
public enum PrReviewDelivery: Equatable, Sendable {
    case session(String)
    case chooseSession

    public static func resolve(chosenSessionId: String?, trackedSessionId: String?) -> Self {
        if let id = chosenSessionId, !id.isEmpty { return .session(id) }
        if let id = trackedSessionId, !id.isEmpty { return .session(id) }
        return .chooseSession
    }
}
