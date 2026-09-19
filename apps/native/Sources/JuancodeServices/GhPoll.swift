import Foundation
import JuancodeCore

/// The `gh` reads the in-process Swift server still makes for itself.
///
/// This is what is left of `Gh.swift` after juancode-h0l6. Everything the SwiftUI app
/// used to call here now goes through `CoreClient` to `juancoded`, which serves the
/// whole PR surface — reads and writes — under the `github` capability. The four
/// probes below did not move with them because their callers did not: `getOpenPrs`,
/// `getRepoNwo`, `getPrActivity` and `getViewerLogin` are read by
/// `JuancodeServer/PrTrackingEngine.swift` and by the two `/api/{tracked-,}prs` routes
/// in `JuancodeServer/JuancodeServer.swift`, in process, on the Swift core only.
///
/// Disposition: juancode-nqpm, which deletes all three of those callers. Measured at
/// this tree — `grep -rn "getOpenPrs\|getRepoNwo\|getPrActivity\|getViewerLogin"
/// apps/native/Sources` finds nothing outside this file and those two, so this file
/// has no reader left the moment the Swift core goes and it goes in the same commit.
/// It is NOT a second implementation of anything the app reads: `juancoded_core::gh`
/// is the one the product runs on, and nothing here is reachable from the Rust path.
///
/// Same prime directive as the rest: every shell-out goes through `ProcessRunner`,
/// which inherits the environment verbatim, so `gh` uses the user's own auth and
/// config — never a shadow env. `gh` is resolved the way the user's login shell would
/// (`resolveBin`), honouring `JUANCODE_GH_BIN` so a test can point it at a stub.


private let MAX_BUFFER = 16 * 1024 * 1024


private let MAX_PRS = 100

/// The `gh pr list --json` fields we request. `assignees` powers the native
/// "Assigned to me" filter (each element is `{ login }`); `createdAt`,
/// `reviewDecision` and `reviewRequests` drive the row's age + review chips and the
/// "needs you" triage group; `additions`/`deletions`/`changedFiles` size the diff
/// for the row's PR badge, so a shipped PR reads like the working tree does.
private let FIELDS = """
number,title,url,headRefName,isDraft,statusCheckRollup,author,assignees,\
createdAt,reviewDecision,reviewRequests,additions,deletions,changedFiles
"""

/// Resolve the `gh` binary like the user's terminal would, honouring the
/// `JUANCODE_GH_BIN` override. Resolved per call (not cached at load) so a test
/// can point it at a stub script via the env var.
private func ghBin() -> String {
    resolveBin("gh", override: ProcessInfo.processInfo.environment["JUANCODE_GH_BIN"])
}


/// CheckRun uses status/conclusion; legacy StatusContext uses state — all optional.
struct RollupCheck: Decodable {
    var status: String?
    var conclusion: String?
    var state: String?
}

/// gh's raw `pr list --json` shape, before mapping onto our wire `PullRequest`.
struct RawPr: Decodable {
    var number: Int
    var title: String
    var url: String
    var headRefName: String
    var isDraft: Bool
    var statusCheckRollup: [RollupCheck]?
    var author: RawPrAuthor?
    // Defaulted so the synthesized memberwise init stays back-compatible with
    // existing call sites (e.g. tests) that predate the assignees field.
    var assignees: [RawPrAuthor]? = nil
    var createdAt: String? = nil
    var reviewDecision: String? = nil
    var reviewRequests: [RawReviewRequest]? = nil
    var additions: Int? = nil
    var deletions: Int? = nil
    var changedFiles: Int? = nil
}

struct RawPrAuthor: Decodable {
    var login: String?
    // Only populated by the GraphQL conversation query (`author { login avatarUrl }`);
    // `gh pr list --json author` doesn't carry it, so it stays nil on that path.
    var avatarUrl: String?
}

/// One entry of gh's `reviewRequests`: a User (`login`) or a Team (`slug`/`name`).
struct RawReviewRequest: Decodable {
    var login: String?
    var slug: String?
    var name: String?

    /// The handle to match a viewer login (or show) against.
    var handle: String? { login ?? slug ?? name }
}

/// Collapse a PR's individual checks into a single failing/pending/passing/none.
func rollupChecks(_ checks: [RollupCheck]?) -> PrChecks {
    guard let checks, !checks.isEmpty else { return .none }
    var pending = false
    for c in checks {
        let conclusion = (c.conclusion ?? "").uppercased()
        let state = (c.state ?? "").uppercased()
        let status = (c.status ?? "").uppercased()
        if ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED"].contains(conclusion) {
            return .failing
        }
        if ["FAILURE", "ERROR"].contains(state) { return .failing }
        // Not yet concluded: a CheckRun still running, or a pending commit status.
        if !status.isEmpty && status != "COMPLETED" { pending = true }
        if state == "PENDING" { pending = true }
    }
    return pending ? .pending : .passing
}

