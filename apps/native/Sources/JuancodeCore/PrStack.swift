import Foundation

/// Canonical GitHub stack membership, with branch inference when unavailable.
/// Uses the full fetched list so UI filters cannot change the count or color.
public struct PrStack: Equatable, Sendable {
    public let id: String
    /// Base first, then dependents; independent siblings use PR number as a tie-breaker.
    public let entries: [PrStackEntry]
    public let size: Int
    public let stackNumber: Int?
    public var numbers: [Int] { entries.map(\.number) }

    public func position(of number: Int) -> Int? {
        entries.first { $0.number == number }?.position
    }

    public static func containing(_ pr: PullRequest, in prs: [PullRequest]) -> PrStack? {
        func repository(_ url: String) -> String? {
            guard let url = URL(string: url), let host = url.host else { return nil }
            let parts = url.pathComponents
            guard parts.count >= 5, parts[3] == "pull" else { return nil }
            return "\(host)/\(parts[1])/\(parts[2])".lowercased()
        }
        guard let repo = repository(pr.url) else { return nil }
        let sameRepo = prs.filter { repository($0.url) == repo }
        // Prefer the row's own metadata. A duplicate from another view can provide
        // it for an older row, but must not override an explicit "not stacked".
        let authoritative = pr.stackKnown == true || pr.stack != nil ? pr
            : sameRepo.first { $0.number == pr.number && ($0.stackKnown == true || $0.stack != nil) } ?? pr
        if let stack = authoritative.stack {
            let entries = stack.entries.sorted { $0.position < $1.position }
            guard !stack.id.isEmpty, stack.size > 1,
                  entries.contains(where: { $0.number == pr.number }),
                  entries.allSatisfy({ $0.position > 0 && $0.position <= stack.size
                      && repository($0.url) == repo }),
                  Set(entries.map(\.number)).count == entries.count,
                  Set(entries.map(\.position)).count == entries.count else { return nil }
            return PrStack(id: stack.id, entries: entries, size: stack.size, stackNumber: stack.number)
        }
        if authoritative.stackKnown == true { return nil }
        // Never pull a known unstacked PR or another explicit stack into an inferred group.
        let candidates = sameRepo.filter { $0.stackKnown != true && $0.stack == nil }
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
        var remaining = Dictionary(
            candidates.filter { members.contains($0.number) }.map { ($0.number, $0) },
            uniquingKeysWith: { first, _ in first })
        remaining[pr.number] = pr
        var ordered: [PullRequest] = []
        while !remaining.isEmpty {
            let sorted = remaining.values.sorted { $0.number < $1.number }
            // A PR is ready only after all of its parents. Cyclic/malformed data
            // falls back deterministically rather than hanging the UI.
            let next = sorted.first { child in
                !sorted.contains { parent in
                    parent.number != child.number && parent.isCrossRepository == false
                        && !parent.branch.isEmpty && child.baseBranch == parent.branch
                }
            } ?? sorted[0]
            ordered.append(next)
            remaining.removeValue(forKey: next.number)
        }
        let entries = ordered.enumerated().map { index, pr in
            PrStackEntry(position: index + 1, number: pr.number, title: pr.title,
                         url: pr.url, branch: pr.branch, state: "OPEN")
        }
        return PrStack(id: "\(repo)#\(members.min()!)", entries: entries,
                       size: entries.count, stackNumber: nil)
    }
}
