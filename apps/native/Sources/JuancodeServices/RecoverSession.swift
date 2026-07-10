import Foundation
import JuancodeCore

/// Recover the resumable CLI session id for an *old* session that was created
/// before we started capturing it (Claude) or whose post-spawn discovery never
/// landed (Codex). Both CLIs persist a transcript per conversation that records
/// the working directory it ran in, so we match on `cwd` and pick the transcript
/// whose start time is closest to when our session was created — the same
/// cwd-plus-time heuristic `codexSession.ts` uses for live Codex discovery.
///
/// A transcript can't predate our spawn, and a match more than a few minutes off
/// is almost certainly a *different* conversation in the same folder, so we bound
/// the window on both sides and never reuse an id already claimed by another
/// session. When nothing fits we return nil and the session stays unresumable.
///
/// (Ported 1:1 from `apps/server/src/recoverSession.ts`. Distinct from
/// `CodexSessionDiscovery`, which finds a *new* id right after spawn; this module
/// recovers an *existing* id for an *old* session from transcripts already on disk.)

// Renamed from CLAUDE_PROJECTS/CODEX_SESSIONS to avoid colliding with the
// module-visible constants of the same name in SessionTitle.swift.
private let RECOVER_CLAUDE_PROJECTS = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/projects").path
private let RECOVER_CODEX_SESSIONS = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex/sessions").path

/// A transcript can't start before we spawned it; allow small clock skew.
private let GRACE_BEFORE_MS = 5_000
/// Beyond this gap a cwd match is untrustworthy (likely a later session).
private let MAX_GAP_MS = 15 * 60_000

/// Override the transcript roots (used by tests to point at fixtures).
public struct RecoverRoots {
    public var claudeProjects: String?
    public var codexSessions: String?

    public init(claudeProjects: String? = nil, codexSessions: String? = nil) {
        self.claudeProjects = claudeProjects
        self.codexSessions = codexSessions
    }
}

/// A resumable conversation found on disk: its CLI id and when it began.
private struct Candidate {
    let id: String
    let startMs: Int
}

/// Read JSONL lines, calling `onRecord`; stop early when it returns false.
///
/// The TS version streams line-by-line via `readline`; for our header-only reads
/// the files are small, so we read the whole file and split on newlines. Malformed
/// JSON lines are tolerated (skipped) exactly as the TS `try/catch` does.
private func forEachRecord(
    _ file: String,
    _ onRecord: ([String: Any]) -> Bool?
) {
    guard let data = FileManager.default.contents(atPath: file),
          let text = String(data: data, encoding: .utf8) else { return }
    // `crlfDelay: Infinity` in TS collapses CRLF; splitting on \n then trimming \r
    // (and whitespace) matches `if (!line.trim()) continue`.
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { continue }
        guard let lineData = line.data(using: .utf8),
              let rec = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
        else { continue }
        if onRecord(rec) == false { return }
    }
}

/// Parse an ISO-8601 timestamp the way JS `Date.parse` does, returning ms since
/// epoch or nil when unparseable. Covers fractional seconds and a trailing `Z`.
private func parseIsoMs(_ s: String) -> Int? {
    let withFrac = ISO8601DateFormatter()
    withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFrac.date(from: s) { return Int(d.timeIntervalSince1970 * 1000) }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let d = plain.date(from: s) { return Int(d.timeIntervalSince1970 * 1000) }
    return nil
}

/// Claude encodes a cwd into a project-dir name by replacing path separators
/// (and, in newer versions, dots) with dashes. We try both encodings, and fall
/// back to scanning every project dir if neither exists — the transcript's own
/// `cwd` field is the source of truth either way.
private func claudeDirs(_ root: String, _ cwd: String) -> [String] {
    // `[...new Set([...])]` dedupes while preserving first-seen order.
    let raw = [
        cwd.replacingOccurrences(of: "[/.]", with: "-", options: .regularExpression),
        cwd.replacingOccurrences(of: "/", with: "-"),
    ]
    var seen = Set<String>()
    let variants = raw.filter { seen.insert($0).inserted }
    let direct = variants
        .map { (root as NSString).appendingPathComponent($0) }
        .filter { FileManager.default.fileExists(atPath: $0) }
    return direct.isEmpty ? [] : direct
}

