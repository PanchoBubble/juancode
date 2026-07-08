import Darwin
import Foundation
import os

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
/// (`let`), and every mutable field (`readSource`, `exited`, `fdClosed`,
/// `pendingWrites`, `flushScheduled`) is only ever read or written on the serial
/// `queue` — the read source, exit watcher, `write`, and `terminate` all funnel
/// their state access through it. That serial confinement is the synchronization
/// invariant, so the cross-thread captures below (`[weak self]` from the waitpid
/// thread / dispatch closures) are sound.
public final class PtyProcess: @unchecked Sendable {
    public let masterFd: Int32
    public let pid: pid_t

    private let onData: @Sendable ([UInt8]) -> Void
    private let onExit: @Sendable (Int32) -> Void
    private var readSource: DispatchSourceRead?
    private let queue: DispatchQueue
    private var exited = false
    private var fdClosed = false
    /// Flipped true the instant the waitpid thread reaps the child — independent of
    /// the serial `queue`, so the off-queue kill path in `terminate()` can tell a
    /// live child (safe to signal) from a reaped one (whose pid may be recycled)
    /// even when `queue` is wedged and `exited`/`finish()` haven't run yet.
    private let reaped = OSAllocatedUnfairLock(initialState: false)

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
        // Non-blocking master. Writes must NEVER block: the write path shares the
        // serial `queue` with the read source, so a write blocked on a full pty
        // input buffer (child busy repainting, not draining stdin) starves our
        // reads, the child then blocks writing its own output, never returns to
        // read stdin, and both sides deadlock permanently — the frozen session at
        // claude's options menu (juancode-3mg). With O_NONBLOCK the write returns
        // EAGAIN instead and the pending buffer retries (see `flushPendingWrites`),
        // while reads keep draining so the child can always make progress.
        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
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
            } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                // The master is O_NONBLOCK (see init): a spurious readability
                // wakeup drains to EAGAIN. Not EOF — wait for the next event.
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
            // Mark reaped at the true reap moment, before hopping to `queue` — so a
            // concurrent `terminate()` escalation never signals a recycled pid, and
            // so it stops escalating even if `queue` is wedged and `finish()` is
            // still pending.
            self.reaped.withLock { $0 = true }
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
        failPendingWrites()
    }

    /// Keystrokes / paste -> child stdin. Safe to call from any thread.
    public func write(_ bytes: [UInt8]) {
        write(bytes) { _ in }
    }

    /// Write `bytes`, invoking `completion(true)` on the work queue once the whole
    /// buffer has flushed to the child (or `completion(false)` if the fd is closed
    /// or the write errored). Chunks are queued FIFO and flushed with non-blocking
    /// writes — a full pty input buffer (child not draining stdin) parks the
    /// remainder in `pendingWrites` for a short retry instead of blocking the
    /// serial queue, which would starve the read source and deadlock against a
    /// child blocked on its own output (juancode-3mg). Short writes / `EINTR` are
    /// looped over so a large chunk is never silently truncated. Lets a chunked
    /// paste apply backpressure: the next chunk waits for this one to flush
    /// instead of piling a giant buffer onto a possibly-stalled pty.
    public func write(_ bytes: [UInt8], completion: @escaping @Sendable (Bool) -> Void) {
        guard !bytes.isEmpty else { completion(true); return }
        queue.async { [weak self] in
            guard let self, !self.fdClosed else { completion(false); return }
            self.pendingWrites.append(PendingWrite(bytes: bytes, completion: completion))
            self.flushPendingWrites()
        }
    }

    /// One queued input chunk: `offset` tracks partial-flush progress across
    /// EAGAIN retries. Confined to `queue`.
    private struct PendingWrite {
        let bytes: [UInt8]
        var offset = 0
        let completion: @Sendable (Bool) -> Void
    }

    /// Input chunks not yet fully flushed to the child, FIFO. Confined to `queue`.
    private var pendingWrites: [PendingWrite] = []
    /// True while an EAGAIN retry is scheduled, so a burst of writes arms one
    /// retry rather than one per chunk. Confined to `queue`.
    private var flushScheduled = false

    /// Flush queued chunks to the (non-blocking) master in order. On EAGAIN —
    /// pty input buffer full, child not reading right now — keep the remainder
    /// and retry shortly; the queue stays free so reads keep draining, which is
    /// exactly what lets the child make progress and empty the input buffer.
    /// On a hard error (EIO after exit) fail everything queued.
    private func flushPendingWrites() {
        enum Outcome { case flushed, wouldBlock, failed }
        while !pendingWrites.isEmpty {
            guard !fdClosed else { failPendingWrites(); return }
            var entry = pendingWrites[0]
            let outcome: Outcome = entry.bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return .flushed }
                while entry.offset < raw.count {
                    let n = Darwin.write(masterFd, base + entry.offset, raw.count - entry.offset)
                    if n > 0 {
                        entry.offset += n
                    } else if n < 0 && errno == EINTR {
                        continue
                    } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                        return .wouldBlock
                    } else {
                        return .failed
                    }
                }
                return .flushed
            }
            switch outcome {
            case .flushed:
                pendingWrites.removeFirst()
                entry.completion(true)
            case .wouldBlock:
                pendingWrites[0].offset = entry.offset // keep partial progress
                scheduleFlushRetry()
                return
            case .failed:
                failPendingWrites()
                return
            }
        }
    }

    /// Re-attempt the flush after a short beat. 15ms is far below human input
    /// cadence (a stalled paste chunk resumes imperceptibly) yet coarse enough
    /// not to spin while the child is busy.
    private func scheduleFlushRetry() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(15)) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            self.flushPendingWrites()
        }
    }

    /// The fd is gone (or errored): every queued chunk's completion gets a
    /// definitive `false` so no paste-backpressure waiter hangs forever.
    private func failPendingWrites() {
        let pending = pendingWrites
        pendingWrites = []
        for entry in pending { entry.completion(false) }
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

    /// The grid the pty has actually applied (`TIOCGWINSZ` readback). Lets a
    /// client verify its surface grid against the pty's real one and repair only
    /// on true drift, instead of nudging blindly. Nil when the master is closed
    /// or the ioctl fails.
    public func currentGrid() -> (cols: Int, rows: Int)? {
        guard !fdClosed else { return nil }
        var ws = winsize()
        guard ioctl(masterFd, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 else { return nil }
        return (cols: Int(ws.ws_col), rows: Int(ws.ws_row))
    }

    /// Hang up: send a graceful SIGTERM to the group and close the master so the
    /// slave EOFs and the child exits (the universal "terminal closed" path,
    /// reliable even for a shell blocked on a foreground child). The waitpid
    /// thread then reports the exit.
    ///
    /// The kill signals are delivered OFF the serial `queue` as defense in depth:
    /// writes are non-blocking now (juancode-3mg — a blocking write once wedged
    /// `queue` behind a child that stopped draining stdin, so "Kill Agent did
    /// nothing"), but signaling directly costs nothing and keeps kill working even
    /// if the queue is ever busy or stalled for another reason. `killpg`/`kill`
    /// are thread-safe. Killing the group makes the master EIO once every slave
    /// fd is gone, the read source EOFs, and the waitpid thread reports the exit.
    public func terminate() {
        // Already reaped: pid may be recycled — never signal it.
        guard !reaped.withLock({ $0 }) else { return }
        _ = killpg(pid, SIGTERM)
        // Escalate on a dedicated thread, NOT on `queue` (which may be wedged): a
        // child stuck such that SIGTERM can't unwind it still dies on SIGKILL.
        // Skipped if the child was reaped in the meantime (recycled-pid guard).
        Thread.detachNewThread { [weak self] in
            Thread.sleep(forTimeInterval: 0.2)
            guard let self, !self.reaped.withLock({ $0 }) else { return }
            _ = killpg(self.pid, SIGKILL)
            _ = kill(self.pid, SIGKILL)
        }
        // Healthy-queue path (unchanged for the common case): close the master so
        // a child blocked on stdin EOFs out gracefully. When the queue is wedged
        // this simply doesn't run; the SIGKILL escalation above covers that case.
        queue.async { [weak self] in
            guard let self, !self.exited else { return }
            self.readSource?.cancel() // cancel handler closes the master fd
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
