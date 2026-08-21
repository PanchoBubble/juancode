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
    /// Environment entries to overlay on the inherited environment for this spawn,
    /// for a knob a CLI exposes ONLY as an env var (opencode's bypass). Empty for
    /// every provider that has a flag — the prime directive still holds: we never
    /// inject a shadow HOME/CODEX_HOME/config path, and an empty overlay means the
    /// child inherits `environ` verbatim.
    public let spawnEnv: @Sendable (_ opts: SpawnOptions) -> [String: String]

    public init(id: ProviderId,
                label: String,
                pinsSessionId: Bool,
                bracketedPaste: Bool = true,
                startArgs: @escaping @Sendable (_ juancodeId: String, _ opts: SpawnOptions) -> [String],
                resumeArgs: @escaping @Sendable (_ cliSessionId: String, _ opts: SpawnOptions) -> [String],
                spawnEnv: @escaping @Sendable (_ opts: SpawnOptions) -> [String: String] = { _ in [:] }) {
        self.id = id
        self.label = label
        self.pinsSessionId = pinsSessionId
        self.bracketedPaste = bracketedPaste
        self.startArgs = startArgs
        self.resumeArgs = resumeArgs
        self.spawnEnv = spawnEnv
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

    /// opencode takes `-m provider/model` (e.g. "anthropic/claude-opus-4-6"), a
    /// different naming scheme again from Claude's and Codex's — forwarded as given.
    static func opencodeModelArgs(_ model: String?) -> [String] {
        guard let model, !model.isEmpty else { return [] }
        return ["--model", model]
    }

    public static let opencode = ProviderSpec(
        id: .opencode,
        label: "opencode",
        pinsSessionId: false,
        // `--session <id>` continues an EXISTING conversation only — there's no flag
        // to pin a new one — so a fresh session starts clean and we read the id it
        // created out of opencode's own database (see `OpencodeStore`).
        startArgs: { _, opts in opencodeModelArgs(opts.model) },
        resumeArgs: { cliSessionId, opts in
            ["--session", cliSessionId] + opencodeModelArgs(opts.model)
        },
        // opencode's TUI has no `--dangerously-skip-permissions` (only `opencode run`
        // does), so bypass rides on the env var its config layer reads. Set ONLY when
        // the session opted in; otherwise the overlay is empty and the child inherits
        // the environment untouched.
        spawnEnv: { opts in
            guard opts.skipPermissions else { return [:] }
            return ["OPENCODE_PERMISSION": #"{"edit":"allow","bash":"allow","webfetch":"allow"}"#]
        }
    )

    public static let all: [ProviderId: ProviderSpec] =
        [.claude: claude, .codex: codex, .opencode: opencode]

    public static func spec(for id: ProviderId) -> ProviderSpec {
        switch id {
        case .claude: return claude
        case .codex: return codex
        case .opencode: return opencode
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
    /// The absolute path when the CLI really exists, nil when every probe came up
    /// empty. `command(for:)` still answers with the bare name in that case (execvp
    /// may yet resolve it in the child), but a caller that would rather refuse the
    /// spawn than hand the user a dead pane asks this instead (juancode-meqj).
    ///
    /// Defaulted so a test's fake resolver — which points at a path it knows exists —
    /// stays valid without implementing it.
    func resolved(for provider: ProviderId) -> String?
}

public extension BinaryResolver {
    func resolved(for provider: ProviderId) -> String? { command(for: provider) }
}

/// Resolve a CLI to the SAME absolute path the user's interactive terminal would.
///
/// A GUI/server process often has a different (or stripped) PATH than the user's
/// login shell, so we ask the login shell to resolve the command. Faithful
/// environment is the whole point — we never inject a shadow HOME/PATH.
public func resolveBin(_ cmd: String, override: String?) -> String {
    locateBin(cmd, override: override) ?? cmd
}

/// The same resolution as `resolveBin`, but honest about failure: nil when no probe
/// found `cmd` anywhere. Callers that can't do anything useful with a bare name
/// (spawning an agent CLI) use this to fail fast with a real message instead of
/// letting `execvp` die inside a fresh pty (juancode-meqj).
public func locateBin(_ cmd: String, override: String?) -> String? {
    // An explicit override short-circuits before the cache, so a test can still
    // point a binary at a stub via its env var (`JUANCODE_*_BIN`) on any call.
    if let override, !override.isEmpty { return override }

    // Memoize the no-override resolution per command (juancode-8fp). The result is
    // stable for the process (PATH and the login shell don't change under us), and
    // the resolver is hit on every git/gh/bd spawn — without this, a Finder/stripped
    // -PATH launch pays the blocking shell probes below on every call, which starves
    // the concurrency pool when several spawns fan out at once.
    if let cached = resolveBinCache.get(cmd) { return cached }
    // A recent probe already came up empty. Report the miss again rather than
    // re-paying the shell round-trips; the cooldown expires so a binary installed
    // (or a shell that got faster) while the app runs still resolves.
    if resolveBinCache.inMissCooldown(cmd) { return nil }

    // Probes, cheapest first — each one alone is enough on some setup:
    //  1. the inherited PATH, no subprocess. A terminal-launched juancode already
    //     has the user's full PATH, so this hits instantly.
    //  2. `$SHELL -lc`: a login-but-not-interactive shell, so /etc/zprofile
    //     (path_helper, /etc/paths.d — where Homebrew registers itself) and
    //     .zprofile/.zshenv apply. Milliseconds on a normal setup.
    //  3. the well-known install dirs, no subprocess — covers a Homebrew/local
    //     install even when the shell probes are unavailable or slow.
    //  4. `$SHELL -lic`: the interactive shell, the only one that sees a PATH built
    //     in .zshrc. Last because it pays for the user's whole interactive rc —
    //     6s+ with a plugin-heavy zsh, which is exactly what used to time out and
    //     leave every `gh` call broken for the app's lifetime (juancode-z0c6).
    if let hit = lookupInPath(cmd)
        ?? lookupViaShell(cmd, interactive: false, timeout: 5)
        ?? lookupInWellKnownDirs(cmd)
        ?? lookupViaShell(cmd, interactive: true, timeout: 20) {
        resolveBinCache.set(cmd, hit)
        return hit
    }
    // Nothing found. Remember the miss only for the cooldown window: a probe can come
    // up empty for reasons that have nothing to do with the binary — a slow rc, a
    // transient spawn failure — and caching it for good would wedge every later call
    // until restart. `resolveBin` still degrades to the bare name so execvp gets a
    // last chance; `locateBin`'s nil is what lets a caller refuse the spawn instead.
    resolveBinCache.noteMiss(cmd)
    return nil
}

/// Process-lifetime memo of `resolveBin`'s no-override results, keyed by command.
private let resolveBinCache = ResolveBinCache()

/// Hits are cached for the process's lifetime; misses only for `missTTL`, so a
/// failed probe costs one cooldown window instead of the whole session.
final class ResolveBinCache: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: String] = [:]
    private var misses: [String: Date] = [:]
    private let missTTL: TimeInterval

    init(missTTL: TimeInterval = 60) { self.missTTL = missTTL }

    func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return map[key] }

    func set(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        map[key] = value
        misses[key] = nil
    }

    /// Record that every probe for `key` came up empty, just now.
    func noteMiss(_ key: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        misses[key] = now
    }

    /// Whether a miss for `key` is recent enough to skip re-probing.
    func inMissCooldown(_ key: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let at = misses[key] else { return false }
        let age = now.timeIntervalSince(at)
        // A backwards clock jump would otherwise pin the cooldown on forever.
        guard age >= 0 else { misses[key] = now; return true }
        if age >= missTTL { misses[key] = nil; return false }
        return true
    }
}

