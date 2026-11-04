import Foundation
import Testing
@testable import JuancodeCore

/// The global PR queue opens on what wants you: which slice a stored preference
/// resolves to, which rows count as wanting you, and the actionable count the badge
/// keeps apart from the quiet total.

private func row(_ n: Int, repo: String = "o/a", _ reason: ViewerPrReason = .mine,
                 checks: PrChecks = .passing,
                 attention: PrAttentionReason? = nil, label: String? = nil) -> ViewerPr {
    let pr = PullRequest(number: n, title: "t\(n)", url: "https://github.com/\(repo)/pull/\(n)",
                         branch: "b\(n)", draft: false, checks: checks, author: "octocat")
    return ViewerPr(pr: pr, repo: repo, reason: reason, attention: attention,
                    attentionLabel: label ?? attention?.label)
}

@Suite struct ViewerPrSlicePreferenceTests {
    @Test func freshInstallOpensTheAttentionView() {
        #expect(ViewerPrSlice(storedRaw: nil) == .needsYou)
        #expect(ViewerPrSlice.attentionDefault == .needsYou)
    }

    @Test func everyExplicitChoiceIsHonoured() {
        for slice in ViewerPrSlice.allCases {
            #expect(ViewerPrSlice(storedRaw: slice.rawValue) == slice)
        }
    }

    @Test func anUnreadablePreferenceFallsBackToAttention() {
        #expect(ViewerPrSlice(storedRaw: "somethingANewerBuildWrote") == .needsYou)
    }
}

@Suite struct ViewerPrAttentionTests {
    private let queue = ViewerPrResult(available: true, rows: [
        row(1),                                            // quiet, green
        row(2, checks: .pending),                          // running checks ask nothing
        row(3, checks: .none),                             // unknown checks ask nothing
        row(4, checks: .failing, attention: .ciFailing),
        row(5, repo: "o/b", .reviewRequested, attention: .reviewRequested),
        row(6, attention: .unresolved),
    ], viewer: "octocat")

    @Test func needsYouIsOnlyWhatKnownFactsAskFor() {
        let rows = viewerPrRows(queue, slice: .needsYou)
        #expect(rows.map(\.pr.number) == [4, 6, 5])
        #expect(viewerPrsNeedingYou(queue) == 3)
    }

    @Test func aTrackingAgentWaitingOnYouJoinsAndLeadsTheQueue() {
        // #1 is green and asks nothing on GitHub, but its agent stopped for a decision.
        let decisions: Set<String> = ["o/a#1"]
        let rows = viewerPrRows(queue, slice: .needsYou, decisions: decisions)
        #expect(rows.map(\.pr.number) == [1, 4, 6, 5])
        #expect(rows.first?.queueAttention(decisions: decisions) == .decisionNeeded)
        #expect(viewerPrCount(queue, slice: .needsYou, decisions: decisions) == 4)
        // A decision on a row the queue does not hold changes nothing.
        #expect(viewerPrsNeedingYou(queue, decisions: ["o/zzz#9"]) == 3)
    }

    @Test func slicesStillListEveryRowTheyCount() {
        let decisions: Set<String> = ["o/a#2"]
        for slice in ViewerPrSlice.allCases {
            #expect(viewerPrCount(queue, slice: slice, decisions: decisions)
                == viewerPrRows(queue, slice: slice, decisions: decisions).count)
        }
        #expect(viewerPrCount(queue, slice: .all, decisions: decisions) == 6)
        #expect(viewerPrCount(queue, slice: .mine, decisions: decisions) == 5)
        #expect(viewerPrCount(queue, slice: .review, decisions: decisions) == 1)
    }

    @Test func tallyKeepsActionableApartFromTheQuietTotal() {
        let tally = viewerPrTally(queue, decisions: ["o/a#1"])
        #expect(tally.actionable == 4)
        #expect(tally.total == 6)
        #expect(tally.quiet == 2)
        #expect(tally.mine == 5)
        #expect(tally.reviewing == 1)
    }

    @Test func aFailedSearchClaimsNoNumbers() {
        let failed = ViewerPrResult(available: false, rows: queue.rows, error: "gh not authenticated")
        #expect(viewerPrTally(failed, decisions: ["o/a#1"]) == ViewerPrTally())
    }

    @Test func rowsSayWhyTheyWantYouInTheCoresWords() {
        let core = row(7, attention: .ciFailing, label: "CI is red")
        #expect(core.queueAttentionLabel() == "CI is red")
        #expect(core.queueAttentionLabel(decisions: [core.id]) == "decision needed")
        #expect(row(8).queueAttentionLabel() == nil)
    }
}
