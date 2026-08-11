import Testing
@testable import JuancodeCore

/// What a relaunch brings back after a crash: one revived pane (the one you were in),
/// every previously-live session surfaced as a restored row, and a mid-turn marker for
/// the optional Continue offer.
@Suite struct SessionRestorePlanTests {
    private static func meta(_ id: String, updatedAt: Int, archived: Bool = false) -> SessionMeta {
        var m = SessionMeta(id: id, provider: .claude, cwd: "/repo", title: id,
                           status: .exited, exitCode: nil, createdAt: 0, updatedAt: updatedAt,
                           cliSessionId: "cli-\(id)", skipPermissions: false,
                           worktreePath: nil, usage: nil)
        m.archived = archived
        return m
    }

    private let rows = [
        Self.meta("a", updatedAt: 300),
        Self.meta("b", updatedAt: 200),
        Self.meta("c", updatedAt: 100),
    ]

    @Test func focusesTheLastPaneAndReopensTheRestByRecency() {
        let plan = SessionRestorePlan.make(previouslyLive: ["a", "b", "c"], metas: rows,
                                           lastFocused: "c", midTurnIds: [])
        #expect(plan.focus == "c")
        #expect(plan.reopen == ["a", "b", "c"])
    }

    /// The crash path: the last-focused marker may never have reached disk, so fall
    /// back to the most recently updated session that was live.
    @Test func fallsBackToNewestWhenLastFocusedIsUnusable() {
        for lastFocused in [nil, "gone", "c"] as [String?] {
            let live: Set<String> = ["a", "b"]
            let plan = SessionRestorePlan.make(previouslyLive: live, metas: rows,
                                               lastFocused: lastFocused, midTurnIds: [])
            #expect(plan.focus == "a")
        }
    }

    /// A session you archived stays away, even if it happened to be open — and if it
    /// was the last-focused one, focus moves on rather than resurrecting it.
    @Test func skipsArchivedAndUnknownIds() {
        let metas = [Self.meta("a", updatedAt: 300, archived: true), Self.meta("b", updatedAt: 200)]
        let plan = SessionRestorePlan.make(previouslyLive: ["a", "b", "deleted"], metas: metas,
                                           lastFocused: "a", midTurnIds: [])
        #expect(plan.reopen == ["b"])
        #expect(plan.focus == "b")
    }

    @Test func nothingLiveMeansNothingRestored() {
        #expect(SessionRestorePlan.make(previouslyLive: [], metas: rows,
                                        lastFocused: "a", midTurnIds: ["a"]) == .empty)
    }

    /// Markers for sessions that aren't being restored are dropped — the store clears
    /// them wholesale at boot, so a stale one must not follow a session around.
    @Test func midTurnIsNarrowedToRestoredSessions() {
        let plan = SessionRestorePlan.make(previouslyLive: ["a", "b"], metas: rows,
                                           lastFocused: nil, midTurnIds: ["b", "c", "ghost"])
        #expect(plan.midTurn == ["b"])
    }

    // MARK: - the Continue offer

    @Test func offersOnlyForALiveMidTurnRestoreThatIsntAlreadyWorking() {
        #expect(SessionContinueOffer.shouldOffer(wasMidTurn: true, isLive: true,
                                                 activity: .idle, handled: false))
        #expect(SessionContinueOffer.shouldOffer(wasMidTurn: true, isLive: true,
                                                 activity: .waitingInput, handled: false))
        // A resume that picked the turn back up on its own needs no nudge.
        #expect(!SessionContinueOffer.shouldOffer(wasMidTurn: true, isLive: true,
                                                  activity: .busy, handled: false))
        // Replay-only pane: nothing to type into.
        #expect(!SessionContinueOffer.shouldOffer(wasMidTurn: true, isLive: false,
                                                  activity: nil, handled: false))
        // Idle at death, or already continued/dismissed.
        #expect(!SessionContinueOffer.shouldOffer(wasMidTurn: false, isLive: true,
                                                  activity: .idle, handled: false))
        #expect(!SessionContinueOffer.shouldOffer(wasMidTurn: true, isLive: true,
                                                  activity: .idle, handled: true))
    }
}
