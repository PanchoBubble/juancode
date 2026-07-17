import Foundation

/// Captured result of a finished child process.
public struct ProcessResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public var ok: Bool { exitCode == 0 }

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode
    }
}

/// Mirrors how a failed `execFile(...)` rejects in the Node services: carries the
/// exit code, captured streams, and the two flags callers branch on (binary not
/// found → ENOENT, and timeout).
public struct ProcessError: Error, Sendable {
    public let code: Int32
    public let stdout: String
    public let stderr: String
    /// The executable couldn't be launched at all (≈ Node's `code === "ENOENT"`).
    public let launchFailed: Bool
    public let timedOut: Bool

    public var message: String {
        if launchFailed { return "command not found" }
        if timedOut { return "command timed out" }
        let s = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "exited with code \(code)" : s
    }
}

/// Faithful `execFile` replacement for the auxiliary services (juancode-u34.6):
/// run a binary with args in a cwd, capture stdout/stderr, with a timeout — and
/// crucially **inherit the parent environment untouched** (the prime directive),
/// so git/gh/bd/claude resolve the same config they would in the user's terminal.
public enum ProcessRunner {
    /// Default cap on captured output, mirroring the services' `maxBuffer`.
    public static let defaultMaxBytes = 16 * 1024 * 1024

    /// Run and return the result regardless of exit code. Throws `ProcessError`
    /// only when the process can't be launched or exceeds `timeout`.
    public static func capture(
        _ executable: String,
        _ args: [String],
        cwd: String? = nil,
        timeout: TimeInterval = 60,
        stdin: String? = nil,
        maxBytes: Int = defaultMaxBytes
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { cont in
            run(executable, args, cwd: cwd, timeout: timeout, stdin: stdin, maxBytes: maxBytes) { result in
                cont.resume(with: result)
            }
        }
    }

    /// Run and require success: returns the result on a zero exit, otherwise
    /// throws `ProcessError` (matching how `execFile` rejects on non-zero exit).
    @discardableResult
    public static func run(
        _ executable: String,
        _ args: [String],
        cwd: String? = nil,
        timeout: TimeInterval = 60,
        stdin: String? = nil,
        maxBytes: Int = defaultMaxBytes
    ) async throws -> ProcessResult {
        let result = try await capture(executable, args, cwd: cwd, timeout: timeout, stdin: stdin, maxBytes: maxBytes)
        guard result.ok else {
            throw ProcessError(code: result.exitCode, stdout: result.stdout, stderr: result.stderr,
                               launchFailed: false, timedOut: false)
        }
        return result
    }

    // MARK: - core

    private static func run(
        _ executable: String,
        _ args: [String],
        cwd: String?,
        timeout: TimeInterval,
        stdin: String?,
        maxBytes: Int,
        completion: @escaping @Sendable (Result<ProcessResult, Error>) -> Void
    ) {
        let proc = Process()
        // Absolute paths run directly; bare command names go through `/usr/bin/env`
        // so PATH is searched against the inherited environment (like execFile).
        if executable.hasPrefix("/") {
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = args
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [executable] + args
        }
        if let cwd, !cwd.isEmpty { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        // Leave `proc.environment` nil → the child inherits our environment verbatim.

        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        let inPipe: Pipe? = stdin != nil ? Pipe() : nil
        if let inPipe { proc.standardInput = inPipe }

        // Accumulate both streams on a private queue to avoid pipe-buffer deadlock.
        let ioQueue = DispatchQueue(label: "juancode.process.io")
        let box = Box()
        let group = DispatchGroup()
        let handles = Handles(out: outPipe.fileHandleForReading, err: errPipe.fileHandleForReading)
        let exit = ExitBox()

        func drain(_ isOut: Bool, appendingTo append: @escaping @Sendable (Data) -> Void) {
            group.enter()
            (isOut ? handles.out : handles.err).readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    // EOF: every write end of this stream is closed.
                    if handles.finish(isOut) { group.leave() }
                } else {
                    ioQueue.sync { append(chunk) }
                }
            }
        }
        drain(true) { d in if box.out.count < maxBytes { box.out.append(d) } }
        drain(false) { d in if box.err.count < maxBytes { box.err.append(d) } }

