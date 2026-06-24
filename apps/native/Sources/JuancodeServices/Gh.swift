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
