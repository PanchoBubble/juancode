import Darwin
import Foundation

/// Imports the user's login-shell environment into this process when the app was
/// NOT started from a terminal (juancode-aw7r).
///
/// A Dock/Finder/`launchd` launch hands the app launchd's session environment, which
/// on this machine is fourteen variables and `PATH=/usr/bin:/bin:/usr/sbin:/sbin`.
/// Every agent we spawn inherits that `environ` verbatim — which is the point, and
/// normally the whole value of the harness — so from the Dock the agents come up with
/// no Homebrew/nvm/pyenv on PATH and none of the API keys and MCP credentials the
/// user exports from `.zshrc`. That is what surfaced as "1 MCP server needs
/// authentication" on a Dock launch that works fine from a terminal. The visible half
/// of the same bug (no `TERM`, so monochrome agents) is already handled by
/// `PtyProcess.terminalEnv`.
///
/// The fix is to make this process's `environ` look like the terminal's before any
/// child is spawned: ask the login shell what it exports, once, and merge the answer
/// in. `setenv` is the right place to land it because everything downstream reads the
/// live process environment — `PtyProcess`'s `envp`, `Process()`'s inherited
/// environment for git/gh/bd, and `lookupInPath`'s PATH search — so one merge fixes
/// all of them without any component learning about this file.
///
/// Three things make it more than a one-liner, and each is answered below:
/// detection (`needsImport`), precedence (`plannedMerge` — an inherited value always
/// wins), and cost (the probe pays for the user's whole interactive `.zshrc`: 555ms
/// measured on a real Finder launch here, 1.5-5.1s standalone under load — so it runs
/// on a detached thread from the first line of app init and spawns wait on
/// `waitUntilReady` rather than the UI).
///
/// Secrets: the imported values pass from the probe pipe into `setenv` and are never
/// logged, persisted, or returned. Only variable NAMES ever reach the log.
public enum LoginEnvironment {
    /// What the import did, for a caller that wants to surface it.
    public enum Status: Sendable, Equatable {
        /// The process already has a shell's environment — nothing to import.
        case notNeeded
        /// The probe is running; `waitUntilReady` will block until it isn't.
        case pending
        /// Merged `added` variables in, and rewrote PATH if `rewrotePath`.
        case imported(added: Int, rewrotePath: Bool)
        /// The probe failed or timed out. The process keeps launchd's environment,
        /// so agents may be missing PATH entries and credentials.
        case failed(reason: String)
    }

    /// Names we never import, because they describe the *probe shell* or a terminal
    /// this process does not have — not the user's configuration.
    ///
    /// The shell bookkeeping (`_`, `SHLVL`, `PWD`, `OLDPWD`) would be actively
    /// misleading: `SHLVL` in particular is the marker `needsImport` reads, so
    /// importing it would make a second import decision lie. The terminal set
    /// (`TERM`, `COLORTERM`, `TERMINFO`, `LINES`, `COLUMNS`, `GPG_TTY`) describes the
    /// tty the probe inherited, and every juancode pty declares its own terminal in
    /// `PtyProcess.terminalEnv` anyway. `TMUX*` would tell a child it is inside a tmux
    /// pane that isn't there.
    static let neverImport: Set<String> = [
        "_", "SHLVL", "PWD", "OLDPWD",
        "TERM", "COLORTERM", "TERMINFO", "LINES", "COLUMNS", "GPG_TTY",
        "TMUX", "TMUX_PANE", "WINDOWID",
    ]

    /// Marker the probe prints before `env -0`, so a `.zshrc` that writes to stdout
    /// (a greeting, a version-manager notice) can't be parsed as an environment
    /// entry: everything up to and including the marker is discarded.
    static let marker = "__JUANCODE_ENV_BEGIN__"

    /// How long the probe gets before we give up on it.
    ///
    /// Measured on this machine: 555ms inside a real Finder launch, and standalone
    /// from a launchd-shaped environment 1.5-2.5s warm, 5.1s under load (the user's rc
    /// runs zinit, nvm, pyenv and rbenv). 20s is ~4x the worst measurement and matches
    /// the budget `locateBin`'s own interactive probe already uses for the same shell.
    static let probeTimeout: TimeInterval = 20

