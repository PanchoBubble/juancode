import Foundation

/// Connected open PRs whose base points at another PR's head in the same repository.
/// Uses the full fetched list so UI filters cannot change the count or color.
public struct PrStack: Equatable, Sendable {
    public let id: String
    public let numbers: [Int]

    public static func containing(_ pr: PullRequest, in prs: [PullRequest]) -> PrStack? {
        func repository(_ url: String) -> String? {
            guard let url = URL(string: url), let host = url.host else { return nil }
            let parts = url.pathComponents
            guard parts.count >= 5, parts[3] == "pull" else { return nil }
            return "\(host)/\(parts[1])/\(parts[2])".lowercased()
        }
        guard let repo = repository(pr.url) else { return nil }
        let candidates = prs.filter { repository($0.url) == repo }
        var members: Set<Int> = [pr.number]
        var pending = [pr]
        while let current = pending.popLast() {
            for other in candidates where !members.contains(other.number) {
                // A fork's head does not live in the base repository, even when
                // its branch name happens to match another PR's base.
                let parent = other.isCrossRepository == false && !other.branch.isEmpty
                    && current.baseBranch == other.branch
                let child = current.isCrossRepository == false && !current.branch.isEmpty
                    && other.baseBranch == current.branch
                if parent || child {
                    members.insert(other.number)
                    pending.append(other)
                }
            }
        }
        guard members.count > 1 else { return nil }
        let numbers = members.sorted()
        return PrStack(id: "\(repo)#\(numbers[0])", numbers: numbers)
    }
}
