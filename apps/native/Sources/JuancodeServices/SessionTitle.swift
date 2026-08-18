import Foundation
import JuancodeCore

/// Derives a human-readable "what is this session doing" title from the CLI's own
/// transcript files — the same data the CLI shows in its own session list.
///
///   - Claude writes an `ai-title` entry (a model-generated summary) into
///     `~/.claude/projects/<encoded-cwd>/<cliSessionId>.jsonl`. We take the latest.
///   - Codex has no generated title, so we fall back to the first `user_message`
///     payload in its rollout file (the user's opening prompt).
///   - opencode stores a generated title on the session row of its own SQLite
///     database, which `OpencodeStore` reads directly.
///
/// Returns nil when nothing is available yet (e.g. before the first turn), in
/// which case the caller keeps the existing placeholder title.

public let CLAUDE_PROJECTS: String =
    (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
    .appendingPathComponent(".claude/projects")
public let CODEX_SESSIONS: String =
    (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
    .appendingPathComponent(".codex/sessions")

private let MAX_TITLE_LEN = 80

/// Override the transcript roots (used by tests to point at fixtures).
public struct TitleRoots {
    public var claudeProjects: String?
    public var codexSessions: String?
    /// opencode's database file rather than a transcript directory (it has no
    /// per-session files); nil uses `OpencodeStore.defaultPath`.
    public var opencodeDb: String?
    public init(claudeProjects: String? = nil, codexSessions: String? = nil,
                opencodeDb: String? = nil) {
        self.claudeProjects = claudeProjects
        self.codexSessions = codexSessions
        self.opencodeDb = opencodeDb
    }
}

/// Resolving a transcript file means scanning a whole directory tree, which is
/// wasteful to repeat on every poll. Cache the resolved path per CLI session id
/// once we've found it so later polls read just that one file.
///
/// (Mirrors the module-level `Map` in the TS source; guarded by a lock since the
/// Swift module is reachable from multiple threads.)
private final class FileCache: @unchecked Sendable {
    private var map: [String: String] = [:]
    private let lock = NSLock()
    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[key]
    }
    func set(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        map[key] = value
    }
}
private let fileCache = FileCache()

/// Namespace for this module's read positions in `TranscriptReader` (the usage poll
/// reads the same files at its own pace under its own namespace).
private let titleNamespace = "title"

/// The latest `ai-title` seen for a session, carried across polls: an incremental
/// pass that appended no new title must keep reporting the previous one rather than
/// fall back to the placeholder (juancode-dfhg). Also holds a resolved Codex title,
/// which never changes once its first user message is written.
private let titleCache = FileCache()

/// Collapse whitespace and trim/truncate a raw prompt or summary into a title.
public func tidy(_ raw: String) -> String? {
    // Replace each run of whitespace with a single space, then trim. Mirrors the
    // JS `raw.replace(/\s+/g, " ").trim()`.
    let collapsed = raw
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    let text = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return nil }
    if text.count > MAX_TITLE_LEN {
        // `text.slice(0, MAX_TITLE_LEN - 1)` keeps 79 chars; appending the ellipsis
        // yields exactly MAX_TITLE_LEN characters.
        let prefix = String(text.prefix(MAX_TITLE_LEN - 1))
        return "\(prefix)…"
    }
    return text
}

/// Find a `.jsonl` file by basename anywhere under `root`.
public func findByBasename(_ root: String, _ basename: String) async -> String? {
    let entries = recursiveDirEntries(root)
    guard let match = entries.first(where: { $0.hasSuffix(basename) }) else { return nil }
    return (root as NSString).appendingPathComponent(match)
}

/// List every entry (files and dirs) under `root` recursively, as paths relative
/// to `root` — the Swift equivalent of `readdir(root, { recursive: true })`.
/// Returns an empty list when `root` cannot be read (mirrors the TS try/catch).
private func recursiveDirEntries(_ root: String) -> [String] {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { return [] }
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    guard let enumerator = fm.enumerator(
        at: rootURL,
        includingPropertiesForKeys: nil,
        options: []
    ) else { return [] }
    var out: [String] = []
    let prefix = rootURL.standardizedFileURL.path
    for case let url as URL in enumerator {
        // Relative path from root, matching Node's recursive readdir output.
        let full = url.standardizedFileURL.path
        if full.hasPrefix(prefix + "/") {
            out.append(String(full.dropFirst(prefix.count + 1)))
        } else {
            out.append(url.lastPathComponent)
        }
    }
    return out
}

