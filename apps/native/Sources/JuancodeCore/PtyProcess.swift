import Darwin
import Foundation

/// Owns a real pty whose child is an UNMODIFIED CLI binary (claude/codex),
/// spawned via `forkpty` + `execvp`. Promoted from the u34.1 spike and the
/// node-pty replacement at the heart of u34.2.
///
/// `execvp` inherits the parent process's `environ` verbatim — we never build an
/// envp, never inject a shadow HOME/CODEX_HOME — so user-scope MCP, connectors
/// and CLI config resolve exactly as in a normal terminal. Env fidelity is true
/// by construction. The child `chdir`s into the session's cwd before exec.
///
/// Output bytes are handed to `onData` on a private serial queue; `Session` fans
/// them out to N subscribers. This is the seam that replaces node-pty's onData.
///
/// Exit is detected by a dedicated thread blocked in `waitpid` — authoritative
/// for any exit cause (natural or killed), and free of the races that dog a
/// kqueue process source or master-fd EOF under concurrent load. Kill is a
/// terminal hangup: we close the master fd (the slave then EOFs and the child
/// exits, exactly as when a terminal window closes) plus a graceful SIGTERM to
/// the process group for any child that doesn't exit on stdin EOF.
/// `@unchecked Sendable`: `masterFd`/`pid`/`queue`/`onData`/`onExit` are immutable
/// (`let`), and every mutable field (`readSource`, `exited`, `fdClosed`) is only
/// ever read or written on the serial `queue` — the read source, exit watcher,
/// `write`, and `terminate` all funnel their state access through it. That serial
/// confinement is the synchronization invariant, so the cross-thread captures
/// below (`[weak self]` from the waitpid thread / dispatch closures) are sound.
public final class PtyProcess: @unchecked Sendable {
    public let masterFd: Int32
    public let pid: pid_t

    private let onData: @Sendable ([UInt8]) -> Void
    private let onExit: @Sendable (Int32) -> Void
    private var readSource: DispatchSourceRead?
    private let queue: DispatchQueue
    private var exited = false
    private var fdClosed = false

    public init?(
        executable: String,
        args: [String],
        cwd: String,
        cols: Int,
        rows: Int,
        queue: DispatchQueue = DispatchQueue(label: "juancode.pty"),
        onData: @escaping @Sendable ([UInt8]) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        self.onData = onData
        self.onExit = onExit
        self.queue = queue

        // CRITICAL: build every C string in the PARENT, before forkpty. fork() in
        // a multithreaded process leaves the child able to call only async-signal-
        // safe functions until exec — malloc/ARC/String bridging are NOT safe and
        // will deadlock if another thread held the allocator lock at fork time.
        // So the child below touches only chdir/execvp/_exit on pre-built buffers.
        let argvStrings = [executable] + args
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: argvStrings.count + 1)
        for (i, s) in argvStrings.enumerated() { argv[i] = strdup(s) }
        argv[argvStrings.count] = nil
        let cExecutable = strdup(executable)
        let cCwd: UnsafeMutablePointer<CChar>? = cwd.isEmpty ? nil : strdup(cwd)

