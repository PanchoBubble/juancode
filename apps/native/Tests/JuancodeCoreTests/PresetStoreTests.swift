import Foundation
import Testing
@testable import JuancodeCore

/// One preset name, three mechanisms. These pin both halves: that a name resolves to
/// what each provider actually needs, and that a name we cannot honour is refused
/// rather than dropped — a session that silently started without the instruction set it
/// was asked for looks exactly like one that has it.
/// `.serialized` because `JUANCODE_PRESET_DIR` is process-global: run in parallel, one
/// test's cleanup unsets the directory while another is still resolving against it.
@Suite(.serialized) struct PresetStoreTests {
    /// `PresetStore.directory` reads the environment at call time, so a test writes its
    /// own directory there and puts back whatever was set before.
    private func withPresetDir(_ body: (String) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-presets-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["JUANCODE_PRESET_DIR"]
        setenv("JUANCODE_PRESET_DIR", dir, 1)
        defer {
            if let previous { setenv("JUANCODE_PRESET_DIR", previous, 1) }
            else { unsetenv("JUANCODE_PRESET_DIR") }
            try? FileManager.default.removeItem(atPath: dir)
        }
        try body(dir)
    }

    private func write(_ name: String, _ body: String, in dir: String) throws {
        try body.write(toFile: (dir as NSString).appendingPathComponent("\(name).md"),
                       atomically: true, encoding: .utf8)
    }

    @Test func nameAllowlistRejectsTraversalAndFlags() {
        #expect(PresetStore.isValidName("lazy"))
        #expect(PresetStore.isValidName("lazy-senior_dev2"))
        // A name reaches both a filesystem path and an argv slot, so these are the two
        // shapes that matter: escaping out of the preset directory, and being read as a
        // flag by the CLI.
        #expect(!PresetStore.isValidName("../../etc/passwd"))
        #expect(!PresetStore.isValidName("a/b"))
        #expect(!PresetStore.isValidName(".."))
        #expect(!PresetStore.isValidName("-rf"))
        #expect(!PresetStore.isValidName(""))
        #expect(!PresetStore.isValidName("has space"))
        #expect(!PresetStore.isValidName(String(repeating: "a", count: 65)))
        #expect(PresetStore.isValidName(String(repeating: "a", count: 64)))
    }

    @Test func claudeResolvesToTheBodyAndTrimsIt() throws {
        try withPresetDir { dir in
            try write("lazy", "\n  be lazy  \n\n", in: dir)
            let preset = try PresetStore.resolve(name: "lazy", for: .claude)
            #expect(preset.name == "lazy")
            // Trimmed: the trailing newline every editor adds would otherwise ride into
            // the CLI's argv as part of the system prompt.
            #expect(preset.body == "be lazy")
        }
    }

    @Test func codexAndOpencodeNeedNoBodyOnDisk() throws {
        try withPresetDir { _ in
            // Their mechanisms select a definition the USER wrote (`--profile`,
            // `--agent`), so there is nothing for us to read and no file to require.
            for provider in [ProviderId.codex, .opencode] {
                let preset = try PresetStore.resolve(name: "lazy", for: provider)
                #expect(preset.name == "lazy")
                #expect(preset.body == nil)
            }
        }
    }

    @Test func aClaudePresetWithNoBodyIsRefused() throws {
        try withPresetDir { dir in
            #expect(throws: PresetError.self) {
                try PresetStore.resolve(name: "missing", for: .claude)
            }
            // An empty file counts as no body: it would otherwise spawn with
            // `--append-system-prompt ""`, which reads as "applied" and is not.
            try write("blank", "\n   \n", in: dir)
            #expect(throws: PresetError.self) {
                try PresetStore.resolve(name: "blank", for: .claude)
            }
        }
    }

    @Test func aBadNameIsRefusedForEveryProvider() throws {
        try withPresetDir { _ in
            for provider in [ProviderId.claude, .codex, .opencode] {
                #expect(throws: PresetError.self) {
                    try PresetStore.resolve(name: "../escape", for: provider)
                }
            }
        }
    }

    @Test func anOversizedBodyIsRefusedRatherThanFailingAtExec() throws {
        try withPresetDir { dir in
            try write("huge", String(repeating: "x", count: PresetStore.bodyLimit + 1), in: dir)
            #expect(throws: PresetError.self) {
                try PresetStore.resolve(name: "huge", for: .claude)
            }
        }
    }

    @Test func eachProviderGetsItsOwnMechanism() {
        let claudePreset = Preset(name: "lazy", body: "be lazy")
        let namePreset = Preset(name: "lazy", body: nil)

        let claudeArgs = Providers.claude.startArgs("sid", SpawnOptions(preset: claudePreset))
        #expect(claudeArgs.contains("--append-system-prompt"))
        #expect(claudeArgs.contains("be lazy"))

        #expect(Providers.codex.startArgs("sid", SpawnOptions(preset: namePreset))
            == ["--profile", "lazy"])
        #expect(Providers.opencode.startArgs("sid", SpawnOptions(preset: namePreset))
            == ["--agent", "lazy"])
    }

    @Test func theMechanismRidesOnResumeToo() {
        // All three are per-invocation flags, not state the conversation carries, so a
        // resume without them would quietly drop the instruction set mid-session.
        let claudeArgs = Providers.claude.resumeArgs(
            "cli-id", SpawnOptions(preset: Preset(name: "lazy", body: "be lazy")))
        #expect(claudeArgs.contains("--append-system-prompt"))

        let name = Preset(name: "lazy", body: nil)
        #expect(Providers.codex.resumeArgs("cli-id", SpawnOptions(preset: name)).contains("--profile"))
        #expect(Providers.opencode.resumeArgs("cli-id", SpawnOptions(preset: name)).contains("--agent"))
    }

    @Test func noPresetMeansNoFlagAnywhere() {
        // The other half of the contract: the flag appears because it was asked for.
        let opts = SpawnOptions()
        for args in [Providers.claude.startArgs("sid", opts),
                     Providers.codex.startArgs("sid", opts),
                     Providers.opencode.startArgs("sid", opts),
                     Providers.claude.resumeArgs("cli", opts),
                     Providers.codex.resumeArgs("cli", opts),
                     Providers.opencode.resumeArgs("cli", opts)] {
            #expect(!args.contains("--append-system-prompt"))
            #expect(!args.contains("--profile"))
            #expect(!args.contains("--agent"))
        }
    }
}
