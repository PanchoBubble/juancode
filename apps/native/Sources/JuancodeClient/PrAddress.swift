import Foundation

/// A GitHub pull request named by its URL, for a review that has no local checkout.
///
/// The right rail's "Review PR" takes a URL, and the PR it names may live in a repo
/// this machine has never cloned. Everything keyed or routed by a checkout path (the
/// GitHub model's caches, `TrackedPr.key`, the core's `cwd` + `number` routes) takes
/// `cwd` as an opaque string, so such a PR is addressed by a sentinel `cwd` that carries
/// the URL: `GitHubReads` turns it into `url=` on the wire, and nothing before that has
/// to learn a second kind of identity.
public struct PrAddress: Equatable, Sendable {
    public let host: String
    public let owner: String
    public let repo: String
    public let number: Int

    /// The canonical `https://host/owner/repo/pull/N`.
    public var url: String { "https://\(host)/\(owner)/\(repo)/pull/\(number)" }

    /// The `cwd` stand-in the review and the reads carry for this PR.
    public var cwd: String { Self.cwdPrefix + url }

    static let cwdPrefix = "github-pr:"

    /// Accepts what a browser shows for a PR — extra path (`/files`), query and fragment
    /// included — and nothing else. Mirrors the core's `PrUrl::parse`, which re-checks it.
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(), scheme == "https" || scheme == "http",
              comps.user == nil, comps.password == nil,
              let host = comps.host, !host.isEmpty else { return nil }
        let parts = comps.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard parts.count >= 4, parts[2] == "pull",
              !["", ".", ".."].contains(parts[0]), !["", ".", ".."].contains(parts[1]),
              let number = Int(parts[3]), number > 0 else { return nil }
        self.host = comps.port.map { "\(host):\($0)" } ?? host
        self.owner = parts[0]
        self.repo = parts[1]
        self.number = number
    }

    /// The address a sentinel `cwd` carries, or nil for an ordinary checkout path.
    public init?(cwd: String) {
        guard cwd.hasPrefix(Self.cwdPrefix) else { return nil }
        self.init(parsing: String(cwd.dropFirst(Self.cwdPrefix.count)))
    }

    /// Whether `cwd` is the sentinel — a PR with no checkout behind it.
    public static func isRemote(cwd: String) -> Bool { cwd.hasPrefix(cwdPrefix) }
}
