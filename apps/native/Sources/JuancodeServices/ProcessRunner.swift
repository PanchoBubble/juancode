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

        func drain(_ pipe: Pipe, appendingTo append: @escaping @Sendable (Data) -> Void) {
            group.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    group.leave()
                } else {
                    ioQueue.sync { append(chunk) }
                }
            }
        }
        drain(outPipe) { d in if box.out.count < maxBytes { box.out.append(d) } }
        drain(errPipe) { d in if box.err.count < maxBytes { box.err.append(d) } }

        let state = ResultState()
        proc.terminationHandler = { p in
            group.notify(queue: ioQueue) {
                state.finishOnce {
                    completion(.success(ProcessResult(
                        stdout: String(decoding: box.out, as: UTF8.self),
                        stderr: String(decoding: box.err, as: UTF8.self),
                        exitCode: p.terminationStatus
                    )))
                }
            }
        }

        do {
            try proc.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            state.finishOnce {
                completion(.failure(ProcessError(code: -1, stdout: "", stderr: "\(error)",
                                                 launchFailed: true, timedOut: false)))
            }
            return
        }

        if let stdin, let inPipe {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        if timeout > 0 {
            ioQueue.asyncAfter(deadline: .now() + timeout) {
                guard !state.isFinished else { return }
                proc.terminate()
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