/// Count the checks that concluded successfully — anything not failing and not
/// still running (SUCCESS, plus skipped/neutral). Mirrors `rollupChecks`'
/// per-check classification so `passedCount/checkCount` stays consistent with the
/// rolled-up colour.
func countPassedChecks(_ checks: [RollupCheck]?) -> Int {
    guard let checks else { return 0 }
    var passed = 0
    for c in checks {
        let conclusion = (c.conclusion ?? "").uppercased()
        let state = (c.state ?? "").uppercased()
        let status = (c.status ?? "").uppercased()
        if ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED"].contains(conclusion) { continue }
        if ["FAILURE", "ERROR"].contains(state) { continue }
        // Not yet concluded — a CheckRun still running or a pending commit status.
        if !status.isEmpty && status != "COMPLETED" { continue }
        if state == "PENDING" { continue }
        passed += 1
    }
    return passed
}

/// Map gh's raw JSON into our wire shape. Exposed for testing. `unresolvedComments`
/// is left at 0 here — the list fetch can't see review-thread resolution, so it's

func parsePrs(_ raw: [RawPr]) -> [PullRequest] {
    raw.map { p in
        PullRequest(
            number: p.number,
            title: p.title,
            url: p.url,
            branch: p.headRefName,
            draft: p.isDraft,
            checks: rollupChecks(p.statusCheckRollup),
            author: p.author?.login ?? "",
            assignees: (p.assignees ?? []).compactMap { $0.login },
            checkCount: p.statusCheckRollup?.count ?? 0,
            passedCount: countPassedChecks(p.statusCheckRollup),
            createdAt: p.createdAt,
            reviewDecision: p.reviewDecision,
            reviewRequests: (p.reviewRequests ?? []).compactMap(\.handle),
            additions: p.additions, deletions: p.deletions, changedFiles: p.changedFiles)
    }
}

/// A PR's age as a single compact token ("4h", "2d", "3w", "1y") from gh's ISO8601
/// `createdAt`, or nil when the timestamp is missing or unparseable. Deliberately
/// coarse — the row needs "is this rotting?", not a duration. Pure; exposed for

/// The authenticated GitHub login, cached for the process lifetime. Best-effort:
/// returns "" if `gh` is missing or unauthenticated (the caller still lists PRs).
private let viewerLoginBox = ViewerLoginBox()

private final class ViewerLoginBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
}

public func getViewerLogin(_ cwd: String) async -> String {
    if let cached = viewerLoginBox.get() { return cached }
    do {
        // `capture` returns the result for any exit code and only throws on
        // launch-failure/timeout — mirror the TS try/catch by treating a non-zero
        // exit the same as a thrown error (fall through to "").
        let r = try await ProcessRunner.capture(
            ghBin(), ["api", "user", "--jq", ".login"], cwd: cwd, maxBytes: MAX_BUFFER)
        guard r.ok else {
            viewerLoginBox.set("")
            return ""
        }
        let login = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        viewerLoginBox.set(login)
        return login
    } catch {
        viewerLoginBox.set("")
        return ""
    }
}

/// The folder's repo identity as `owner/name`, via the real `gh` CLI. This is
/// the key a GitHub webhook carries (`repository.full_name`), so it's what lets
/// an inbound event find the tracked PRs it concerns — a cwd means nothing to a
/// webhook. Best-effort: nil when gh is missing, unauthenticated, or the cwd
/// isn't a repo with a GitHub remote.
public func getRepoNwo(_ cwd: String) async -> String? {
    do {
        let r = try await ProcessRunner.capture(
            ghBin(), ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
            cwd: cwd, maxBytes: MAX_BUFFER)
        guard r.ok else { return nil }
        let nwo = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return nwo.isEmpty ? nil : nwo
    } catch {
        return nil
    }
}

