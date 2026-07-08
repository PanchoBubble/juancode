import XCTest
@testable import JuancodeServices

/// `ProcessReaper.parseVitestTrees` groups `ps` output into stuck vitest trees.
final class ProcessReaperTests: XCTestCase {
    // A launcher (pnpm vitest) under a shell, its vitest main, and two workers —
    // plus unrelated processes that must be ignored. RSS is KB, as `ps` reports.
    private let sample = """
     1389  1000  5000 -zsh
     1466  1389 71264 node /Users/x/.nvm/bin/pnpm vitest related --bail 0 --passWithNoTests
     1468  1466 434480 node (vitest)
     3456  1468 602880 node (vitest 2)
     3674  1468 517920 node (vitest 7)
     2222  1000 120000 node /Users/x/some/other/app.js
    """

    func testGroupsWorkersUnderLauncher() {
        let trees = ProcessReaper.parseVitestTrees(psOutput: sample)
        XCTAssertEqual(trees.count, 1)
        let tree = trees[0]
        XCTAssertEqual(tree.rootPid, 1466)
        XCTAssertEqual(tree.pids, [1466, 1468, 3456, 3674])
        XCTAssertEqual(tree.processCount, 4)
        XCTAssertTrue(tree.command.contains("pnpm vitest related"))
    }

    func testSumsRSSAcrossTreeInBytes() {
        let tree = ProcessReaper.parseVitestTrees(psOutput: sample)[0]
        // (71264 + 434480 + 602880 + 517920) KB * 1024
        XCTAssertEqual(tree.totalRSSBytes, (71264 + 434480 + 602880 + 517920) * 1024)
    }

    func testIgnoresNonVitestProcesses() {
        let trees = ProcessReaper.parseVitestTrees(psOutput: sample)
        XCTAssertFalse(trees.contains { $0.pids.contains(2222) || $0.pids.contains(1389) })
    }

    func testIgnoresShellThatMerelyMentionsVitest() {
        // A shell running a script that references vitest must not be treated as a
        // vitest process — only node executables count.
        let out = """
         500  1 4000 /bin/zsh -c "pnpm vitest related && echo done"
         600  1 5000 node /x/pnpm vitest related
         601 600 6000 node (vitest)
        """
        let trees = ProcessReaper.parseVitestTrees(psOutput: out)
        XCTAssertEqual(trees.count, 1)
        XCTAssertEqual(trees[0].pids, [600, 601])
        XCTAssertFalse(ProcessReaper.isVitestProcess("/bin/zsh -c \"pnpm vitest related\""))
        XCTAssertTrue(ProcessReaper.isVitestProcess("node (vitest 2)"))
    }

    func testNoVitestIsEmpty() {
        let out = " 100 1 5000 -zsh\n 200 100 6000 node app.js\n"
        XCTAssertEqual(ProcessReaper.parseVitestTrees(psOutput: out), [])
    }

    func testSeparateLaunchersAreSeparateTrees() {
        let out = """
         10  1 1000 node /a/pnpm vitest related
         11 10 2000 node (vitest)
         20  1 3000 node /b/pnpm vitest related
         21 20 4000 node (vitest)
        """
        let trees = ProcessReaper.parseVitestTrees(psOutput: out)
        XCTAssertEqual(trees.count, 2)
        // Largest RSS first: the 20-tree (3000+4000) outranks the 10-tree (1000+2000).
        XCTAssertEqual(trees.map(\.rootPid), [20, 10])
    }
}
