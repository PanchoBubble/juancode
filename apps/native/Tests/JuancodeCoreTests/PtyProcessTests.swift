import Foundation
import Testing
@testable import JuancodeCore

/// Pty input/output plumbing, and the juancode-3mg deadlock regression: writes
/// must never block the serial queue the read source runs on, or a child that's
/// busy writing output (and momentarily not reading stdin) deadlocks the whole
/// session — the frozen pane at claude's interactive options menu.
@Suite struct PtyProcessTests {
    /// Thread-safe output sink for the pty's background onData callback.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var exitCode: Int32?
        func add(_ n: Int) { lock.withLock { count += n } }
        func exited(_ code: Int32) { lock.withLock { exitCode = code } }
        var bytesSeen: Int { lock.withLock { count } }
        var didExit: Bool { lock.withLock { exitCode != nil } }
    }

    private func poll(_ timeout: TimeInterval = 5.0, _ cond: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cond()
    }

    private func spawn(_ script: String, into out: Collector) -> PtyProcess? {
        PtyProcess(
            executable: "/bin/sh", args: ["-c", script], cwd: "/", cols: 80, rows: 24,
            onData: { bytes in out.add(bytes.count) },
            onExit: { code in out.exited(code) }
        )
    }

    /// juancode-3mg: a child that floods output and NEVER reads stdin must not
    /// wedge the session when we flood input at it. With the old blocking write,
    /// the pty input buffer (~1KB) filled, `Darwin.write` blocked the serial
    /// queue, the read source starved, and output stopped forever. Non-blocking
    /// writes park the input and reads keep draining.
    @Test func inputFloodDoesNotStarveReadsWhenChildIgnoresStdin() async throws {
        let out = Collector()
        // Raw mode, like the agent TUIs: unread input accumulates in the slave's
        // raw queue until the master write EAGAINs (cooked mode would silently
        // discard past the canonical limit and never exercise the parked path).
        let proc = try #require(spawn("stty raw -echo; while :; do echo tick; done", into: out))
        defer { proc.terminate() }

        // Let the child start streaming.
        #expect(await poll { out.bytesSeen > 0 })

        // Flood stdin well past the kernel pty input buffer. Fire-and-forget:
        // the child never reads, so these can never fully flush — the point is
        // that queuing them must not stop the output side.
        let junk = [UInt8](repeating: UInt8(ascii: "x"), count: 4096)
        for _ in 0..<16 { proc.write(junk) }

        // Output must keep flowing AFTER the input flood is queued.
        let baseline = out.bytesSeen
        let stillStreaming = await poll { out.bytesSeen > baseline + 10_000 }
        #expect(stillStreaming, "read side starved after input flood — write path is blocking the pty queue")

        proc.terminate()
        #expect(await poll { out.didExit })
    }

    /// The paste-backpressure contract: a chunk a healthy child actually drains
    /// completes `true`, in order.
    @Test func writeCompletionFiresWhenChildDrainsStdin() async throws {
        let out = Collector()
        let proc = try #require(spawn("cat >/dev/null", into: out))
        defer { proc.terminate() }

        let done = Collector()
        proc.write(Array("hello\n".utf8)) { ok in done.add(ok ? 1 : -1) }
        #expect(await poll { done.bytesSeen == 1 })

        proc.terminate()
        #expect(await poll { out.didExit })
    }

    /// juancode-1qf: fds above the pty stdio must NOT leak into the CLI child.
    /// The embedded server's 127.0.0.1:4280 NIO listen socket used to survive in a
    /// still-alive child and block the next app launch from rebinding. Open a pipe
    /// in the parent (an inheritable fd >= 3), then prove the forkpty child cannot
    /// write into it — the write end is closed before `execvp`.
    @Test func childDoesNotInheritParentFileDescriptors() async throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let readEnd = fds[0], writeEnd = fds[1]
        defer { close(readEnd); close(writeEnd) }
        #expect(writeEnd >= 3) // an inheritable fd above stdio

        // Non-blocking read end so the post-run check can't hang.
        let rflags = fcntl(readEnd, F_GETFL, 0)
        _ = fcntl(readEnd, F_SETFL, rflags | O_NONBLOCK)

        let out = Collector()
        // If the child still holds the inherited fd, `printf x >&N` writes 'x' into
        // the parent's pipe and prints LEAKED; otherwise the redirect fails (Bad
        // file descriptor, swallowed) and it prints SEALED.
        let script = "if printf x >&\(writeEnd) 2>/dev/null; then printf LEAKED; else printf SEALED; fi"
        let proc = try #require(spawn(script, into: out))
        defer { proc.terminate() }

        #expect(await poll { out.didExit })

        // Authoritative check: did anything reach the parent's pipe?
        var buf = [UInt8](repeating: 0, count: 8)
        let n = read(readEnd, &buf, buf.count)
        #expect(n <= 0, "forkpty child inherited and wrote to the parent's pipe fd — fd leaked into the CLI child")
    }

    /// Chunks still parked when the pty dies must complete `false` — a paste
    /// waiting on backpressure would otherwise hang forever.
    @Test func pendingWritesFailOnTerminate() async throws {
        let out = Collector()
        // Raw mode (see above), and the child never reads stdin — input past the
        // kernel's raw queue stays parked in pendingWrites. The READY echo is a
        // handshake: without it the write below races ahead of `stty raw`, lands
        // while the tty is still cooked, and gets discarded instead of parked.
        let proc = try #require(spawn("stty raw -echo; echo READY; exec sleep 300", into: out))
        #expect(await poll { out.bytesSeen >= 5 })

        let done = Collector()
        let junk = [UInt8](repeating: UInt8(ascii: "x"), count: 256 * 1024)
        proc.write(junk) { ok in done.add(ok ? 1 : -1) }
        // Give the flush a beat to hit EAGAIN and park before killing the pty.
        try? await Task.sleep(nanoseconds: 100_000_000)

        proc.terminate()
        #expect(await poll { out.didExit })
        // Completion must resolve (false) rather than hang.
        #expect(await poll { done.bytesSeen != 0 })
        #expect(done.bytesSeen == -1)
    }
}
