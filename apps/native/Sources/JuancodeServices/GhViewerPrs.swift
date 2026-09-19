import Foundation
import JuancodeCore

/// The viewer's own GitHub queue: every open PR you authored, plus every open PR
/// that asked for your review — across *all* repos, not just the folders juancode
/// happens to have open.
///
/// The rest of the GitHub surface is folder-scoped: `getOpenPrs(cwd)` runs
/// `gh pr list` inside a checkout, so a repo you have no clone of is invisible and
/// each folder costs its own round trips. The Tools-menu count has to answer "what
/// is on my plate right now" without either of those limits, so this asks GitHub's
/// search instead, through one `gh api graphql` call carrying both queries as
/// aliases. That single call returns the same shape the folder list does — checks
/// rollup, review decision, review requests, diff size, unresolved threads — so the
/// rows render with the existing PR row and need no follow-up fetch.
///
/// Same prime directive as everything else here: the real `gh` CLI with the user's
/// own auth and environment, never a shadow env.
///
/// Disposition (juancode-a2s7): NOT desktop-local, despite having only in-process
/// `JuancodeApp` callers today. Measured at f06cb04: `grep -rn viewer_prs
/// apps/juancoded/crates` still finds nothing, so the daemon has no counterpart —
/// but this file is `Gh.swift` part two, not an independent renderer. It reads five
/// symbols that are internal to this target (`ghErrorReason`, `RollupCheck`,
/// `rollupChecks`, `countPassedChecks`, plus `resolveBin`), so moving it to
/// `JuancodeDesktop` would mean widening the public surface of the very target this
/// epic is shrinking, for a `gh` shell-out whose parent has to stay here anyway.
/// It shares `Gh.swift`'s fate: the daemon grows a `viewer_prs` read, `JuancodeApp`
/// calls it through `CoreClient`, and both files go in that change (juancode-h0l6).

private let MAX_VIEWER_PRS = 50

/// Resolve `gh` the way the rest of the GitHub services do — the user's own binary,
/// honouring `JUANCODE_GH_BIN`, resolved per call so a test can point it at a stub.
/// File-private like its twin in `Gh.swift`.
private func ghBin() -> String {
    resolveBin("gh", override: ProcessInfo.processInfo.environment["JUANCODE_GH_BIN"])
}

/// Why a PR is in your queue. A PR you authored that also lists you as a reviewer
/// is yours — authorship wins, so each PR appears once.
public enum ViewerPrReason: String, Sendable, Codable, Equatable {
    case mine
    case reviewRequested
}

/// One row of the viewer queue: the PR, the repo it lives in (`owner/name` — these
/// rows span repos, so the folder name a folder-scoped row shows doesn't exist
/// here), and why it's on your plate.
public struct ViewerPr: Sendable, Equatable, Identifiable {
    public var pr: PullRequest
    public var repo: String
    public var reason: ViewerPrReason

    public init(pr: PullRequest, repo: String, reason: ViewerPrReason) {
        self.pr = pr; self.repo = repo; self.reason = reason
    }

    /// Stable across refetches and unique within a queue (a repo can't have two
    /// open PRs with the same number).
    public var id: String { "\(repo)#\(pr.number)" }
}

/// The viewer queue as one fetch: `available: false` when gh is missing,
/// unauthenticated, or the search failed, so the UI can stay quiet rather than
/// claim an empty queue.
public struct ViewerPrResult: Sendable, Equatable {
    public var available: Bool
    public var rows: [ViewerPr]
    public var viewer: String
    public var error: String?

    public init(available: Bool, rows: [ViewerPr] = [], viewer: String = "", error: String? = nil) {
        self.available = available; self.rows = rows; self.viewer = viewer; self.error = error
    }

    /// PRs you authored.
    public var mine: [ViewerPr] { rows.filter { $0.reason == .mine } }
    /// PRs waiting on your review.
    public var reviewing: [ViewerPr] { rows.filter { $0.reason == .reviewRequested } }
}

/// The two searches, as one GraphQL document with aliases — one round trip for both
/// halves of the queue. `archived:false` keeps dead repos out; `sort:updated` puts
/// the ones that moved most recently in the window when there are more than the cap.
let viewerPrQuery = """
query($mine: String!, $reviews: String!, $first: Int!) {
  mine: search(query: $mine, type: ISSUE, first: $first) { nodes { ...prBits } }
  reviews: search(query: $reviews, type: ISSUE, first: $first) { nodes { ...prBits } }
}
fragment prBits on PullRequest {
  number title url isDraft createdAt headRefName additions deletions changedFiles
  repository { nameWithOwner }
  author { login }
  assignees(first: 10) { nodes { login } }
  reviewDecision
  reviewRequests(first: 10) {
    nodes { requestedReviewer { ... on User { login } ... on Team { slug } } }
  }
  reviewThreads(first: 100) { nodes { isResolved } }
  rollup: commits(last: 1) {
    nodes {
      commit {
        statusCheckRollup {
          contexts(first: 100) {
            nodes {
              ... on CheckRun { status conclusion }
              ... on StatusContext { state }
            }
          }
        }
      }
    }
  }
}
"""