        // Gate completion on the process terminating too, so the exit code is
        // captured before we resolve (an EOF can otherwise be observed first).
        group.enter()

        let state = ResultState()
        group.notify(queue: ioQueue) {
            state.finishOnce {
                completion(.success(ProcessResult(
                    stdout: String(decoding: box.out, as: UTF8.self),
                    stderr: String(decoding: box.err, as: UTF8.self),
                    exitCode: exit.code
                )))
            }
        }

        proc.terminationHandler = { p in
            exit.code = p.terminationStatus
            group.leave() // balances the process-lifetime `enter` above
            // The child is gone. Give the drains a brief grace to flush whatever is
            // still buffered, then force each stream closed regardless of EOF: a
            // detached descendant (e.g. git's background `maintenance`/`gc --auto`)
            // can inherit our pipe fds and never close them, so waiting for EOF
            // would stall us until `timeout`.
            ioQueue.asyncAfter(deadline: .now() + 0.2) {
                if handles.finish(true) { group.leave() }
                if handles.finish(false) { group.leave() }
            }
        }

        do {
            try proc.run()
        } catch {
            handles.finish(true)
            handles.finish(false)
            state.finishOnce {
                completion(.failure(ProcessError(code: -1, stdout: "", stderr: "\(error)",
                                                 launchFailed: true, timedOut: false)))
            }
            return
        }

        // Drop our copies of the pipe write-ends now the child owns its own (dup'd
        // at spawn). Otherwise the parent stays a writer, the read ends never EOF,
        // and both fds leak — over a long run that exhausts the fd table until the
        // next forkpty fails "Too many open files" (juancode-nft0). inPipe's writer
        // is closed below, after stdin is fed.
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        if let stdin, let inPipe {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        if timeout > 0 {
            ioQueue.asyncAfter(deadline: .now() + timeout) {
                guard !state.isFinished else { return }
                proc.terminate()
                handles.finish(true)
                handles.finish(false)
                state.finishOnce {
                    completion(.failure(ProcessError(
                        code: -1,
                        stdout: String(decoding: box.out, as: UTF8.self),
                        stderr: String(decoding: box.err, as: UTF8.self),
                        launchFailed: false, timedOut: true)))
                }
            }
        }
    }

    private final class Box: @unchecked Sendable {
        var out = Data()
        var err = Data()
    }

    /// Child exit status, captured by the termination handler and read once the
    /// process is confirmed gone. Locked so the read in `group.notify` can't race
    /// the write in `terminationHandler`.
    private final class ExitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int32 = -1
        var code: Int32 {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    /// Owns the two read handles and guarantees each stream is torn down (reader
    /// cancelled, fd closed, `DispatchGroup` signalled) exactly once — whether
    /// that's driven by a real EOF, the post-termination grace, or the timeout.
    /// Prevents an unbalanced `group.leave()` while letting us force-close a stream
    /// whose write end a leaked child still holds open.
    private final class Handles: @unchecked Sendable {
        private let lock = NSLock()
        let out: FileHandle
        let err: FileHandle
        private var outDone = false
        private var errDone = false
        init(out: FileHandle, err: FileHandle) { self.out = out; self.err = err }

        /// Cancel a stream's reader once. Returns true only on the first call for
        /// that stream, so the caller balances its `group.enter()` exactly once.
        @discardableResult
        func finish(_ isOut: Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if isOut {
                if outDone { return false }
                outDone = true
                out.readabilityHandler = nil
                // Nil-ing the handler cancels the dispatch source but does NOT free
                // the fd — FileHandle only releases it on close/dealloc. Close it
                // here or the read-end leaks on every run (juancode-nft0).
                try? out.close()
                return true
            } else {
                if errDone { return false }
                errDone = true
                err.readabilityHandler = nil
                try? err.close()
                return true
            }
        }
    }

    private final class ResultState: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var isFinished = false
        func finishOnce(_ body: () -> Void) {
            lock.lock()
            if isFinished { lock.unlock(); return }
            isFinished = true
            lock.unlock()
            body()
        }
    }
}