/// List a folder's open pull requests via the real `gh` CLI (the user's own auth,
/// never a shadow env — same philosophy as spawning the genuine agent CLIs).
///
/// Returns `available: false` rather than throwing when gh is missing,
/// unauthenticated, or the cwd isn't a repo with a remote, so the UI can hide the
/// badge gracefully.
public func getOpenPrs(_ cwd: String) async -> PrListResult {
    let stdout: String
    do {
        // `capture` only throws on launch-fail/timeout; a non-zero exit (not a
        // repo, no remote, not authed) returns a result we must inspect ourselves,
        // matching how `execFile` rejects on non-zero exit.
        let r = try await ProcessRunner.capture(
            ghBin(),
            ["pr", "list", "--state", "open", "--limit", String(MAX_PRS), "--json", FIELDS],
            cwd: cwd, maxBytes: MAX_BUFFER)
        guard r.ok else {
            return PrListResult(available: false, prs: [],
                                error: ghErrorReason(ProcessError(
                                    code: r.exitCode, stdout: r.stdout, stderr: r.stderr,
                                    launchFailed: false, timedOut: false)))
        }
        stdout = r.stdout
    } catch {
        return PrListResult(available: false, prs: [], error: ghErrorReason(error))
    }
    do {
        let raw = try JSONDecoder().decode([RawPr].self, from: Data(stdout.utf8))
        let viewer = await getViewerLogin(cwd)
        var prs = parsePrs(raw)
        // Best-effort: fold in the unresolved-review-thread count per PR (one
        // GraphQL call for the whole list). Failures leave counts at 0.
        let counts = await getUnresolvedThreadCounts(cwd, prs: prs)
        prs = mergeUnresolvedCounts(prs, counts: counts)
        return PrListResult(available: true, prs: prs, viewer: viewer)
    } catch {
        return PrListResult(available: false, prs: [], error: "Could not parse gh output")
    }
}

// MARK: - Unresolved review threads (the "active comments" count in the PR list)

/// Overlay unresolved-review-thread counts onto parsed PRs, keyed by PR number.
/// Pure; exposed for testing.
func mergeUnresolvedCounts(_ prs: [PullRequest], counts: [Int: Int]) -> [PullRequest] {
    prs.map { pr in
        guard let n = counts[pr.number] else { return pr }
        var pr = pr
        pr.unresolvedComments = n
        return pr
    }
}

/// GraphQL response shape for the unresolved-thread query.
private struct ThreadCountsResponse: Decodable {
    struct DataField: Decodable { let repository: Repository? }
    struct Repository: Decodable { let pullRequests: PrConnection? }
    struct PrConnection: Decodable { let nodes: [PrNode]? }
    struct PrNode: Decodable { let number: Int?; let reviewThreads: ThreadConnection? }
    struct ThreadConnection: Decodable { let nodes: [ThreadNode]? }
    struct ThreadNode: Decodable { let isResolved: Bool? }
    let data: DataField?
}

/// Parse the GraphQL response into number→unresolved-thread-count. Pure; exposed
/// for testing. A thread counts as unresolved when `isResolved` is false/absent.
func parseUnresolvedThreadCounts(_ json: String) -> [Int: Int] {
    guard let data = json.data(using: .utf8),
          let decoded = try? JSONDecoder().decode(ThreadCountsResponse.self, from: data),
          let nodes = decoded.data?.repository?.pullRequests?.nodes else { return [:] }
    var out: [Int: Int] = [:]
    for node in nodes {
        guard let number = node.number else { continue }
        let unresolved = (node.reviewThreads?.nodes ?? []).filter { $0.isResolved != true }.count
        out[number] = unresolved
    }
    return out
}

/// Count of unresolved review threads per open PR, via a single `gh api graphql`
/// call scoped to the repo (owner/name lifted from a PR url, so no extra lookup).
/// Best-effort: returns `[:]` when gh is missing/unauthenticated, there are no PRs,
/// or the response won't parse — the list still renders, just without the count.
func getUnresolvedThreadCounts(_ cwd: String, prs: [PullRequest]) async -> [Int: Int] {
    guard let slug = prs.lazy.compactMap({ repoSlug(fromPrUrl: $0.url) }).first else { return [:] }
    let query = """
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        pullRequests(states: OPEN, first: \(MAX_PRS)) {
          nodes {
            number
            reviewThreads(first: 100) { nodes { isResolved } }
          }
        }
      }
    }
    """
    do {
        let r = try await ProcessRunner.capture(
            ghBin(),
            ["api", "graphql", "-f", "query=\(query)",
             "-f", "owner=\(slug.owner)", "-f", "name=\(slug.name)"],
            cwd: cwd, maxBytes: MAX_BUFFER)
        guard r.ok else { return [:] }
        return parseUnresolvedThreadCounts(r.stdout)
    } catch {
        return [:]
    }
}

/// Open a pull request for the current branch via the real `gh` CLI. The caller
/// pushes the branch first, so this just creates the PR. If a PR already exists
/// for the branch, gh prints its url to stderr — we return that with


/// One issue-level PR comment, as returned by `gh pr view --json comments`. We
/// keep only the fields the poller needs to dedup and summarise new activity.
public struct PrComment: Sendable, Equatable {
    public let id: String
    public let author: String
    public let body: String
    public init(id: String, author: String, body: String) {
        self.id = id; self.author = author; self.body = body
    }
}

