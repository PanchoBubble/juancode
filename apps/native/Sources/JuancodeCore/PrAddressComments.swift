import Foundation

/// "Address comments": one agent session per PR that has unresolved review threads.
///
/// This is deliberately not Track. Tracking is a standing watch — one agent per PR that
/// reacts to *new* activity for as long as the PR is open. Addressing comments is a
/// one-shot: work through what is unresolved *now*, answer each thread, resolve it, ask
/// for a fresh review, and stop. Nothing here fetches or spawns; the app does that.
/// What lives here is the part that must stay predictable: which PRs are eligible, how
/// a batch is trimmed to the cap, the prompt, and the id that lets a second click find
/// the session the first one started.
public enum PrAddressComments {
    /// How many agents one batch starts. A live session costs ~300 MB and ~6% of a core,
    /// and the PRs left over are one more click once these are done.
    public static let batchCap = 4

    /// What the prompt says when a repo has no review-trigger command configured.
    public static let noReviewTrigger =
        "No re-review trigger is configured for this repo, so do not comment on the PR to ask for one."

    /// The default prompt. Everything in `{braces}` is filled per PR; the user can edit
    /// the text in the sheet and the edited copy is what is remembered.
    public static let defaultTemplate = """
    Address the unresolved review comments on pull request #{number} "{title}" in {repo}: {url}
    The PR's branch is `{branch}`.

    1. Check the PR out in this worktree: `gh pr checkout {number}`. If that fails because \
    the branch is already checked out elsewhere, use `gh pr checkout {number} --detach` and \
    push with `git push origin HEAD:{branch}`.
    2. List the unresolved review threads (GraphQL `reviewThreads` where `isResolved == false`). \
    Many come from review bots, for example "[F001] BUG … confidence 80"; treat those exactly \
    like a human's.
    3. Verify every thread against the code. Fix the ones that are right. Decline the ones that \
    are wrong or out of scope, and say why.
    4. Run the tests relevant to what you changed. Commit and push to `{branch}`. Never merge \
    the PR, never force-push, and do not touch any other PR.
    5. Reply on every thread with the commit sha that fixed it, or your reason for declining, \
    then resolve it (`resolveReviewThread`).
    6. {review_step}
    7. If CI is failing and this PR caused it, fix that too.
    {stack_note}
    If anything is ambiguous, or a thread needs a decision that is not yours, stop and ask me \
    instead of guessing. When you are done, summarise what you did per thread and ask whether I \
    have questions.
    """

    /// The placeholders the template understands, for the sheet's hint line.
    public static let placeholders = [
        "{number}", "{title}", "{url}", "{repo}", "{branch}", "{review_step}", "{stack_note}",
    ]

    /// `template` filled in for one PR. `reviewCommand` is the comment that makes the
    /// repo's reviewer run again (`/review` in luma-core); blank means the repo has none.
    /// `stackSiblings` are the other PR numbers of the stack this PR sits in.
    public static func prompt(template: String, pr: PullRequest, repo: String,
                              reviewCommand: String?, stackSiblings: [Int]) -> String {
        let command = reviewCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reviewStep = command.isEmpty
            ? noReviewTrigger
            : "Once every thread is answered, trigger a new review by commenting `\(command)` on the "
                + "PR: `gh pr comment \(pr.number) --body '\(command.replacingOccurrences(of: "'", with: "'\\''"))'`."
        let stackNote = stackSiblings.isEmpty ? "" : """

            This PR is part of a stack with \(stackSiblings.map { "#\($0)" }.joined(separator: ", ")). \
            Do not rebase, merge into, or push to the sibling PRs' branches, and do not retarget \
            any PR. Fix only this one.

            """
        let values: [String: String] = [
            "{number}": String(pr.number), "{title}": pr.title, "{url}": pr.url,
            "{repo}": repo, "{branch}": pr.branch,
            "{review_step}": reviewStep, "{stack_note}": stackNote,
        ]
        // One pass over the template, so a value that happens to contain `{number}` (a PR
        // title can) is not expanded a second time.
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let tail = rest[open...]
            if let close = tail.firstIndex(of: "}"),
               let value = values[String(tail[...close])] {
                out += value
                rest = tail[tail.index(after: close)...]
            } else {
                out += "{"
                rest = tail.dropFirst()
            }
        }
        return out + rest
    }

    /// Whether the agent should be sent at this PR: it has threads to answer, and it is
    /// the viewer's own, since the agent pushes to its branch. A fork PR is out too — its
    /// branch is not ours to push to.
    public static func isEligible(_ pr: PullRequest, viewer: String) -> Bool {
        guard pr.unresolvedComments > 0, pr.isCrossRepository != true else { return false }
        return !viewer.isEmpty && pr.author.caseInsensitiveCompare(viewer) == .orderedSame
    }

    /// The prefix every session this feature starts carries in its `dispatchId`. The
    /// daemon persists that id on the session, so "is there already an agent on this PR"
    /// is a lookup, not a registry that could drift from reality.
    public static func dispatchIdPrefix(repo: String, number: Int) -> String {
        "address-comments/\(repo.lowercased())#\(number)/"
    }

    public static func dispatchId(repo: String, number: Int, nonce: String) -> String {
        dispatchIdPrefix(repo: repo, number: number) + nonce
    }

    /// Why a PR was left out of a batch.
    public enum Skip: Equatable, Sendable {
        /// An agent from an earlier click is still alive on this PR.
        case alreadyAddressing
        /// A tracking agent already owns this PR's branch; a second writer would race it.
        case tracked
        /// Over the batch cap; one more click after these finish.
        case overCap

        public var label: String {
            switch self {
            case .alreadyAddressing: return "an agent is already on it"
            case .tracked: return "tracked — its agent owns the branch"
            case .overCap: return "over the batch limit"
            }
        }
    }

    public struct Plan: Equatable, Sendable {
        public var start: [Int]
        public var skipped: [(number: Int, why: Skip)]

        public static func == (a: Plan, b: Plan) -> Bool {
            a.start == b.start && a.skipped.map(\.number) == b.skipped.map(\.number)
                && a.skipped.map(\.why) == b.skipped.map(\.why)
        }
    }

    /// Split the chosen PRs into the ones to start now and the ones to leave, in the order
    /// given. Dedupe comes before the cap, so a PR that is already covered never uses up one
    /// of the batch's slots.
    public static func plan(numbers: [Int], cap: Int = batchCap,
                            isAddressing: (Int) -> Bool, isTracked: (Int) -> Bool) -> Plan {
        var plan = Plan(start: [], skipped: [])
        for number in numbers {
            if isAddressing(number) {
                plan.skipped.append((number, .alreadyAddressing))
            } else if isTracked(number) {
                plan.skipped.append((number, .tracked))
            } else if plan.start.count >= cap {
                plan.skipped.append((number, .overCap))
            } else {
                plan.start.append(number)
            }
        }
        return plan
    }
}