    /// Grace between SIGTERM and SIGKILL for a probe that blew the timeout — an rc
    /// that prompts for input or hangs on a network call.
    static let terminateGrace: TimeInterval = 2

    /// Default ceiling on `waitUntilReady`: the probe's own worst case plus its kill
    /// escalation, so a spawn can never wait longer than the probe can live.
    public static let waitBudget: TimeInterval = probeTimeout + terminateGrace + 1

    // MARK: - entry points

    /// Decide and, if needed, start the import. Returns immediately; idempotent.
    ///
    /// Call this as early as possible in app startup: everything between this call
    /// and the first spawn is time the probe gets for free.
    public static func importAtLaunch() {
        state.withLock { s in
            guard case .idle = s.phase else { return }  // already started
            guard needsImport() else {
                s.phase = .settled(.notNeeded)
                s.latch.signal()
                return
            }
            s.phase = .running
            // Detached, not a Task: this is a blocking pipe read with a hard timeout,
            // and it must not occupy a cooperative-pool thread for seconds while the
            // UI's own work is queued behind it.
            let t = Thread { runProbeAndMerge() }
            t.name = "juancode.login-env"
            t.stackSize = 512 * 1024
            t.start()
        }
    }

    /// Block until the import has settled, or `timeout` elapses.
    ///
    /// Called on the spawn path (see `PtyProcess.init`), never on the main actor's
    /// critical path to first paint. In practice this returns immediately: the probe
    /// starts at the top of app init and a session spawn is seconds later at the
    /// earliest. When it does wait, waiting is the correct trade — a session that
    /// starts 300ms late beats one whose agent has no credentials.
    public static func waitUntilReady(timeout: TimeInterval = LoginEnvironment.waitBudget) {
        let latch = state.withLock { s -> DispatchSemaphore? in
            // `.idle` means no import was ever started — a terminal launch, or any
            // process that isn't the app (the test bundle, juancode-serve). There is
            // nothing to wait for, and waiting would stall every spawn for the whole
            // budget.
            guard case .running = s.phase else { return nil }
            return s.latch
        }
        guard let latch else { return }
        let startedAt = Date()
        // The latch is signalled once and never reset, so re-signal after a
        // successful wait to keep it available to the next caller.
        let outcome = latch.wait(timeout: .now() + timeout)
        if outcome == .success { latch.signal() }
        // How long a spawn actually paid. Logged so the cost is measurable from a real
        // launch rather than argued about.
        NSLog("juancode: spawn waited \(elapsedMs(since: startedAt))ms for the "
              + "login-shell environment import (\(outcome == .success ? "settled" : "gave up"))")
    }

    /// What the import did. `.pending` while the probe is in flight.
    public static var status: Status {
        state.withLock { s in
            switch s.phase {
            case .idle, .running: return .pending
            case .settled(let st): return st
            }
        }
    }

    // MARK: - detection

    /// Whether this process needs the login shell's environment merged in.
    ///
    /// Two conditions, both required, because either alone has a false positive:
    ///
    /// 1. **No tty on any of stdin/stdout/stderr.** A `swift run juancode` or a
    ///    direct `./juancode` from a terminal has one; Dock, Finder, `open`, and
    ///    launchd have none. Alone this is not enough — see (2).
    /// 2. **No `SHLVL`.** Every shell exports `SHLVL` (login or not, interactive or
    ///    not), and launchd's session environment does not have it, so its presence
    ///    means *some shell was an ancestor that handed us its environment*. This is
    ///    the condition that matters, because `open -a` measurably propagates the
    ///    caller's full environment: launched from a terminal it has no tty (so (1)
    ///    alone would import) but already has the user's PATH and keys. It also makes
    ///    `juancode >log 2>&1 &` from a shell correctly skip the import.
    ///
    /// Measured, this machine: Finder launch → no tty, no `SHLVL`, 14 variables,
    /// `PATH=/usr/bin:/bin:/usr/sbin:/sbin` (import). `open -a` from a terminal → no
    /// tty, `SHLVL=3`, 100+ variables including the keys (skip).
    ///
    /// `JUANCODE_LOGIN_ENV=0` forces skip, `=1` forces import — the latter is how a
    /// terminal session reproduces the Dock path.
    static func needsImport(
        env: [String: String] = ProcessInfo.processInfo.environment,
        hasTTY: Bool = isatty(0) == 1 || isatty(1) == 1 || isatty(2) == 1
    ) -> Bool {
        switch (env["JUANCODE_LOGIN_ENV"] ?? "").trimmingCharacters(in: .whitespaces) {
        case "0", "false", "no": return false
        case "1", "true", "yes": return true
        default: break
        }
        if hasTTY { return false }
        return env["SHLVL"] == nil
    }

