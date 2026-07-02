import Foundation

/// REST + panel data types mirrored from `apps/server/src/protocol.ts`. Kept in
/// sync with the TS wire shapes (camelCase keys) so the existing web client and
/// the embedded server agree. Dependency-free.

// ── Diff viewer ──────────────────────────────────────────────────────────────

public enum FileStatus: String, Codable, Sendable {
    case modified, added, deleted, renamed, untracked
}

public struct DiffFile: Codable, Sendable, Equatable {
    public var path: String
    public var oldPath: String?
    public var status: FileStatus
    public var additions: Int
    public var deletions: Int
    public var binary: Bool
    public var diff: String
    public var truncated: Bool

    public init(path: String, oldPath: String?, status: FileStatus, additions: Int,
                deletions: Int, binary: Bool, diff: String, truncated: Bool) {
        self.path = path; self.oldPath = oldPath; self.status = status
        self.additions = additions; self.deletions = deletions; self.binary = binary
        self.diff = diff; self.truncated = truncated
    }
}

public struct DiffResult: Codable, Sendable, Equatable {
    public var git: Bool
    public var root: String?
    public var files: [DiffFile]
    public var truncatedFiles: Bool?

    public init(git: Bool, root: String? = nil, files: [DiffFile], truncatedFiles: Bool? = nil) {
        self.git = git; self.root = root; self.files = files; self.truncatedFiles = truncatedFiles
    }
}

/// One linked git worktree of a repo (from `git worktree list`).
public struct Worktree: Codable, Sendable, Equatable {
    public var path: String
    public var branch: String?
    public var head: String?
    public var main: Bool

    public init(path: String, branch: String?, head: String?, main: Bool) {
        self.path = path; self.branch = branch; self.head = head; self.main = main
    }
}

// ── Inline diff comments ─────────────────────────────────────────────────────

public enum CommentSide: String, Codable, Sendable {
    case old, new
}

public struct DiffComment: Codable, Sendable, Equatable {
    public var id: String
    public var sessionId: String
    public var file: String
    public var side: CommentSide
    public var line: Int
    public var endLine: Int
    public var body: String
    public var createdAt: Int

    public init(id: String, sessionId: String, file: String, side: CommentSide,
                line: Int, endLine: Int, body: String, createdAt: Int) {
        self.id = id; self.sessionId = sessionId; self.file = file; self.side = side
        self.line = line; self.endLine = endLine; self.body = body; self.createdAt = createdAt
    }
}

// ── 'Review with Claude' AI pass ─────────────────────────────────────────────

public enum ReviewSeverity: String, Codable, Sendable {
    case critical, high, medium, low, info
}

public struct ReviewFinding: Codable, Sendable, Equatable {
    public var file: String
    public var side: CommentSide
    public var line: Int?
    public var severity: ReviewSeverity
    public var title: String
    public var note: String

    public init(file: String, side: CommentSide, line: Int?, severity: ReviewSeverity,
                title: String, note: String) {
        self.file = file; self.side = side; self.line = line
        self.severity = severity; self.title = title; self.note = note
    }
}

public struct ReviewResult: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case ok, empty, error }
    public var status: Status
    public var findings: [ReviewFinding]
    public var summary: String?
    public var createdAt: Int
    public var error: String?

    public init(status: Status, findings: [ReviewFinding], summary: String?,
                createdAt: Int, error: String? = nil) {
        self.status = status; self.findings = findings; self.summary = summary
        self.createdAt = createdAt; self.error = error
    }
}

// ── Beads (bd) issues ────────────────────────────────────────────────────────

public struct BeadsIssue: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var status: String
    public var priority: Int
    public var issueType: String
    public var parent: String?
    public var dependencyCount: Int
    public var dependentCount: Int
    public var ready: Bool
    public var blocked: Bool

    public init(id: String, title: String, status: String, priority: Int, issueType: String,
                parent: String?, dependencyCount: Int, dependentCount: Int, ready: Bool, blocked: Bool) {
        self.id = id; self.title = title; self.status = status; self.priority = priority
        self.issueType = issueType; self.parent = parent
        self.dependencyCount = dependencyCount; self.dependentCount = dependentCount
        self.ready = ready; self.blocked = blocked
    }
}

public struct BeadsResult: Codable, Sendable, Equatable {
    public var available: Bool
    public var issues: [BeadsIssue]
    public var error: String?

    public init(available: Bool, issues: [BeadsIssue], error: String? = nil) {
        self.available = available; self.issues = issues; self.error = error
    }
}

