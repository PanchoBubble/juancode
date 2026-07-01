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
    /// default. Currently only wired for Claude (`--model`).
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
    public let startArgs: @Sendable (_ juancodeId: String, _ opts: SpawnOptions) -> [String]
    public let resumeArgs: @Sendable (_ cliSessionId: String, _ opts: SpawnOptions) -> [String]
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
            opts.skipPermissions ? ["--dangerously-bypass-approvals-and-sandbox"] : []
        },
        resumeArgs: { cliSessionId, opts in
            ["resume"]
                + (opts.skipPermissions ? ["--dangerously-bypass-approvals-and-sandbox"] : [])
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
    if let override, !override.isEmpty { return override }

    // Fast path: resolve against the inherited PATH directly, no subprocess. When
    // juancode is launched from a terminal it already has the user's full PATH, so
    // this finds claude/codex instantly — and avoids spawning the user's login
    // shell at all (a slow or hanging interactive rc must never wedge a spawn).
    if let direct = lookupInPath(cmd) { return direct }

    // Fallback (e.g. launched from Finder with a stripped PATH): ask the login
    // shell where the command is, but cap it with a timeout so a slow/hanging rc
    // can't block — falling back to the bare name (execvp resolves it via PATH).
    if let viaShell = lookupViaLoginShell(cmd, timeout: 5) { return viaShell }

    return cmd
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
