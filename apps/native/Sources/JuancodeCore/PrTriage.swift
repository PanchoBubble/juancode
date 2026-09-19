import Foundation

/// Reading a PR list once it is in hand: the triage question, the two orders, the
/// filters, and the viewer's cross-repo queue.
///
/// Nothing here fetches anything. Every `gh` call the desktop used to make in its own
/// process now belongs to the core (`juancoded_core::gh`, served under the `github`
/// capability), and `JuancodeClient.GitHubReads` is how this app asks it — including
/// for the triage answer, which arrives on `/api/prs` as `needsYou` and on
/// `/api/prs/viewer` as each row's `attention`, decided once in the daemon so the
/// phone and the desktop cannot disagree about which PR is on fire.
///
/// What is left here is the half that must not be a round trip: which rows a chip is
/// showing, what a filter box matches as you type, and how a compact age reads. Those
/// run per keystroke over a list already fetched, and a request per keystroke is not a
/// design — it is a stutter. They are pure functions over the wire types, they live in
/// `JuancodeCore` beside `PullRequest` itself (`RestModels.swift`) and the freshness
/// policy that paces the queue (`PrFreshness.swift`), and they have the daemon's own
/// `gh.rs` as their counterpart to be checked against.

// ── the page cap ─────────────────────────────────────────────────────────────

/// How many open PRs one list read returns. A folder whose list comes back exactly
/// this long may be truncated, which is when a caller that needs a *specific* branch's
/// PR asks for that branch instead of reading further down the page.
public let ghPrListLimit = 100

// ── reading a row ────────────────────────────────────────────────────────────

/// A PR's age as a single compact token ("4h", "2d", "3w", "1y") from gh's ISO8601
/// `createdAt`, or nil when the timestamp is missing or unparseable. Deliberately
/// coarse — the row needs "is this rotting?", not a duration. `now` is injected so the
/// expectations do not drift.
public func prAgeLabel(_ iso: String?, now: Date = Date()) -> String? {
    guard let iso, let created = parseIso8601(iso) else { return nil }
    let seconds = max(0, now.timeIntervalSince(created))
    // Rounded, not truncated: a fractional-second timestamp otherwise lands
    // 239.99 minutes after creation and reads as "3h" instead of "4h".
    let minutes = Int((seconds / 60).rounded())
    if minutes < 60 { return "\(max(1, minutes))m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    let days = hours / 24
    if days < 14 { return "\(days)d" }
    let weeks = days / 7
    if weeks < 52 { return "\(weeks)w" }
    return "\(days / 365)y"
}

/// gh emits `2026-08-05T12:34:56Z`; some fields carry fractional seconds. Try both.
private func parseIso8601(_ s: String) -> Date? {
    let plain = ISO8601DateFormatter()
    if let d = plain.date(from: s) { return d }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: s)
}

/// `owner`/`name` from a `https://github.com/<owner>/<repo>/pull/<n>` url, which is
/// what maps a cross-repo queue row back onto a local checkout for free whenever that
/// folder already has an open PR loaded. Nil for anything that is not a PR url.
public func repoSlug(fromPrUrl url: String) -> (owner: String, name: String)? {
    guard let rest = url.range(of: "github.com/", options: .caseInsensitive)
        .map({ String(url[$0.upperBound...]) }) else { return nil }
    let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count >= 3, parts[2] == "pull",
          !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    return (String(parts[0]), String(parts[1]))
}

// ── filtering and ordering a list already in hand ────────────────────────────

/// The `--search` qualifiers for the Mine/Assigned/text filters, or nil when there is
/// nothing to scope and the page already covers the view.
public func prBackfillQuery(mine: Bool, assigned: Bool, query: String, viewer: String) -> String? {
    let text = query.trimmingCharacters(in: .whitespaces)
    var qualifiers = "state:open"
    if mine && !viewer.isEmpty { qualifiers += " author:\(viewer)" }
    if assigned && !viewer.isEmpty { qualifiers += " assignee:\(viewer)" }
    if !text.isEmpty { qualifiers += " \(text)" }
    return qualifiers == "state:open" ? nil : qualifiers
}

/// Union `extra` PRs into `base` by PR number: keep `base` exactly as-is — same
/// entries (they carry enrichment like `unresolvedComments` the backfill lacks),
/// same order, same identity — and append only the genuinely-new PRs from `extra`
/// (those newest-first among themselves). Preserving `base` order is deliberate:
/// the backfill lands ~seconds after the instant client-side filter, so a full
/// re-sort here would visibly reshuffle every already-shown row (the flash when
/// toggling Mine/Assigned). Appending keeps shown rows put and only folds the
/// older, beyond-the-firehose matches in at the end.
public func mergePrLists(_ base: [PullRequest], _ extra: [PullRequest]) -> [PullRequest] {
    let present = Set(base.map(\.number))
    let newcomers = extra
        .filter { !present.contains($0.number) }
        .sorted { $0.number > $1.number }
    return base + newcomers
}