/// The search qualifiers for each half of the queue. Pure; exposed for testing.
public func viewerPrSearch(mine: Bool) -> String {
    let base = "is:open is:pr archived:false sort:updated"
    return mine ? "\(base) author:@me" : "\(base) review-requested:@me"
}

/// Fetch the viewer's queue. `cwd` only needs to be a directory that exists — the
/// search is not repo-scoped — so it defaults to home and works even when no
/// project folder is open.
public func getViewerPrs(cwd: String = FileManager.default.homeDirectoryForCurrentUser.path)
    async -> ViewerPrResult {
    let stdout: String
    do {
        let r = try await ProcessRunner.capture(
            ghBin(),
            ["api", "graphql",
             "-f", "query=\(viewerPrQuery)",
             "-f", "mine=\(viewerPrSearch(mine: true))",
             "-f", "reviews=\(viewerPrSearch(mine: false))",
             "-F", "first=\(MAX_VIEWER_PRS)"],
            cwd: cwd, maxBytes: 16 * 1024 * 1024)
        guard r.ok else {
            return ViewerPrResult(available: false, error: ghErrorReason(ProcessError(
                code: r.exitCode, stdout: r.stdout, stderr: r.stderr,
                launchFailed: false, timedOut: false)))
        }
        stdout = r.stdout
    } catch {
        return ViewerPrResult(available: false, error: ghErrorReason(error))
    }
    guard let rows = parseViewerPrs(stdout) else {
        return ViewerPrResult(available: false, error: "Could not parse gh output")
    }
    let viewer = await getViewerLogin(cwd)
    return ViewerPrResult(available: true, rows: rows, viewer: viewer)
}

// MARK: - parsing

/// gh's GraphQL envelope for the two aliased searches.
private struct ViewerSearchEnvelope: Decodable {
    struct Payload: Decodable {
        var mine: Bucket?
        var reviews: Bucket?
    }
    struct Bucket: Decodable { var nodes: [RawViewerPr]? }
    var data: Payload?
}

/// One search hit. Everything past `number` is optional so a field GitHub declines
/// to serve (or a node that isn't a PullRequest at all, which the fragment renders
/// as `{}`) costs that row, not the whole queue.
struct RawViewerPr: Decodable {
    struct Repo: Decodable { var nameWithOwner: String? }
    struct Login: Decodable { var login: String? }
    struct Logins: Decodable { var nodes: [Login]? }
    struct ReviewRequest: Decodable {
        struct Reviewer: Decodable { var login: String?; var slug: String? }
        var requestedReviewer: Reviewer?
        var handle: String? { requestedReviewer?.login ?? requestedReviewer?.slug }
    }
    struct ReviewRequests: Decodable { var nodes: [ReviewRequest]? }
    struct Thread: Decodable { var isResolved: Bool? }
    struct Threads: Decodable { var nodes: [Thread]? }
    struct Rollup: Decodable {
        struct CommitNode: Decodable {
            struct Commit: Decodable {
                struct Status: Decodable {
                    struct Contexts: Decodable { var nodes: [RollupCheck]? }
                    var contexts: Contexts?
                }
                var statusCheckRollup: Status?
            }
            var commit: Commit?
        }
        var nodes: [CommitNode]?
    }

    var number: Int?
    var title: String?
    var url: String?
    var isDraft: Bool?
    var createdAt: String?
    var headRefName: String?
    var additions: Int?
    var deletions: Int?
    var changedFiles: Int?
    var repository: Repo?
    var author: Login?
    var assignees: Logins?
    var reviewDecision: String?
    var reviewRequests: ReviewRequests?
    var reviewThreads: Threads?
    var rollup: Rollup?

    /// The head commit's check contexts, flattened — the same `[RollupCheck]` shape
    /// `gh pr list --json statusCheckRollup` produces, so the existing rollup
    /// helpers classify both identically.
    var checkContexts: [RollupCheck] {
        rollup?.nodes?.first?.commit?.statusCheckRollup?.contexts?.nodes ?? []
    }
}

/// Map one search hit onto the wire `PullRequest`, or nil when it carries no PR
/// identity (a non-PullRequest node the fragment left empty).
func viewerPullRequest(_ raw: RawViewerPr) -> PullRequest? {
    guard let number = raw.number, let url = raw.url else { return nil }
    let contexts = raw.checkContexts
    let unresolved = (raw.reviewThreads?.nodes ?? []).filter { $0.isResolved == false }.count
    return PullRequest(
        number: number,
        title: raw.title ?? "",
        url: url,
        branch: raw.headRefName ?? "",
        draft: raw.isDraft ?? false,
        checks: rollupChecks(contexts),
        author: raw.author?.login ?? "",
        assignees: (raw.assignees?.nodes ?? []).compactMap(\.login),
        checkCount: contexts.count,
        passedCount: countPassedChecks(contexts),
        unresolvedComments: unresolved,
        createdAt: raw.createdAt,
        reviewDecision: raw.reviewDecision,
        reviewRequests: (raw.reviewRequests?.nodes ?? []).compactMap(\.handle),
        additions: raw.additions, deletions: raw.deletions, changedFiles: raw.changedFiles)
}

