import Foundation
import Testing
@testable import JuancodeCore

/// Binary resolution for a stripped-PATH launch (juancode-z0c6): the well-known-dir
/// probe, and the cache that must not turn one failed probe into a session-long
/// "command not found".
@Suite struct BinaryResolutionTests {
    // MARK: well-known dirs

    /// A temp dir holding one executable `tool` and one non-executable `data`.
    private func fixtureDir() throws -> String {
        let dir = NSTemporaryDirectory() + "juancode-binres-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tool = dir + "/tool"
        try "#!/bin/sh\n".write(toFile: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool)
        try "not a binary".write(toFile: dir + "/data", atomically: true, encoding: .utf8)
        return dir
    }

    @Test func findsAnExecutableInAWellKnownDir() throws {
        let dir = try fixtureDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(lookupInWellKnownDirs("tool", dirs: ["/nope", dir]) == "\(dir)/tool")
    }

    @Test func skipsNonExecutablesAndMissingDirs() throws {
        let dir = try fixtureDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(lookupInWellKnownDirs("data", dirs: [dir]) == nil)
        #expect(lookupInWellKnownDirs("tool", dirs: ["/nope"]) == nil)
    }

    @Test func aCommandThatIsAlreadyAPathPassesThrough() {
        #expect(lookupInWellKnownDirs("/opt/custom/gh", dirs: []) == "/opt/custom/gh")
    }

    @Test func theDefaultDirListLeadsWithHomebrew() {
        #expect(wellKnownBinDirs.first == "/opt/homebrew/bin")
        #expect(wellKnownBinDirs.contains("/usr/local/bin"))
    }

    // MARK: cache

    @Test func hitsAreCachedForTheProcess() {
        let cache = ResolveBinCache()
        #expect(cache.get("gh") == nil)
        cache.set("gh", "/opt/homebrew/bin/gh")
        #expect(cache.get("gh") == "/opt/homebrew/bin/gh")
    }

    @Test func aMissIsRememberedOnlyForItsCooldown() {
        let cache = ResolveBinCache(missTTL: 60)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(!cache.inMissCooldown("gh", now: t0))
        cache.noteMiss("gh", now: t0)
        #expect(cache.inMissCooldown("gh", now: t0.addingTimeInterval(59)))
        // Past the window the probes run again — the binary may have arrived, or the
        // probe may have failed for reasons unrelated to the binary.
        #expect(!cache.inMissCooldown("gh", now: t0.addingTimeInterval(60)))
    }

    @Test func aMissIsNeverReturnedAsAResolvedPath() {
        let cache = ResolveBinCache()
        cache.noteMiss("gh")
        #expect(cache.get("gh") == nil)
    }

    @Test func aLaterHitClearsTheMiss() {
        let cache = ResolveBinCache(missTTL: 600)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        cache.noteMiss("gh", now: t0)
        cache.set("gh", "/opt/homebrew/bin/gh")
        #expect(!cache.inMissCooldown("gh", now: t0.addingTimeInterval(1)))
    }

    @Test func aBackwardsClockDoesNotPinTheCooldownOn() {
        let cache = ResolveBinCache(missTTL: 60)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        cache.noteMiss("gh", now: t0)
        // Clock stepped back an hour: the cooldown restamps to the new "now" instead
        // of holding a negative age forever.
        let back = t0.addingTimeInterval(-3600)
        #expect(cache.inMissCooldown("gh", now: back))
        #expect(!cache.inMissCooldown("gh", now: back.addingTimeInterval(60)))
    }
}