/// Whether a PR matches a free-text filter, case-insensitively, over its title,
/// author, branch and number. An empty query matches everything. A query that is
/// digits (optionally `#`-prefixed) matches the PR number as a prefix, so "48"
/// finds #4821 — but it still also matches text, since "48" can legitimately appear
/// in a title.
public func prMatchesQuery(_ pr: PullRequest, _ query: String) -> Bool {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !q.isEmpty else { return true }
    if pr.title.lowercased().contains(q) { return true }
    if pr.author.lowercased().contains(q) { return true }
    if pr.branch.lowercased().contains(q) { return true }
    let digits = q.hasPrefix("#") ? String(q.dropFirst()) : q
    guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return false }
    return String(pr.number).hasPrefix(digits)
}

/// Order a folder's open PRs for the GitHub view: tracked PRs first (they are the ones
/// being actively driven), each band keeping its incoming newest-first order.
public func sortPrsTrackedFirst(_ prs: [PullRequest],
                                isTracked: (PullRequest) -> Bool) -> [PullRequest] {
    prs.filter(isTracked) + prs.filter { !isTracked($0) }
}

/// Order a folder's open PRs strictly by submit date, newest first. GitHub assigns PR
/// numbers sequentially at creation, so descending number *is* descending submit date
/// and there is no second field to fetch.
public func sortPrsBySubmitDate(_ prs: [PullRequest]) -> [PullRequest] {
    prs.sorted { $0.number > $1.number }
}

// ── the triage answer, as the core spells it ─────────────────────────────────

/// Why a PR is waiting on the viewer, most urgent first. `rank` orders the pinned
/// triage group; `label` is what the row shows.
///
/// A mirror of the daemon's `PrAttentionReason`, decoded from the wire rather than
/// decided here: the rule is four clauses with a priority between them, and two
/// surfaces that implemented it separately would eventually disagree about the same
/// PR. The label travels on the wire too, so a client that decodes a reason it does
/// not know still has words for it.
public enum PrAttentionReason: String, Codable, Sendable, CaseIterable {
    /// Yours, and a reviewer asked for changes — the ball is squarely with you.
    case changesRequested
    /// Yours, and CI is red, so it cannot merge.
    case ciFailing
    /// Yours, with review threads still open.
    case unresolved
    /// Someone asked you, or a team of yours, to review it.
    case reviewRequested

    /// The words the core chose for this reason.
    public var label: String {
        switch self {
        case .changesRequested: return "changes requested"
        case .ciFailing: return "CI failing"
        case .unresolved: return "unresolved threads"
        case .reviewRequested: return "review requested"
        }
    }

    public var rank: Int {
        switch self {
        case .changesRequested: return 0
        case .ciFailing: return 1
        case .unresolved: return 2
        case .reviewRequested: return 3
        }
    }
}

/// One row of the pinned triage list, as `/api/prs` answers it: the PR, the folder it
/// came from, and why it is there.
public struct NeedsYouRow: Codable, Sendable, Equatable {
    public var cwd: String
    public var pr: PullRequest
    public var reason: PrAttentionReason
    /// The reason spelled the way the core spells it. Preferred over `reason.label`
    /// when present, so the daemon stays the one place these four strings live.
    public var label: String?

    public init(cwd: String, pr: PullRequest, reason: PrAttentionReason, label: String? = nil) {
        self.cwd = cwd; self.pr = pr; self.reason = reason; self.label = label
    }

    /// What the row draws.
    public var text: String { label ?? reason.label }
}

/// Merge the per-folder triage answers into the one pinned list the global view draws,
/// in the core's own order: by reason, then newest first.
///
/// The fan-out is here and not in the daemon on purpose, and it is the one rule from
/// `prs_needing_you` this side keeps: a list is one `gh` call per folder and never a
/// route that walks every folder the client happens to have open, because `fork+exec`
/// costs a quarter of a second on this machine and five folders in series is more than
/// a second before GitHub has been asked anything. Each folder's rows were decided by
/// the core; this only interleaves them.
public func mergeNeedsYou(_ byFolder: [[NeedsYouRow]]) -> [NeedsYouRow] {
    var rows: [NeedsYouRow] = []
    for folder in byFolder { rows.append(contentsOf: folder) }
    rows.sort { a, b in
        a.reason.rank == b.reason.rank ? a.pr.number > b.pr.number : a.reason.rank < b.reason.rank
    }
    return rows
}

