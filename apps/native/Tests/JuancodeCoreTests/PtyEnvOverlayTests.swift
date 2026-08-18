import Foundation
import Testing

@testable import JuancodeCore

/// The per-spawn environment overlay (`ProviderSpec.spawnEnv` → `PtyProcess`). Proves
/// the `execve` path really carries the entry, and that the default path still hands the
/// child the inherited environment untouched.
@Suite struct PtyEnvOverlayTests {
    /// Collects a pty's output until the child exits (or we run out of patience).
    private func run(_ args: [String], envOverrides: [String: String]) async -> String {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var bytes = [UInt8]()
            private var done = false
            func add(_ b: [UInt8]) { lock.withLock { bytes += b } }
            func finish() { lock.withLock { done = true } }
            var isDone: Bool { lock.withLock { done } }
            var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
        }
        let box = Box()
        let proc = PtyProcess(
            executable: "/usr/bin/env",
            args: args,
            cwd: FileManager.default.temporaryDirectory.path,
            cols: 80,
            rows: 24,
            envOverrides: envOverrides,
            onData: { box.add($0) },
            onExit: { _ in box.finish() })
        #expect(proc != nil)
        let deadline = Date().addingTimeInterval(5)
        while !box.isDone, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return box.text
    }

    @Test func anOverlayEntryReachesTheChild() async {
        let out = await run(["sh", "-c", "printf %s \"$OPENCODE_PERMISSION\""],
                           envOverrides: ["OPENCODE_PERMISSION": #"{"edit":"allow"}"#])
        #expect(out.contains(#"{"edit":"allow"}"#))
    }

    @Test func theRestOfTheEnvironmentSurvivesTheOverlay() async {
        // PATH is inherited, not replaced — the overlay is a merge, and losing PATH
        // would break every tool the agent shells out to.
        let out = await run(["sh", "-c", "printf %s \"$PATH\""],
                           envOverrides: ["JUANCODE_OVERLAY_PROBE": "1"])
        #expect(!out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func withNoOverlayTheChildIsNotGivenTheVariable() async {
        let out = await run(["sh", "-c", "printf %s \"[$OPENCODE_PERMISSION]\""],
                           envOverrides: [:])
        #expect(out.contains("[]"))
    }
}