/// Where a Mac keeps user-installed CLIs, in the order a login shell would put
/// them on PATH. Probed directly so a stripped-PATH launch resolves `gh`/`claude`
/// without depending on a shell round-trip succeeding.
let wellKnownBinDirs: [String] = {
    let home = NSHomeDirectory()
    return [
        "/opt/homebrew/bin", "/opt/homebrew/sbin",  // Homebrew (Apple silicon)
        "/usr/local/bin",                           // Homebrew (Intel), manual installs
        "\(home)/.local/bin",                       // pipx, uv, hand-rolled
        "\(home)/.bun/bin", "\(home)/.cargo/bin", "\(home)/go/bin",
        "\(home)/.volta/bin", "\(home)/.npm-global/bin",
        "\(home)/.opencode/bin",                    // opencode's own installer

        "/opt/local/bin",                           // MacPorts
    ]
}()

/// Look for `cmd` in `dirs` (defaults to `wellKnownBinDirs`).
func lookupInWellKnownDirs(_ cmd: String, dirs: [String] = wellKnownBinDirs) -> String? {
    if cmd.contains("/") { return cmd }
    let fm = FileManager.default
    for dir in dirs {
        let full = "\(dir)/\(cmd)"
        if fm.isExecutableFile(atPath: full) { return full }
    }
    return nil
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

/// Resolve `cmd` by asking the user's shell, bounded by `timeout` seconds. Returns
/// nil on timeout/failure. `interactive` adds `-i`, which is what makes `.zshrc`
/// PATH edits visible — and what makes the probe cost the user's whole interactive
/// rc, so callers try the non-interactive form first.
private func lookupViaShell(_ cmd: String, interactive: Bool, timeout: TimeInterval) -> String? {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: shell)
    proc.arguments = [interactive ? "-lic" : "-lc", "command -v \(cmd) 2>/dev/null"]
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

/// The editor command string, from the one precedence every editor path shares:
/// `JUANCODE_EDITOR` (the knob `Config.editor` documents) wins, then the unix
/// `$VISUAL`/`$EDITOR` convention, then nvim. Blank values count as unset, so an
/// exported-but-empty `EDITOR` doesn't shadow the default.
public func editorCommandString(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    for key in ["JUANCODE_EDITOR", "VISUAL", "EDITOR"] {
        let value = (env[key] ?? "").trimmingCharacters(in: .whitespaces)
        if !value.isEmpty { return value }
    }
    return "nvim"
}

/// Resolve the editor command (see `editorCommandString`) into an absolute binary
/// plus its leading args. The command string is split naively on whitespace — enough
/// for the common single-binary case and flags like `"code -w"` — and the binary is
/// resolved against the login-shell PATH (via `resolveBin`) so a Finder-launched app
/// still finds it.
public func resolveEditorCommand(_ raw: String = editorCommandString()) -> (executable: String, args: [String]) {
    let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    let cmd = parts.first ?? "nvim"
    return (resolveBin(cmd, override: nil), Array(parts.dropFirst()))
}

/// Default resolver honouring `JUANCODE_CLAUDE_BIN` / `JUANCODE_CODEX_BIN` /
/// `JUANCODE_OPENCODE_BIN`.
public struct DefaultBinaryResolver: BinaryResolver {
    public init() {}

    /// The bare command name and its env override, per provider.
    private func spawnTarget(_ provider: ProviderId) -> (cmd: String, override: String?) {
        let env = ProcessInfo.processInfo.environment
        switch provider {
        case .claude: return ("claude", env["JUANCODE_CLAUDE_BIN"])
        case .codex: return ("codex", env["JUANCODE_CODEX_BIN"])
        case .opencode: return ("opencode", env["JUANCODE_OPENCODE_BIN"])
        }
    }

    public func command(for provider: ProviderId) -> String {
        let t = spawnTarget(provider)
        return resolveBin(t.cmd, override: t.override)
    }

    public func resolved(for provider: ProviderId) -> String? {
        let t = spawnTarget(provider)
        return locateBin(t.cmd, override: t.override)
    }
}
