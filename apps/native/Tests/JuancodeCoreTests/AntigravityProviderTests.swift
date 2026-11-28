import Foundation
import Testing

@testable import JuancodeCore

/// antigravity's launch contract (mirrors the ANTIGRAVITY arm of the daemon's
/// `provider.rs`): the CLI is `agy`, bypass rides `--dangerously-skip-permissions`,
/// resume is `--conversation <id>`, and the preset is `--agent` on start only.
@Suite struct AntigravityProviderTests {
    private let spec = Providers.spec(for: .antigravity)
    private let cid = "conv_agy"

    @Test func isReachableFromTheProviderRegistry() {
        #expect(ProviderId.allCases.contains(.antigravity))
        #expect(ProviderId(rawValue: "antigravity") == .antigravity)
        #expect(spec.id == .antigravity)
        #expect(Providers.all[.antigravity] != nil)
    }

    @Test func startsCleanBecauseTheConversationIdCannotBePinned() {
        #expect(!spec.pinsSessionId)
        #expect(spec.startArgs("our-uuid", SpawnOptions()) == [])
        #expect(spec.resumeArgs(cid, SpawnOptions()) == ["--conversation", cid])
    }

    @Test func bypassModelAndPresetRideTheirOwnFlagsAndThePresetIsStartOnly() {
        let opts = SpawnOptions(
            skipPermissions: true, model: "m", preset: Preset(name: "review", body: nil))
        #expect(
            spec.startArgs("x", opts)
                == ["--dangerously-skip-permissions", "--model", "m", "--agent", "review"])
        #expect(
            spec.resumeArgs(cid, opts)
                == ["--conversation", cid, "--dangerously-skip-permissions", "--model", "m"])
    }

    @Test func runsTheAgyBinary() {
        // `JUANCODE_ANTIGRAVITY_BIN` wins outright; otherwise the command is `agy`.
        setenv("JUANCODE_ANTIGRAVITY_BIN", "/nope/agy-stub", 1)
        defer { unsetenv("JUANCODE_ANTIGRAVITY_BIN") }
        #expect(DefaultBinaryResolver().command(for: .antigravity) == "/nope/agy-stub")
    }
}
