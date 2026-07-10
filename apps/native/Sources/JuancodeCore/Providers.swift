import Foundation

/// Mirrors `apps/server/src/providers.ts` + `resolveBin.ts`.
///
/// The prime directive: launch the genuine CLIs with their native config
/// UNTOUCHED. We never inject a shadow HOME/CODEX_HOME or override mcpServers, so
/// `~/.claude.json`, connectors, `~/.codex/config.toml` and project `.mcp.json`
/// load identically to running `claude`/`codex` yourself. The only args we pass
/// are a session-id pin (where supported) and an opt-in skip-permissions flag.

/// Per-session knobs that influence the spawned CLI's argv.
public struct SpawnOptions: Sendable, Equatable {
    /// Run the CLI in "accept all" mode — no permission/approval prompts.
    public var skipPermissions: Bool
    /// Pin the CLI to a specific model (e.g. "opus"). nil = the CLI's own
    /// default. Wired for both Claude and Codex via each CLI's `--model` flag
    /// (note the two CLIs accept different model names).
    public var model: String?
    public init(skipPermissions: Bool = false, model: String? = nil) {
        self.skipPermissions = skipPermissions
        self.model = model
    }
}

/// Pure description of how to launch/resume a provider. No binary resolution
/// here (that's `BinaryResolver`) so specs stay cheap and testable.
public struct ProviderSpec: Sendable {
    public let id: ProviderId
    public let label: String
    /// True when `startArgs` pins the CLI session id to our own UUID (Claude),
    /// so the resumable id is known immediately. False when it must be
    /// discovered from the CLI's session files after spawn (Codex).
    public let pinsSessionId: Bool
    /// Whether the program reads bracketed-paste markers (`ESC[200~ … ESC[201~`).
    /// Both claude and codex do; a future program that doesn't can opt out so the
    /// paste engine delivers raw text instead of wrapping it.
    public let bracketedPaste: Bool
    public let startArgs: @Sendable (_ juancodeId: String, _ opts: SpawnOptions) -> [String]
    public let resumeArgs: @Sendable (_ cliSessionId: String, _ opts: SpawnOptions) -> [String]

    public init(id: ProviderId,
                label: String,
                pinsSessionId: Bool,
                bracketedPaste: Bool = true,
                startArgs: @escaping @Sendable (_ juancodeId: String, _ opts: SpawnOptions) -> [String],
                resumeArgs: @escaping @Sendable (_ cliSessionId: String, _ opts: SpawnOptions) -> [String]) {
        self.id = id
        self.label = label
        self.pinsSessionId = pinsSessionId
        self.bracketedPaste = bracketedPaste
        self.startArgs = startArgs
        self.resumeArgs = resumeArgs
    }
}

public enum Providers {
    /// Claude's accept-all flag — applied ONLY when active. We deliberately do
    /// NOT pass `--allow-dangerously-skip-permissions` for non-bypass sessions:
    /// on real Claude builds it activates bypass and forces an interactive
    /// prompt, which breaks plain resume. So bypass is strictly opt-in.
    static func claudePermArgs(_ skip: Bool) -> [String] {
        skip ? ["--dangerously-skip-permissions"] : []
    }

    /// `--model <name>` when a model is pinned; empty otherwise.
    static func claudeModelArgs(_ model: String?) -> [String] {
        guard let model, !model.isEmpty else { return [] }
        return ["--model", model]
    }

    /// Codex's own `--model <name>` (a top-level flag valid for both the default
    /// interactive launch and `resume`). Empty when unpinned. Model *names* differ
    /// from Claude's (e.g. "o3"/"gpt-5", not "opus"/"sonnet"); we just forward
    /// whatever the dispatch specified and let codex validate it.
    static func codexModelArgs(_ model: String?) -> [String] {
        guard let model, !model.isEmpty else { return [] }
        return ["--model", model]
    }

    public static let claude = ProviderSpec(
        id: .claude,
        label: "Claude Code",
        pinsSessionId: true,
        // Pin the CLI session id to our own UUID so `--resume` revives this exact
        // conversation with no discovery step.
        startArgs: { juancodeId, opts in
            ["--session-id", juancodeId]
                + claudePermArgs(opts.skipPermissions)
                + claudeModelArgs(opts.model)
        },
        resumeArgs: { cliSessionId, opts in
            ["--resume", cliSessionId]
                + claudePermArgs(opts.skipPermissions)
                + claudeModelArgs(opts.model)
        }
    )

    public static let codex = ProviderSpec(
        id: .codex,
        label: "Codex",
        pinsSessionId: false,
        // Codex has no flag to pin a session id, so it starts clean; we discover
        // the id from its rollout file and resume with `codex resume <id>`.
        startArgs: { _, opts in
            (opts.skipPermissions ? ["--dangerously-bypass-approvals-and-sandbox"] : [])
                + codexModelArgs(opts.model)
        },
        resumeArgs: { cliSessionId, opts in
            ["resume"]
                + (opts.skipPermissions ? ["--dangerously-bypass-approvals-and-sandbox"] : [])
                + codexModelArgs(opts.model)
                + [cliSessionId]
        }
    )

    public static let all: [ProviderId: ProviderSpec] = [.claude: claude, .codex: codex]

