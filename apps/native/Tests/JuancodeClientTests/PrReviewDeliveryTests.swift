import Testing
@testable import JuancodeClient

@Suite struct PrReviewDeliveryTests {
    @Test func explicitSessionWinsOverTracker() {
        #expect(PrReviewDelivery.resolve(chosenSessionId: "chosen",
                                        trackedSessionId: nil) == .session("chosen"))
        #expect(PrReviewDelivery.resolve(chosenSessionId: "chosen",
                                        trackedSessionId: "tracker") == .session("chosen"))
    }

    @Test func existingTrackerIsTheAutomaticRecipient() {
        #expect(PrReviewDelivery.resolve(chosenSessionId: nil,
                                        trackedSessionId: "tracker") == .session("tracker"))
    }

    @Test func missingRecipientRequiresChoiceInsteadOfTracking() {
        #expect(PrReviewDelivery.resolve(chosenSessionId: nil,
                                        trackedSessionId: nil) == .chooseSession)
        // A pending track has no recipient yet.
        #expect(PrReviewDelivery.resolve(chosenSessionId: nil,
                                        trackedSessionId: "") == .chooseSession)
    }
}
