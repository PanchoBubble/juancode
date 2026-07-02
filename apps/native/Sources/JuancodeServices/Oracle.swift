import Foundation
import JuancodeCore

/// The "Oracle" global orchestrator (juancode-wjg). Oracle operates at a GLOBAL
/// level — across every session and work dir — unlike the per-project panels. It
/// is a real pinned `claude`/`codex` session whose cwd is a dedicated control
/// directory, so it gets native bd access (its own tracker) plus a place for its
/// instructions and the dispatch mailbox.
///
/// On-disk layout under `~/.juancode/oracle`:
///   `.beads/`        — a dedicated bd tracker (prefix `oracle-`) for global items
///   `AGENTS.md`      — instructions the Oracle CLI agent reads on launch
///   `state.json`     — a live snapshot of active sessions + work dirs (app-written)
///   `dispatch.jsonl` — the mailbox the agent appends to, to spawn project agents
///
/// The control dir is just another cwd, so the existing `getBeads(cwd)` reads the
/// global tracker unchanged — no `--db` plumbing or bd-version coupling needed.

public enum OraclePaths {
    /// `~/.juancode/oracle`, overridable via `JUANCODE_ORACLE_DIR` (used by tests).
    public static var controlDir: String {
        if let o = ProcessInfo.processInfo.environment["JUANCODE_ORACLE_DIR"], !o.isEmpty { return o }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".juancode/oracle")
    }
    public static var beadsDir: String { join(controlDir, ".beads") }
    public static var gitDir: String { join(controlDir, ".git") }
    public static var agentsFile: String { join(controlDir, "AGENTS.md") }
    public static var stateFile: String { join(controlDir, "state.json") }
    public static var dispatchFile: String { join(controlDir, "dispatch.jsonl") }
    public static var askFile: String { join(controlDir, "ask.jsonl") }

    private static func join(_ base: String, _ component: String) -> String {
        (base as NSString).appendingPathComponent(component)
    }
}

/// A request the Oracle agent appends (one JSON object per line) to
/// `dispatch.jsonl` to spawn — or seed an existing — agent in a project. The app
/// tails the file and turns each new line into a real session.
public struct OracleDispatch: Codable, Sendable, Equatable {
    /// Absolute path of the target project / work dir the agent should run in.
    public var project: String
    /// The seed instruction sent to the agent once its TUI is up.
    public var prompt: String
    /// `"claude"` (default) or `"codex"`.
    public var provider: String?
    /// Isolate the dispatched agent in a fresh git worktree off `project`.
    public var worktree: Bool?
    /// Model override passed to the provider CLI, e.g. "opus", "sonnet", or a full
    /// model id; absent = provider default.
    public var model: String?

    public init(project: String, prompt: String, provider: String? = nil,
                worktree: Bool? = nil, model: String? = nil) {
        self.project = project
        self.prompt = prompt
        self.provider = provider
        self.worktree = worktree
        self.model = model
    }

    /// Resolve `provider` to a `ProviderId`, defaulting to Claude for an absent or
    /// unrecognized value (the dispatch should still go through).
    public var resolvedProvider: ProviderId {
        provider.flatMap { ProviderId(rawValue: $0.lowercased()) } ?? .claude
    }
}

/// A line appended to `ask.jsonl` by an out-of-process caller (the MCP sidecar that
/// fronts Oracle for remote/phone clients) to hand the Oracle agent a question. The
/// app tails the file and writes each new line into the live Oracle session — or
/// spawns one seeded with the text if none is running. Mirrors `OracleDispatch`'s
/// mailbox so remote and in-app paths share the same append-only file protocol.
public struct OracleAsk: Codable, Sendable, Equatable {
    /// The text to deliver to the Oracle agent's session.
    public var text: String

    public init(text: String) { self.text = text }
}

/// A project the Oracle may dispatch into — the "address book" for the `project`
/// field of `OracleDispatch`. Written into `state.json` so the agent dispatches to
/// real, valid paths instead of guessing. Sourced from the git repos under the
/// workspace root unioned with any in-play session cwds (see `discoverOracleProjects`).
public struct OracleProject: Codable, Sendable, Equatable {
    /// Absolute path to the project root — a valid `dispatch` target verbatim.
    public var path: String
    /// Basename, so the agent can match a natural-language reference ("juancode").
    public var name: String
    /// True when at least one session is currently live in this project.
    public var active: Bool

