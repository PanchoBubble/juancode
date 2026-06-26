import XCTest
import JuancodeCore
@testable import JuancodeServices

/// Tests for `listExternalSessions` (juancode-723): list every resumable Claude +
/// Codex conversation for a cwd, newest first, with no time window and no
/// exclusion. Mirrors the fixture style of `RecoverSessionTests`.
final class ListExternalSessionsTests: XCTestCase {
    private var tmp: String!

    private let CWD = "/Users/someone/project"
    private let OTHER = "/Users/someone/other"
    private let T0 = ListExternalSessionsTests.isoMs("2026-06-23T12:00:00.000Z")

    override func setUpWithError() throws {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-listext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        tmp = dir
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmp)
    }

    // MARK: - Fixture helpers (mirror RecoverSessionTests)

    private static func isoMs(_ s: String) -> Int {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Int(f.date(from: s)!.timeIntervalSince1970 * 1000)
    }

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

    private func encode(_ cwd: String) -> String {
        cwd.replacingOccurrences(of: "[/.]", with: "-", options: .regularExpression)
    }

    /// `<root>/<encoded-cwd>/<id>.jsonl`, first record carrying cwd + start.
    private func claudeRoot(_ name: String, _ transcripts: [(id: String, cwd: String, startMs: Int)]) -> String {
        let root = (tmp as NSString).appendingPathComponent(name)
        for t in transcripts {
            let dir = (root as NSString).appendingPathComponent(encode(t.cwd))
            try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let body = jsonl([
                ["type": "mode"],
                ["type": "user", "cwd": t.cwd, "timestamp": iso(t.startMs), "message": "hi"],
            ])
            try! body.write(toFile: (dir as NSString).appendingPathComponent("\(t.id).jsonl"),
                            atomically: true, encoding: .utf8)
        }
        return root
    }

    /// `<root>/rollout-<id>.jsonl` whose header is a Codex `session_meta` record.
    private func codexRoot(_ name: String, _ transcripts: [(id: String, cwd: String)]) -> String {
        let root = (tmp as NSString).appendingPathComponent(name)
        try! FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for t in transcripts {
            let body = jsonl([
                ["type": "session_meta", "payload": ["id": t.id, "cwd": t.cwd]],
            ])
            try! body.write(toFile: (root as NSString).appendingPathComponent("rollout-\(t.id).jsonl"),
                            atomically: true, encoding: .utf8)
        }
        return root
    }

    // MARK: - Tests

    func testListsBothProvidersForCwdAndIgnoresOtherDirs() {
        let claude = claudeRoot("c", [
            (id: "claude-a", cwd: CWD, startMs: T0),
            (id: "claude-other", cwd: OTHER, startMs: T0),
        ])
        let codex = codexRoot("x", [
            (id: "codex-a", cwd: CWD),
            (id: "codex-other", cwd: OTHER),
        ])
        let got = listExternalSessions(cwd: CWD, roots: RecoverRoots(claudeProjects: claude, codexSessions: codex))
        let ids = Set(got.map(\.cliSessionId))
        XCTAssertEqual(ids, ["claude-a", "codex-a"])
        XCTAssertEqual(got.first(where: { $0.cliSessionId == "claude-a" })?.provider, .claude)
        XCTAssertEqual(got.first(where: { $0.cliSessionId == "codex-a" })?.provider, .codex)
    }

    func testReturnsAllCandidatesNoTimeWindow() {
        // recoverCliSessionId would reject these (one too early, one too late); the
        // lister applies no window, so both must appear.
        let claude = claudeRoot("c", [
            (id: "early", cwd: CWD, startMs: T0 - 60 * 60_000),
            (id: "late", cwd: CWD, startMs: T0 + 60 * 60_000),
        ])
        let got = listExternalSessions(cwd: CWD, roots: RecoverRoots(claudeProjects: claude, codexSessions: "/no/such"))
        XCTAssertEqual(Set(got.map(\.cliSessionId)), ["early", "late"])
    }

    func testSortedNewestFirst() {
        let claude = claudeRoot("c", [
            (id: "oldest", cwd: CWD, startMs: T0),
            (id: "newest", cwd: CWD, startMs: T0 + 5 * 60_000),
            (id: "middle", cwd: CWD, startMs: T0 + 60_000),
        ])
        let got = listExternalSessions(cwd: CWD, roots: RecoverRoots(claudeProjects: claude, codexSessions: "/no/such"))
        XCTAssertEqual(got.map(\.cliSessionId), ["newest", "middle", "oldest"])
        XCTAssertEqual(got.first?.startMs, T0 + 5 * 60_000)
    }

    func testEmptyWhenNoTranscriptsMatch() {
        let claude = claudeRoot("c", [(id: "x", cwd: OTHER, startMs: T0)])
        let got = listExternalSessions(cwd: CWD, roots: RecoverRoots(claudeProjects: claude, codexSessions: "/no/such"))
        XCTAssertTrue(got.isEmpty)
    }
}