    // MARK: - merge

    /// The entries to `setenv`, given what this process has and what the login shell
    /// reports. Pure, so the precedence rule is testable without a shell.
    ///
    /// Precedence: **an inherited value always wins.** A variable this process was
    /// deliberately given (a launchd `TMPDIR`, a `JUANCODE_*` override on the command
    /// line, an `XPC_SERVICE_NAME`) is never replaced by the shell's idea of it. So
    /// the rule for everything except PATH is "set only what is missing".
    ///
    /// PATH is the one exception, and it has to be: launchd *does* set PATH, to a
    /// four-entry stub, so "set only what is missing" would leave the headline symptom
    /// unfixed. It is merged instead of replaced — the login shell's entries first, in
    /// its order (so a Homebrew `node` shadows `/usr/bin/node` exactly as it does in
    /// the user's terminal), then any entry we already had that the shell didn't
    /// mention. Nothing is ever dropped, and duplicates collapse.
    static func plannedMerge(current: [String: String], login: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (name, value) in login where !neverImport.contains(name) {
            guard name != "PATH" else { continue }
            if current[name] == nil { out[name] = value }
        }
        if let loginPath = login["PATH"], !loginPath.isEmpty {
            let merged = mergedPath(current: current["PATH"] ?? "", login: loginPath)
            if merged != current["PATH"] { out["PATH"] = merged }
        }
        return out
    }

    /// Login-shell entries first, then whatever we already had that they didn't cover.
    static func mergedPath(current: String, login: String) -> String {
        var seen = Set<String>()
        var dirs: [String] = []
        for dir in login.split(separator: ":") + current.split(separator: ":") {
            let d = String(dir)
            guard !d.isEmpty, seen.insert(d).inserted else { continue }
            dirs.append(d)
        }
        return dirs.joined(separator: ":")
    }