/// One PR review (`gh pr view --json reviews`). `state` is GitHub's review state
/// (APPROVED / CHANGES_REQUESTED / COMMENTED / DISMISSED / PENDING).
public struct PrReview: Sendable, Equatable {
    public let id: String
    public let author: String
    public let body: String
    public let state: String
    public init(id: String, author: String, body: String, state: String) {
        self.id = id; self.author = author; self.body = body; self.state = state
    }
}

/// A snapshot of a PR's reviewable activity: rolled-up CI status, issue comments,
/// and reviews. What the tracked-PR poller diffs each tick to detect new events.
public struct PrActivity: Sendable, Equatable {
    /// GitHub's PR state, upper-cased: OPEN / CLOSED / MERGED. Drives auto-untrack.
    public let state: String
    public let checks: PrChecks
    public let comments: [PrComment]
    public let reviews: [PrReview]
    public init(state: String, checks: PrChecks, comments: [PrComment], reviews: [PrReview]) {
        self.state = state; self.checks = checks; self.comments = comments; self.reviews = reviews
    }
}

/// Raw `gh pr view --json` comment/review element shapes.
private struct RawPrComment: Decodable {
    var id: String?
    var author: RawPrAuthor?
    var body: String?
}
private struct RawPrReview: Decodable {
    var id: String?
    var author: RawPrAuthor?
    var body: String?
    var state: String?
}

/// Map gh's raw activity JSON onto our wire shape. Exposed for testing. Drops any
/// comment/review missing an `id` (can't be deduped reliably without one).
func parsePrActivity(_ raw: RawPrActivityForTest) -> PrActivity {
    PrActivity(
        state: (raw.state ?? "").uppercased(),
        checks: rollupChecks(raw.statusCheckRollup),
        comments: (raw.comments ?? []).compactMap { c in
            guard let id = c.id else { return nil }
            return PrComment(id: id, author: c.author?.login ?? "", body: c.body ?? "")
        },
        reviews: (raw.reviews ?? []).compactMap { r in
            guard let id = r.id else { return nil }
            return PrReview(id: id, author: r.author?.login ?? "",
                            body: r.body ?? "", state: (r.state ?? "").uppercased())
        })
}

/// Test seam mirroring the private raw decode shape (so `parsePrActivity` can be
/// unit-tested without spawning `gh`). Decodes the same JSON `gh pr view` emits.
public struct RawPrActivityForTest: Decodable {
    fileprivate var state: String?
    fileprivate var statusCheckRollup: [RollupCheck]?
    fileprivate var comments: [RawPrComment]?
    fileprivate var reviews: [RawPrReview]?
}

/// Read a single PR's reviewable activity via the real `gh` CLI. Returns nil when
/// gh is missing/unauthenticated, the cwd isn't a repo, or the output won't parse
/// — the poller treats nil as "couldn't poll this tick" and tries again later.
public func getPrActivity(_ cwd: String, number: Int) async -> PrActivity? {
    let fields = "state,statusCheckRollup,comments,reviews"
    do {
        let r = try await ProcessRunner.capture(
            ghBin(), ["pr", "view", String(number), "--json", fields],
            cwd: cwd, maxBytes: MAX_BUFFER)
        guard r.ok else { return nil }
        let raw = try JSONDecoder().decode(RawPrActivityForTest.self, from: Data(r.stdout.utf8))
        return parsePrActivity(raw)
    } catch {
        return nil
    }
}

/// Turn a process failure into a short, user-facing reason: ENOENT → not installed,
/// then auth/repo heuristics on stderr, else the first line of stderr (or a generic
/// fallback). The same four sentences `juancoded_core::gh::gh_error_reason` gives, so
/// a list that failed reads the same on either core.
func ghErrorReason(_ err: Error) -> String {
    // launchFailed ≈ Node's `code === "ENOENT"` (binary not found).
    var stderr = ""
    if let e = err as? ProcessError {
        if e.launchFailed { return "gh CLI not installed" }
        stderr = e.stderr
    }
    let lower = stderr.lowercased()
    if lower.contains("no git remotes") || lower.contains("not a git repository") {
        return "Not a GitHub repo"
    }
    if lower.contains("auth") || lower.contains("logged") {
        return "gh not authenticated"
    }
    // First line of stderr (TS: `(e.stderr ?? "gh failed").trim().split("\n")[0] || "gh failed"`).
    let firstLine = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: "\n").first ?? ""
    return firstLine.isEmpty ? "gh failed" : firstLine
}
