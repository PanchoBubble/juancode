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

    /// Regression: a tall multi-line seed renders as literal text (no collapsed
    /// chip), so its first line — the signature — sits near the TOP of
    /// the box and scrolls above the bottom rows. Confirming the paste landed by
    /// scanning only the footer slice misses it; scanning the whole screen catches
    /// it. `Session.seedLanded` scans the whole screen for exactly this reason.
    @Test func tallLiteralSeedSignatureIsAboveTheFooterButOnScreen() {
        let sig = InitialPromptDelivery.signature(for: trackerSeed)
        // Render the seed as literal wrapped rows inside the input box: the first
        // line (with the signature) at the top, 20 continuation rows below it.
        var rows = ["╭──────────────────────────────╮", "│ > \(trackerSeed.split(separator: "\n")[0]) │"]
        for i in 0..<20 { rows.append("│   continuation line \(i) of the pasted seed text │") }
        rows.append("╰──────────────────────────────╯")
        let fullScreen = rows.joined(separator: "\n")
        let footer = rows.suffix(16).joined(separator: "\n") // what bottomText(16) would slice

        // The footer-only check (the old behavior) misses the signature entirely...
        #expect(!InitialPromptDelivery.region(footer, contains: sig))
        #expect(!InitialPromptDelivery.regionShowsCollapsedPaste(footer))
        // ...but the whole-screen check (what seedLanded uses) finds it.
        #expect(InitialPromptDelivery.region(fullScreen, contains: sig))
    }

    private var trackerSeed: String {
        """
        [juancode PR-tracker] You are now tracking pull request #123 "Add billing" \
        (branch `feat/billing`): https://example.com/pr/123

        I'll periodically tell you when there's new activity on this PR.
        """
    }
}