// ── the viewer's own queue ───────────────────────────────────────────────────

/// Why a PR is in your queue. A PR you authored that also lists you as a reviewer is
/// yours — authorship wins, so each PR appears once.
public enum ViewerPrReason: String, Codable, Sendable, Equatable {
    case mine
    case reviewRequested
}

/// One row of the viewer queue: the PR, the repo it lives in (`owner/name` — these
/// rows span repos, so the folder name a folder-scoped row shows does not exist here),
/// why it is on your plate, and whether it wants something from you.
public struct ViewerPr: Codable, Sendable, Equatable, Identifiable {
    public var pr: PullRequest
    public var repo: String
    public var reason: ViewerPrReason
    /// Why this row wants the viewer, or nil when it does not — decided by the core,
    /// which is also the only side that can tell a review request apart from a PR that
    /// merely lists you, because the request is what put the row in its bucket.
    public var attention: PrAttentionReason?
    public var attentionLabel: String?

    public init(pr: PullRequest, repo: String, reason: ViewerPrReason,
                attention: PrAttentionReason? = nil, attentionLabel: String? = nil) {
        self.pr = pr; self.repo = repo; self.reason = reason
        self.attention = attention; self.attentionLabel = attentionLabel
    }

    /// Stable across refetches and unique within a queue (a repo cannot have two open
    /// PRs with the same number).
    public var id: String { "\(repo)#\(pr.number)" }
}

/// The viewer queue as one fetch: `available: false` when gh is missing,
/// unauthenticated, or the search failed, so the UI can stay quiet rather than claim
/// an empty queue.
public struct ViewerPrResult: Codable, Sendable, Equatable {
    public var available: Bool
    public var rows: [ViewerPr]
    public var viewer: String
    public var error: String?

    public init(available: Bool, rows: [ViewerPr] = [], viewer: String = "",
                error: String? = nil) {
        self.available = available; self.rows = rows; self.viewer = viewer; self.error = error
    }

    /// PRs you authored.
    public var mine: [ViewerPr] { rows.filter { $0.reason == .mine } }
    /// PRs waiting on your review.
    public var reviewing: [ViewerPr] { rows.filter { $0.reason == .reviewRequested } }
}

/// Which slice of the queue a surface is showing — the four questions the toolbar
/// badge's chips ask: everything, the ones you wrote, the ones you owe a review, and
/// the ones that actually want something today.
public enum ViewerPrSlice: String, Sendable, CaseIterable, Identifiable {
    case all, mine, review, needsYou
    public var id: String { rawValue }
}

/// The rows in `slice`, the ones that want you first (by `PrAttentionReason.rank`) and
/// each group otherwise keeping the queue's own order, which is GitHub's
/// `sort:updated`.
public func viewerPrRows(_ result: ViewerPrResult, slice: ViewerPrSlice) -> [ViewerPr] {
    let kept: [ViewerPr] = result.rows.filter { row in
        switch slice {
        case .all: return true
        case .mine: return row.reason == .mine
        case .review: return row.reason == .reviewRequested
        case .needsYou: return row.attention != nil
        }
    }
    return kept.enumerated().sorted { a, b in
        let ra = a.element.attention?.rank ?? Int.max
        let rb = b.element.attention?.rank ?? Int.max
        return ra == rb ? a.offset < b.offset : ra < rb
    }.map(\.element)
}

/// How many rows a slice holds — the chip counts, and for `needsYou` the badge's tint:
/// a queue that is merely long is not a queue that is on fire. Zero for every slice
/// until the queue has actually landed, so a failed search never claims a number.
public func viewerPrCount(_ result: ViewerPrResult, slice: ViewerPrSlice) -> Int {
    guard result.available else { return 0 }
    return viewerPrRows(result, slice: slice).count
}

/// How many rows in the queue actually want something from you — CI red, changes
/// requested or open threads on yours, plus every review you owe.
public func viewerPrsNeedingYou(_ result: ViewerPrResult) -> Int {
    viewerPrCount(result, slice: .needsYou)
}

/// Group a queue by repo for display: repos in first-appearance order (so the
/// freshest-updated repo leads), each keeping its incoming row order.
public func groupViewerPrsByRepo(_ rows: [ViewerPr]) -> [(repo: String, rows: [ViewerPr])] {
    var order: [String] = []
    var byRepo: [String: [ViewerPr]] = [:]
    for row in rows {
        if byRepo[row.repo] == nil { order.append(row.repo) }
        byRepo[row.repo, default: []].append(row)
    }
    return order.map { (repo: $0, rows: byRepo[$0] ?? []) }
}
