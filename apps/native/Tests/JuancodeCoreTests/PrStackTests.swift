import Testing
@testable import JuancodeCore

struct PrStackTests {
    private func pr(_ number: Int, _ branch: String, _ base: String?,
                    repo: String = "owner/repo", fork: Bool? = false) -> PullRequest {
        PullRequest(number: number, title: "PR", url: "https://github.com/\(repo)/pull/\(number)",
                    branch: branch, draft: false, checks: .passing, author: "author",
                    baseBranch: base, isCrossRepository: fork)
    }

    @Test func connectsWholeStackWithStableIdentity() {
        let rows = [pr(1, "a", "main"), pr(2, "b", "a"), pr(3, "c", "b"),
                    pr(4, "unrelated", "main")]
        let stack = PrStack.containing(rows[0], in: rows)
        #expect(stack?.numbers == [1, 2, 3])
        #expect(PrStack.containing(rows[2], in: rows.reversed()) == stack)
        #expect(PrStack.containing(rows[3], in: rows) == nil)
    }

    @Test func positionsFollowDependenciesInsteadOfPRNumbers() {
        let rows = [pr(90, "base", "main"), pr(12, "middle", "base"), pr(5, "tip", "middle")]
        let stack = PrStack.containing(rows[1], in: rows.reversed())
        #expect(stack?.numbers == [90, 12, 5])
        #expect(stack?.position(of: 90) == 1)
        #expect(stack?.position(of: 12) == 2)
        #expect(stack?.position(of: 5) == 3)
        #expect(stack?.position(of: 999) == nil)
        #expect(stack == PrStack.containing(rows[0], in: rows))
    }

    @Test func branchingStacksKeepParentsBeforeChildren() {
        let rows = [pr(90, "base", "main"), pr(12, "left", "base"), pr(5, "right", "base")]
        let stack = PrStack.containing(rows[2], in: rows + rows)
        #expect(stack?.numbers == [90, 5, 12])
        #expect(stack == PrStack.containing(rows[0], in: rows.reversed()))
    }

    @Test func excludesOtherRepositoriesAndForkHeads() {
        let root = pr(1, "a", "main")
        #expect(PrStack.containing(root, in: [root, pr(2, "b", "a", repo: "other/repo")]) == nil)
        let fork = pr(1, "a", "main", fork: true)
        #expect(PrStack.containing(fork, in: [fork, pr(2, "b", "a")]) == nil)
    }

    @Test func missingMetadataAndCyclesAreSafe() {
        let old = pr(1, "a", nil, fork: nil)
        #expect(PrStack.containing(old, in: [old, pr(2, "b", "a")]) == nil)
        let cycle = [pr(1, "a", "b"), pr(2, "b", "a")]
        #expect(PrStack.containing(cycle[0], in: cycle + cycle)?.numbers == [1, 2])
    }
}
