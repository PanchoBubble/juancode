import Foundation
import JuancodeCore

/// GitHub PR services for a session's folder — list open PRs and open a new PR via
/// the real `gh` CLI. Ported faithfully from `apps/server/src/gh.ts`: every
/// shell-out goes through `ProcessRunner` (which inherits the environment verbatim,
/// the prime directive) so `gh` uses the user's own auth and config — never a
/// shadow env, same philosophy as spawning the genuine agent CLIs.
///
/// Binary resolution: the TS spawned a bare `"gh"`, relying on PATH. Here we
/// resolve `gh` to the SAME absolute path the user's login shell would (via
/// JuancodeCore's `resolveBin`), honouring a `JUANCODE_GH_BIN` override — the same
/// pattern the other ported services use (`JUANCODE_BD_BIN`, `JUANCODE_CLAUDE_BIN`).
/// This both fixes GUI/stripped-PATH launches and lets tests inject a fake binary.

private let MAX_BUFFER = 16 * 1024 * 1024

private let MAX_PRS = 50

/// The `gh pr list --json` fields we request. `assignees` powers the native
/// "Assigned to me" filter (each element is `{ login }`).
private let FIELDS = "number,title,url,headRefName,isDraft,statusCheckRollup,author,assignees"

/// Resolve the `gh` binary like the user's terminal would, honouring the
/// `JUANCODE_GH_BIN` override. Resolved per call (not cached at load) so a test
/// can point it at a stub script via the env var.
private func ghBin() -> String {
    resolveBin("gh", override: ProcessInfo.processInfo.environment["JUANCODE_GH_BIN"])
}

/// One entry of gh's `statusCheckRollup` array (CheckRun or StatusContext).
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
}

struct RawPrAuthor: Decodable {
    var login: String?
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

/// Map gh's raw JSON into our wire shape. Exposed for testing.
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
            assignees: (p.assignees ?? []).compactMap { $0.login })
    }
}

/// The authenticated GitHub login, cached for the process lifetime. Best-effort:
/// returns "" if `gh` is missing or unauthenticated (the caller still lists PRs).
private let viewerLoginBox = ViewerLoginBox()

private final class ViewerLoginBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
}

func getViewerLogin(_ cwd: String) async -> String {
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
        return PrListResult(available: true, prs: parsePrs(raw), viewer: viewer)
    } catch {
        return PrListResult(available: false, prs: [], error: "Could not parse gh output")
    }
}

/// Open a pull request for the current branch via the real `gh` CLI. The caller
/// pushes the branch first, so this just creates the PR. If a PR already exists
/// for the branch, gh prints its url to stderr — we return that with
/// `created: false` rather than erroring.
public func createPr(
    _ cwd: String,
    title: String,
    body: String,
    draft: Bool
) async throws -> PrCreateResult {
    var args = ["pr", "create", "--title", title, "--body", body]
    if draft { args.append("--draft") }
    let r: ProcessResult
    do {
        r = try await ProcessRunner.capture(ghBin(), args, cwd: cwd, maxBytes: MAX_BUFFER)
    } catch {
        // Launch-fail/timeout — surface as a thrown reason, like the TS `throw`.
        throw GhError(ghErrorReason(error))
    }
    if r.ok {
        // Prefer the first url printed to stdout; fall back to trimmed stdout.
        let url = firstUrl(in: r.stdout) ?? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return PrCreateResult(url: url, created: true)
    }
    // Non-zero exit: if a PR already exists, gh prints its url to stderr — return
    // that with `created: false` instead of erroring.
    let stderr = r.stderr
    if let existing = existingPrUrl(in: stderr) {
        return PrCreateResult(url: existing, created: false)
    }
    throw GhError(ghErrorReason(ProcessError(
        code: r.exitCode, stdout: r.stdout, stderr: r.stderr,
        launchFailed: false, timedOut: false)))
}

// MARK: - PR activity (for the tracked-PR poller, juancode-it5 / juancode-49w)

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
    public let checks: PrChecks
    public let comments: [PrComment]
    public let reviews: [PrReview]
    public init(checks: PrChecks, comments: [PrComment], reviews: [PrReview]) {
        self.checks = checks; self.comments = comments; self.reviews = reviews
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
    fileprivate var statusCheckRollup: [RollupCheck]?
    fileprivate var comments: [RawPrComment]?
    fileprivate var reviews: [RawPrReview]?
}

