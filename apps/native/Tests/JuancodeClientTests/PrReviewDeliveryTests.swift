import Testing
@testable import JuancodeClient

@Suite struct PrReviewDeliveryTests {
    private let remote = "github-pr:https://github.com/acme/widgets/pull/42"

    @Test func urlReviewCanSendToAnExplicitSessionWithoutTracking() {
        #expect(PrReviewDelivery.resolve(cwd: remote, chosenSessionId: "chosen",
                                        trackedSessionId: nil) == .session("chosen"))
        #expect(PrReviewDelivery.resolve(cwd: remote, chosenSessionId: "chosen",
                                        trackedSessionId: "tracker") == .session("chosen"))
    }

    @Test func urlReviewNeverSpawnsAnAgentInTheUrlSentinel() {
        #expect(PrReviewDelivery.resolve(cwd: remote, chosenSessionId: nil,
                                        trackedSessionId: nil) == .chooseSession)
        // A pending track has no recipient yet.
        #expect(PrReviewDelivery.resolve(cwd: remote, chosenSessionId: nil,
                                        trackedSessionId: "") == .chooseSession)
    }

    @Test func automaticDeliveryPreservesTrackingAndLocalSpawning() {
        for cwd in [remote, "/tmp/widgets"] {
            #expect(PrReviewDelivery.resolve(cwd: cwd, chosenSessionId: nil,
                                            trackedSessionId: "tracker") == .session("tracker"))
        }
        #expect(PrReviewDelivery.resolve(cwd: "/tmp/widgets", chosenSessionId: nil,
                                        trackedSessionId: nil) == .trackLocal)
    }
}
