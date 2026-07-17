import XCTest
@testable import JuancodeServices

final class ProcessRunnerTests: XCTestCase {
    func testCapturesStdout() async throws {
        let r = try await ProcessRunner.run("/bin/echo", ["hello world"])
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .newlines), "hello world")
        XCTAssertTrue(r.ok)
    }

    func testCaptureReturnsNonZeroWithoutThrowing() async throws {
        let r = try await ProcessRunner.capture("/bin/sh", ["-c", "echo out; echo err 1>&2; exit 3"])
        XCTAssertEqual(r.exitCode, 3)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .newlines), "out")
        XCTAssertEqual(r.stderr.trimmingCharacters(in: .newlines), "err")
        XCTAssertFalse(r.ok)
    }

    func testRunThrowsOnNonZeroExit() async {
        do {
            _ = try await ProcessRunner.run("/bin/sh", ["-c", "exit 1"])
            XCTFail("expected throw")
        } catch let e as ProcessError {
            XCTAssertEqual(e.code, 1)
            XCTAssertFalse(e.launchFailed)
            XCTAssertFalse(e.timedOut)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testLaunchFailureForMissingBinary() async {
        do {
            _ = try await ProcessRunner.run("/no/such/binary-xyz", [])
            XCTFail("expected throw")
        } catch let e as ProcessError {
            XCTAssertTrue(e.launchFailed)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testBareCommandResolvesViaPath() async throws {
        // No leading slash → resolved through /usr/bin/env against inherited PATH.
        let r = try await ProcessRunner.run("echo", ["hi"])
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .newlines), "hi")
    }

    func testTimeoutTerminates() async {
        do {
            _ = try await ProcessRunner.run("/bin/sh", ["-c", "sleep 5"], timeout: 0.2)
            XCTFail("expected timeout")
        } catch let e as ProcessError {
            XCTAssertTrue(e.timedOut)
        } catch { XCTFail("wrong error: \(error)") }
    }

    /// A child that exits but leaves a backgrounded descendant holding the stdout
    /// pipe open must still resolve promptly on the child's exit — not stall waiting
    /// for an EOF that the leaked descendant will never send (the git background
    /// `maintenance`/`gc --auto` stall class). `timeout` here is longer than the
    /// post-termination grace but far shorter than the leaked child's lifetime, so a
    /// regression would surface as a `timedOut` failure instead of a clean success.
    func testResolvesWhenDescendantHoldsPipeOpen() async throws {
        let r = try await ProcessRunner.run(
            "/bin/sh", ["-c", "echo hi; sleep 3 &"], timeout: 2.0)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .newlines), "hi")
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertTrue(r.ok)
    }

    func testStdinIsForwarded() async throws {
        let r = try await ProcessRunner.run("/bin/cat", [], stdin: "piped input")
        XCTAssertEqual(r.stdout, "piped input")
    }

    func testCwdIsApplied() async throws {
        let r = try await ProcessRunner.run("/bin/pwd", [], cwd: "/tmp")
        // /tmp is a symlink to /private/tmp on macOS; just assert it resolved somewhere.
        XCTAssertTrue(r.stdout.contains("tmp"))
    }

    func testEnvironmentIsInherited() async throws {
        setenv("JUANCODE_TEST_VAR", "inherited-value", 1)
        defer { unsetenv("JUANCODE_TEST_VAR") }
        let r = try await ProcessRunner.run("/bin/sh", ["-c", "printf %s \"$JUANCODE_TEST_VAR\""])
        XCTAssertEqual(r.stdout, "inherited-value")
    }

    /// Every run must release its pipe fds. Before the fix, `Handles.finish` nil-ed
    /// the readabilityHandler but never closed the read handle, and the pipe
    /// write-ends were never closed, so each call leaked ~2-4 fds — the poll-loop
    /// exhaustion that made forkpty fail "Too many open files" (juancode-nft0).
    /// Assert the process fd count doesn't grow across many runs (with/without stdin).
    func testDoesNotLeakFileDescriptors() async throws {
        // Warm up so one-time allocations don't count as growth.
        for _ in 0..<5 { _ = try await ProcessRunner.run("/bin/echo", ["warmup"]) }
        let before = Self.openFdCount()
        for i in 0..<60 {
            _ = try await ProcessRunner.run("/bin/echo", ["\(i)"])
            _ = try await ProcessRunner.run("/bin/cat", [], stdin: "s\(i)")
        }
        let after = Self.openFdCount()
        // A leak would add hundreds; allow a small slack for lazy runtime fds.
        XCTAssertLessThan(after - before, 16, "fd count grew from \(before) to \(after)")
    }

    /// Count this process's open fds by listing `/dev/fd`.
    private static func openFdCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }
}