// ── Open pull requests ───────────────────────────────────────────────────────

public enum PrChecks: String, Codable, Sendable {
    case passing, failing, pending, none
}

public struct PullRequest: Codable, Sendable, Equatable {
    public var number: Int
    public var title: String
    public var url: String
    public var branch: String
    public var draft: Bool
    public var checks: PrChecks
    /// Total number of CI checks (`statusCheckRollup` entries), 0 when none —
    /// shown in the row instead of a "passing/failing" phrase; `checks` still
    /// carries the rolled-up colour.
    public var checkCount: Int
    /// Number of checks that concluded successfully (SUCCESS / skipped / neutral —
    /// anything not failing and not still running). Drives the `passed/total` badge
    /// alongside `checkCount`. 0 when there are no checks.
    public var passedCount: Int
    /// Count of unresolved review threads ("active" conversations) on the PR, 0
    /// when none or when it couldn't be fetched. Populated via a GraphQL call
    /// alongside the list fetch.
    public var unresolvedComments: Int
    /// GitHub login of the PR author (empty if unknown).
    public var author: String
    /// GitHub logins of the PR's assignees (empty when none) — powers the
    /// "Assigned to me" filter alongside `author` for "Mine".
    public var assignees: [String]

    public init(number: Int, title: String, url: String, branch: String,
                draft: Bool, checks: PrChecks, author: String, assignees: [String] = [],
                checkCount: Int = 0, passedCount: Int = 0, unresolvedComments: Int = 0) {
        self.number = number; self.title = title; self.url = url; self.branch = branch
        self.draft = draft; self.checks = checks; self.author = author; self.assignees = assignees
        self.checkCount = checkCount; self.passedCount = passedCount
        self.unresolvedComments = unresolvedComments
    }
}

public struct PrListResult: Codable, Sendable, Equatable {
    public var available: Bool
    public var prs: [PullRequest]
    public var viewer: String?
    public var error: String?

    public init(available: Bool, prs: [PullRequest], viewer: String? = nil, error: String? = nil) {
        self.available = available; self.prs = prs; self.viewer = viewer; self.error = error
    }
}

// ── Git actions (commit / push / PR) ─────────────────────────────────────────

public struct GitState: Codable, Sendable, Equatable {
    public var git: Bool
    public var branch: String?
    public var detached: Bool
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var dirty: Bool
    public var remote: Bool

    public init(git: Bool, branch: String?, detached: Bool, upstream: String?,
                ahead: Int, behind: Int, dirty: Bool, remote: Bool) {
        self.git = git; self.branch = branch; self.detached = detached; self.upstream = upstream
        self.ahead = ahead; self.behind = behind; self.dirty = dirty; self.remote = remote
    }
}

public struct CommitResult: Codable, Sendable, Equatable {
    public var sha: String
    public var subject: String
    public init(sha: String, subject: String) { self.sha = sha; self.subject = subject }
}

public struct PushResult: Codable, Sendable, Equatable {
    public var branch: String
    public var output: String
    public init(branch: String, output: String) { self.branch = branch; self.output = output }
}

public struct CommitMessageResult: Codable, Sendable, Equatable {
    public var message: String
    public init(message: String) { self.message = message }
}

public struct PrCreateResult: Codable, Sendable, Equatable {
    public var url: String
    public var created: Bool
    public init(url: String, created: Bool) { self.url = url; self.created = created }
}

// ── Full-text search ─────────────────────────────────────────────────────────

/// A session matched by full-text search, plus a highlighted scrollback snippet.
/// Encodes as `SessionMeta` fields + a `snippet` (matching the TS `SearchHit`).
public struct SearchHit: Codable, Sendable, Equatable {
    public var meta: SessionMeta
    public var snippet: String

    public init(meta: SessionMeta, snippet: String) {
        self.meta = meta; self.snippet = snippet
    }

    // Flatten SessionMeta into the same object as `snippet`, matching
    // `interface SearchHit extends SessionMeta { snippet }`.
    public init(from decoder: Decoder) throws {
        meta = try SessionMeta(from: decoder)
        snippet = try decoder.container(keyedBy: SnippetKey.self).decode(String.self, forKey: .snippet)
    }

    public func encode(to encoder: Encoder) throws {
        try meta.encode(to: encoder)
        var c = encoder.container(keyedBy: SnippetKey.self)
        try c.encode(snippet, forKey: .snippet)
    }

    private enum SnippetKey: String, CodingKey { case snippet }
}
