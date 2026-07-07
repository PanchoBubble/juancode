import Testing
@testable import JuancodeCore

/// Edge rules for the sidebar's "done since you last looked" flag (juancode-t9p).
@Suite struct UnseenCompletionTests {
    @Test func turnFinishingOffScreenSets() {
        #expect(unseenCompletionEffect(prev: .busy, next: .idle, notify: true, isSelected: false) == .set)
    }

    @Test func turnFinishingWhileSelectedIsNotUnseen() {
        #expect(unseenCompletionEffect(prev: .busy, next: .idle, notify: true, isSelected: true) == .none)
    }

    @Test func teardownResetEdgeDoesNotFlagKilledSession() {
        // ActivityDetector.reset() emits busy → idle with notify == false.
        #expect(unseenCompletionEffect(prev: .busy, next: .idle, notify: false, isSelected: false) == .none)
    }

    @Test func newTurnClearsStaleDone() {
        #expect(unseenCompletionEffect(prev: .idle, next: .busy, notify: false, isSelected: false) == .clear)
        #expect(unseenCompletionEffect(prev: nil, next: .busy, notify: false, isSelected: false) == .clear)
    }

    @Test func waitingInputIsItsOwnStateNotDone() {
        // busy → waitingInput shows the amber glyph; it must not also flag done.
        #expect(unseenCompletionEffect(prev: .busy, next: .waitingInput, notify: true, isSelected: false) == .none)
    }

    @Test func promptClearingBackToIdleIsNotACompletion() {
        // waitingInput → idle (an answered/repainted-away prompt) is not a turn end.
        #expect(unseenCompletionEffect(prev: .waitingInput, next: .idle, notify: false, isSelected: false) == .none)
    }
}
