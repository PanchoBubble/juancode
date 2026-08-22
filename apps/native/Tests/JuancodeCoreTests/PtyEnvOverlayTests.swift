import Foundation
import Testing

@testable import JuancodeCore

/// The per-spawn environment overlay (`ProviderSpec.spawnEnv` → `PtyProcess`). Proves
/// the `execve` path really carries the entry, and that the default path still hands the
/// child the inherited environment untouched.
@Suite struct PtyEnvOverlayTests {
    /// Collects a pty's output until the child exits (or we run out of patience).
    private func run(_ args: [String], envOverrides: [String: String],
                     executable: String = "/usr/bin/env") async -> String {
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
            executable: executable,
            args: args,
            cwd: FileManager.default.temporaryDirectory.path,
            cols: 80,
            rows: 24,
            envOverrides: envOverrides,
            onData: { box.add($0) },
            onExit: { _ in box.finish() })
        #expect(proc != nil)
        // Wait for the child to have exited *and* for its dump to be in hand. Exit
        // alone is not enough: `onExit` comes off the waitpid thread and can beat the
        // last read, so the caller would parse a partial environment. The bound is
        // only here so a broken spawn fails instead of hanging — `/usr/bin/env sh -c
        // printf` answers in milliseconds on an idle machine — so it is generous:
        // under a full parallel suite a 5s bound handed these assertions an empty
        // string, which reads as "the overlay is broken" rather than "the child had
        // not run yet".
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !(box.isDone && !box.text.isEmpty) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(box.isDone, "the child never exited")
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

    /// The pty declares its own terminal type, whatever the app inherited. A
    /// Finder/Dock launch inherits none at all (launchd's environment has no `TERM`),
    /// and a CLI with no terminfo to find renders in monochrome — so this must hold
    /// with an empty overlay, not just alongside one.
    @Test func theChildAlwaysGetsATerminalType() async {
        let out = await run(["sh", "-c", #"printf %s "[$TERM][$COLORTERM]""#],
                           envOverrides: [:])
        #expect(out.contains("[xterm-256color][truecolor]"))
    }

    /// A bare command name is PATH-resolved in the parent so it execs through our
    /// envp; without that resolution it would fall back to `execvp` and lose the
    /// overlay — the monochrome bug again, for anything spawned by name.
    @Test func aBareCommandNameStillCarriesTheOverlay() async {
        let out = await run(["sh", "-c", #"printf %s "[$TERM]""#],
                           envOverrides: [:], executable: "env")
        #expect(out.contains("[xterm-256color]"))
    }
}
