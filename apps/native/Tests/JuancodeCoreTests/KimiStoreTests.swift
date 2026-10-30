import Foundation
import Testing

@testable import JuancodeCore

/// Reads against a fixture kimi home (its own session-store schema: mirror index
/// lines plus per-session `state.json`), so these cover the mapping and the
/// discovery window — not kimi itself.
@Suite struct KimiStoreTests {
    private let fm = FileManager.default

    /// A throwaway kimi home. Sessions live under a workdir key that decodes to
    /// nothing we can match on, so arbitrary key names are used — as kimi does.
    private func makeHome() -> String {
        let home = fm.temporaryDirectory
            .appendingPathComponent("kimi-fixture-\(UUID().uuidString)").path
        return home
    }

    private func mkdir(_ path: String) {
        try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    @discardableResult
    private func writeState(_ home: String, _ sessionDir: String, _ body: String) -> String {
        let dir = (home as NSString).appendingPathComponent(sessionDir)
        mkdir(dir)
        let path = (dir as NSString).appendingPathComponent("state.json")
        fm.createFile(atPath: path, contents: Data(body.utf8))
        return path
    }

    private func writeIndex(_ home: String, _ lines: [String]) {
        mkdir(home)
        fm.createFile(
            atPath: (home as NSString).appendingPathComponent("session_index.jsonl"),
            contents: Data(lines.joined(separator: "\n").utf8))
    }

    private func indexLine(_ id: String, _ sessionDir: String, _ workDir: String) -> String {
        #"{"sessionId":"\#(id)","sessionDir":"\#(sessionDir)","workDir":"\#(workDir)"}"#
    }

    @Test func anIndexLineAnswersWhenTheStateFileConfirmsTheCwdAndClock() {
        let home = makeHome()
        writeIndex(home, [
            indexLine("ses_kimi", "sessions/ws-key/ses_kimi", "/tmp/mine"),
            indexLine("ses_elsewhere", "sessions/other/ses_elsewhere", "/tmp/somebody-else"),
        ])
        writeState(home, "sessions/ws-key/ses_kimi",
                   #"{"title":"Our session","createdAt":2000,"updatedAt":2000,"cwd":"/tmp/mine","custom":{}}"#)
        writeState(home, "sessions/other/ses_elsewhere",
                   #"{"createdAt":1500,"cwd":"/tmp/somebody-else"}"#)

        let rows = KimiStore.sessions(directory: "/tmp/mine", home: home)
        #expect(rows.map(\.id) == ["ses_kimi"])
        #expect(rows.first?.directory == "/tmp/mine")
        #expect(rows.first?.title == "Our session")

        // A different directory is not ours, however recent it is.
        #expect(KimiStore.sessions(directory: "/tmp/nobody", home: home).isEmpty)
        // Before the spawn floor is somebody else's conversation.
        #expect(KimiStore.scanOnce(cwd: "/tmp/mine", sinceMs: 8_000, home: home) == nil)
        #expect(KimiStore.scanOnce(cwd: "/tmp/mine", sinceMs: 2_000, home: home) == "ses_kimi")
    }

    @Test func aLaggingMirrorFallsBackToTheSessionTree() {
        let home = makeHome()
        writeState(home, "sessions/ws-key/ses_kimi",
                   #"{"createdAt":2000,"title":"fresh","cwd":"/tmp/mine"}"#)
        writeIndex(home, [])  // the mirror has not caught up yet

        // The state file's mtime is "now", so the mtime prefilter lets it through;
        // the state's own createdAt (2000, inside a spawn at 2000) is what answers.
        #expect(KimiStore.scanOnce(cwd: "/tmp/mine", sinceMs: 2_000, home: home) == "ses_kimi")
        #expect(KimiStore.sessions(directory: "/tmp/mine", home: home).map(\.id) == ["ses_kimi"])
    }

    @Test func aChildSessionIsNeverAQuietCandidate() {
        let home = makeHome()
        writeState(home, "sessions/ws-key/ses_child",
                   #"{"createdAt":2000,"cwd":"/tmp/mine","custom":{"parent_session_id":"ses_parent","child_session_kind":"child"}}"#)
        #expect(KimiStore.sessions(directory: "/tmp/mine", home: home).isEmpty)
        // Inside a real window too — the child flag, not the clock, is what keeps
        // kimi's own subagent session out of the answer.
        #expect(KimiStore.scanOnce(cwd: "/tmp/mine", sinceMs: 2_000, home: home) == nil)
    }

    @Test func anArchivedSessionStaysOutOfTheAnswer() {
        let home = makeHome()
        writeState(home, "sessions/ws-key/ses_gone",
                   #"{"createdAt":2000,"archived":true,"cwd":"/tmp/mine"}"#)
        #expect(KimiStore.sessions(directory: "/tmp/mine", home: home).isEmpty)
        #expect(KimiStore.scanOnce(cwd: "/tmp/mine", sinceMs: 2_000, home: home) == nil)
    }

    @Test func theLegacySessionMetaLayoutIsReadToo() {
        let home = makeHome()
        // Legacy spelling: `session-meta/state.json` inside the session dir.
        let dir = (home as NSString)
            .appendingPathComponent("sessions/ws-key/ses_legacy/session-meta")
        mkdir(dir)
        fm.createFile(
            atPath: (dir as NSString).appendingPathComponent("state.json"),
            contents: Data(#"{"createdAt":2000,"title":"legacy","cwd":"/tmp/mine"}"#.utf8))
        writeIndex(home, [indexLine("ses_legacy", "sessions/ws-key/ses_legacy", "/tmp/mine")])

        #expect(KimiStore.session("ses_legacy", home: home)?.title == "legacy")
    }

    @Test func anIsoCreatedClockParsesLikeJsDoes() {
        let home = makeHome()
        writeIndex(home, [indexLine("ses_1", "sessions/k/ses_1", "/tmp/mine")])
        writeState(home, "sessions/k/ses_1",
                   #"{"createdAt":"1970-01-01T00:00:02.000Z"}"#)
        // No cwd anywhere in the state — the index line's workDir claim is what ties
        // the row to a directory.
        #expect(KimiStore.session("ses_1", home: home)?.directory == "/tmp/mine")
        #expect(KimiStore.session("ses_1", home: home)?.createdMs == 2_000)
        #expect(KimiStore.scanOnce(cwd: "/tmp/mine", sinceMs: 2_000, home: home) == "ses_1")
    }

    @Test func garbageTimeParsesAsZeroAndCanNeverBeDiscovered() {
        #expect(KimiStore.parseTimeMs("not a time" as Any?) == 0)
        #expect(KimiStore.parseTimeMs(2_000 as Any?) == 2_000)
        #expect(KimiStore.parseTimeMs(1_999.9 as Any?) == 1_999)
        #expect(KimiStore.parseTimeMs(nil) == 0)
    }

    @Test func discoveryPicksTheConversationClosestToTheSpawn() {
        let home = makeHome()
        writeIndex(home, [
            indexLine("ses_early", "sessions/k/ses_early", "/tmp/mine"),
            indexLine("ses_late", "sessions/k/ses_late", "/tmp/mine"),
        ])
        writeState(home, "sessions/k/ses_early", #"{"createdAt":1000,"cwd":"/tmp/mine"}"#)
        writeState(home, "sessions/k/ses_late", #"{"createdAt":5500,"cwd":"/tmp/mine"}"#)

        #expect(KimiStore.scanOnce(cwd: "/tmp/mine", sinceMs: 5_000, home: home) == "ses_late")
        #expect(KimiStore.scanOnce(cwd: "/tmp/mine", sinceMs: 2_000, home: home) == "ses_early")
        // Past the 30s ceiling a fresh session in the dir is not ours.
        #expect(KimiStore.scanOnce(cwd: "/tmp/mine", sinceMs: 60_000, home: home) == nil)
    }

    @Test func recentSessionsOrdersAcrossDirectoriesNewestTouchedFirst() {
        let home = makeHome()
        writeIndex(home, [
            indexLine("ses_a", "sessions/k/ses_a", "/a"),
            indexLine("ses_b", "sessions/k/ses_b", "/b"),
            indexLine("ses_child", "sessions/k/ses_child", "/a"),
        ])
        writeState(home, "sessions/k/ses_a",
                   #"{"createdAt":1,"updatedAt":10,"title":"stale","cwd":"/a"}"#)
        writeState(home, "sessions/k/ses_b",
                   #"{"createdAt":2,"updatedAt":99,"title":"hot","cwd":"/b"}"#)
        // A child session of kimi's own subagent is never surfaced.
        writeState(home, "sessions/k/ses_child",
                   #"{"createdAt":3,"updatedAt":999,"cwd":"/a","custom":{"parent_session_id":"ses_b"}}"#)

        #expect(KimiStore.recentSessions(limit: 5, home: home).map(\.id) == ["ses_b", "ses_a"])
        #expect(KimiStore.recentSessions(limit: 1, home: home).map(\.id) == ["ses_b"])
    }

    @Test func aMissingHomeReadsAsEmptyRatherThanThrowing() {
        let missing = "/tmp/juancode-no-such-kimi-\(UUID().uuidString)"
        #expect(KimiStore.session("ses_x", home: missing) == nil)
        #expect(KimiStore.recentSessions(limit: 5, home: missing).isEmpty)
        #expect(KimiStore.sessions(directory: "/repo", home: missing).isEmpty)
        #expect(KimiStore.scanOnce(cwd: "/repo", sinceMs: 0, home: missing) == nil)
    }

    @Test func titleFallsBackToTheOpeningPromptLikeKimisOwnDisplay() {
        let home = makeHome()
        writeIndex(home, [
            indexLine("ses_none", "sessions/k/ses_none", "/repo"),
            indexLine("ses_prompt", "sessions/k/ses_prompt", "/repo"),
            indexLine("ses_real", "sessions/k/ses_real", "/repo"),
        ])
        writeState(home, "sessions/k/ses_none", #"{"createdAt":1,"cwd":"/repo"}"#)
        writeState(home, "sessions/k/ses_prompt",
                   #"{"createdAt":2,"lastPrompt":"Wire up   the paste engine","cwd":"/repo"}"#)
        writeState(home, "sessions/k/ses_real",
                   #"{"createdAt":3,"title":"Proper title","lastPrompt":"ignored once titled","cwd":"/repo"}"#)

        #expect(KimiStore.title("ses_none", home: home) == nil)
        // Whitespace collapsed by `tidy`, like every other provider's title.
        #expect(KimiStore.title("ses_prompt", home: home) == "Wire up the paste engine")
        #expect(KimiStore.title("ses_real", home: home) == "Proper title")
        #expect(KimiStore.title("ses_missing", home: home) == nil)
    }

    @Test func capturePollsUntilTheStateFileLandsOrTheWindowCloses() async {
        let home = makeHome()
        // A fixture state file that already exists but predates the spawn: the scan
        // answers nothing, so capture must stop at its deadline rather than hang.
        let since = Int(Date().timeIntervalSince1970 * 1000)
        let id = await KimiStore.capture(
            cwd: "/tmp/mine", sinceMs: since - 60_000,
            timeoutMs: 50, intervalMs: 10, home: home)
        #expect(id == nil)

        // And the happy path doesn't wait: the state file is already there.
        writeIndex(home, [indexLine("ses_kimi", "sessions/ws-key/ses_kimi", "/tmp/mine")])
        writeState(home, "sessions/ws-key/ses_kimi",
                   #"{"createdAt":\#(since - 100),"cwd":"/tmp/mine"}"#)
        let found = await KimiStore.capture(
            cwd: "/tmp/mine", sinceMs: since - 5_000,
            timeoutMs: 500, intervalMs: 10, home: home)
        #expect(found == "ses_kimi")
    }
}