/// Stream JSONL lines, calling `onRecord`; stop early when it returns false.
public func forEachRecord(
    _ file: String,
    _ onRecord: ([String: Any]) -> Bool?
) async {
    // Read the whole file and split on newlines. We tolerate malformed lines
    // exactly as the TS does (skip lines that don't parse / are blank).
    guard let data = FileManager.default.contents(atPath: file),
          let contents = String(data: data, encoding: .utf8) else { return }
    // `crlfDelay: Infinity` in Node coalesces \r\n; splitting on \n and trimming
    // each line of trailing \r reproduces that.
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
    for rawLine in lines {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        guard let lineData = line.data(using: .utf8) else { continue }
        let parsed = try? JSONSerialization.jsonObject(with: lineData)
        guard let rec = parsed as? [String: Any] else { continue }
        if onRecord(rec) == false { return }
    }
}

/// Latest `ai-title` (model-generated summary) from a Claude transcript.
///
/// Reads only the records appended since the last call (`TranscriptReader`): the CLI
/// appends one `ai-title` per rename, so the newest one in this pass wins, and a pass
/// that brought none keeps the title an earlier pass found. Re-parsing the whole
/// transcript every 4s per session is what this replaces (juancode-dfhg).
public func deriveClaudeTitle(
    _ cliSessionId: String,
    _ root: String = CLAUDE_PROJECTS
) async -> String? {
    var file = fileCache.get(cliSessionId)
    if file == nil {
        guard let found = await findByBasename(root, "\(cliSessionId).jsonl") else { return nil }
        fileCache.set(cliSessionId, found)
        file = found
    }
    var title: String? = nil
    let scan = TranscriptReader.shared.scan(file: file!, namespace: titleNamespace) { rec in
        if rec["type"] as? String == "ai-title", let aiTitle = rec["aiTitle"] as? String {
            title = aiTitle  // keep scanning — take the most recent one
        }
        return nil
    }
    // A restarted pass (first sight, or a rewritten file) re-read everything, so the
    // remembered title is superseded by whatever this pass found — including nothing.
    let prior = scan.fromStart ? nil : titleCache.get(cliSessionId)
    guard let raw = title ?? prior else { return nil }
    titleCache.set(cliSessionId, raw)
    return tidy(raw)
}

/// First user prompt from a Codex rollout, located by its session_meta id.
///
/// The first user message never changes, so once found it is cached and no further
/// poll touches the file at all (juancode-dfhg) — discovery still needs whole-file
/// scans, since matching a rollout to a session id means reading its `session_meta`.
public func deriveCodexTitle(
    _ cliSessionId: String,
    _ root: String = CODEX_SESSIONS
) async -> String? {
    if let resolved = titleCache.get(cliSessionId) { return tidy(resolved) }
    let cached = fileCache.get(cliSessionId)
    let files = cached != nil ? [cached!] : await codexRolloutFiles(root)

    for full in files {
        var isMatch = false
        var prompt: String? = nil
        await forEachRecord(full) { rec in
            if rec["type"] as? String == "session_meta" {
                let payload = rec["payload"] as? [String: Any]
                if (payload?["id"] as? String) != cliSessionId { return false }  // wrong file — bail
                isMatch = true
                return nil
            }
            let payload = rec["payload"] as? [String: Any]
            if isMatch,
               payload?["type"] as? String == "user_message",
               let message = payload?["message"] as? String {
                prompt = message
                return false  // first user message is enough
            }
            return nil
        }
        if isMatch {
            fileCache.set(cliSessionId, full)
            guard let prompt else { return nil }  // matched; no prompt written yet
            titleCache.set(cliSessionId, prompt)
            return tidy(prompt)
        }
    }
    return nil
}

/// Absolute paths of every Codex rollout file, newest scan each call.
public func codexRolloutFiles(_ root: String) async -> [String] {
    let entries = recursiveDirEntries(root)
    return entries
        .filter { $0.hasSuffix(".jsonl") && $0.contains("rollout-") }
        .map { (root as NSString).appendingPathComponent($0) }
}

public func deriveSessionTitle(
    _ provider: ProviderId,
    _ cliSessionId: String,
    _ roots: TitleRoots = TitleRoots()
) async -> String? {
    switch provider {
    case .claude:
        return await deriveClaudeTitle(cliSessionId, roots.claudeProjects ?? CLAUDE_PROJECTS)
    case .codex:
        return await deriveCodexTitle(cliSessionId, roots.codexSessions ?? CODEX_SESSIONS)
    case .opencode:
        // opencode keeps its own generated title on the session row — no transcript
        // scan, no caching needed (see OpencodeStore).
        return OpencodeStore.title(cliSessionId, db: roots.opencodeDb ?? OpencodeStore.defaultPath)
    }
}
