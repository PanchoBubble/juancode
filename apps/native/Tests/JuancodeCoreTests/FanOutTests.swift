import Testing
@testable import JuancodeCore

/// Unit tests for the pure fan-out naming helpers (branch suffix + group title
/// generation) that back the NewSessionView "compare N agents" flow.
@Suite struct FanOutTests {
    @Test func clampsCountIntoSupportedRange() {
        #expect(FanOut.clampCount(0) == 1)
        #expect(FanOut.clampCount(-3) == 1)
        #expect(FanOut.clampCount(3) == 3)
        #expect(FanOut.clampCount(99) == FanOut.maxAgents)
    }

    @Test func lettersAreSequentialAndClamped() {
        #expect(FanOut.letters(count: 1) == ["a"])
        #expect(FanOut.letters(count: 3) == ["a", "b", "c"])
        #expect(FanOut.letters(count: 5) == ["a", "b", "c", "d", "e"])
        #expect(FanOut.letters(count: 12) == ["a", "b", "c", "d", "e"]) // clamped to max
        #expect(FanOut.letters(count: 0) == ["a"]) // clamped up to 1
    }

    @Test func worktreeNameSuffixesStemWithLetter() {
        #expect(FanOut.worktreeName(stem: "a1b2c3", letter: "a") == "a1b2c3-a")
        #expect(FanOut.worktreeName(stem: "a1b2c3", letter: "c") == "a1b2c3-c")
    }

    @Test func worktreeNamesInAGroupShareStemAndStayDistinct() {
        let stem = "9f8e7d"
        let names = FanOut.letters(count: 4).map { FanOut.worktreeName(stem: stem, letter: $0) }
        #expect(names == ["9f8e7d-a", "9f8e7d-b", "9f8e7d-c", "9f8e7d-d"])
        #expect(Set(names).count == names.count) // all unique
        #expect(names.allSatisfy { $0.hasPrefix(stem) }) // recognizable as one family
    }

    @Test func titleStemTakesCollapsedFirstLine() {
        #expect(FanOut.titleStem(for: "Refactor the   auth module\nand add tests") == "Refactor the auth module")
    }

    @Test func titleStemSkipsLeadingBlanksAndTrimsToMaxLen() {
        #expect(FanOut.titleStem(for: "\n\n  Implement caching  \n") == "Implement caching")
        #expect(FanOut.titleStem(for: "abcdefghijklmnopqrstuvwxyz", maxLen: 10) == "abcdefghij")
    }

    @Test func titleStemOfBlankPromptIsEmpty() {
        #expect(FanOut.titleStem(for: "   \n\t ") == "")
    }

    @Test func groupTitlePairsStemWithUppercasedLetter() {
        #expect(FanOut.groupTitle(stem: "Fix login", letter: "a") == "Fix login · A")
        #expect(FanOut.groupTitle(stem: "Fix login", letter: "b") == "Fix login · B")
    }

    @Test func groupTitleFallsBackToLetterWhenNoStem() {
        #expect(FanOut.groupTitle(stem: "", letter: "a") == "A")
        #expect(FanOut.groupTitle(stem: "   ", letter: "c") == "C")
    }
}
