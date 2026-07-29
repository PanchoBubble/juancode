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
        // The standardized root is memoized per process (it's read ~550x per sidebar
        // render), so moving the env override mid-run needs an explicit invalidation.
        Config.invalidateWorkspaceRootCache()
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

    /// The clean-path fast path skips `standardizingPath`, so it has to agree with the
    /// standardizing path on every shape — including the messy ones it must NOT skip.
    func testUnstandardizedPathsStillResolveCorrectly() {
        for path in ["/Users/me/workdir/./repo",
                     "/Users/me/workdir/personal/../repo",
                     "/Users/me/workdir//repo",
                     "/Users/me/workdir/repo/",
                     "/Users/me/workdir/repo/.",
                     "/Users/me/workdir/.."] {
            XCTAssertEqual(Config.isUnderWorkspaceRoot(path),
                           referenceIsUnderWorkspaceRoot(path),
                           "disagreed on \(path)")
        }
    }

    func testStandardizedPathsMatchReference() {
        for path in ["/Users/me/workdir", "/Users/me/workdir/repo", "/Users/me/workdir-other/x",
                     "/tmp/elsewhere", "/", "relative/path"] {
            XCTAssertEqual(Config.isUnderWorkspaceRoot(path),
                           referenceIsUnderWorkspaceRoot(path),
                           "disagreed on \(path)")
        }
    }

    /// The original implementation, standardizing unconditionally — the oracle the
    /// optimized version is checked against.
    private func referenceIsUnderWorkspaceRoot(_ path: String) -> Bool {
        let root = (Config.workspaceRoot as NSString).standardizingPath
        let p = (path as NSString).standardizingPath
        return p == root || p.hasPrefix(root + "/")
    }

    // MARK: - tracked-PR poll interval (webhook-gated slow reconciler)

    func testPrPollIntervalDemotesToSlowReconcilerInWebhookMode() {
        XCTAssertEqual(Config.prPollInterval(webhookConfigured: false), .seconds(60))
        XCTAssertEqual(Config.prPollInterval(webhookConfigured: true), .seconds(300))
    }

    func testGhWebhookConfiguredTracksSecretEnv() {
        let saved = ProcessInfo.processInfo.environment["JUANCODE_GH_WEBHOOK_SECRET"]
        defer {
            if let saved { setenv("JUANCODE_GH_WEBHOOK_SECRET", saved, 1) }
            else { unsetenv("JUANCODE_GH_WEBHOOK_SECRET") }
        }

        unsetenv("JUANCODE_GH_WEBHOOK_SECRET")
        XCTAssertFalse(Config.ghWebhookConfigured)
        XCTAssertEqual(Config.prPollInterval, .seconds(60))

        // Whitespace-only is not configured.
        setenv("JUANCODE_GH_WEBHOOK_SECRET", "  ", 1)
        XCTAssertFalse(Config.ghWebhookConfigured)

        setenv("JUANCODE_GH_WEBHOOK_SECRET", "dummy-test-value", 1)
        XCTAssertTrue(Config.ghWebhookConfigured)
        XCTAssertEqual(Config.prPollInterval, .seconds(300))
    }
}