    public static func spec(for id: ProviderId) -> ProviderSpec {
        switch id {
        case .claude: return claude
        case .codex: return codex
        }
    }
}

public func isProviderId(_ value: String) -> Bool {
    ProviderId(rawValue: value) != nil
}

// MARK: - Binary resolution

/// Resolves a provider to the absolute binary path to spawn. Pulled out of the
/// spec so tests can inject a fake (e.g. point at `/bin/cat`) without needing
/// claude/codex installed.
public protocol BinaryResolver: Sendable {
    func command(for provider: ProviderId) -> String
}

/// Resolve a CLI to the SAME absolute path the user's interactive terminal would.
///
/// A GUI/server process often has a different (or stripped) PATH than the user's
/// login shell, so we ask the login shell to resolve the command. Faithful
/// environment is the whole point — we never inject a shadow HOME/PATH.
public func resolveBin(_ cmd: String, override: String?) -> String {
    // An explicit override short-circuits before the cache, so a test can still
    // point a binary at a stub via its env var (`JUANCODE_*_BIN`) on any call.
    if let override, !override.isEmpty { return override }

    // Memoize the no-override resolution per command (juancode-8fp). The result is
    // stable for the process (PATH and the login shell don't change under us), and
    // the resolver is hit on every git/gh/bd spawn — without this, a Finder/stripped
    // -PATH launch pays the blocking `lookupViaLoginShell` probe below on every call,
    // which starves the concurrency pool when several spawns fan out at once.
    if let cached = resolveBinCache.get(cmd) { return cached }

    // Fast path: resolve against the inherited PATH directly, no subprocess. When
    // juancode is launched from a terminal it already has the user's full PATH, so
    // this finds claude/codex instantly — and avoids spawning the user's login
    // shell at all (a slow or hanging interactive rc must never wedge a spawn).
    // Fallback (e.g. launched from Finder with a stripped PATH): ask the login shell
    // where the command is, capped by a timeout so a slow/hanging rc can't block —
    // falling back to the bare name (execvp resolves it via PATH).
    let resolved = lookupInPath(cmd) ?? lookupViaLoginShell(cmd, timeout: 5) ?? cmd
    resolveBinCache.set(cmd, resolved)
    return resolved
}

/// Process-lifetime memo of `resolveBin`'s no-override results, keyed by command.
private let resolveBinCache = ResolveBinCache()

private final class ResolveBinCache: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: String] = [:]
    func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return map[key] }
    func set(_ key: String, _ value: String) { lock.lock(); map[key] = value; lock.unlock() }
}

/// Search the process's inherited `PATH` for an executable named `cmd`.
private func lookupInPath(_ cmd: String) -> String? {
    if cmd.contains("/") { return cmd } // already a path
    guard let path = ProcessInfo.processInfo.environment["PATH"], !path.isEmpty else { return nil }
    let fm = FileManager.default
    for dir in path.split(separator: ":") where !dir.isEmpty {
        let full = "\(dir)/\(cmd)"
        if fm.isExecutableFile(atPath: full) { return full }
    }
    return nil
}

/// Resolve `cmd` via the user's login+interactive shell (so `.zshrc` PATH edits
/// apply), bounded by `timeout` seconds. Returns nil on timeout/failure.
private func lookupViaLoginShell(_ cmd: String, timeout: TimeInterval) -> String? {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: shell)
    proc.arguments = ["-lic", "command -v \(cmd) 2>/dev/null"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    // Non-tty stdin so an interactive shell doesn't start its line editor (ZLE)
    // and grab the terminal.
    proc.standardInput = FileHandle.nullDevice

    let sem = DispatchSemaphore(value: 0)
    proc.terminationHandler = { _ in sem.signal() }
    do { try proc.run() } catch { return nil }

    if sem.wait(timeout: .now() + timeout) == .timedOut {
        proc.terminate()
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let out = String(data: data, encoding: .utf8) ?? ""
    let resolved = out
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .last { !$0.isEmpty }
    return (resolved?.hasPrefix("/") == true) ? resolved : nil
}

/// Resolve the configured editor (`Config.editor`, i.e. `JUANCODE_EDITOR`, default
/// nvim) into an absolute binary plus its leading args. The command string is split
/// naively on whitespace — enough for the common single-binary case and flags like
/// `"code -w"` — and the binary is resolved against the login-shell PATH (via
/// `resolveBin`) so a Finder-launched app still finds it.
public func resolveEditorCommand(_ raw: String = Config.editor) -> (executable: String, args: [String]) {
    let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    let cmd = parts.first ?? "nvim"
    return (resolveBin(cmd, override: nil), Array(parts.dropFirst()))
}

/// Default resolver honouring `JUANCODE_CLAUDE_BIN` / `JUANCODE_CODEX_BIN`.
public struct DefaultBinaryResolver: BinaryResolver {
    public init() {}
    public func command(for provider: ProviderId) -> String {
        let env = ProcessInfo.processInfo.environment
        switch provider {
        case .claude: return resolveBin("claude", override: env["JUANCODE_CLAUDE_BIN"])
        case .codex: return resolveBin("codex", override: env["JUANCODE_CODEX_BIN"])
        }
    }
}
