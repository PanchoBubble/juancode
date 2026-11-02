import Foundation
import Testing

@testable import JuancodeCore

/// GitHub Copilot's launch contract (mirrors the COPILOT arm of the daemon's
/// `provider.rs`): the CLI adopts our `--session-id`, so like claude it is resumable
/// at spawn with no discovery; bypass rides its own `--allow-all` flag; the preset is
/// `--agent <name>` on both start and resume; and nothing touches the environment.
@Suite struct CopilotProviderTests {
    private let spec = Providers.spec(for: .copilot)
    private let sid = "11111111-2222-3333-4444-555555555555"

    @Test func isReachableFromTheProviderRegistry() {
        #expect(ProviderId.allCases.contains(.copilot))
        #expect(ProviderId(rawValue: "copilot") == .copilot)
        #expect(spec.id == .copilot)
        #expect(spec.label == "GitHub Copilot")
        #expect(Providers.all[.copilot] != nil)
        #expect(spec.bracketedPaste)
    }

    @Test func pinsTheSessionIdToOurOwn() {
        #expect(spec.pinsSessionId)
        #expect(spec.startArgs("our-uuid", SpawnOptions()) == ["--session-id", "our-uuid"])
        #expect(spec.resumeArgs(sid, SpawnOptions()) == ["--resume", sid])
    }

    @Test func autoApproveRidesOnItsOwnFlagAndIsOptIn() {
        #expect(spec.startArgs("id", SpawnOptions(skipPermissions: true))
            == ["--session-id", "id", "--allow-all"])
        #expect(spec.resumeArgs(sid, SpawnOptions(skipPermissions: true))
            == ["--resume", sid, "--allow-all"])
        let plain = SpawnOptions()
        for args in [spec.startArgs("id", plain), spec.resumeArgs(sid, plain)] {
            for flag in ["--allow-all", "--yolo", "--allow-all-tools"] {
                #expect(!args.contains(flag), "\(args) carries \(flag)")
            }
        }
    }

    @Test func theFullArgvMirrorsTheDaemonExactly() {
        let everything = SpawnOptions(
            skipPermissions: true, model: "gpt-5", preset: Preset(name: "review", body: nil))
        #expect(spec.startArgs("our-uuid", everything)
            == ["--session-id", "our-uuid", "--allow-all", "--model", "gpt-5", "--agent", "review"])
        // Unlike kimi, the preset rides on resume too.
        #expect(spec.resumeArgs(sid, everything)
            == ["--resume", sid, "--allow-all", "--model", "gpt-5", "--agent", "review"])
        // An empty model or preset name is the same as none.
        #expect(spec.startArgs("id", SpawnOptions(model: "", preset: Preset(name: "", body: nil)))
            == ["--session-id", "id"])
    }

    @Test func noEnvironmentEntryIsEverSetForTheMode() {
        #expect(spec.spawnEnv(SpawnOptions()).isEmpty)
        #expect(spec.spawnEnv(SpawnOptions(skipPermissions: true)).isEmpty)
    }

    @Test func aMissingCliIsRefusedWithAMessageNamingTheProvider() {
        let error = SessionError.cliNotFound(provider: .copilot, command: "copilot")
        #expect("\(error)".contains("copilot"))
        #expect("\(error)".contains("JUANCODE_COPILOT_BIN"))
    }

    @Test func aPresetNameNeverNeedsItsBody() {
        // copilot selects an agent the user defined; only claude is handed prose.
        #expect(!ProviderId.copilot.presetNeedsBody)
    }

    @Test func aRevivedSessionIsNeverThrownAwayByClaudesTranscriptCheck() {
        // `resumeNeedsFreshStart` asks claude's transcript store whether a pinned id
        // has a conversation. copilot pins too, but its conversations are not in that
        // store, so asking would answer "missing" for every copilot session and
        // silently boot each one fresh instead of resuming it.
        let empty = NSTemporaryDirectory() + "juancode-copilot-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: empty) }
        let meta = SessionMeta(
            id: "m-1", provider: .copilot, cwd: "/Users/someone/project", title: "t",
            status: .exited, exitCode: 0, createdAt: 0, updatedAt: 0,
            cliSessionId: sid, skipPermissions: false, worktreePath: nil, usage: nil)
        #expect(!resumeNeedsFreshStart(meta, roots: RecoverRoots(claudeProjects: empty)))
    }
}
