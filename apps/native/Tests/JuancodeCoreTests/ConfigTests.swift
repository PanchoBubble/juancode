import XCTest
@testable import JuancodeCore

final class ConfigTests: XCTestCase {
    /// Pin the workspace root via the env override so the assertions don't depend
    /// on the host's `~/workdir`. Restored after each test.
    private var savedOverride: String??

    override func setUp() {
        super.setUp()
        savedOverride = ProcessInfo.processInfo.environment["JUANCODE_DEFAULT_CWD"]
        setenv("JUANCODE_DEFAULT_CWD", "/Users/me/workdir", 1)
    }

    override func tearDown() {
        if let saved = savedOverride, let value = saved {
            setenv("JUANCODE_DEFAULT_CWD", value, 1)
        } else {
            unsetenv("JUANCODE_DEFAULT_CWD")
        }
        super.tearDown()
    }

    func testRootItselfCounts() {
        XCTAssertTrue(Config.isUnderWorkspaceRoot("/Users/me/workdir"))
        XCTAssertTrue(Config.isUnderWorkspaceRoot("/Users/me/workdir/"))
    }

    func testNestedReposAndWorktreesKept() {
        XCTAssertTrue(Config.isUnderWorkspaceRoot("/Users/me/workdir/personal/juancode"))
        // Worktrees live in a sibling `<repo>-worktrees/…` dir, still under the root.
        XCTAssertTrue(Config.isUnderWorkspaceRoot("/Users/me/workdir/personal/juancode-worktrees/eng-11509"))
    }

    func testOutsidePathsDropped() {
        XCTAssertFalse(Config.isUnderWorkspaceRoot("/Users/me/.claude/projects/x"))
        XCTAssertFalse(Config.isUnderWorkspaceRoot("/tmp/somewhere"))
    }

    func testSiblingSharingNamePrefixNotMatched() {
        // `/Users/me/workdir-other` must not be treated as inside `/Users/me/workdir`.
        XCTAssertFalse(Config.isUnderWorkspaceRoot("/Users/me/workdir-other/repo"))
    }
}
