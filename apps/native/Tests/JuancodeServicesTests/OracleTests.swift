import XCTest
import JuancodeCore
@testable import JuancodeServices

/// Covers the testable Oracle plumbing (juancode-wjg): the dispatch-mailbox
/// append/tail protocol (offset semantics, partial + malformed lines), provider
/// resolution, and the state-snapshot round-trip. The control dir is pointed at a
/// fresh temp dir via `JUANCODE_ORACLE_DIR` so nothing touches `~/.juancode`.
final class OracleTests: XCTestCase {
    private var dir: String = ""

    override func setUpWithError() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-oracle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        dir = path
        setenv("JUANCODE_ORACLE_DIR", path, 1)
        // Start with an empty mailbox, as bootstrap would.
        FileManager.default.createFile(atPath: OraclePaths.dispatchFile, contents: Data())
    }

    override func tearDownWithError() throws {
        unsetenv("JUANCODE_ORACLE_DIR")
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testPathsRootAtControlDir() {
        XCTAssertEqual(OraclePaths.controlDir, dir)
        XCTAssertTrue(OraclePaths.dispatchFile.hasSuffix("dispatch.jsonl"))
        XCTAssertTrue(OraclePaths.stateFile.hasSuffix("state.json"))
        XCTAssertTrue(OraclePaths.beadsDir.hasSuffix(".beads"))
    }

    func testResolvedProviderDefaultsToClaude() {
        XCTAssertEqual(OracleDispatch(project: "/p", prompt: "x").resolvedProvider, .claude)
        XCTAssertEqual(OracleDispatch(project: "/p", prompt: "x", provider: "codex").resolvedProvider, .codex)
        XCTAssertEqual(OracleDispatch(project: "/p", prompt: "x", provider: "CLAUDE").resolvedProvider, .claude)
        // Unrecognized provider still dispatches (as Claude) rather than dropping.
        XCTAssertEqual(OracleDispatch(project: "/p", prompt: "x", provider: "bogus").resolvedProvider, .claude)
    }

    func testAppendThenReadRoundTrips() throws {
        try appendOracleDispatch(OracleDispatch(project: "/a", prompt: "do a"))
        try appendOracleDispatch(OracleDispatch(project: "/b", prompt: "do b", provider: "codex", worktree: true))

        let (out, offset) = readOracleDispatches(since: 0)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], OracleDispatch(project: "/a", prompt: "do a"))
        XCTAssertEqual(out[1].project, "/b")
        XCTAssertEqual(out[1].worktree, true)
        XCTAssertEqual(out[1].resolvedProvider, .codex)
        // Offset advances past everything consumed.
        let size = try Data(contentsOf: URL(fileURLWithPath: OraclePaths.dispatchFile)).count
        XCTAssertEqual(offset, size)
    }

    func testDispatchEncodesModelWhenSet() throws {
        try appendOracleDispatch(OracleDispatch(
            project: "/a", prompt: "on opus", provider: "claude", worktree: false, model: "opus"))
        let raw = try String(contentsOf: URL(fileURLWithPath: OraclePaths.dispatchFile), encoding: .utf8)
        XCTAssertTrue(raw.contains(#""model":"opus""#))

        let (out, _) = readOracleDispatches(since: 0)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].model, "opus")
        XCTAssertEqual(out[0], OracleDispatch(
            project: "/a", prompt: "on opus", provider: "claude", worktree: false, model: "opus"))
    }

    func testDispatchDecodesLineWithoutModel() throws {
        // Backward compatibility: pre-`model` lines (and the app's own older
        // dispatches) omit the field entirely and must decode with model == nil.
        let url = URL(fileURLWithPath: OraclePaths.dispatchFile)
        let contents = #"{"project":"/a","prompt":"legacy","provider":"claude","worktree":false}"# + "\n"
        try Data(contents.utf8).write(to: url)

        let (out, _) = readOracleDispatches(since: 0)
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(out[0].model)
        XCTAssertEqual(out[0], OracleDispatch(project: "/a", prompt: "legacy", provider: "claude", worktree: false))
    }

    func testDispatchOmitsModelKeyWhenNil() throws {
        // An absent model should not serialize a null/empty key — keeps lines lean
        // and matches how existing (model-less) dispatches look on disk.
        try appendOracleDispatch(OracleDispatch(project: "/a", prompt: "plain dispatch"))
        let raw = try String(contentsOf: URL(fileURLWithPath: OraclePaths.dispatchFile), encoding: .utf8)
        XCTAssertFalse(raw.contains(#""model""#))
    }

    func testReadIsIncrementalFromOffset() throws {
        try appendOracleDispatch(OracleDispatch(project: "/a", prompt: "first"))
        let (first, off1) = readOracleDispatches(since: 0)
        XCTAssertEqual(first.count, 1)

        // Nothing new yet.
        let (none, off2) = readOracleDispatches(since: off1)
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(off2, off1)

        try appendOracleDispatch(OracleDispatch(project: "/b", prompt: "second"))
        let (second, _) = readOracleDispatches(since: off2)
        XCTAssertEqual(second.map(\.project), ["/b"])
    }

    func testPartialTrailingLineIsNotConsumed() throws {
        // A half-written append (no trailing newline) must be left for next time so
        // we never misparse a torn line.
        let url = URL(fileURLWithPath: OraclePaths.dispatchFile)
        let contents = #"{"project":"/a","prompt":"complete"}"# + "\n"
            + #"{"project":"/b","prompt":"partial"#
        try Data(contents.utf8).write(to: url)

        let (out, offset) = readOracleDispatches(since: 0)
        XCTAssertEqual(out.map(\.project), ["/a"])
        // Re-reading from the returned offset still yields nothing until the partial
        // line is completed.
        XCTAssertTrue(readOracleDispatches(since: offset).dispatches.isEmpty)
    }

    func testMalformedLineIsSkipped() throws {
        let url = URL(fileURLWithPath: OraclePaths.dispatchFile)
        let contents = "not json\n" + #"{"project":"/ok","prompt":"good"}"# + "\n"
        try Data(contents.utf8).write(to: url)
        let (out, _) = readOracleDispatches(since: 0)
        XCTAssertEqual(out.map(\.project), ["/ok"])
    }

    func testFileShrinkResetsOffset() throws {
        try appendOracleDispatch(OracleDispatch(project: "/a", prompt: "x"))
        let big = 10_000
        // An offset past EOF (file rotated/shrank) clamps to the current size
        // instead of crashing on an out-of-range subdata.
        let (out, offset) = readOracleDispatches(since: big)
        XCTAssertTrue(out.isEmpty)
        let size = try Data(contentsOf: URL(fileURLWithPath: OraclePaths.dispatchFile)).count
        XCTAssertEqual(offset, size)
    }

    func testStateRoundTrips() throws {
        let state = OracleState(
            updatedAt: 123,
            workdirs: ["/proj"],
            sessions: [OracleSessionSnapshot(
                id: "s1", title: "T", cwd: "/proj", provider: "claude",
                status: "running", activity: "idle", live: true)])
        try writeOracleState(state)
        let data = try Data(contentsOf: URL(fileURLWithPath: OraclePaths.stateFile))
        let decoded = try JSONDecoder().decode(OracleState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    func testDiscoverProjectsFindsGitReposAndUnionsSessions() throws {
        let fm = FileManager.default
        // A workspace root with one git repo, one plain dir (ignored), and a file.
        let ws = (dir as NSString).appendingPathComponent("ws")
        let repo = (ws as NSString).appendingPathComponent("repo")
        try fm.createDirectory(atPath: (repo as NSString).appendingPathComponent(".git"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(atPath: (ws as NSString).appendingPathComponent("plain"),
                               withIntermediateDirectories: true)
        // A session cwd outside the workspace root still shows up (union), as active.
        let outside = (dir as NSString).appendingPathComponent("elsewhere")
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)

        let projects = discoverOracleProjects(workspaceRoot: ws, sessionCwds: [outside])
        let byPath = Dictionary(uniqueKeysWithValues: projects.map { ($0.path, $0) })

        // The git repo is listed (inactive — no session), the plain dir is not.
        XCTAssertEqual(byPath[repo]?.active, false)
        XCTAssertEqual(byPath[repo]?.name, "repo")
        XCTAssertNil(byPath[(ws as NSString).appendingPathComponent("plain")])
        // The out-of-workspace session cwd is unioned in and marked active.
        XCTAssertEqual(byPath[outside]?.active, true)
    }

    func testStateRoundTripsWithProjects() throws {
        let state = OracleState(
            updatedAt: 1, workdirs: ["/proj"], sessions: [],
            projects: [OracleProject(path: "/proj", name: "proj", active: true)])
        try writeOracleState(state)
        let data = try Data(contentsOf: URL(fileURLWithPath: OraclePaths.stateFile))
        XCTAssertEqual(try JSONDecoder().decode(OracleState.self, from: data), state)
    }

    func testAskMailboxRoundTripsIncrementally() throws {
        // The ask mailbox (remote/MCP path) shares the JSONL plumbing but is its own
        // file + offset, so a dispatch must never be read as an ask or vice versa.
        try appendOracleAsk(OracleAsk(text: "what's on the board?"))
        let (first, off1) = readOracleAsks(since: 0)
        XCTAssertEqual(first.map(\.text), ["what's on the board?"])
        XCTAssertTrue(OraclePaths.askFile.hasSuffix("ask.jsonl"))

        // Nothing new from the advanced offset.
        XCTAssertTrue(readOracleAsks(since: off1).asks.isEmpty)

        // A dispatch appended to its own file is not visible to the ask reader.
        try appendOracleDispatch(OracleDispatch(project: "/a", prompt: "x"))
        XCTAssertTrue(readOracleAsks(since: off1).asks.isEmpty)

        try appendOracleAsk(OracleAsk(text: "and now?"))
        XCTAssertEqual(readOracleAsks(since: off1).asks.map(\.text), ["and now?"])
    }

    // ── WS-first dispatch plumbing (juancode-2kz.1) ─────────────────────────────

    func testDispatchIdRoundTripsAndLegacyLinesDecode() throws {
        try appendOracleDispatch(OracleDispatch(project: "/a", prompt: "x", dispatchId: "d-1"))
        let raw = try String(contentsOf: URL(fileURLWithPath: OraclePaths.dispatchFile), encoding: .utf8)
        XCTAssertTrue(raw.contains(#""dispatchId":"d-1""#))
        let (out, _) = readOracleDispatches(since: 0)
        XCTAssertEqual(out.first?.dispatchId, "d-1")

        // Lines the Oracle agent writes by hand carry no dispatchId and must decode.
        let legacy = #"{"project":"/b","prompt":"agent-written"}"# + "\n"
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: OraclePaths.dispatchFile))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(legacy.utf8))
        try handle.close()
        let (all, _) = readOracleDispatches(since: 0)
        XCTAssertEqual(all.count, 2)
        XCTAssertNil(all[1].dispatchId)
    }

    func testDispatchOmitsDispatchIdKeyWhenNil() throws {
        try appendOracleDispatch(OracleDispatch(project: "/a", prompt: "plain"))
        let raw = try String(contentsOf: URL(fileURLWithPath: OraclePaths.dispatchFile), encoding: .utf8)
        XCTAssertFalse(raw.contains(#""dispatchId""#))
    }

    func testMailboxOffsetPersistsAndRoundTrips() {
        // Absent file → nil, so the caller primes to EOF exactly once.
        XCTAssertNil(readOracleMailboxOffset(at: OraclePaths.dispatchOffsetFile))
        writeOracleMailboxOffset(42, at: OraclePaths.dispatchOffsetFile)
        XCTAssertEqual(readOracleMailboxOffset(at: OraclePaths.dispatchOffsetFile), 42)
        writeOracleMailboxOffset(0, at: OraclePaths.dispatchOffsetFile)
        XCTAssertEqual(readOracleMailboxOffset(at: OraclePaths.dispatchOffsetFile), 0)
        // Corrupt content degrades to nil (re-prime), never a crash or bogus offset.
        try? Data("garbage".utf8).write(to: URL(fileURLWithPath: OraclePaths.askOffsetFile))
        XCTAssertNil(readOracleMailboxOffset(at: OraclePaths.askOffsetFile))
    }

    func testDispatchResultAppendAndReadRoundTrips() throws {
        try appendOracleDispatchResult(OracleDispatchResult(
            dispatchId: "d-1", project: "/a", ok: false,
            error: "\"/a\" is not an existing directory", at: 100))
        try appendOracleDispatchResult(OracleDispatchResult(
            dispatchId: nil, project: "/b", ok: true, sessionId: "s-9", at: 200))

        let (results, offset) = readOracleDispatchResults(since: 0)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].dispatchId, "d-1")
        XCTAssertEqual(results[0].ok, false)
        XCTAssertEqual(results[0].error, "\"/a\" is not an existing directory")
        XCTAssertNil(results[1].dispatchId)
        XCTAssertEqual(results[1].sessionId, "s-9")
        // Incremental like the mailboxes: nothing new from the returned offset.
        XCTAssertTrue(readOracleDispatchResults(since: offset).results.isEmpty)
    }

    func testDispatchLedgerClaimsExactlyOnce() {
        let path = (dir as NSString).appendingPathComponent("ledger.json")
        let ledger = OracleDispatchLedger(path: { path })
        XCTAssertTrue(ledger.claim("d-1"))
        XCTAssertFalse(ledger.claim("d-1")) // the double-spawn guard
        XCTAssertTrue(ledger.claim("d-2"))
    }

    func testDispatchLedgerPersistsAcrossInstances() {
        let path = (dir as NSString).appendingPathComponent("ledger.json")
        XCTAssertTrue(OracleDispatchLedger(path: { path }).claim("d-1"))
        // A fresh instance (≈ app relaunch) still refuses the processed id, so a
        // replayed mailbox line can't start the dispatch a second time.
        let reloaded = OracleDispatchLedger(path: { path })
        XCTAssertFalse(reloaded.claim("d-1"))
        XCTAssertTrue(reloaded.claim("d-2"))
    }

    func testDispatchLedgerEvictsOldestPastCapacity() {
        let path = (dir as NSString).appendingPathComponent("ledger.json")
        let ledger = OracleDispatchLedger(capacity: 2, path: { path })
        XCTAssertTrue(ledger.claim("d-1"))
        XCTAssertTrue(ledger.claim("d-2"))
        XCTAssertTrue(ledger.claim("d-3")) // evicts d-1
        XCTAssertFalse(ledger.claim("d-3"))
        XCTAssertFalse(ledger.claim("d-2"))
        XCTAssertTrue(ledger.claim("d-1")) // evicted → claimable again (bounded memory)
    }

    func testAppendsArePathSafeWithSlashes() throws {
        // withoutEscapingSlashes keeps the path readable in the JSONL (and the agent
        // sees clean paths), while still decoding back exactly.
        try appendOracleDispatch(OracleDispatch(project: "/abs/path/repo", prompt: "x"))
        let raw = try String(contentsOf: URL(fileURLWithPath: OraclePaths.dispatchFile), encoding: .utf8)
        XCTAssertTrue(raw.contains("/abs/path/repo"))
        XCTAssertFalse(raw.contains("\\/"))
    }
}
