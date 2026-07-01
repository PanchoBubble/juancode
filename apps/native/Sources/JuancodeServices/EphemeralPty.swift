import Foundation
import JuancodeCore

/// An ephemeral pty: the user's real editor on one file, or a plain interactive
/// shell. Mirrors `editor.ts` (`EditorPty`) + `terminal.ts` (`ShellPty`). Unlike
/// a `Session` it is never persisted, titled, or resumed — it lives only while
/// its pane is open, so the editor/shell loads the user's genuine config + env
/// (inherited verbatim via `PtyProcess`'s `forkpty`+`execvp`) exactly as a normal
/// terminal would. Output is fanned out as raw bytes, like `Session`.
public final class EphemeralPty: @unchecked Sendable {
    public typealias OutputListener = @Sendable (_ bytes: [UInt8]) -> Void
    public typealias ExitListener = @Sendable (_ exitCode: Int?) -> Void

    public let id = UUID().uuidString.lowercased()

    private let lock = NSLock()
    private var proc: PtyProcess?
    private var outputListeners: [Int: OutputListener] = [:]
    private var exitListeners: [Int: ExitListener] = [:]
    private var nextToken = 0
    private var alive = true
    /// Capped scrollback so a late/re-attaching view repaints history. Without it,
    /// switching sessions tears down the bottom panel's terminal view and the fresh
    /// one re-attaches to this still-alive pty showing nothing. (Mirrors `Session`.)
    private var scroll = Scrollback(limit: Config.scrollbackLimit)

    /// Spawn `executable` with `args` in `cwd`. Returns nil if `forkpty` fails.
    init?(executable: String, args: [String], cwd: String, cols: Int, rows: Int) {
        guard let proc = PtyProcess(
            executable: executable, args: args, cwd: cwd, cols: cols, rows: rows,
            onData: { [weak self] bytes in self?.emitOutput(bytes) },
            onExit: { [weak self] code in self?.handleExit(code) }
        ) else { return nil }
        self.proc = proc
    }

    private func emitOutput(_ bytes: [UInt8]) {
        let listeners = lock.withLock { () -> [OutputListener] in
            scroll.append(bytes)
            return Array(outputListeners.values)
        }
        for l in listeners { l(bytes) }
    }

    private func handleExit(_ code: Int32) {
        lock.withLock { alive = false }
        for l in lock.withLock({ Array(exitListeners.values) }) { l(Int(code)) }
    }

    public func write(_ bytes: [UInt8]) {
        if lock.withLock({ alive }) { proc?.write(bytes) }
    }

    public func write(_ text: String) { write(Array(text.utf8)) }

    /// Resize the pty grid; returns whether it reached the live pty (juancode-uz6).
    @discardableResult
    public func resize(cols: Int, rows: Int) -> Bool {
        guard cols > 0, rows > 0, lock.withLock({ alive }) else { return false }
        return proc?.resize(cols: cols, rows: rows) ?? false
    }

    public func kill() {
        if lock.withLock({ alive }) { proc?.terminate() }
    }

    /// Subscribe to output bytes. With `replay: true` (default) the current
    /// scrollback is delivered immediately so a re-attaching view repaints history;
    /// registration + snapshot happen atomically so no byte is dropped or doubled.
    @discardableResult
    public func onOutput(replay: Bool = true, _ listener: @escaping OutputListener) -> () -> Void {
        let (token, replayBytes): (Int, [UInt8]) = lock.withLock {
            let t = nextToken; nextToken += 1
            outputListeners[t] = listener
            return (t, replay ? scroll.replay : [])
        }
        if replay && !replayBytes.isEmpty { listener(replayBytes) }
        return { [weak self] in self?.lock.withLock { _ = self?.outputListeners.removeValue(forKey: token) } }
    }

    @discardableResult
    public func onExit(_ listener: @escaping ExitListener) -> () -> Void {
        let token = lock.withLock { () -> Int in
            let t = nextToken; nextToken += 1
            exitListeners[t] = listener
            return t
        }
        return { [weak self] in self?.lock.withLock { _ = self?.exitListeners.removeValue(forKey: token) } }
    }
}

public enum EphemeralPtyError: Error {
    case spawnFailed
    case outsideWorkingDir
}

/// Resolve the editor command from `$VISUAL`/`$EDITOR`, defaulting to nvim.
/// These may carry args (e.g. "code -w"); split naively — good enough for the
/// common single-binary case and the nvim default. Mirrors `editorCommand()`.
func editorCommand(env: [String: String] = ProcessInfo.processInfo.environment) -> (cmd: String, args: [String]) {
    let raw = (env["VISUAL"] ?? env["EDITOR"] ?? "nvim").trimmingCharacters(in: .whitespaces)
    let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    return (parts.first ?? "nvim", Array(parts.dropFirst()))
}

/// Resolve the interactive shell from `$SHELL`, defaulting to zsh, launched `-i`
/// so it sources the user's rc files. Mirrors `shellCommand()`.
func shellCommand(env: [String: String] = ProcessInfo.processInfo.environment) -> (cmd: String, args: [String]) {
    let cmd = (env["SHELL"] ?? "/bin/zsh").trimmingCharacters(in: .whitespaces)
    return (cmd.isEmpty ? "/bin/zsh" : cmd, ["-i"])
}

/// Holds live ephemeral ptys (editors + shell terminals) for the process
/// lifetime. Mirrors the `editors` / `terminals` registries; combined here since
/// they share identical lifetime + lookup semantics. The server addresses these
/// by id over the same input/resize/kill/output/exit messages as real sessions.
public final class EphemeralPtyRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var ptys: [String: EphemeralPty] = [:]

    public init() {}

    /// Spawn an editor on `file`, confined to `cwd` so a client can't escape it.
    public func openEditor(cwd: String, file: String, cols: Int, rows: Int) throws -> EphemeralPty {
        let root = URL(fileURLWithPath: cwd).standardizedFileURL
        let full = URL(fileURLWithPath: file, relativeTo: root).standardizedFileURL
        guard full.path == root.path || full.path.hasPrefix(root.path + "/") else {
            throw EphemeralPtyError.outsideWorkingDir
        }
        let (cmd, args) = editorCommand()
        guard let pty = EphemeralPty(executable: cmd, args: args + [full.path],
                                     cwd: root.path, cols: cols, rows: rows) else {
            throw EphemeralPtyError.spawnFailed
        }
        track(pty)
        return pty
    }

    /// Spawn an interactive shell in `cwd`.
    public func openTerminal(cwd: String, cols: Int, rows: Int) throws -> EphemeralPty {
        let (cmd, args) = shellCommand()
        guard let pty = EphemeralPty(executable: cmd, args: args, cwd: cwd, cols: cols, rows: rows) else {
            throw EphemeralPtyError.spawnFailed
        }
        track(pty)
        return pty
    }

    private func track(_ pty: EphemeralPty) {
        lock.withLock { ptys[pty.id] = pty }
        pty.onExit { [weak self, weak pty] _ in
            guard let self, let pty else { return }
            self.lock.withLock { _ = self.ptys.removeValue(forKey: pty.id) }
        }
    }

    public func get(_ id: String) -> EphemeralPty? {
        lock.withLock { ptys[id] }
    }

    public func killAll() {
        for p in lock.withLock({ Array(ptys.values) }) { p.kill() }
    }
}
