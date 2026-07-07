import Testing
@testable import JuancodeCore

/// Decidable logic behind the "restored from disk" pane banner (juancode-mya): the
/// phase machine that distinguishes a booting resume from a replay-only pane, and
/// the dismiss rules (first live byte / grace / manual X).
@Suite struct SessionRestoredBannerTests {
    typealias B = SessionRestoredBanner

    @Test func opensHiddenAndOnlyRestoreTurnsItOn() {
        // No banner until a restore actually begins.
        #expect(B.reduce(nil, on: .liveOutput) == nil)
        #expect(B.reduce(nil, on: .graceElapsed) == nil)
        #expect(B.reduce(nil, on: .resumeFailed) == nil)
        #expect(B.reduce(nil, on: .restoreBegan) == .resuming)
    }

    @Test func resumingAutoDismissesOnFirstLiveOutput() {
        #expect(B.reduce(.resuming, on: .liveOutput) == nil)
    }

    @Test func resumingAutoDismissesAfterGrace() {
        #expect(B.reduce(.resuming, on: .graceElapsed) == nil)
    }

    @Test func failedResumeDegradesToUnresumable() {
        #expect(B.reduce(.resuming, on: .resumeFailed) == .unresumable)
    }

    @Test func unresumableClearsOnlyOnManualDismiss() {
        // No live pty behind it, so output/grace signals never touch it.
        #expect(B.reduce(.unresumable, on: .liveOutput) == .unresumable)
        #expect(B.reduce(.unresumable, on: .graceElapsed) == .unresumable)
        #expect(B.reduce(.unresumable, on: .dismissed) == nil)
    }

    @Test func dismissAlwaysHides() {
        #expect(B.reduce(.resuming, on: .dismissed) == nil)
        #expect(B.reduce(.unresumable, on: .dismissed) == nil)
    }

    @Test func lateResumeResultCannotResurrectADismissedBanner() {
        // User dismissed while resuming; a resume result landing afterwards must not
        // bring the banner back.
        let dismissed = B.reduce(.resuming, on: .dismissed)
        #expect(dismissed == nil)
        #expect(B.reduce(dismissed, on: .resumeFailed) == nil)
        #expect(B.reduce(dismissed, on: .liveOutput) == nil)
    }

    @Test func titlesDistinguishTheTwoCases() {
        #expect(B.title(for: .resuming).contains("resuming"))
        #expect(B.title(for: .unresumable).contains("couldn't resume"))
    }
}