/// First record carrying both a cwd and a timestamp (Claude transcripts).
private func claudeHeader(_ file: String) -> (cwd: String, startMs: Int)? {
    var result: (cwd: String, startMs: Int)?
    forEachRecord(file) { rec in
        if let cwd = rec["cwd"] as? String, let timestamp = rec["timestamp"] as? String {
            if let startMs = parseIsoMs(timestamp) {
                result = (cwd, startMs)
                return false
            }
        }
        return nil
    }
    return result
}

private func claudeCandidates(_ root: String, _ cwd: String) -> [Candidate] {
    let fm = FileManager.default
    var dirs = claudeDirs(root, cwd)
    if dirs.isEmpty {
        // Unknown encoding — scan every project dir and trust the in-file cwd.
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        dirs = names
            .map { (root as NSString).appendingPathComponent($0) }
            .filter { p in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
            }
    }
    var candidates: [Candidate] = []
    for dir in dirs {
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
        for f in files {
            if !f.hasSuffix(".jsonl") { continue }
            let header = claudeHeader((dir as NSString).appendingPathComponent(f))
            // The file's basename IS Claude's session id.
            if let header, header.cwd == cwd {
                candidates.append(Candidate(id: String(f.dropLast(".jsonl".count)), startMs: header.startMs))
            }
        }
    }
    return candidates
}

/// Codex session_meta header: the resumable id and the cwd it ran in.
private func codexHeader(_ file: String) -> (id: String, cwd: String)? {
    var result: (id: String, cwd: String)?
    forEachRecord(file) { rec in
        if rec["type"] as? String == "session_meta" {
            if let payload = rec["payload"] as? [String: Any],
               let id = payload["id"] as? String,
               let cwd = payload["cwd"] as? String {
                result = (id, cwd)
            }
        }
        return false // header is the first non-empty line
    }
    return result
}

private func codexCandidates(_ root: String, _ cwd: String) -> [Candidate] {
    let fm = FileManager.default
    // `readdir(root, { recursive: true })` yields paths relative to `root`; the
    // enumerator gives us the same recursive walk. Bail out (empty) when the root
    // doesn't exist, matching the TS try/catch.
    guard let en = fm.enumerator(atPath: root) else { return [] }
    var candidates: [Candidate] = []
    for case let rel as String in en {
        if !rel.hasSuffix(".jsonl") || !rel.contains("rollout-") { continue }
        let full = (root as NSString).appendingPathComponent(rel)
        guard let header = codexHeader(full), header.cwd == cwd else { continue }
        // Codex has no in-record start time we can rely on; the rollout file's
        // creation time is when the session began.
        guard let attrs = try? fm.attributesOfItem(atPath: full) else { continue }
        // `s.birthtimeMs || s.mtimeMs` — prefer creation time, fall back to mtime
        // when birthtime is missing or 0 (a falsy value in the JS `||`).
        let birth = (attrs[.creationDate] as? Date)?.timeIntervalSince1970
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        let chosen: TimeInterval? = (birth != nil && birth! > 0) ? birth : mtime
        guard let startSec = chosen else { continue }
        candidates.append(Candidate(id: header.id, startMs: Int(startSec * 1000)))
    }
    return candidates
}

/// Pick the candidate that began nearest to (and not well before) `createdAtMs`.
private func chooseNearest(_ cands: [Candidate], _ createdAtMs: Int, _ exclude: Set<String>) -> String? {
    var best: (id: String, gap: Int)?
    for c in cands {
        if exclude.contains(c.id) { continue }
        if c.startMs < createdAtMs - GRACE_BEFORE_MS { continue }
        if c.startMs - createdAtMs > MAX_GAP_MS { continue }
        let gap = abs(c.startMs - createdAtMs)
        if best == nil || gap < best!.gap { best = (c.id, gap) }
    }
    return best?.id
}

