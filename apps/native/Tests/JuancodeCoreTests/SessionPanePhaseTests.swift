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
