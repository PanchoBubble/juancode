import Foundation
import Testing

@testable import JuancodeCore

/// opencode's launch contract: how its argv is built, how bypass reaches it (its own
/// `--auto` flag), and that an uninstallable CLI is reported rather than spawned.
@Suite struct OpencodeProviderTests {
    private let spec = Providers.spec(for: .opencode)

    @Test func isReachableFromTheProviderRegistry() {
        #expect(ProviderId.allCases.contains(.opencode))
        #expect(ProviderId(rawValue: "opencode") == .opencode)
        #expect(spec.id == .opencode)
        #expect(Providers.all[.opencode] != nil)
        // The TUI reads bracketed paste, like the others.
        #expect(spec.bracketedPaste)
    }

    @Test func startsCleanBecauseTheSessionIdCannotBePinned() {
        #expect(!spec.pinsSessionId)
        #expect(spec.startArgs("our-uuid", SpawnOptions()) == [])
        // Our own id must never leak into argv as if it were an opencode session id.
        #expect(!spec.startArgs("our-uuid", SpawnOptions()).contains("our-uuid"))
    }

    @Test func resumesWithTheSessionFlag() {
        #expect(spec.resumeArgs("ses_abc", SpawnOptions()) == ["--session", "ses_abc"])
    }

    @Test func forwardsThePinnedModelOnBothPaths() {
        let opts = SpawnOptions(model: "anthropic/claude-opus-4-6")
        #expect(spec.startArgs("id", opts) == ["--model", "anthropic/claude-opus-4-6"])
        #expect(spec.resumeArgs("ses_abc", opts)
            == ["--session", "ses_abc", "--model", "anthropic/claude-opus-4-6"])
        // An empty model is the same as none.
        #expect(spec.startArgs("id", SpawnOptions(model: "")) == [])
    }

    @Test func bypassRidesOnItsOwnFlagNotTheEnvironment() {
        // opencode's documented `--auto` ("auto-approve permissions that are not
        // explicitly denied") is how a bypass reaches it; the env-var indirection an
        // earlier revision used is gone, so the environment overlay is empty both
        // ways and the child inherits `environ` verbatim.
        #expect(spec.startArgs("id", SpawnOptions(skipPermissions: true)) == ["--auto"])
        #expect(spec.resumeArgs("ses_abc", SpawnOptions(skipPermissions: true))
            == ["--session", "ses_abc", "--auto"])
        // And without the opt-in none of it is asked for, nor `-y`'s ask-when-needed.
        #expect(spec.startArgs("id", SpawnOptions()) == [])
        #expect(spec.resumeArgs("ses_abc", SpawnOptions()) == ["--session", "ses_abc"])
    }

    @Test func noProviderOverlaysTheEnvironmentAnyMore() {
        for id in ProviderId.allCases {
            #expect(Providers.spec(for: id).spawnEnv(SpawnOptions()).isEmpty)
            #expect(Providers.spec(for: id)
                .spawnEnv(SpawnOptions(skipPermissions: true)).isEmpty)
        }
    }

    @Test func opencodesOwnInstallDirIsProbed() {
        // opencode installs to ~/.opencode/bin, which no login shell guarantees is on
        // PATH — a Finder-launched app has to find it without one.
        #expect(wellKnownBinDirs.contains("\(NSHomeDirectory())/.opencode/bin"))
        // kimi's own installer does the same thing under ~/.kimi-code/bin.
        #expect(wellKnownBinDirs.contains("\(NSHomeDirectory())/.kimi-code/bin"))
    }

    @Test func anUnfindableCliLocatesAsNilButStillResolvesToItsBareName() {
        let bogus = "juancode-definitely-not-a-real-binary-\(UUID().uuidString.prefix(6))"
        #expect(locateBin(bogus, override: nil) == nil)
        // resolveBin keeps its permissive contract for callers that want execvp to try.
        #expect(resolveBin(bogus, override: nil) == bogus)
        // An explicit override always wins, cache or no cache.
        #expect(locateBin(bogus, override: "/bin/cat") == "/bin/cat")
    }

    @Test func aMissingCliIsRefusedWithAMessageNamingTheProvider() {
        let error = SessionError.cliNotFound(provider: .opencode, command: "opencode")
        #expect("\(error)".contains("opencode"))
        #expect("\(error)".contains("JUANCODE_OPENCODE_BIN"))
    }
}