    public init(path: String, name: String, active: Bool) {
        self.path = path
        self.name = name
        self.active = active
    }
}

/// One live (or recently-exited) session, as written into `state.json` for the
/// Oracle agent to read with its own tools.
public struct OracleSessionSnapshot: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var cwd: String
    public var provider: String
    public var status: String
    public var activity: String?
    public var live: Bool

    public init(id: String, title: String, cwd: String, provider: String,
                status: String, activity: String?, live: Bool) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.provider = provider
        self.status = status
        self.activity = activity
        self.live = live
    }
}

/// The global snapshot the app keeps fresh in `state.json` so the Oracle agent can
/// see what's running and where, to drive cross-session/cross-project work.
public struct OracleState: Codable, Sendable, Equatable {
    /// ms since epoch (matches the rest of the app's timestamp unit).
    public var updatedAt: Int
    /// Distinct work dirs in play (project sessions), excluding the control dir.
    public var workdirs: [String]
    /// The dispatch address book: every project the Oracle may target, whether or
    /// not it currently has a session. See `OracleProject` / `discoverOracleProjects`.
    public var projects: [OracleProject]
    public var sessions: [OracleSessionSnapshot]

    public init(updatedAt: Int, workdirs: [String], sessions: [OracleSessionSnapshot],
                projects: [OracleProject] = []) {
        self.updatedAt = updatedAt
        self.workdirs = workdirs
        self.projects = projects
        self.sessions = sessions
    }
}

/// Build the Oracle's dispatch address book: every immediate git repo under
/// `workspaceRoot`, unioned with `sessionCwds` (projects already open, even ones
/// living outside the workspace root). Every returned `path` is an absolute,
/// existing directory the agent can dispatch to verbatim. `active` marks the ones
/// currently running a session. Pure + best-effort: an unreadable root yields just
/// the session cwds. Results are sorted by path for a stable `state.json`.
public func discoverOracleProjects(workspaceRoot: String, sessionCwds: [String]) -> [OracleProject] {
    let fm = FileManager.default
    let active = Set(sessionCwds.map { ($0 as NSString).standardizingPath })
    var byPath: [String: Bool] = [:] // path -> active

    // Git repos directly under the workspace root (the common case: ~/workdir/<repo>).
    let root = (workspaceRoot as NSString).standardizingPath
    if let entries = try? fm.contentsOfDirectory(atPath: root) {
        for entry in entries {
            let p = (root as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
            guard fm.fileExists(atPath: (p as NSString).appendingPathComponent(".git")) else { continue }
            byPath[p] = active.contains(p)
        }
    }
    // Union the cwds of sessions already in play — they're valid targets too, and a
    // repo opened from outside the workspace root would be invisible otherwise.
    for cwd in active { byPath[cwd] = true }

    return byPath
        .map { OracleProject(path: $0.key, name: ($0.key as NSString).lastPathComponent, active: $0.value) }
        .sorted { $0.path.localizedCompare($1.path) == .orderedAscending }
}

/// Errors raised while bootstrapping the control dir. UI degrades on these.
public struct OracleError: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

private func bdBin() -> String {
    resolveBin("bd", override: ProcessInfo.processInfo.environment["JUANCODE_BD_BIN"])
}

/// Fast, subprocess-free prep so the dock is usable immediately: create the
/// control dir, the dispatch mailbox, and (re)write the instructions. Throws only
/// if the directory itself can't be created. The slow tracker setup runs
/// separately in `ensureOracleTracker()`.
public func prepareOracleControlDir() throws {
    let fm = FileManager.default
    let dir = OraclePaths.controlDir
    do {
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    } catch {
        throw OracleError("Couldn't create Oracle control dir: \(error.localizedDescription)")
    }
    // Dispatch mailbox — an empty append-only log of OracleDispatch lines.
    if !fm.fileExists(atPath: OraclePaths.dispatchFile) {
        fm.createFile(atPath: OraclePaths.dispatchFile, contents: Data())
    }
    // Ask mailbox — an empty append-only log of OracleAsk lines (remote/MCP path).
    if !fm.fileExists(atPath: OraclePaths.askFile) {
        fm.createFile(atPath: OraclePaths.askFile, contents: Data())
    }
    // Instructions — rewritten every launch so the dispatch protocol stays current
    // even if it evolves across app versions.
    try? Data(oracleAgentsMarkdown.utf8).write(to: URL(fileURLWithPath: OraclePaths.agentsFile))
}

/// Ensure the control dir is a self-contained bd tracker (git repo + `.beads`,
/// prefix `oracle-`). Idempotent and best-effort — only runs the side-effecting
/// bits when their markers are absent. Slow, so callers run it off the dock's
/// ready gate.
///
/// `bd init` spawns a persistent `dolt sql-server` daemon that inherits the
/// child's stdout/stderr; if we captured those pipes directly the daemon would
/// hold them open and the call would stall until timeout. So bd commands that may
/// start the daemon run via `sh -c …` with output redirected to `/dev/null`,
/// detaching the daemon from our pipes — the call returns as soon as `bd` exits.
public func ensureOracleTracker() async {
    let fm = FileManager.default
    let dir = OraclePaths.controlDir

    // git init — bd persists its config in the repo; without it `bd create` fails.
    if !fm.fileExists(atPath: OraclePaths.gitDir) {
        _ = try? await ProcessRunner.capture(
            "sh", ["-c", "git init >/dev/null 2>&1 </dev/null"],
            cwd: dir, timeout: 20, maxBytes: 1 << 20)
    }

    // bd init — only when there's no tracker yet (it's a one-time setup).
    if !fm.fileExists(atPath: OraclePaths.beadsDir) {
        let bd = shellQuote(bdBin())
        _ = try? await ProcessRunner.capture(
            "sh", ["-c", "\(bd) init --prefix oracle >/dev/null 2>&1 </dev/null"],
            cwd: dir, timeout: 30, maxBytes: 1 << 20)
    }
}

/// Single-quote a path for safe embedding in an `sh -c` string.
private func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Append `value` as one JSON line to an append-only mailbox file. Shared by the
/// dispatch and ask mailboxes so both use one write path.
private func appendJSONLine<T: Encodable>(_ value: T, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    var line = try encoder.encode(value)
    line.append(0x0A) // newline
    let url = URL(fileURLWithPath: path)
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    } else {
        try line.write(to: url)
    }
}