/// Read a single PR's reviewable activity via the real `gh` CLI. Returns nil when
/// gh is missing/unauthenticated, the cwd isn't a repo, or the output won't parse
/// — the poller treats nil as "couldn't poll this tick" and tries again later.
public func getPrActivity(_ cwd: String, number: Int) async -> PrActivity? {
    let fields = "statusCheckRollup,comments,reviews"
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

// MARK: - PR diff (load an existing PR into the ChangesPanel, juancode-49w)

/// Per-PR-diff cap, mirroring `Git.swift`'s `MAX_FILES` for the working tree.
private let MAX_PR_FILES = 300

/// Load an existing PR's diff via `gh pr diff`, parsed into the same per-file wire
/// shape `getDiff` produces so it drops straight into the ChangesPanel (juancode-49w).
/// Throws `GhError` (gh missing / not authed / no such PR) rather than returning a
/// `git: false` shape, since here the failure is about gh/the PR, not the cwd.
public func getPrDiff(_ cwd: String, number: Int) async throws -> DiffResult {
    let r: ProcessResult
    do {
        r = try await ProcessRunner.capture(
            ghBin(), ["pr", "diff", String(number), "--patch"], cwd: cwd, maxBytes: MAX_BUFFER)
    } catch {
        throw GhError(ghErrorReason(error))
    }
    guard r.ok else {
        throw GhError(ghErrorReason(ProcessError(
            code: r.exitCode, stdout: r.stdout, stderr: r.stderr,
            launchFailed: false, timedOut: false)))
    }
    var files = parseMultiFileDiff(r.stdout)
    let truncatedFiles = files.count > MAX_PR_FILES
    if truncatedFiles { files = Array(files.prefix(MAX_PR_FILES)) }
    files.sort { $0.path.localizedCompare($1.path) == .orderedAscending }
    return DiffResult(git: true, root: nil, files: files, truncatedFiles: truncatedFiles)
}

// MARK: - CI/check logs (juancode-49w)

/// One CI check on a PR, from `gh pr checks --json`. `bucket` is gh's coarse
/// outcome (pass/fail/pending/skipping/cancel); `link` is the check's details URL,
/// from which a GitHub Actions run id can be extracted.
public struct PrCheckRun: Sendable, Equatable {
    public let name: String
    public let state: String
    public let bucket: String
    public let link: String
    public init(name: String, state: String, bucket: String, link: String) {
        self.name = name; self.state = state; self.bucket = bucket; self.link = link
    }
    /// True when this check counts as failed (gh's `fail` bucket, or a raw
    /// FAILURE/ERROR state for older status contexts).
    public var failed: Bool { bucket == "fail" || state == "FAILURE" || state == "ERROR" }
}

private struct RawCheckRun: Decodable {
    var name: String?
    var state: String?
    var bucket: String?
    var link: String?
}

/// Map `gh pr checks --json` output onto `[PrCheckRun]`. Exposed for testing.
func parseCheckRuns(_ json: String) -> [PrCheckRun] {
    guard let data = json.data(using: .utf8),
          let raw = try? JSONDecoder().decode([RawCheckRun].self, from: data) else { return [] }
    return raw.map {
        PrCheckRun(name: $0.name ?? "", state: ($0.state ?? "").uppercased(),
                   bucket: ($0.bucket ?? "").lowercased(), link: $0.link ?? "")
    }
}

/// The GitHub Actions run id embedded in a check's details URL
/// (`…/actions/runs/<id>/job/<jobId>`), or nil for a non-Actions check. Pure;
/// exposed for testing.
func runIdFromCheckLink(_ link: String) -> String? {
    firstMatch(in: link, pattern: "/actions/runs/([0-9]+)", group: 1)
}

/// List a PR's CI checks via `gh pr checks`. Returns `[]` when gh is missing /
/// unauthenticated / there are no checks. Note: `gh pr checks` exits non-zero when
/// checks are failing or pending, but still prints the JSON, so we parse stdout
/// regardless of the exit code.
public func getPrCheckRuns(_ cwd: String, number: Int) async -> [PrCheckRun] {
    do {
        let r = try await ProcessRunner.capture(
            ghBin(), ["pr", "checks", String(number), "--json", "name,state,bucket,link"],
            cwd: cwd, maxBytes: MAX_BUFFER)
        return parseCheckRuns(r.stdout)
    } catch {
        return []
    }
}

/// Cap on captured CI-log text, so a huge log can't blow up the UI / an agent
/// prompt. We keep the tail (where failures surface), not the head.
private let MAX_LOG_CHARS = 20_000

/// Read the failing-step logs for a PR's red CI checks: resolve each failing
/// GitHub Actions check to its run id and pull `gh run view <id> --log-failed`,
/// concatenated (capped). Returns "" when nothing is failing or logs can't be
/// read — best-effort, never throws. Lets the UI / a tracking agent surface *why*
/// CI is red without leaving juancode.
public func getFailedCheckLogs(_ cwd: String, number: Int, maxRuns: Int = 5) async -> String {
    let failing = await getPrCheckRuns(cwd, number: number).filter(\.failed)
    var seen = Set<String>()
    var runIds: [String] = []
    for check in failing {
        if let id = runIdFromCheckLink(check.link), seen.insert(id).inserted { runIds.append(id) }
    }
    guard !runIds.isEmpty else { return "" }

    var sections: [String] = []
    for id in runIds.prefix(maxRuns) {
        guard let log = await failedRunLog(cwd, runId: id), !log.isEmpty else { continue }
        sections.append("===== run \(id) (failed steps) =====\n\(log)")
    }
    return sections.joined(separator: "\n\n")
}

/// `gh run view <id> --log-failed`, capped to the trailing `MAX_LOG_CHARS`.
private func failedRunLog(_ cwd: String, runId: String) async -> String? {
    do {
        let r = try await ProcessRunner.capture(
            ghBin(), ["run", "view", runId, "--log-failed"], cwd: cwd, maxBytes: MAX_BUFFER)
        guard r.ok else { return nil }
        let log = r.stdout
        guard log.count > MAX_LOG_CHARS else { return log }
        return "…(truncated)\n" + String(log.suffix(MAX_LOG_CHARS))
    } catch {
        return nil
    }
}

// MARK: - replying to a PR (juancode-49w)

/// Post a top-level comment on a PR (`gh pr comment`). Throws `GhError` on failure.
public func commentOnPr(_ cwd: String, number: Int, body: String) async throws {
    try await ghWrite(cwd, ["pr", "comment", String(number), "--body", body])
}

/// Reply to an inline PR review-thread comment (`POST …/pulls/<n>/comments/<id>/replies`
/// via `gh api`). `commentId` is the id of the review comment being replied to. gh
/// fills `{owner}`/`{repo}` from the current repo. Throws `GhError` on failure.
public func replyToReviewComment(_ cwd: String, number: Int, commentId: Int, body: String) async throws {
    let path = "repos/{owner}/{repo}/pulls/\(number)/comments/\(commentId)/replies"
    try await ghWrite(cwd, ["api", "--method", "POST", path, "-f", "body=\(body)"])
}

/// Run a gh write command, throwing a clean `GhError` on launch-fail or non-zero exit.
private func ghWrite(_ cwd: String, _ args: [String]) async throws {
    let r: ProcessResult
    do {
        r = try await ProcessRunner.capture(ghBin(), args, cwd: cwd, maxBytes: MAX_BUFFER)
    } catch {
        throw GhError(ghErrorReason(error))
    }
    guard r.ok else {
        throw GhError(ghErrorReason(ProcessError(
            code: r.exitCode, stdout: r.stdout, stderr: r.stderr,
            launchFailed: false, timedOut: false)))
    }
}

/// A clean, message-bearing error for gh failures surfaced to the UI. Mirrors the
/// `throw new Error(ghErrorReason(...))` the TS throws.
public struct GhError: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Turn a process failure into a short, user-facing reason. Mirrors the TS
/// `ghErrorReason`: ENOENT → not installed, then auth/repo heuristics on stderr,
/// else the first line of stderr (or a generic fallback).
private func ghErrorReason(_ err: Error) -> String {
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

// MARK: - small regex helpers (mirroring the TS String.match calls)

/// First `https?://…` (non-whitespace run) in `s`, mirroring `/https?:\/\/\S+/`.
private func firstUrl(in s: String) -> String? {
    firstMatch(in: s, pattern: "https?://\\S+", group: 0)
}

/// The url captured from an "already exists: <url>" gh stderr message,
/// mirroring `/already exists[:\s]+(https?:\/\/\S+)/i` (case-insensitive, group 1).
private func existingPrUrl(in s: String) -> String? {
    firstMatch(in: s, pattern: "already exists[:\\s]+(https?://\\S+)",
               group: 1, options: [.caseInsensitive])
}

/// Run `pattern` over `s` and return the requested capture group of the first
/// match, or nil. `group: 0` is the whole match.
private func firstMatch(in s: String, pattern: String, group: Int,
                        options: NSRegularExpression.Options = []) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
    let ns = s as NSString
    guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else {
        return nil
    }
    let range = m.range(at: group)
    guard range.location != NSNotFound else { return nil }
    return ns.substring(with: range)
}
