import Testing
@testable import JuancodeCore

/// Edge → OS-notification rules for background sessions (juancode-bao).
@Suite struct AgentNotificationTests {
    @Test func turnFinishingInBackgroundNotifies() {
        // App inactive: even the selected session finishing is worth a ding.
        #expect(agentNotificationEffect(prev: .busy, next: .idle, notify: true,
                                        isSelected: true, appActive: false) == .turnFinished)
        // App active but a different (unselected) pane finishes.
        #expect(agentNotificationEffect(prev: .busy, next: .idle, notify: true,
                                        isSelected: false, appActive: true) == .turnFinished)
    }

    @Test func watchedSessionNeverNotifies() {
        // App frontmost and this is the session you're looking at — no surprise.
        #expect(agentNotificationEffect(prev: .busy, next: .idle, notify: true,
                                        isSelected: true, appActive: true) == nil)
        #expect(agentNotificationEffect(prev: .idle, next: .waitingInput, notify: true,
                                        isSelected: true, appActive: true) == nil)
    }

    @Test func waitingForInputNotifiesWhenNotWatched() {
        #expect(agentNotificationEffect(prev: .busy, next: .waitingInput, notify: true,
                                        isSelected: false, appActive: true) == .waitingForInput)
        #expect(agentNotificationEffect(prev: .idle, next: .waitingInput, notify: true,
                                        isSelected: true, appActive: false) == .waitingForInput)
    }

    @Test func teardownResetEdgeDoesNotNotify() {
        // ActivityDetector.reset() emits busy → idle with notify == false.
        #expect(agentNotificationEffect(prev: .busy, next: .idle, notify: false,
                                        isSelected: false, appActive: false) == nil)
    }

    @Test func newTurnStartingDoesNotNotify() {
        // Going busy is not a boundary you need to be told about.
        #expect(agentNotificationEffect(prev: .idle, next: .busy, notify: false,
                                        isSelected: false, appActive: false) == nil)
        #expect(agentNotificationEffect(prev: nil, next: .busy, notify: true,
                                        isSelected: false, appActive: false) == nil)
    }

    @Test func promptClearingBackToIdleDoesNotNotify() {
        // waitingInput → idle is emitted with notify == false (answered/repainted
        // away) and prev != .busy, so it is not a turn end either.
        #expect(agentNotificationEffect(prev: .waitingInput, next: .idle, notify: false,
                                        isSelected: false, appActive: false) == nil)
    }
}
