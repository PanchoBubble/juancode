import Testing
@testable import JuancodeCore

/// What a session pane renders (juancode-p6tw): the live pty wins, an in-flight
/// resume shows a loading card instead of the garbled scrollback replay, and the raw
/// replay is reserved for panes with nothing else to show.
@Suite struct SessionPanePhaseTests {
    private func phase(live: Bool = false, drawn: Bool = false,
                       activating: Bool = false, stopped: Bool = false) -> SessionPanePhase {
        SessionPaneState.phase(isLive: live, hasDrawn: drawn,
                               isActivating: activating, isStopped: stopped)
    }

    @Test func livePtyWithOutputRenders() {
        #expect(phase(live: true, drawn: true) == .live)
    }

    @Test func freshSpawnBootsBeforeItsFirstByte() {
        #expect(phase(live: true, drawn: false) == .booting)
    }

    @Test func livePtyOutranksEveryStaleFlag() {
        // A resume that finished, or a kill the session already came back from.
        #expect(phase(live: true, drawn: true, activating: true, stopped: true) == .live)
    }

    @Test func inFlightResumeReplacesTheReplay() {
        #expect(phase(activating: true) == .resuming)
    }

    @Test func reopeningAKilledPaneShowsTheResumeNotTheStoppedCard() {
        // Reopening revives it, so the loading card is the accurate story.
        #expect(phase(activating: true, stopped: true) == .resuming)
    }

    @Test func killedAndIdleShowsTheStoppedCard() {
        #expect(phase(stopped: true) == .stopped)
    }

    @Test func nothingInFlightFallsBackToReplay() {
        #expect(phase() == .replay)
    }
}

/// Reconciling the first-byte watches that decide `.booting` vs `.live`. The revive
/// case is the one that stuck: a pane back from the dead with no watch left on it.
@Suite struct FirstOutputWatchPlanTests {
    private func plan(live: Set<String> = [], watched: Set<String> = [],
                      drawn: Set<String> = []) -> FirstOutputWatchPlan {
        SessionPaneState.firstOutputWatches(live: live, watched: watched, drawn: drawn)
    }

    @Test func revivedPaneWithNoWatchLeftGetsOneArmed() {
        // Exited, so its watch and drawn flag were dropped; live again now, and no
        // create announced it. Nothing else would ever clear the booting hint.
        #expect(plan(live: ["a"]).arm == ["a"])
    }

    @Test func aPaneAlreadyWatchedIsNotRearmed() {
        #expect(plan(live: ["a"], watched: ["a"]).arm.isEmpty)
    }

    @Test func aPaneThatAlreadyPaintedNeedsNoWatch() {
        #expect(plan(live: ["a"], drawn: ["a"]).arm.isEmpty)
    }

    @Test func deadPanesLoseTheirWatchAndTheirDrawnFlag() {
        let p = plan(live: ["a"], watched: ["a", "b"], drawn: ["a", "c"])
        #expect(p.cancel == ["b"])
        #expect(p.forget == ["c"])
        #expect(p.arm.isEmpty)
    }

    @Test func nothingLiveClearsEverything() {
        let p = plan(watched: ["a"], drawn: ["a"])
        #expect(p.cancel == ["a"])
        #expect(p.forget == ["a"])
        #expect(p.arm.isEmpty)
    }
}