    /// Parse `env -0` output: NUL-separated `NAME=VALUE`, with everything up to and
    /// including `marker` discarded as possible rc chatter.
    ///
    /// Returns nil when the marker never appeared — the probe shell failed before it
    /// got to `env`, and a partial parse of whatever it did print would be worse than
    /// no import at all.
    static func parseProbeOutput(_ data: Data) -> [String: String]? {
        guard let markerData = (marker + "\0").data(using: .utf8),
              let range = data.range(of: markerData) else { return nil }
        var out: [String: String] = [:]
        for field in data[range.upperBound...].split(separator: 0) {
            guard let entry = String(data: field, encoding: .utf8),
                  let eq = entry.firstIndex(of: "="), eq != entry.startIndex else { continue }
            out[String(entry[entry.startIndex..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - probe

    private static func runProbeAndMerge() {
        let startedAt = Date()
        let outcome: Status
        switch probeLoginShell() {
        case .failure(let reason):
            outcome = .failed(reason: reason)
        case .success(let login):
            let plan = plannedMerge(current: ProcessInfo.processInfo.environment, login: login)
            // `setenv` is the whole point: it mutates this process's `environ`, which is
            // what every child inherits. Darwin's libc guards environ with a lock across
            // setenv/getenv, and `ProcessInfo.processInfo.environment` was measured to
            // read through to the mutation rather than serve a cached snapshot.
            for (name, value) in plan { setenv(name, value, 1) }
            outcome = .imported(added: plan.count, rewrotePath: plan["PATH"] != nil)
            // NAMES only. These values are the user's API keys and credentials; they
            // are never logged, written to disk, or handed back to a caller.
            let names = plan.keys.sorted().joined(separator: ", ")
            NSLog("juancode: imported login-shell environment in \(elapsedMs(since: startedAt))ms, "
                  + "\(plan.count) variable(s): \(names)")
        }
        if case .failed(let reason) = outcome {
            NSLog("""
                juancode: could not import the login-shell environment after \
                \(elapsedMs(since: startedAt))ms (\(reason)). \
                Agents spawned from this launch inherit launchd's PATH and may be \
                missing MCP credentials and API keys; relaunch from a terminal if so.
                """)
        }
        state.withLock { s in
            s.phase = .settled(outcome)
            s.latch.signal()
        }
    }

    private static func elapsedMs(since: Date) -> Int {
        Int((Date().timeIntervalSince(since) * 1000).rounded())
    }

    private enum ProbeResult {
        case success([String: String])
        case failure(String)
    }

    /// Ask the login shell for its exported environment.
    ///
    /// `-lic` — login AND interactive — is not optional, and that is what makes this
    /// expensive. Measured on this machine from a launchd-shaped environment,
    /// `zsh -lc` costs 10-50ms but reports 16 variables: no `ANTHROPIC_API_KEY`, no
    /// `PNPM_HOME`, no `NVM_BIN`, no `PYENV_ROOT`. Those are exported from `.zshrc`,
    /// which only `-i` sources, and they are exactly the credentials the ticket is
    /// about. `-lic` reports 54 and costs 1.5-5.1s.
    private static func probeLoginShell() -> ProbeResult {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-lic", "printf '\(marker)\\0'; env -0"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        // An rc that chatters or errors on stderr is not our problem, and we must not
        // let it fill a pipe we never read.
        proc.standardError = FileHandle.nullDevice
        // Non-tty stdin so an interactive shell doesn't start its line editor and try
        // to take a terminal, and so an rc that reads stdin gets EOF instead of hanging.
        proc.standardInput = FileHandle.nullDevice

        // Drain concurrently with the wait. Reading only after termination deadlocks
        // if the rc's output plus `env -0` exceeds the pipe buffer.
        let collected = Locked(Data())
        let reader = DispatchQueue(label: "juancode.login-env.read")
        let drained = DispatchSemaphore(value: 0)
        let handle = pipe.fileHandleForReading
        reader.async {
            let data = handle.readDataToEndOfFile()
            collected.withLock { $0 = data }
            drained.signal()
        }

        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        do { try proc.run() } catch { return .failure("could not start \(shell)") }

        if exited.wait(timeout: .now() + probeTimeout) == .timedOut {
            // An rc that prompts, hangs, or waits on the network. SIGTERM, then SIGKILL
            // if it ignores that, so the app never carries a wedged shell for its
            // lifetime. A process the rc itself forked is not chased — that is the
            // user's rc, not ours.
            let pid = proc.processIdentifier
            proc.terminate()
            if exited.wait(timeout: .now() + terminateGrace) == .timedOut, pid > 0 {
                kill(pid, SIGKILL)
                _ = exited.wait(timeout: .now() + terminateGrace)
            }
            return .failure("\(shell) -lic did not finish within \(Int(probeTimeout))s")
        }
        _ = drained.wait(timeout: .now() + 5)
        guard let login = parseProbeOutput(collected.withLock { $0 }) else {
            return .failure("\(shell) -lic produced no readable environment")
        }
        return .success(login)
    }

    // MARK: - state

    private enum Phase {
        case idle
        case running
        case settled(Status)
    }

    private struct State {
        var phase: Phase = .idle
        /// Signalled once, when `phase` becomes `.settled`.
        let latch = DispatchSemaphore(value: 0)
    }

    private static let state = Locked(State())
}

/// Minimal mutex box. `LoginEnvironment` runs before the app has an actor graph and
/// its barrier is called from synchronous spawn code, so it can't lean on isolation.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
