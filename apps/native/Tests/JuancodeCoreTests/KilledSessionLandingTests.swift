import Testing
@testable import JuancodeCore

/// Where the selection lands when a session's agent is killed (juancode-x46x):
/// a still-running neighbour, so the pane never falls back to replaying a dead
/// CLI's scrollback as garble.
@Suite struct KilledSessionLandingTests {
    private typealias Row = KilledSessionLanding.Candidate

    private let rows: [Row] = [
        Row(id: "a1", cwd: "/proj/a", live: false),
        Row(id: "a2", cwd: "/proj/a", live: true),
        Row(id: "b1", cwd: "/proj/b", live: true),
        Row(id: "b2", cwd: "/proj/b", live: true),
        Row(id: "b3", cwd: "/proj/b", live: false),
    ]

    @Test func landsOnTheNearestLiveRowInTheSameFolder() {
        #expect(KilledSessionLanding.landing(after: "b3", in: rows) == "b2")
    }

    @Test func prefersTheOwnFolderOverACloserOtherFolderRow() {
        // b1 sits right below a2, but a2's own folder still has a live sibling.
        let ordered = [
            Row(id: "a1", cwd: "/proj/a", live: true),
            Row(id: "a2", cwd: "/proj/a", live: true),
            Row(id: "b1", cwd: "/proj/b", live: true),
        ]
        #expect(KilledSessionLanding.landing(after: "a2", in: ordered) == "a1")
    }

    @Test func fallsOutOfTheFolderWhenNoSiblingIsLive() {
        let ordered = [
            Row(id: "a1", cwd: "/proj/a", live: false),
            Row(id: "a2", cwd: "/proj/a", live: true),
            Row(id: "b1", cwd: "/proj/b", live: true),
        ]
        #expect(KilledSessionLanding.landing(after: "a2", in: ordered) == "b1")
    }

    @Test func equalDistanceLandsOnTheRowBelow() {
        let ordered = [
            Row(id: "x", cwd: "/p", live: true),
            Row(id: "killed", cwd: "/p", live: true),
            Row(id: "y", cwd: "/p", live: true),
        ]
        #expect(KilledSessionLanding.landing(after: "killed", in: ordered) == "y")
    }

    @Test func skipsEditorPanes() {
        let ordered = [
            Row(id: "killed", cwd: "/p", live: true),
            Row(id: "nvim", cwd: "/p", live: true, isEditor: true),
            Row(id: "agent", cwd: "/q", live: true),
        ]
        #expect(KilledSessionLanding.landing(after: "killed", in: ordered) == "agent")
    }

    @Test func staysPutWhenNothingElseIsRunning() {
        let ordered = [
            Row(id: "killed", cwd: "/p", live: true),
            Row(id: "dead", cwd: "/p", live: false),
        ]
        #expect(KilledSessionLanding.landing(after: "killed", in: ordered) == nil)
    }

    @Test func offScreenKilledRowHasNoAnchor() {
        // Collapsed folder / active filter: the killed id isn't in the visible
        // order at all, so the distance rule can't apply — callers fall back.
        #expect(KilledSessionLanding.landing(after: "hidden", in: rows) == nil)
        #expect(KilledSessionLanding.anyLive(excluding: "hidden", in: rows) == "a2")
    }

    @Test func anyLiveSkipsTheKilledRowAndEditors() {
        let ordered = [
            Row(id: "killed", cwd: "/p", live: true),
            Row(id: "nvim", cwd: "/p", live: true, isEditor: true),
            Row(id: "agent", cwd: "/q", live: true),
        ]
        #expect(KilledSessionLanding.anyLive(excluding: "killed", in: ordered) == "agent")
    }
}