/// Decode any complete JSON lines of `T` starting at byte `offset`, returning the
/// parsed values and the new offset to resume from. A trailing partial line (no
/// newline yet) is left unconsumed so a half-written append isn't misparsed.
/// Malformed lines are skipped (never throw) so one bad line can't wedge the tail.
/// A shrunken/rotated file resets the offset to the new end. Shared by both mailboxes.
private func readJSONL<T: Decodable>(_ type: T.Type, at path: String, since offset: Int) -> (items: [T], offset: Int) {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else { return ([], offset) }
    guard offset <= data.count else { return ([], data.count) } // file shrank/rotated
    let fresh = data.subdata(in: offset..<data.count)
    guard let lastNewline = fresh.lastIndex(of: 0x0A) else { return ([], offset) }
    let consumable = fresh.subdata(in: 0..<(lastNewline + 1))
    let decoder = JSONDecoder()
    var out: [T] = []
    for lineData in consumable.split(separator: 0x0A) where !lineData.isEmpty {
        if let d = try? decoder.decode(T.self, from: Data(lineData)) { out.append(d) }
    }
    return (out, offset + consumable.count)
}

/// Append a dispatch request as one JSON line to the mailbox. Used by the app's
/// own UI-initiated dispatch so it flows through the exact same path the agent
/// uses (single source of truth for "spawn an agent in a project").
public func appendOracleDispatch(_ dispatch: OracleDispatch) throws {
    try appendJSONLine(dispatch, to: OraclePaths.dispatchFile)
}

/// Decode any complete dispatch lines starting at byte `offset`. See `readJSONL`.
public func readOracleDispatches(since offset: Int) -> (dispatches: [OracleDispatch], offset: Int) {
    let r = readJSONL(OracleDispatch.self, at: OraclePaths.dispatchFile, since: offset)
    return (r.items, r.offset)
}

/// Append an ask as one JSON line to the ask mailbox. Used by the MCP sidecar to
/// hand the Oracle agent a question from a remote/phone client.
public func appendOracleAsk(_ ask: OracleAsk) throws {
    try appendJSONLine(ask, to: OraclePaths.askFile)
}

/// Decode any complete ask lines starting at byte `offset`. See `readJSONL`.
public func readOracleAsks(since offset: Int) -> (asks: [OracleAsk], offset: Int) {
    let r = readJSONL(OracleAsk.self, at: OraclePaths.askFile, since: offset)
    return (r.items, r.offset)
}

