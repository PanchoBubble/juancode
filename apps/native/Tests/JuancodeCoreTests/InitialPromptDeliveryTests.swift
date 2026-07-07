import Testing
@testable import JuancodeCore

/// Unit tests for the pure prompt-delivery matchers that back `Session.autoSubmit`.
/// Mirrors `apps/server/src/initialPromptDelivery.test.ts`.
@Suite struct InitialPromptDeliveryTests {
    @Test func signatureTakesNormalizedPrefixOfFirstLine() {
        let sig = InitialPromptDelivery.signature(for: "Fix the   login bug\nand add a test", maxLen: 24)
        #expect(sig == "fix the login bug")
    }

    @Test func signatureSkipsLeadingBlankLines() {
        let sig = InitialPromptDelivery.signature(for: "\n\n  Implement caching  \n", maxLen: 24)
        #expect(sig == "implement caching")
    }

    @Test func signatureIsCappedToMaxLen() {
        let sig = InitialPromptDelivery.signature(for: "abcdefghijklmnopqrstuvwxyz", maxLen: 10)
        #expect(sig == "abcdefghij")
    }

    @Test func signatureOfBlankPromptIsEmpty() {
        #expect(InitialPromptDelivery.signature(for: "   \n\t ") == "")
    }

    @Test func regionMatchesAcrossBoxPaddingAndCase() {
        // How claude renders the input box: borders + padding around the text.
        let box = "╭───────────────╮\n│ > Fix the   LOGIN bug      │\n╰───────────────╯"
        let sig = InitialPromptDelivery.signature(for: "fix the login bug")
        #expect(InitialPromptDelivery.region(box, contains: sig))
    }

    @Test func regionReportsPromptGoneAfterSubmit() {
        // After submit the input box is empty (the prompt moved up into history).
        let emptyBox = "╭───────────────╮\n│ >                          │\n╰───────────────╯"
        let sig = InitialPromptDelivery.signature(for: "fix the login bug")
        #expect(!InitialPromptDelivery.region(emptyBox, contains: sig))
    }

    @Test func emptySignatureNeverMatches() {
        #expect(!InitialPromptDelivery.region("anything at all", contains: ""))
    }

    @Test func detectsCollapsedPasteChip() {
        // Claude collapses a large/multi-line paste into a chip; the literal first
        // line never renders, so the chip is the only proof the paste landed.
        let box = "╭───────────────╮\n│ > [Pasted text #1 +29 lines]  │\n╰───────────────╯"
        #expect(InitialPromptDelivery.regionShowsCollapsedPaste(box))
        let sig = InitialPromptDelivery.signature(for: "Implement the new billing module")
        #expect(!InitialPromptDelivery.region(box, contains: sig))
    }

    @Test func ordinaryInputBoxHasNoPasteChip() {
        let box = "╭───────────────╮\n│ > Fix the login bug        │\n╰───────────────╯"
        #expect(!InitialPromptDelivery.regionShowsCollapsedPaste(box))
    }
}