/// Parse the two aliased buckets into one deduped queue: authored PRs first (in the
/// order GitHub returned them), then review requests that aren't already listed.
/// Nil when the payload isn't the envelope we asked for; an empty queue is `[]`,
/// which is a real answer and not a failure. Pure; exposed for testing.
func parseViewerPrs(_ stdout: String) -> [ViewerPr]? {
    guard let envelope = try? JSONDecoder().decode(
        ViewerSearchEnvelope.self, from: Data(stdout.utf8)),
        let payload = envelope.data else { return nil }
    var rows: [ViewerPr] = []
    var seen = Set<String>()
    func append(_ nodes: [RawViewerPr]?, reason: ViewerPrReason) {
        for raw in nodes ?? [] {
            guard let pr = viewerPullRequest(raw) else { continue }
            let repo = raw.repository?.nameWithOwner
                ?? repoSlug(fromPrUrl: pr.url).map { "\($0.owner)/\($0.name)" }
                ?? ""
            let row = ViewerPr(pr: pr, repo: repo, reason: reason)
            guard seen.insert(row.id).inserted else { continue }
            rows.append(row)
        }
    }
    append(payload.mine?.nodes, reason: .mine)
    append(payload.reviews?.nodes, reason: .reviewRequested)
    return rows
}

/// Group a queue by repo for display: repos in first-appearance order (so the
/// freshest-updated repo leads), each keeping its incoming row order. Pure; exposed
/// for testing.
public func groupViewerPrsByRepo(_ rows: [ViewerPr]) -> [(repo: String, rows: [ViewerPr])] {
    var order: [String] = []
    var byRepo: [String: [ViewerPr]] = [:]
    for row in rows {
        if byRepo[row.repo] == nil { order.append(row.repo) }
        byRepo[row.repo, default: []].append(row)
    }
    return order.map { (repo: $0, rows: byRepo[$0] ?? []) }
}

/// Which slice of the queue a surface is showing — the four questions the toolbar
/// badge's chips ask: everything, the ones you wrote, the ones you owe a review,
/// and the ones that actually want something today.
public enum ViewerPrSlice: String, Sendable, CaseIterable, Identifiable {
    case all, mine, review, needsYou
    public var id: String { rawValue }
}

/// Why a queue row wants the viewer, or nil when it doesn't.
///
/// A review request is a reason in itself: `prAttentionReason` can only see the
/// request when the PR carries it, and the queue has already answered that question
/// by putting the row in the `reviewRequested` bucket. Pure; exposed for testing.
public func viewerPrAttention(_ row: ViewerPr, viewer: String) -> PrAttentionReason? {
    if row.reason == .reviewRequested { return .reviewRequested }
    return prAttentionReason(row.pr, viewer: viewer)
}

/// The rows in `slice`, the ones that want you first (by `PrAttentionReason.rank`)
/// and each group otherwise keeping the queue's own order, which is GitHub's
/// `sort:updated`. Pure; exposed for testing.
public func viewerPrRows(_ result: ViewerPrResult, slice: ViewerPrSlice) -> [ViewerPr] {
    let viewer = result.viewer
    let kept: [ViewerPr] = result.rows.filter { row in
        switch slice {
        case .all: return true
        case .mine: return row.reason == .mine
        case .review: return row.reason == .reviewRequested
        case .needsYou: return !viewer.isEmpty && viewerPrAttention(row, viewer: viewer) != nil
        }
    }
    guard !viewer.isEmpty else { return kept }
    return kept.enumerated().sorted { a, b in
        let ra = viewerPrAttention(a.element, viewer: viewer)?.rank ?? Int.max
        let rb = viewerPrAttention(b.element, viewer: viewer)?.rank ?? Int.max
        return ra == rb ? a.offset < b.offset : ra < rb
    }.map(\.element)
}

/// How many rows a slice holds — the chip counts, and for `needsYou` the badge's
/// tint: a queue that is merely long is not a queue that is on fire. Zero for every
/// slice until the queue has actually landed, so a failed search never claims a
/// number. Pure; exposed for testing.
public func viewerPrCount(_ result: ViewerPrResult, slice: ViewerPrSlice) -> Int {
    guard result.available else { return 0 }
    return viewerPrRows(result, slice: slice).count
}

/// How many rows in the queue actually want something from you — CI red, changes
/// requested or open threads on yours, plus every review you owe.
public func viewerPrsNeedingYou(_ result: ViewerPrResult) -> Int {
    viewerPrCount(result, slice: .needsYou)
}
