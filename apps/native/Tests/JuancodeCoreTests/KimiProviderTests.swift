import Foundation
import Testing

@testable import JuancodeCore

/// kimi's launch contract (mirrors the KIMI arm of the daemon's `provider.rs` and
/// its parity expectations): bypass rides kimi's own `--auto` flag — "Never Ask
/// mode", deliberately not `-y/--yolo`'s ask-when-needed — the preset is `--agent`
/// on start only (kimi forbids `--agent` + `--session`), and the conversation id is
/// read out of kimi's own session store (`KimiStore`).
@Suite struct KimiProviderTests {
    private let spec = Providers.spec(for: .kimi)
    private let sid = "ses_kimi"

    @Test func isReachableFromTheProviderRegistry() {
        #expect(ProviderId.allCases.contains(.kimi))
        #expect(ProviderId(rawValue: "kimi") == .kimi)
        #expect(spec.id == .kimi)
        #expect(spec.label == "Kimi Code")
        #expect(Providers.all[.kimi] != nil)
        // The TUI reads bracketed paste, like the others.
        #expect(spec.bracketedPaste)
    }

    @Test func startsCleanBecauseTheSessionIdCannotBePinned() {
        #expect(!spec.pinsSessionId)
        #expect(spec.startArgs("our-uuid", SpawnOptions()) == [])
        // Our own id must never leak into argv as if it were a kimi session id.
        #expect(!spec.startArgs("our-uuid", SpawnOptions()).contains("our-uuid"))
    }

    @Test func resumesWithTheSessionFlagOnly() {
        // kimi's resume is the id plus the session's mode/model; nothing else rides,
        // so a bare resume is just the flag-and-id.
        #expect(spec.resumeArgs(sid, SpawnOptions()) == ["--session", sid])
    }

    @Test func autoApproveRidesOnItsOwnFlag() {
        // `--auto` is kimi's Never Ask mode — a session that opted out of prompts
        // wants that, not `-y`/`--yolo`'s "ask when needed".
        #expect(spec.startArgs("our-uuid", SpawnOptions(skipPermissions: true)) == ["--auto"])
        #expect(spec.resumeArgs(sid, SpawnOptions(skipPermissions: true))
            == ["--session", sid, "--auto"])
        // And without the opt-in none of it is asked for.
        let plain = SpawnOptions()
        for args in [spec.startArgs("our-uuid", plain), spec.resumeArgs(sid, plain)] {
            for flag in ["--auto", "--yolo", "-y"] {
                #expect(!args.contains(flag), "\(args) carries \(flag)")
            }
        }
    }

    @Test func forwardsThePinnedModelOnBothPaths() {
        #expect(spec.startArgs("id", SpawnOptions(model: "kimi-k2"))
            == ["--model", "kimi-k2"])
        // Order matches the daemon's argv exactly: permission mode, then model.
        #expect(
            spec.startArgs("id", SpawnOptions(skipPermissions: true, model: "kimi-k2"))
                == ["--auto", "--model", "kimi-k2"])
        #expect(spec.resumeArgs(sid, SpawnOptions(model: "kimi-k2"))
            == ["--session", sid, "--model", "kimi-k2"])
        #expect(
            spec.resumeArgs(sid, SpawnOptions(skipPermissions: true, model: "kimi-k2"))
                == ["--session", sid, "--auto", "--model", "kimi-k2"])
        // An empty model is the same as none.
        #expect(spec.startArgs("id", SpawnOptions(model: "")) == [])
    }

    @Test func thePresetIsAgentOnStartOnly() {
        let preset = Preset(name: "review", body: nil)
        #expect(spec.startArgs("id", SpawnOptions(preset: preset))
            == ["--agent", "review"])
        // On resume the preset is dropped: kimi's help forbids combining `--agent`
        // with `--session`/`--continue`.
        #expect(spec.resumeArgs(sid, SpawnOptions(preset: preset)) == ["--session", sid])
        // An empty name is the same as none.
        #expect(spec.startArgs("id", SpawnOptions(preset: Preset(name: "", body: nil))) == [])
    }

    @Test func theFullArgvMirrorsTheDaemonExactly() {
        // Everything at once: this is the argv the Rust daemon spawns with, and the
        // two cores must keep matching.
        let everything = SpawnOptions(
            skipPermissions: true, model: "kimi-k2", preset: Preset(name: "review", body: nil))
        #expect(spec.startArgs("our-uuid", everything)
            == ["--auto", "--model", "kimi-k2", "--agent", "review"])
        // Only mode and model ride on a kimi resume.
        #expect(spec.resumeArgs(sid, everything)
            == ["--session", sid, "--auto", "--model", "kimi-k2"])
    }

    @Test func noEnvironmentEntryIsEverSetForTheMode() {
        // Every CLI here expresses skip-permissions through a CLI flag, so the
        // overlay is empty with and without the opt-in and the child inherits
        // `environ` verbatim.
        #expect(spec.spawnEnv(SpawnOptions()).isEmpty)
        #expect(spec.spawnEnv(SpawnOptions(skipPermissions: true)).isEmpty)
    }

    @Test func aMissingCliIsRefusedWithAMessageNamingTheProvider() {
        let error = SessionError.cliNotFound(provider: .kimi, command: "kimi")
        #expect("\(error)".contains("kimi"))
        #expect("\(error)".contains("JUANCODE_KIMI_BIN"))
    }

    @Test func kimisOwnInstallDirIsProbed() {
        // kimi's installer puts the binary in ~/.kimi-code/bin, which no login shell
        // guarantees is on PATH — a Finder-launched app has to find it without one.
        #expect(wellKnownBinDirs.contains("\(NSHomeDirectory())/.kimi-code/bin"))
    }
}
