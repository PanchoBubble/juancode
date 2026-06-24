import XCTest
import JuancodeCore
@testable import JuancodeServices

/// Port of `apps/server/src/beads.test.ts`. The TS gates its tracker-backed
/// assertion on whether `bd` is on PATH; we keep that, and additionally inject a
/// fake `bd` via the `JUANCODE_BD_BIN` override so the camelCase mapping has
/// deterministic coverage even on machines without bd installed.
final class BeadsTests: XCTestCase {
    private var dir: String = ""

    /// Is the `bd` CLI available on PATH? Tracker-backed assertions need it.
    private static func hasBd() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["bd", "version"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    override func setUpWithError() throws {
        // `mkdtempSync(join(tmpdir(), "juancode-bd-"))` — a fresh empty temp dir.
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-bd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        dir = path
    }

    override func tearDownWithError() throws {
        // `rmSync(dir, { recursive: true, force: true })`
        if !dir.isEmpty { try? FileManager.default.removeItem(atPath: dir) }
    }

    func testReturnsUnavailableForFolderWithNoTracker() async throws {
        let r = await getBeads(dir)
        XCTAssertFalse(r.available)
        XCTAssertEqual(r.issues, [])
        XCTAssertNotNil(r.error)
        XCTAssertFalse(r.error?.isEmpty ?? true)
    }

    func testListsIssuesFromRealTrackerMappedToCamelCase() async throws {
        try XCTSkipUnless(Self.hasBd(), "bd CLI not on PATH")
        runBd(["init"], in: dir)
        runBd(["create", "First task", "-t", "task", "-p", "1"], in: dir)

        let r = await getBeads(dir)
        XCTAssertTrue(r.available)
        XCTAssertEqual(r.issues.count, 1)
        let issue = try XCTUnwrap(r.issues.first)
        XCTAssertEqual(issue.title, "First task")
        XCTAssertEqual(issue.priority, 1)
        XCTAssertEqual(issue.issueType, "task")
        // `expect(typeof issue.ready).toBe("boolean")` — Bool is non-optional in
        // Swift, so its mere existence satisfies the type assertion.
        _ = issue.ready
        _ = issue.blocked
    }

    /// Inject a fake `bd` that emits canned JSON for list/ready/blocked, so the
    /// snake_case → camelCase mapping and ready/blocked overlay are covered with
    /// no real bd dependency. Mirrors how the TS would swap a binary via the
    /// `JUANCODE_BD_BIN` override env var.
    func testMapsFakeBdOutputWithReadyAndBlockedOverlay() async throws {
        let fake = try writeFakeBd(
            list: """
            [
              {"id":"x-1","title":"Ready one","status":"open","priority":0,"issue_type":"feature","parent":null,"dependency_count":2,"dependent_count":3},
              {"id":"x-2","title":"Blocked one","status":"open","priority":3,"issue_type":"bug"},
              {"title":"No id — dropped","status":"open"}
            ]
            """,
            ready: #"[{"id":"x-1"}]"#,
            blocked: #"[{"id":"x-2"}]"#
        )
        setenv("JUANCODE_BD_BIN", fake, 1)
        defer { unsetenv("JUANCODE_BD_BIN") }

        let r = await getBeads(dir)
        XCTAssertTrue(r.available)
        XCTAssertEqual(r.issues.count, 2, "the id-less entry is filtered out")

        let one = try XCTUnwrap(r.issues.first { $0.id == "x-1" })
        XCTAssertEqual(one.title, "Ready one")
        XCTAssertEqual(one.priority, 0)
        XCTAssertEqual(one.issueType, "feature")
        XCTAssertNil(one.parent)
        XCTAssertEqual(one.dependencyCount, 2)
        XCTAssertEqual(one.dependentCount, 3)
        XCTAssertTrue(one.ready)
        XCTAssertFalse(one.blocked)

        let two = try XCTUnwrap(r.issues.first { $0.id == "x-2" })
        // Defaults applied for missing fields, mirroring the TS `?? ...`.
        XCTAssertEqual(two.status, "open")
        XCTAssertEqual(two.priority, 3)
        XCTAssertEqual(two.issueType, "bug")
        XCTAssertEqual(two.dependencyCount, 0)
        XCTAssertEqual(two.dependentCount, 0)
        XCTAssertFalse(two.ready)
        XCTAssertTrue(two.blocked)
    }

    /// A fake `bd` that exits non-zero with a "no beads database" stderr → the
    /// graceful no-tracker message.
    func testFakeBdNoDatabaseReportsNoTracker() async throws {
        let fake = try writeFakeBdScript("""
        #!/bin/sh
        echo "Error: no beads database found in this directory" 1>&2
        exit 1
        """)
        setenv("JUANCODE_BD_BIN", fake, 1)
        defer { unsetenv("JUANCODE_BD_BIN") }

        let r = await getBeads(dir)
        XCTAssertFalse(r.available)
        XCTAssertEqual(r.error, "No beads tracker in this folder")
    }

    // MARK: - issuePrompt (juancode-sfh)

    func testIssuePromptWithDescription() {
        let p = issuePrompt(id: "x-1", title: "Fix the parser", description: "It chokes on empty input.")
        XCTAssertEqual(p, "Work on x-1: Fix the parser\n\nIt chokes on empty input.")
    }

    func testIssuePromptWithoutDescriptionIsSingleLine() {
        let p = issuePrompt(id: "x-2", title: "Add a flag")
        XCTAssertEqual(p, "Work on x-2: Add a flag")
        // A blank/whitespace description is treated as none — no trailing block.
        XCTAssertEqual(issuePrompt(id: "x-2", title: "Add a flag", description: "   \n  "),
                       "Work on x-2: Add a flag")
    }

    func testIssuePromptTrimsTitleAndDescription() {
        let p = issuePrompt(id: "x-3", title: "  Spaced title  ", description: "  body  ")
        XCTAssertEqual(p, "Work on x-3: Spaced title\n\nbody")
    }

    func testIssuePromptEmptyTitleOmitsColon() {
        XCTAssertEqual(issuePrompt(id: "x-4", title: ""), "Work on x-4")
        XCTAssertEqual(issuePrompt(id: "x-4", title: "   ", description: "details"),
                       "Work on x-4\n\ndetails")
    }

    /// `getBeadsDescription` reads `[0].description` from `bd show <id> --json` and
    /// degrades to nil for a missing/empty description — covered via a fake bd.
    func testGetBeadsDescriptionReadsShowOutput() async throws {
        let fake = try writeFakeBdShow(#"[{"id":"x-1","description":"the full body"}]"#)
        setenv("JUANCODE_BD_BIN", fake, 1)
        defer { unsetenv("JUANCODE_BD_BIN") }
        let desc = await getBeadsDescription(dir, id: "x-1")
        XCTAssertEqual(desc, "the full body")
    }

    func testGetBeadsDescriptionNilWhenMissing() async throws {
        let fake = try writeFakeBdShow(#"[{"id":"x-1"}]"#)
        setenv("JUANCODE_BD_BIN", fake, 1)
        defer { unsetenv("JUANCODE_BD_BIN") }
        let desc = await getBeadsDescription(dir, id: "x-1")
        XCTAssertNil(desc)
        // Empty id short-circuits without launching bd.
        let none = await getBeadsDescription(dir, id: "")
        XCTAssertNil(none)
    }

    // MARK: - helpers

    private func runBd(_ args: [String], in cwd: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["bd"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    /// Write an executable shell script and return its absolute path.
    private func writeFakeBdScript(_ body: String) throws -> String {
        let path = (dir as NSString).appendingPathComponent("fake-bd-\(UUID().uuidString)")
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// Write a fake `bd` that dispatches on the subcommand (after `--sandbox`)
    /// and echoes the matching canned JSON. The real invocation is
    /// `bd --sandbox <cmd> ... --json`, so `$2` is the subcommand.
    private func writeFakeBd(list: String, ready: String, blocked: String) throws -> String {
        // Embed the JSON via heredocs to avoid quoting headaches.
        let script = """
        #!/bin/sh
        case "$2" in
          list)
        cat <<'JSON'
        \(list)
        JSON
            ;;
          ready)
        cat <<'JSON'
        \(ready)
        JSON
            ;;
          blocked)
        cat <<'JSON'
        \(blocked)
        JSON
            ;;
          *)
            echo 'null'
            ;;
        esac
        """
        return try writeFakeBdScript(script)
    }

    /// A fake `bd` that echoes canned JSON for `bd --sandbox show <id> --json`
    /// (the subcommand is `$2`), used to cover `getBeadsDescription`.
    private func writeFakeBdShow(_ json: String) throws -> String {
        let script = """
        #!/bin/sh
        case "$2" in
          show)
        cat <<'JSON'
        \(json)
        JSON
            ;;
          *)
            echo 'null'
            ;;
        esac
        """
        return try writeFakeBdScript(script)
    }
}
