import XCTest
import JuancodeCore
@testable import JuancodeServices

/// Ported 1:1 from `apps/server/src/recoverSession.test.ts`. Each case writes fake
/// transcript files into a temp dir and points `recoverCliSessionId` at it via the
/// `claudeProjects` root override (the same seam the TS tests use).
final class RecoverSessionTests: XCTestCase {
    // A fresh temp root per test class, cleaned up in tearDown (mirrors mkdtemp + afterAll).
    private var tmp: String!

    private let CWD = "/Users/someone/project"
    private let OTHER = "/Users/someone/other"
    // a session's createdAt — `Date.parse("2026-06-23T12:00:00.000Z")`.
    private let T0 = RecoverSessionTests.isoMs("2026-06-23T12:00:00.000Z")

    override func setUpWithError() throws {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-recover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        tmp = dir
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmp)
    }

    // MARK: - Fixture helpers (mirror the TS `jsonl`/`encode`/`claudeRoot`/`recover`)

    /// Parse an ISO string to ms since epoch (test-local `Date.parse`).
    private static func isoMs(_ s: String) -> Int {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Int(f.date(from: s)!.timeIntervalSince1970 * 1000)
    }

    /// `new Date(ms).toISOString()` — UTC, millisecond precision, trailing `Z`.
    private func iso(_ ms: Int) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private func jsonl(_ records: [[String: Any]]) -> String {
        records
            .map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
            .joined(separator: "\n") + "\n"
    }

    /// Encode a cwd the way Claude names its project dirs (path separators → dashes).
    private func encode(_ cwd: String) -> String {
        cwd.replacingOccurrences(of: "[/.]", with: "-", options: .regularExpression)
    }

    /// Build a Claude projects root containing one transcript per entry, each a
    /// `<root>/<encoded-cwd>/<id>.jsonl` whose first record carries the cwd + start.
    private func claudeRoot(_ name: String, _ transcripts: [(id: String, cwd: String, startMs: Int)]) -> String {
        let root = (tmp as NSString).appendingPathComponent(name)
        for t in transcripts {
            let dir = (root as NSString).appendingPathComponent(encode(t.cwd))
            try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let body = jsonl([
                ["type": "mode"], // no cwd/timestamp — must be skipped
                ["type": "user", "cwd": t.cwd, "timestamp": iso(t.startMs), "message": "hi"],
            ])
            let file = (dir as NSString).appendingPathComponent("\(t.id).jsonl")
            try! body.write(toFile: file, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func recover(_ root: String, excludeIds: [String] = [], createdAt: Int? = nil) async -> String? {
        await recoverCliSessionId(
            .claude,
            cwd: CWD,
            createdAtMs: createdAt ?? T0,
            excludeIds: Set(excludeIds),
            roots: RecoverRoots(claudeProjects: root)
        )
    }

    // MARK: - Tests

    func testPicksTranscriptClosestAfterCreation() async {
        let root = claudeRoot("near", [
            (id: "near", cwd: CWD, startMs: T0 + 30_000),
            (id: "later", cwd: CWD, startMs: T0 + 9 * 60_000),
        ])
        let got = await recover(root)
        XCTAssertEqual(got, "near")
    }

    func testSkipsIdsAlreadyClaimedByAnotherSession() async {
        let root = claudeRoot("excluded", [
            (id: "near", cwd: CWD, startMs: T0 + 30_000),
            (id: "later", cwd: CWD, startMs: T0 + 9 * 60_000),
        ])
        let got = await recover(root, excludeIds: ["near"])
        XCTAssertEqual(got, "later")
    }

    func testIgnoresTranscriptsFromADifferentWorkingDirectory() async {
        let root = claudeRoot("other-cwd", [(id: "elsewhere", cwd: OTHER, startMs: T0 + 30_000)])
        let got = await recover(root)
        XCTAssertNil(got)
    }

    func testRejectsMatchTooFarAfterCreation() async {
        let root = claudeRoot("too-late", [(id: "stale", cwd: CWD, startMs: T0 + 20 * 60_000)])
        let got = await recover(root)
        XCTAssertNil(got)
    }

    func testRejectsTranscriptThatBeganBeforeCreation() async {
        let root = claudeRoot("too-early", [(id: "prior", cwd: CWD, startMs: T0 - 60_000)])
        let got = await recover(root)
        XCTAssertNil(got)
    }

    func testReturnsNullWhenProjectsRootHasNothingForThisCwd() async {
        let root = claudeRoot("empty", [(id: "x", cwd: OTHER, startMs: T0)])
        let got = await recover(root)
        XCTAssertNil(got)
    }

    // MARK: - claudeConversationExists

    private func exists(_ root: String, _ id: String, cwd: String? = nil) -> Bool {
        claudeConversationExists(
            cliSessionId: id, cwd: cwd ?? CWD,
            roots: RecoverRoots(claudeProjects: root)
        )
    }

    func testConversationExistsWhenTranscriptPresentForCwd() {
        let root = claudeRoot("present", [(id: "abc", cwd: CWD, startMs: T0)])
        XCTAssertTrue(exists(root, "abc"))
    }

    func testConversationMissingWhenNoTurnEverWritten() {
        // The doomed-resume case: a session id with no transcript on disk (booted
        // but never completed a turn).
        let root = claudeRoot("present", [(id: "abc", cwd: CWD, startMs: T0)])
        XCTAssertFalse(exists(root, "never-had-a-turn"))
    }

    func testConversationMissingWhenTranscriptIsForADifferentCwd() {
        let root = claudeRoot("other-cwd", [(id: "abc", cwd: OTHER, startMs: T0)])
        XCTAssertFalse(exists(root, "abc"))
    }
}
