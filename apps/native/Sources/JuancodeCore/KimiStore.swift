import Foundation

/// Read-only view of kimi's own session store — the kimi analogue of the JSONL
/// transcripts `SessionTitle`/`RecoverSession` read for claude and codex, and of the
/// SQLite `OpencodeStore` reads.
///
/// kimi persists every conversation under `$KIMI_CODE_HOME/sessions/` (default
/// `~/.kimi-code/sessions/`), grouped by an opaque per-working-directory key:
///
///     ~/.kimi-code/
///     ├── session_index.jsonl          # one `{sessionId, sessionDir, workDir}` line
///     │                                #   per conversation, no timestamps
///     └── sessions/
///         └── <workdirKey>/
///             └── <sessionId>/
///                 ├── state.json       # title, createdAt/updatedAt, archived, cwd
///                 └── agents/*/wire.jsonl
///
/// The workdir key decodes to nothing we can trust, so matching is done on what the
/// files *say*: the index line's `workDir` (a mirrored claim) and each `state.json`'s
/// own `cwd`/`workDir`/`custom.cwd` (confirmed live). Timestamps and titles come
/// from `state.json` — `createdAt`/`updatedAt` are epoch millis, with an ISO string
/// accepted the same way kimi's own reader reads them — and `custom.parent_session_
/// id` marks a sub-agent's session, which is never a candidate of its own. Sessions
/// can be `archived`; those are not candidates either.
///
/// Everything here opens files for reading only and never writes: we are a reader of
/// kimi's data, never a second writer.
public enum KimiStore {
    /// Where kimi keeps its data (`KIMI_CODE_HOME`, else `~/.kimi-code`), the same
    /// root kimi's own data-locations doc gives for config, sessions and the index.
    public static var home: String {
        let env = ProcessInfo.processInfo.environment
        if let own = env["KIMI_CODE_HOME"], !own.isEmpty { return own }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".kimi-code")
    }

    /// One `{sessionId, sessionDir, workDir}` mirror line. The index carries no
    /// timestamps — the clock lives in the session's own `state.json`.
    struct IndexLine {
        let sessionId: String
        /// The session's own folder under the kimi home, relative to it (e.g.
        /// `sessions/<workdirKey>/<id>`).
        let sessionDir: String
        let workDir: String
    }

    /// Every mirror line kimi has published, tolerating blank and malformed lines.
    static func indexLines(_ homeDir: String) -> [IndexLine] {
        guard let data = FileManager.default.contents(
            atPath: (homeDir as NSString).appendingPathComponent("session_index.jsonl")),
            let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("{"),
                  let lineData = line.data(using: .utf8),
                  let v = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let sessionId = v["sessionId"] as? String, !sessionId.isEmpty,
                  let sessionDir = v["sessionDir"] as? String, !sessionDir.isEmpty,
                  let workDir = v["workDir"] as? String else { return nil }
            return IndexLine(sessionId: sessionId, sessionDir: sessionDir, workDir: workDir)
        }
    }

    // MARK: - rows

    /// One kimi conversation, as much of the on-disk data as we use.
    public struct SessionRow: Sendable, Equatable {
        public let id: String
        /// The session's own folder under the kimi home, as the index recorded it.
        public let sessionDir: String
        /// The working directory the conversation ran in (index `workDir`, confirmed
        /// by the state file's own cwd fields when it has one).
        public let directory: String
        public let title: String?
        /// The user's opening prompt — kimi's own display's fallback before a title
        /// is generated, and ours too.
        public let lastPrompt: String?
        public let createdMs: Int
        public let updatedMs: Int
        public let archived: Bool
        /// Set for a sub-agent's session, which belongs to its parent conversation
        /// and is never resumed on its own.
        public let parentId: String?

        /// A conversation that can be offered for resume: never archived, never a
        /// sub-agent's child.
        var resumable: Bool { !archived && parentId == nil }
    }

    /// kimi's `createdAt`/`updatedAt`: epoch millis as a number, an ISO string
    /// accepted, garbage as 0 (the same contract kimi's own reader implements; a 0
    /// can never fall inside a real spawn window).
    static func parseTimeMs(_ v: Any?) -> Int {
        if let n = v as? Int { return n }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String, let ms = parseIsoMs(s) { return ms }
        return 0
    }

    /// ISO-8601 the way JS `Date.parse` does: fractional seconds, then plain.
    private static func parseIsoMs(_ s: String) -> Int? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return Int(d.timeIntervalSince1970 * 1000) }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return Int(d.timeIntervalSince1970 * 1000) }
        return nil
    }

    /// A non-empty string field of a dictionary, or nil.
    private static func str(_ dict: [String: Any]?, _ key: String) -> String? {
        let raw = dict?[key] as? String
        return (raw?.isEmpty == false) ? raw : nil
    }

    /// Read a session's `state.json`, in either layout kimi ships
    /// (`<dir>/state.json`, legacy `<dir>/session-meta/state.json`).
    static func stateDict(_ homeDir: String, _ sessionDir: String) -> [String: Any]? {
        let base = sessionDir.hasPrefix("/")
            ? sessionDir
            : (homeDir as NSString).appendingPathComponent(sessionDir)
        for sub in ["state.json", "session-meta/state.json"] {
            let path = (base as NSString).appendingPathComponent(sub)
            if let data = FileManager.default.contents(atPath: path) {
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
        }
        return nil
    }

    /// Build a row from what the index says, confirmed (and given its clock) by the
    /// state file. `directory` prefers what the state file claims and only falls
    /// back to the mirror's `workDir`.
    static func row(_ line: IndexLine, homeDir: String) -> SessionRow? {
        guard let state = stateDict(homeDir, line.sessionDir) else { return nil }
        let custom = state["custom"] as? [String: Any]
        return SessionRow(
            id: line.sessionId,
            sessionDir: line.sessionDir,
            directory: str(state, "cwd") ?? str(state, "workDir")
                ?? str(custom, "cwd") ?? line.workDir,
            title: state["title"] as? String,
            lastPrompt: state["lastPrompt"] as? String,
            createdMs: parseTimeMs(state["createdAt"]),
            updatedMs: parseTimeMs(state["updatedAt"]),
            archived: (state["archived"] as? Bool) == true,
            parentId: str(custom, "parent_session_id")
        )
    }

    /// A `sessions/<key>/<id>/<state file>` that exists, discovered by walking.
    private struct SessionFile {
        /// The session dir in the index's own spelling (`sessions/<key>/<id>`).
        let sessionDir: String
        /// mtime of the state file, epoch millis, so a hot poll can skip everything
        /// older than its window without opening a file.
        let mtimeMs: Int
    }

    private static let sessionsDirName = "sessions"

    /// Walk `sessions/<workdirKey>/<id>/` two levels — never deeper — and collect
    /// the sessions whose state file exists, in either layout kimi ships.
    private static func sessionFiles(_ homeDir: String) -> [SessionFile] {
        let sessions = (homeDir as NSString).appendingPathComponent(sessionsDirName)
        let fm = FileManager.default
        guard let workspaces = try? fm.contentsOfDirectory(atPath: sessions) else { return [] }
        var out: [SessionFile] = []
        for workspace in workspaces {
            let workspaceDir = (sessions as NSString).appendingPathComponent(workspace)
            guard let ids = try? fm.contentsOfDirectory(atPath: workspaceDir) else { continue }
            for id in ids {
                let dir = (workspaceDir as NSString).appendingPathComponent(id)
                for stateName in ["state.json", "session-meta/state.json"] {
                    let path = (dir as NSString).appendingPathComponent(stateName)
                    guard let attrs = try? fm.attributesOfItem(atPath: path),
                          let date = attrs[.modificationDate] as? Date else { continue }
                    out.append(SessionFile(
                        sessionDir: ((sessionsDirName as NSString)
                            .appendingPathComponent(workspace) as NSString)
                            .appendingPathComponent(id),
                        mtimeMs: Int(date.timeIntervalSince1970 * 1000)))
                    break
                }
            }
        }
        return out
    }

    // MARK: - listing

    /// Every top-level conversation recorded for `directory`, newest touched first.
    public static func sessions(directory: String, home: String = KimiStore.home) -> [SessionRow] {
        let dirs = OpencodeStore.directoryVariants(directory)
        var byId = rowIndexLines(dirs, home: home)
        if byId.isEmpty {
            // The index is a mirror — kimi's own reconcile can lag a fresh session
            // by a little — so a listing with nothing in it walks the tree directly.
            // The workdir key decodes to nothing we can match on, so every state
            // file is opened and the state's own cwd is what decides.
            for found in sessionFiles(home) {
                let line = IndexLine(
                    sessionId: (found.sessionDir as NSString).lastPathComponent,
                    sessionDir: found.sessionDir,
                    workDir: "")
                if let row = row(line, homeDir: home), row.resumable,
                   dirs.contains(row.directory) {
                    byId[row.id] = row
                }
            }
        }
        return byId.values.sorted { $0.updatedMs > $1.updatedMs }
    }

    /// The `limit` most recently touched top-level conversations, across every
    /// directory — the candidate pool for the "conversations you started in a
    /// terminal" list, mirroring `OpencodeStore.recentSessions`.
    public static func recentSessions(limit: Int, home: String = KimiStore.home) -> [SessionRow] {
        var byId = rowIndexLines([], home: home)
        if byId.isEmpty {
            fillFromTree(into: &byId, home: home) { _ in true }
        }
        return byId.values.sorted { $0.updatedMs > $1.updatedMs }.prefix(limit).map { $0 }
    }

    /// One session by id, or nil when kimi has no such conversation (yet).
    public static func session(_ id: String, home: String = KimiStore.home) -> SessionRow? {
        for line in indexLines(home) where line.sessionId == id {
            if let row = row(line, homeDir: home) { return row }
        }
        // Index miss: the same tree walk the listing falls back to, narrowed to the
        // folder named for this id — kimi names each session's directory after it.
        for found in sessionFiles(home) where (found.sessionDir as NSString).lastPathComponent == id {
            let line = IndexLine(sessionId: id, sessionDir: found.sessionDir, workDir: "")
            if let row = row(line, homeDir: home) { return row }
        }
        return nil
    }

    // MARK: - post-spawn id discovery

    /// One scan pass: the newest conversation in `cwd` created at/after `sinceMs`.
    ///
    /// Mirrors the daemon's `kimi_scan_once`: an index line claims `workDir`, the
    /// state file confirms the cwd and supplies the `createdAt` clock, and an empty
    /// index answer falls back to a stat-gated tree walk. Only a conversation whose
    /// own creation time lands in the spawn window, and closest to it, is ours.
    static func scanOnce(cwd: String, sinceMs: Int, home: String = KimiStore.home) -> String? {
        let floor = sinceMs - 2_000           // same clock-skew grace as Codex
        let ceiling = sinceMs + 30_000        // later sessions in the dir are not ours
        let dirs = OpencodeStore.directoryVariants(cwd)

        var candidates: [(id: String, gap: Int)] = []
        for line in indexLines(home) where dirs.contains(line.workDir) {
            guard let state = row(line, homeDir: home), state.resumable,
                  state.createdMs >= floor, state.createdMs <= ceiling else { continue }
            candidates.append((state.id, abs(state.createdMs - sinceMs)))
        }
        if candidates.isEmpty {
            for found in sessionFiles(home) where found.mtimeMs >= floor {
                let line = IndexLine(
                    sessionId: (found.sessionDir as NSString).lastPathComponent,
                    sessionDir: found.sessionDir,
                    workDir: "")
                guard let state = row(line, homeDir: home), state.resumable,
                      dirs.contains(state.directory),
                      state.createdMs >= floor, state.createdMs <= ceiling else { continue }
                candidates.append((state.id, abs(state.createdMs - sinceMs)))
            }
        }
        return candidates.min { $0.gap < $1.gap }?.id
    }

    /// Poll for the session kimi created at/after `sinceMs` in `cwd`, mirroring
    /// `OpencodeStore.capture`: kimi has no flag to pin an id, and its state file
    /// lands at boot but the index mirror can lag, so the id can be moments away.
    /// The window matches `recoverCliSessionId`'s 15-minute one, past which a cwd
    /// match stops being trustworthy anyway; each pass is a bounded walk, so waiting
    /// is cheap.
    public static let captureTimeoutMs = 15 * 60_000

    public static func capture(
        cwd: String,
        sinceMs: Int,
        timeoutMs: Int = captureTimeoutMs,
        intervalMs: Int = 1500,
        home: String = KimiStore.home
    ) async -> String? {
        let deadline = sinceMs + timeoutMs
        while true {
            if let id = scanOnce(cwd: cwd, sinceMs: sinceMs, home: home) { return id }
            if Int(Date().timeIntervalSince1970 * 1000) >= deadline { return nil }
            try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
        }
    }

    // MARK: - title

    /// The conversation's own title, falling back to kimi's own fallback (the user's
    /// opening prompt) while no generated title exists. nil while neither is on disk
    /// yet, so the caller keeps the placeholder.
    public static func title(_ id: String, home: String = KimiStore.home) -> String? {
        guard let row = session(id, home: home) else { return nil }
        for raw in [row.title, row.lastPrompt] {
            if let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, let tidy = tidy(text) {
                return tidy
            }
        }
        return nil
    }

    // (used by the listings)
    private static func rowIndexLines(_ dirs: [String], home: String) -> [String: SessionRow] {
        var byId: [String: SessionRow] = [:]
        for line in indexLines(home) where dirs.isEmpty || dirs.contains(line.workDir) {
            if let row = row(line, homeDir: home), row.resumable {
                byId[row.id] = row
            }
        }
        return byId
    }

    /// The tree-walk fallback the listings use when the index answers nothing.
    /// `keep` decides by row (the state's own cwd is what matches) so the caller
    /// doesn't have to care that a workdir key decodes to nothing.
    private static func fillFromTree(
        into byId: inout [String: SessionRow], home: String,
        keep: (SessionRow) -> Bool
    ) {
        for found in sessionFiles(home) {
            let line = IndexLine(
                sessionId: (found.sessionDir as NSString).lastPathComponent,
                sessionDir: found.sessionDir,
                workDir: "")
            if let row = row(line, homeDir: home), row.resumable, keep(row) {
                byId[row.id] = row
            }
        }
    }
}
