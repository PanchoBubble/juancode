import Foundation
import Testing

@testable import JuancodeCore

/// opencode's launch contract: how its argv is built, how bypass reaches it (an env
/// var, not a flag), and that an uninstallable CLI is reported rather than spawned.
@Suite struct OpencodeProviderTests {
    private let spec = Providers.spec(for: .opencode)

    @Test func isReachableFromTheProviderRegistry() {
        #expect(ProviderId.allCases.contains(.opencode))
        #expect(ProviderId(rawValue: "opencode") == .opencode)
        #expect(spec.id == .opencode)
        #expect(Providers.all[.opencode] != nil)
        // The TUI reads bracketed paste, like the other two.
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

    @Test func bypassRidesOnTheEnvironmentBecauseTheTuiHasNoFlag() {
        // Without bypass: no overlay at all, so the child inherits `environ` verbatim.
        #expect(spec.spawnEnv(SpawnOptions()).isEmpty)
        #expect(spec.startArgs("id", SpawnOptions(skipPermissions: true)) == [])

        let overlay = spec.spawnEnv(SpawnOptions(skipPermissions: true))
        #expect(overlay.count == 1)
        let json = overlay["OPENCODE_PERMISSION"] ?? ""
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        #expect(parsed?["edit"] == "allow")
        #expect(parsed?["bash"] == "allow")
    }

    @Test func theOtherProvidersOverlayNothing() {
        for id in [ProviderId.claude, .codex] {
            #expect(Providers.spec(for: id).spawnEnv(SpawnOptions()).isEmpty)
            #expect(Providers.spec(for: id).spawnEnv(SpawnOptions(skipPermissions: true)).isEmpty)
        }
    }

    @Test func opencodesOwnInstallDirIsProbed() {
        // opencode installs to ~/.opencode/bin, which no login shell guarantees is on
        // PATH — a Finder-launched app has to find it without one.
        #expect(wellKnownBinDirs.contains("\(NSHomeDirectory())/.opencode/bin"))
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
