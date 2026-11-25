import Testing
@testable import JuancodeCore

/// Stalled only from a known-idle owner with an open obligation; a slept owner is an
/// intentional hold; no activity heard is unknown (juancode-043.3).
@Suite struct ChainHandoffStandingTests {
    private let handoff = ChainHandoff(id: "h1", chainSlug: "c", source: .human,
                                       target: .session("s1"), summary: "do it")

    private func owner(status: SessionStatus = .running, dormant: Bool = false) -> SessionMeta {
        SessionMeta(id: "s1", provider: .claude, cwd: "/tmp", title: "s1", status: status,
                    exitCode: nil, createdAt: 0, updatedAt: 0, cliSessionId: nil,
                    skipPermissions: false, worktreePath: nil, usage: nil, dormant: dormant)
    }

    @Test func standingFollowsOnlyWhatIsKnown() {
        #expect(handoff.standing(owner: owner(), activity: .busy) == .working)
        #expect(handoff.standing(owner: owner(), activity: .idle) == .stalled)
        #expect(handoff.standing(owner: owner(), activity: .waitingInput) == .stalled)
        #expect(handoff.standing(owner: owner(), activity: nil) == .unknown)
        #expect(handoff.standing(owner: owner(status: .exited), activity: nil) == .stalled)
        #expect(handoff.standing(owner: owner(status: .exited, dormant: true), activity: .idle) == .onHold)
        #expect(handoff.standing(owner: nil, activity: .idle) == .gone)
        var toHuman = handoff
        toHuman.target = .human
        #expect(toHuman.standing(owner: nil, activity: nil) == .needsYou)
    }
}