/// Find the on-disk CLI conversation for an orphaned session, or nil when none
/// can be matched confidently. `excludeIds` are ids already claimed by other
/// sessions, so two orphans in one folder can't both grab the same transcript.
public func recoverCliSessionId(
    _ provider: ProviderId,
    cwd: String,
    createdAtMs: Int,
    excludeIds: Set<String>,
    roots: RecoverRoots = RecoverRoots()
) async -> String? {
    let cands = provider == .claude
        ? claudeCandidates(roots.claudeProjects ?? RECOVER_CLAUDE_PROJECTS, cwd)
        : codexCandidates(roots.codexSessions ?? RECOVER_CODEX_SESSIONS, cwd)
    return chooseNearest(cands, createdAtMs, excludeIds)
}

/// Whether a resumable Claude transcript for `cliSessionId` exists on disk under
/// `cwd`. Claude writes a transcript only once a turn completes, so a pinned-id
/// session that booted but never got a turn has none and `claude --resume <id>`
/// would just fast-exit. Reuses the same candidate scan as `recoverCliSessionId`
/// (basename = id, matched on the transcript's own `cwd`) so "exists" means exactly
/// "recovery would accept it". Callers use this to skip a doomed resume and boot a
/// fresh session in place instead.
public func claudeConversationExists(
    cliSessionId: String,
    cwd: String,
    roots: RecoverRoots = RecoverRoots()
) -> Bool {
    claudeCandidates(roots.claudeProjects ?? RECOVER_CLAUDE_PROJECTS, cwd)
        .contains { $0.id == cliSessionId }
}

/// A resumable CLI conversation found on disk for a `cwd`: which CLI produced it,
/// its resumable id, and when it began. The lightweight result of
/// `listExternalSessions` — just enough to build a `SessionMeta` and adopt it
/// (juancode-iqi). Distinct from `ExternalSession` (SessionDiscovery.swift), which
/// reads each transcript's content to derive a display title for the global
/// "discover" list; this one is a cheap, cwd-scoped, header-only lookup.
public struct ResumableCliSession: Sendable, Equatable {
    /// The CLI that owns this transcript (`claude` or `codex`).
    public let provider: ProviderId
    /// The id to resume with (`claude --resume <id>` / a Codex rollout id).
    public let cliSessionId: String
    /// When the conversation began, ms since epoch.
    public let startMs: Int

    public init(provider: ProviderId, cliSessionId: String, startMs: Int) {
        self.provider = provider
        self.cliSessionId = cliSessionId
        self.startMs = startMs
    }
}

/// List every resumable CLI conversation (Claude + Codex) whose transcript ran in
/// `cwd`, newest first. Reuses the same header parsing as `recoverCliSessionId`
/// (Claude: basename = id, cwd+timestamp on the first matching line; Codex:
/// `session_meta` payload id+cwd) but applies no time window and no exclusion —
/// it surfaces *all* candidates so the caller can offer them for adoption. Dedupe
/// against already-adopted ids (`store.usedCliSessionIds()`) at the call site,
/// not here.
public func listExternalSessions(
    cwd: String,
    roots: RecoverRoots = RecoverRoots()
) -> [ResumableCliSession] {
    let claude = claudeCandidates(roots.claudeProjects ?? RECOVER_CLAUDE_PROJECTS, cwd)
        .map { ResumableCliSession(provider: .claude, cliSessionId: $0.id, startMs: $0.startMs) }
    let codex = codexCandidates(roots.codexSessions ?? RECOVER_CODEX_SESSIONS, cwd)
        .map { ResumableCliSession(provider: .codex, cliSessionId: $0.id, startMs: $0.startMs) }
    return (claude + codex).sorted { $0.startMs > $1.startMs }
}