        var master: Int32 = 0
        var winp = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)

        let childPid = forkpty(&master, nil, nil, &winp)
        if childPid < 0 {
            perror("forkpty")
            return nil
        }

        if childPid == 0 {
            // ---- child ---- (async-signal-safe calls only)
            if let cCwd { _ = chdir(cCwd) }
            execvp(cExecutable, argv)
            _exit(127)
        }

        // ---- parent ----
        // The child got copies of these via fork; free our originals.
        for i in 0..<argvStrings.count { free(argv[i]) }
        argv.deallocate()
        free(cExecutable)
        if let cCwd { free(cCwd) }

        self.masterFd = master
        self.pid = childPid
        Self.disableSuspendChar(master)
        startReading()
        startExitWatch()
    }

    /// Disable the terminal's SUSP control char (Ctrl-Z) on the pty's line
    /// discipline, so Ctrl-Z can never raise `SIGTSTP` and suspend the agent.
    ///
    /// We are a terminal emulator with no job-control shell behind the pty — the CLI
    /// (claude/codex) is the foreground process directly. A `SIGTSTP` therefore just
    /// stops it with nothing to resume it, freezing the session ("Ctrl-Z borks it").
    /// During normal TUI operation the agent runs in raw mode (`ISIG` off) where
    /// Ctrl-Z is already an inert byte; disabling SUSP here also covers the
    /// cooked-mode windows (boot, tool shell-outs) where `ISIG` is on. The agent
    /// saves/restores this termios, so the disable sticks across its own mode flips.
    private static func disableSuspendChar(_ fd: Int32) {
        var tio = termios()
        guard tcgetattr(fd, &tio) == 0 else { return }
        withUnsafeMutablePointer(to: &tio.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VSUSP)] = 0xff  // _POSIX_VDISABLE — disable Ctrl-Z
            }
        }
        _ = tcsetattr(fd, TCSANOW, &tio)
    }

    private func startReading() {
        let fd = masterFd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                self.onData(Array(buf[0..<n]))
            } else {
                // EOF/EIO: nothing more to read. Stop reading (which closes the
                // fd via the cancel handler). Exit itself is reported by the
                // waitpid thread, not from here.
                self.readSource?.cancel()
            }
        }
        // Closing the monitored fd must happen in the cancel handler (the only
        // safe place once a dispatch source owns it).
        src.setCancelHandler { [weak self] in self?.closeFd() }
        readSource = src
        src.resume()
    }

    /// Authoritative exit detection: one thread blocked in waitpid. Returns for
    /// any exit cause, reaps the zombie, then reports on the work queue.
    private func startExitWatch() {
        let pid = self.pid
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            while true {
                let r = waitpid(pid, &status, 0)
                if r == pid { break }
                if r == -1 && errno != EINTR { break } // ECHILD etc.
            }
            // Copy to a `let` so the `@Sendable` queue closure captures an
            // immutable value rather than the mutated `var`.
            let finalStatus = status
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self else { return }
                self.finish(finalStatus)
            }
        }
    }

    private func finish(_ status: Int32) {
        guard !exited else { return }
        exited = true
        readSource?.cancel() // closes the master fd via the cancel handler
        let code = WIFEXITED(status) ? WEXITSTATUS(status) : -1
        onExit(code)
    }

    private func closeFd() {
        guard !fdClosed else { return }
        fdClosed = true
        close(masterFd)
    }

    /// Keystrokes / paste -> child stdin. Safe to call from any thread.
    public func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let fd = masterFd
        queue.async { [weak self] in
            guard let self, !self.fdClosed else { return }
            _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        }
    }

    /// Propagate a view resize into the pty so the CLI re-lays out its TUI.
    ///
    /// `TIOCSWINSZ` is supposed to raise `SIGWINCH` on the slave's foreground
    /// process group, but in practice that delivery isn't reliable here (the CLI
    /// then never re-lays-out and stays stuck at its boot-time size on every
    /// resize). The child is its own session/group leader after `forkpty`
    /// (`login_tty` → `setsid`), so we send `SIGWINCH` to its group explicitly —
    /// idempotent with whatever the kernel does, and what actually makes claude/codex
    /// repaint when you drag the window or a panel.
    ///
    /// Returns whether the grid actually took: after setting it we read the winsize
    /// back (`TIOCGWINSZ`) and confirm it matches (juancode-uz6). A closed master
    /// (the child exited) makes both ioctls fail, so a `false` return tells the
    /// caller the resize never landed instead of it silently trusting a size the
    /// pty never adopted.
    @discardableResult
    public func resize(cols: Int, rows: Int) -> Bool {
        guard cols > 0, rows > 0, !fdClosed else { return false }
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(masterFd, TIOCSWINSZ, &ws) == 0 else { return false }
        _ = killpg(pid, SIGWINCH)
        var got = winsize()
        guard ioctl(masterFd, TIOCGWINSZ, &got) == 0 else { return false }
        return got.ws_col == UInt16(cols) && got.ws_row == UInt16(rows)
    }

    /// Hang up: send a graceful SIGTERM to the group and close the master so the
    /// slave EOFs and the child exits (the universal "terminal closed" path,
    /// reliable even for a shell blocked on a foreground child). The waitpid
    /// thread then reports the exit.
    public func terminate() {
        queue.async { [weak self] in
            guard let self, !self.exited else { return }
            _ = killpg(self.pid, SIGTERM)
            self.readSource?.cancel() // cancel handler closes the master fd
            // Escalate: a shell (or any child) blocked on a foreground child can
            // defer SIGTERM and won't always exit on terminal hangup, so force it
            // down if it hasn't gone away shortly after. Real CLIs exit on the
            // SIGTERM above well before this fires.
            self.queue.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
                guard let self, !self.exited else { return }
                _ = killpg(self.pid, SIGKILL)
                _ = kill(self.pid, SIGKILL)
            }
        }
    }
}

// POSIX wait-status macros aren't imported into Swift; reimplement the two we use.
@inline(__always) private func WIFEXITED(_ status: Int32) -> Bool {
    (status & 0x7f) == 0
}
@inline(__always) private func WEXITSTATUS(_ status: Int32) -> Int32 {
    (status >> 8) & 0xff
}
