import XCTest
import JuancodeCore
import JuancodeServices
@testable import JuancodeServer

/// The app-quit path (oracle-qb5 / juancode-0f64), end to end over two boots.
///
/// Quitting kills every live pty whatever the agent was doing — they are children
/// of this process, so there is no "spare the busy ones" available here. What went
/// wrong was that the path did not SAY so: 25 mid-turn agents and 25 idle ones
/// persisted identical state and wrote identical log lines, so an interrupted batch
/// was indistinguishable from a clean one and nothing offered to pick the work back
/// up. These tests pin the two halves of the honest version — the reason stamped at
/// kill time, and the durable marker the next boot reads.
final class QuitPathTests: XCTestCase {
    private var dbPath: String!
    private var fakeAgent: String!

    override func setUpWithError() throws {
        dbPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-quitpath-\(UUID().uuidString).db")
        // A pty that needs no real CLI but can paint the two footers the activity
        // detector keys on: the "esc to interrupt" working line (busy) and a
        // permission prompt in the bottom screen band (waitingInput).
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-fake-agent-\(UUID().uuidString).sh")
        let script = """
        #!/bin/bash
        stty -echo 2>/dev/null
        printf 'ready\\n'
        while IFS= read -r line; do
          case "$line" in
          BUSY*)   printf '\\033[2J\\033[H  Thinking… (esc to interrupt)\\n' ;;
          PROMPT*) printf '\\033[2J\\033[H'; for i in $(seq 1 12); do printf '\\n'; done
                   printf 'Do you want to proceed? (y/n)\\n' ;;
          esac
        done
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        fakeAgent = url.path
        setenv("JUANCODE_CLAUDE_BIN", url.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JUANCODE_CLAUDE_BIN")
        try? FileManager.default.removeItem(atPath: fakeAgent)
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + s) }
    }

    private func liveSession(_ state: AppState) throws -> Session {
        try state.registry.create(provider: .claude,
                                  cwd: FileManager.default.temporaryDirectory.path,
                                  cols: 80, rows: 24)
    }

    /// Poll until `check()` holds, or fail. Activity is derived off the pty byte
    /// stream through a settle timer, so nothing about it is synchronous.
    private func waitUntil(
        _ message: String,
        timeoutMs: Int = 5_000,
        _ check: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<(timeoutMs / 20) where !check() {
            await Nap.ms(20)
        }
        XCTAssertTrue(check(), message, file: file, line: line)
    }

    private func drive(_ session: Session, _ command: String,
                       until activity: SessionActivity) async {
        session.write("\(command)\n")
        await waitUntil("session reached \(activity.rawValue)") { session.activity == activity }
    }

    /// The last `dormant` record per session id, out of the shared JSONL activity
    /// log. Keyed by session so a log other tests also append to still reads.
    private func dormantRecords(in path: String) throws -> [String: [String: Any]] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var byId: [String: [String: Any]] = [:]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["event"] as? String == "dormant",
                  let id = obj["session"] as? String else { continue }
            byId[id] = obj
        }
        return byId
    }

    // MARK: - the reason is stamped per session, not per quit

    /// A quit that interrupts a turn must be readable as such in
    /// `session-activity.log`, and readable apart from the idle session slept by the
    /// same quit. Before this, both wrote `reason=quit` and the only difference was
    /// an `activity` field nothing rolled up.
    func testQuitStampsBusyAndIdleSessionsDifferently() async throws {
        let state = try AppState(dbPath: dbPath)
        let busy = try liveSession(state)
        let quiet = try liveSession(state)
        await waitUntil("both sessions idle") {
            busy.activity == .idle && quiet.activity == .idle
        }
        await drive(busy, "BUSY", until: .busy)

        state.shutdownGracefully(timeout: 3.0)

        state.activityLog.flush()
        let records = try dormantRecords(in: state.activityLog.logPath)

        let busyLine = try XCTUnwrap(records[busy.id], "no dormant line for the busy session")
        XCTAssertEqual(busyLine["reason"] as? String, SessionSleepReason.quitBusy.rawValue)
        XCTAssertEqual(busyLine["workInFlight"] as? String, "true")

        let quietLine = try XCTUnwrap(records[quiet.id], "no dormant line for the idle session")
        XCTAssertEqual(quietLine["reason"] as? String, SessionSleepReason.quit.rawValue)
        XCTAssertEqual(quietLine["workInFlight"] as? String, "false")
    }

    // MARK: - the next boot knows which work needs picking back up

    /// The whole point of stamping it: the sessions whose turn the quit aborted come
    /// back flagged, so `SessionRestorePlan.midTurn` can offer to continue them,
    /// while the ones that were merely quiet come back as ordinary sleeping rows.
    ///
    /// A session sitting on a permission prompt is included and is the case that was
    /// missed entirely: `Session.maybePersistMidTurn` only latches `.busy`, so
    /// without the quit path writing the marker itself, a pane whose tool call never
    /// ran was restored with nothing said — and the prompt cannot come back on its
    /// own, since an unanswered menu is not in the transcript.
    func testInterruptedSessionsComeBackFlaggedAndQuietOnesDoNot() async throws {
        let state = try AppState(dbPath: dbPath)
        let busy = try liveSession(state)
        let prompted = try liveSession(state)
        let quiet = try liveSession(state)
        await waitUntil("all three sessions idle") {
            [busy, prompted, quiet].allSatisfy { $0.activity == .idle }
        }
        await drive(busy, "BUSY", until: .busy)
        await drive(prompted, "PROMPT", until: .waitingInput)

        state.shutdownGracefully(timeout: 3.0)

        // Second boot over the same db: it consumes both the slept-on-quit marker and
        // the durable mid-turn column.
        let next = try AppState(dbPath: dbPath)
        XCTAssertTrue(next.crashOrphanIds.isSuperset(of: [busy.id, prompted.id, quiet.id]),
                      "every session live at the quit comes back surfaced")
        XCTAssertEqual(next.midTurnOrphanIds, [busy.id, prompted.id],
                       "the interrupted two, and only those (quiet=\(quiet.id))")

        // And the markers are consumed, so a third boot offers nothing — a stale
        // flag must not keep offering to continue work finished two launches ago.
        let third = try AppState(dbPath: dbPath)
        XCTAssertEqual(third.midTurnOrphanIds, [])
    }
}
