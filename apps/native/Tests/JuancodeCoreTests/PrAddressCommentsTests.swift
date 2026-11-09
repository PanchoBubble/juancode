import Testing
@testable import JuancodeCore

/// "Address comments" decides which PRs get an agent and what that agent is told. A
/// wrong answer here is a duplicate agent racing on one branch, or an agent pushing to
/// a PR that is not the viewer's.
@Suite struct PrAddressCommentsTests {
    private func pr(_ n: Int, author: String = "me", unresolved: Int = 2,
                    title: String = "Fix it", fork: Bool? = nil) -> PullRequest {
        PullRequest(number: n, title: title, url: "https://github.com/acme/widgets/pull/\(n)",
                    branch: "feat/\(n)", draft: false, checks: .passing, author: author,
                    unresolvedComments: unresolved, isCrossRepository: fork)
    }

    @Test func onlyTheViewersOwnPrsWithOpenThreadsAreEligible() {
        #expect(PrAddressComments.isEligible(pr(1), viewer: "Me"))
        #expect(!PrAddressComments.isEligible(pr(1, unresolved: 0), viewer: "me"))
        #expect(!PrAddressComments.isEligible(pr(1, author: "someone"), viewer: "me"))
        #expect(!PrAddressComments.isEligible(pr(1, fork: true), viewer: "me"))
        #expect(!PrAddressComments.isEligible(pr(1), viewer: ""))
    }

    @Test func aPrAlreadyCoveredNeverSpendsABatchSlot() {
        let plan = PrAddressComments.plan(
            numbers: [1, 2, 3, 4, 5, 6], cap: 2,
            isAddressing: { $0 == 1 }, isTracked: { $0 == 2 })
        #expect(plan.start == [3, 4])
        #expect(plan.skipped.map(\.number) == [1, 2, 5, 6])
        #expect(plan.skipped.map(\.why) == [.alreadyAddressing, .tracked, .overCap, .overCap])
    }

    @Test func promptIsFilledOnceAndCarriesTheReviewTrigger() {
        let p = pr(7, title: "Handle {number} and {branch}")
        let text = PrAddressComments.prompt(
            template: "PR #{number} {title} on {branch}\n{review_step}\n{stack_note}", pr: p,
            repo: "acme/widgets", reviewCommand: "/review", stackSiblings: [])
        // A title that looks like a placeholder is data, not a second expansion.
        #expect(text.contains("PR #7 Handle {number} and {branch} on feat/7"))
        #expect(text.contains("gh pr comment 7 --body '/review'"))
        let none = PrAddressComments.prompt(
            template: "{review_step}", pr: p, repo: "acme/widgets",
            reviewCommand: "  ", stackSiblings: [])
        #expect(none == PrAddressComments.noReviewTrigger)
    }

    @Test func aStackedPrIsToldNotToTouchItsSiblings() {
        let stacked = PrAddressComments.prompt(
            template: PrAddressComments.defaultTemplate, pr: pr(7), repo: "acme/widgets",
            reviewCommand: "/review", stackSiblings: [6, 8])
        #expect(stacked.contains("#6, #8"))
        #expect(stacked.contains("Do not rebase"))
        let alone = PrAddressComments.prompt(
            template: PrAddressComments.defaultTemplate, pr: pr(7), repo: "acme/widgets",
            reviewCommand: "/review", stackSiblings: [])
        #expect(!alone.contains("part of a stack"))
        #expect(!alone.contains("{"))
    }

    @Test func dispatchIdsAreFoundByPrefixAndNeverCollideAcrossPrs() {
        let id = PrAddressComments.dispatchId(repo: "Acme/Widgets", number: 12, nonce: "ab12")
        #expect(id.hasPrefix(PrAddressComments.dispatchIdPrefix(repo: "acme/widgets", number: 12)))
        // #1 must not match #12's agent.
        #expect(!id.hasPrefix(PrAddressComments.dispatchIdPrefix(repo: "acme/widgets", number: 1)))
    }
}
