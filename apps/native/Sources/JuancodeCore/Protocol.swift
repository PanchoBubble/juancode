import Foundation

/// Model types mirrored from `apps/server/src/protocol.ts`. Kept dependency-free
/// and in sync with the TS wire protocol — these are what the embedded server
/// (juancode-u34.3) will encode for remote clients.

public enum ProviderId: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
}

/// Inferred live activity of a running session. Derived from the pty stream
/// (see `ActivityDetector`); not persisted — only meaningful for live sessions.
public enum SessionActivity: String, Codable, Sendable {
    case busy
    case idle
    case waitingInput = "waiting_input"
}

public enum SessionStatus: String, Codable, Sendable {
    case running
    case exited
}

/// What a session's pty is running. `.agent` is a real Claude/Codex CLI (the
/// default, and everything that predates the field). `.editor` is a full-screen
/// editor (`$JUANCODE_EDITOR`, default nvim) opened in a source session's working
/// directory — a first-class pty session so it renders in the same terminal
/// surface and groups in the sidebar, but excluded from agent-turn notifications
/// and the retention cap since it has no transcript and is transient.
public enum SessionKind: String, Codable, Sendable {
    case agent
    case editor
}

/// Per-session token usage parsed from the CLI transcript. `costUsd` is a
/// best-effort estimate, nil when not computable.
public struct SessionUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    /// input + output + cache read + cache write.
    public var totalTokens: Int
    public var costUsd: Double?

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        totalTokens: Int,
        costUsd: Double?
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens
        self.costUsd = costUsd
    }
}

public struct SessionMeta: Codable, Sendable, Equatable {
    public var id: String
    public var provider: ProviderId
    public var cwd: String
    public var title: String
    public var status: SessionStatus
    public var exitCode: Int?
    /// ms since epoch, matching the TS `Date.now()` shape.
    public var createdAt: Int
    public var updatedAt: Int
    /// The CLI's resumable conversation id. Known immediately for Claude
    /// (pinned via `--session-id`); discovered after spawn for Codex. Nil until
    /// captured — when nil the session can be viewed but not reactivated.
    public var cliSessionId: String?
    /// "Accept all" mode — the CLI runs with no permission/approval prompts.
    public var skipPermissions: Bool
    /// Absolute path of a juancode-owned git worktree, or nil for sessions that
    /// run in an existing directory.
    public var worktreePath: String?
    public var usage: SessionUsage?
    /// Archived sessions are kept in the store but hidden from the default
    /// sidebar list (reachable via a "Show archived" toggle). Defaults to false.
    public var archived: Bool
    /// True when the idle reaper killed this session's pty to free RAM
    /// (juancode-lgq) — the CLI process is gone but the conversation is intact
    /// and resumable, so the UI should render it as "sleeping" rather than
    /// crashed/exited. Deliberately a flag next to `status == .exited` (not a new
    /// `SessionStatus` case): the status enum crosses the wire and a case old
    /// clients can't decode would break them, while an extra bool is ignored.
    /// Cleared on resume. Defaults to false.
    public var dormant: Bool
    /// What the pty is running (see `SessionKind`). Defaults to `.agent` so rows
    /// predating the field — and any peer that doesn't model it — read as agents.
    public var kind: SessionKind
    /// For an `.editor` session, the id of the agent session it was opened from,
    /// so the two read as linked. Nil for agents. Not persisted (editor sessions
    /// are transient) — it lives only on the in-memory registry meta.
    public var parentSessionId: String?

    /// The directory an agent is actually working in: its juancode-owned worktree
    /// when isolated, otherwise its cwd. An "open editor" action roots the editor
    /// here so it lands in the same checkout the agent edits.
    public var effectiveCwd: String { worktreePath ?? cwd }

    public init(
        id: String,
        provider: ProviderId,
        cwd: String,
        title: String,
        status: SessionStatus,
        exitCode: Int?,
        createdAt: Int,
        updatedAt: Int,
        cliSessionId: String?,
        skipPermissions: Bool,
        worktreePath: String?,
        usage: SessionUsage?,
        archived: Bool = false,
        dormant: Bool = false,
        kind: SessionKind = .agent,
        parentSessionId: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.cwd = cwd
        self.title = title
        self.status = status
        self.exitCode = exitCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cliSessionId = cliSessionId
        self.skipPermissions = skipPermissions
        self.worktreePath = worktreePath
        self.usage = usage
        self.archived = archived
        self.dormant = dormant
        self.kind = kind
        self.parentSessionId = parentSessionId
    }

    // Custom decode so payloads predating `archived` (older db rows / wire
    // messages from a Node peer that doesn't model it) still decode cleanly.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decode(ProviderId.self, forKey: .provider)
        cwd = try c.decode(String.self, forKey: .cwd)
        title = try c.decode(String.self, forKey: .title)
        status = try c.decode(SessionStatus.self, forKey: .status)
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
        createdAt = try c.decode(Int.self, forKey: .createdAt)
        updatedAt = try c.decode(Int.self, forKey: .updatedAt)
        cliSessionId = try c.decodeIfPresent(String.self, forKey: .cliSessionId)
        skipPermissions = try c.decode(Bool.self, forKey: .skipPermissions)
        worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
        usage = try c.decodeIfPresent(SessionUsage.self, forKey: .usage)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        dormant = try c.decodeIfPresent(Bool.self, forKey: .dormant) ?? false
        kind = try c.decodeIfPresent(SessionKind.self, forKey: .kind) ?? .agent
        parentSessionId = try c.decodeIfPresent(String.self, forKey: .parentSessionId)
    }
}

extension SessionMeta {
    /// Build a persisted session that *adopts* an existing external CLI conversation
    /// (juancode-iqi): a fresh juancode `id` pointing at an already-known
    /// `cliSessionId` that ran in `cwd`. `startMs` (when the conversation began)
    /// becomes `createdAt` so the adopted row sorts by its real age. The title is a
    /// placeholder mirroring `Session.create`; the live session's poll loop derives
    /// the real title + usage from the transcript once it's resumed.
    public static func adopting(
        provider: ProviderId,
        cliSessionId: String,
        cwd: String,
        startMs: Int,
        skipPermissions: Bool = true
    ) -> SessionMeta {
        let spec = Providers.spec(for: provider)
        let folder = (cwd as NSString).lastPathComponent
        return SessionMeta(
            id: UUID().uuidString.lowercased(),
            provider: provider,
            cwd: cwd,
            title: "\(spec.label) · \(folder.isEmpty ? cwd : folder)",
            status: .running,
            exitCode: nil,
            createdAt: startMs,
            updatedAt: nowMs(),
            cliSessionId: cliSessionId,
            skipPermissions: skipPermissions,
            worktreePath: nil,
            usage: nil
        )
    }
}

/// Milliseconds since the unix epoch — the timestamp unit the TS layer uses.
@inline(__always)
public func nowMs() -> Int {
    Int(Date().timeIntervalSince1970 * 1000)
}
