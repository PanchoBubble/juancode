import XCTest
@testable import JuancodeServices

/// `discoverExternalSessions` should surface real terminal conversations but hide
/// harness-internal transcripts — forked subagents and local slash-command runs
/// whose first user record is injected boilerplate, not a prompt the user typed.
final class ExternalDiscoveryTests: XCTestCase {
    private static let tmp: String = {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-discovery-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    override class func tearDown() {
        try? FileManager.default.removeItem(atPath: tmp)
        super.tearDown()
    }

    private func jsonl(_ records: [Any]) -> String {
        records.map { rec in
            let data = try! JSONSerialization.data(withJSONObject: rec, options: [.sortedKeys])
            return String(data: data, encoding: .utf8)!
        }.joined(separator: "\n") + "\n"
    }

    /// Write one Claude transcript <root>/<encoded-cwd>/<id>.jsonl under a shared root.
    private func writeClaude(_ root: String, id: String, cwd: String, records: [Any]) {
        let dir = (root as NSString).appendingPathComponent("-Users-me-project")
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(id).jsonl")
        let withCwd = [["cwd": cwd]] + records
        try! jsonl(withCwd).write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func user(_ text: String) -> [String: Any] {
        ["type": "user", "message": ["content": text]]
    }

    private func discover(_ root: String) async -> [ExternalSession] {
        await discoverExternalSessions(
            limit: 50, excluding: [],
            roots: TitleRoots(claudeProjects: root, codexSessions: "/nonexistent")
        ).sessions
    }

    func testHidesForkAndCaveatTranscriptsButKeepsRealOnes() async {
        let root = (Self.tmp as NSString).appendingPathComponent("mix")
        writeClaude(root, id: "real-1", cwd: "/work/horizon", records: [user("Add a dark mode toggle")])
        writeClaude(root, id: "fork-1", cwd: "/work/horizon",
                    records: [user("<fork-boilerplate> You are a worktree agent…")])
        writeClaude(root, id: "caveat-1", cwd: "/work/horizon",
                    records: [user("<local-command-caveat>Caveat: The messages below…")])

        let titles = await discover(root).map(\.title).sorted()
        XCTAssertEqual(titles, ["Add a dark mode toggle"])
    }

    func testHidesSubagentSidechainTranscripts() async {
        // Claude writes Task/subagent transcripts to
        // <encoded-cwd>/<parent-session>/subagents/agent-<hex>.jsonl. Their first user
        // record is a real task prompt (not fork boilerplate), so the isInjectedPrompt
        // filter misses them — they must be excluded by their `subagents/` location, or
        // the sidebar fills with `agent-<hex>` folders.
        let root = (Self.tmp as NSString).appendingPathComponent("subagents")
        writeClaude(root, id: "real-2", cwd: "/work/horizon", records: [user("Ship the login flow")])
        let subDir = (root as NSString)
            .appendingPathComponent("-Users-me-project/parent-session/subagents")
        try! FileManager.default.createDirectory(atPath: subDir, withIntermediateDirectories: true)
        let subPath = (subDir as NSString).appendingPathComponent("agent-a271cc6c76d2ca134.jsonl")
        let sub = jsonl([
            ["cwd": "/work/horizon", "isSidechain": true, "agentId": "a271cc6c76d2ca134"],
            user("I'm in the pandora monorepo. Find the exact field names for the invoice model."),
        ])
        try! sub.write(toFile: subPath, atomically: true, encoding: .utf8)

        let titles = await discover(root).map(\.title)
        XCTAssertEqual(titles, ["Ship the login flow"])
    }

    func testHidesSidechainTranscriptOutsideSubagentsDir() async {
        // Backstop for the path guard: even a transcript at the normal top-level
        // location must be dropped if its records carry isSidechain: true.
        let root = (Self.tmp as NSString).appendingPathComponent("sidechain-content")
        writeClaude(root, id: "real-3", cwd: "/work/horizon", records: [user("Wire up settings page")])
        writeClaude(root, id: "sidechain-1", cwd: "/work/horizon", records: [
            ["type": "user", "isSidechain": true, "agentId": "a271cc6c76d2ca134",
             "message": ["content": "Find the invoice model field names."]],
        ])

        let titles = await discover(root).map(\.title)
        XCTAssertEqual(titles, ["Wire up settings page"])
    }

    func testKeepsCaveatSessionWhenItHasAnAiTitle() async {
        // A slash-command run that became a real conversation (ai-title present) is
        // a genuine session — surface it with the model-generated title.
        let root = (Self.tmp as NSString).appendingPathComponent("caveat-real")
        writeClaude(root, id: "caveat-2", cwd: "/work/horizon", records: [
            user("<local-command-caveat>Caveat: The messages below…"),
            ["type": "ai-title", "aiTitle": "Investigate the flaky test"],
        ])

        let titles = await discover(root).map(\.title)
        XCTAssertEqual(titles, ["Investigate the flaky test"])
    }
}