/// Persist the global state snapshot to `state.json` (pretty, stable key order) so
/// the Oracle agent can read it. Best-effort — failures are swallowed by callers.
public func writeOracleState(_ state: OracleState) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(state)
    try data.write(to: URL(fileURLWithPath: OraclePaths.stateFile))
}

/// Instructions written to the control dir's `AGENTS.md`, read by the Oracle CLI
/// agent on launch. Kept here (not a bundled resource) so it ships with the binary
/// and stays in lockstep with the dispatch protocol the app implements.
public let oracleAgentsMarkdown = """
# Oracle — global orchestrator

You are **Oracle**, a persistent agent operating at a GLOBAL level across every
juancode session and work dir. You are not scoped to one project. Your job is to
track cross-cutting work and dispatch agents into the projects where the work
actually happens.

## Dispatch by default — don't do project work yourself

You are an orchestrator, not a worker. Any task that touches a project's
code, files, tests, or git — anything that belongs inside a repo — you DISPATCH
to an agent in that project (see below). Do NOT read, edit, run, or investigate a
project's contents from here, even when it seems quick. Your hands stay on the
global tier: the `oracle-` tracker, `state.json`, cross-project reasoning, and
deciding what to dispatch where.

Do the work inline ONLY when there is genuinely no project to dispatch to —
i.e. the request is purely global (managing the `oracle-` tracker, summarizing
what's running, planning) OR no entry in `state.json`'s `projects` list matches
and the user can't name a path. In that last case, say so and ask for the path
rather than doing the work yourself in the wrong place.

When unsure whether something is "project work," assume it is and dispatch.

## On startup

When the user first speaks to you, orient yourself before answering: run
`bd ready` to see the current global work items and read `./state.json` to see
what agents are already running. Then tell them, briefly, what's on the board and
what you'd suggest tackling first.

## Your global tracker

This directory has its own `bd` (beads) tracker (prefix `oracle-`). Use it as a
GLOBAL notes/issue tracker — a single item may span one or more projects.

- `bd ready` / `bd list --json` — see global items.
- `bd create "Title" --description="…" -t task -p 1` — capture a new global item.
- A global item should link the per-project issues it spans by quoting their ids
  in its description (e.g. "covers juancode-eba, web-77"). The per-project
  trackers live in each repo's own `.beads/` and are owned by that project — read
  them by dispatching an agent there; don't edit them from here.

## Seeing what's running, and where you can dispatch

`state.json` (refreshed by the app) has two lists you need. `projects` is your
**dispatch address book** — every project you may target, with its absolute path,
whether or not it has a session yet. `sessions` is what's currently running.

```json
{ "updatedAt": 0,
  "workdirs": ["/abs/project"],
  "projects": [{ "path": "/abs/project", "name": "project", "active": true }],
  "sessions": [{ "id": "…", "title": "…", "cwd": "/abs/project",
                 "provider": "claude", "status": "running", "activity": "idle",
                 "live": true }] }
```

## Choosing the project to dispatch to

The `project` field of a dispatch MUST be the exact `path` of an entry in
`state.json`'s `projects` list. **Never invent, guess, or hand-construct a path** —
a wrong path silently fails or spawns an agent in the wrong place. Match the user's
words against the `name`/`path` of a listed project. If what they're asking for
isn't in the list, DON'T guess — tell them it's not a known project and ask for the
absolute path (then it'll appear once a session exists there).

## Dispatching agents into projects

To spin up (or seed) an agent in a project, append ONE JSON object per line to
`dispatch.jsonl`. The app tails this file and turns each new line into a real
juancode session in that project:

```jsonl
{"project":"/abs/path/to/repo","prompt":"Work on oracle-12: …","provider":"claude","worktree":false,"model":"opus"}
```

Fields: `project` (absolute path from the `projects` list, required), `prompt`
(required), `provider` (`"claude"` or `"codex"`, default claude), `worktree`
(default false — set true to isolate the agent in a fresh git worktree off the
project so parallel agents don't collide), `model` (optional — a model override
passed to the provider CLI, e.g. `"opus"`, `"sonnet"`, or a full model id; omit
to use the provider's default. Model names differ per provider — Claude takes
`"opus"`/`"sonnet"`, codex takes its own ids). Append with your file tools, e.g.:

```sh
echo '{"project":"/abs/repo","prompt":"…"}' >> dispatch.jsonl
```

One line per dispatch. After appending, tell the user what you dispatched and
where so they can watch it in the session list.
"""
