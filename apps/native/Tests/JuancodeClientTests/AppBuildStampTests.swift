import XCTest
@testable import JuancodeClient

/// Whether the app can tell you it is behind, and — as much of the point — whether it
/// stays quiet when it is not.
///
/// The failure being tested for is a day of a fix being invisible: it had landed, it
/// had been pulled into a checkout the running bundle was not built from, and nothing
/// on screen said the window predated it. So the loud cases assert on the number and
/// the ref being named, and the quiet cases matter just as much: a build indicator
/// that lights up one commit after every commit is one nobody will read the day it is
/// telling the truth.
final class AppBuildStampTests: XCTestCase {

    private let built = Date(timeIntervalSince1970: 1_700_000_000)

    private func stamp(commit: String = "8306487f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f",
                       at: Date? = nil, dirty: Bool = false) -> AppBuildStamp {
        AppBuildStamp(sourceRoot: "/checkout", commit: commit,
                      commitAt: at ?? built, dirty: dirty, bundledAt: at ?? built)
    }

    private func drift(_ ref: String, _ commits: Int, hoursNewer: Double = 0) -> CheckoutDrift {
        CheckoutDrift(ref: ref, commits: commits,
                      tipCommittedAt: built.addingTimeInterval(hoursNewer * 3600))
    }

    // MARK: - The stamp

    func testDecodesTheKeysTheBundleScriptWrites() {
        let stamp = AppBuildStamp(info: [
            "JuancodeSourceRoot": "/checkout",
            "JuancodeSourceCommit": "8306487f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f",
            "JuancodeSourceCommitAt": "1700000000",
            "JuancodeSourceDirty": true,
            "JuancodeBundledAt": "1700000900",
        ])
        XCTAssertEqual(stamp?.sourceRoot, "/checkout")
        XCTAssertEqual(stamp?.shortCommit, "8306487")
        XCTAssertEqual(stamp?.commitAt, built)
        XCTAssertEqual(stamp?.dirty, true)
        XCTAssertEqual(stamp?.bundledAt, built.addingTimeInterval(900))
    }

    /// A bare `swift run juancode` has no bundle at all, and half a stamp is not an
    /// answer: without both the root and the commit there is nothing to compare, and
    /// guessing from one of them is how a confident wrong warning gets made.
    func testAHalfStampIsNoStamp() {
        XCTAssertNil(AppBuildStamp(info: nil))
        XCTAssertNil(AppBuildStamp(info: [:]))
        XCTAssertNil(AppBuildStamp(info: ["JuancodeSourceRoot": "/checkout"]))
        XCTAssertNil(AppBuildStamp(info: ["JuancodeSourceCommit": "abc"]))
        // A checkout with no git: the script still writes the keys, empty.
        XCTAssertNil(AppBuildStamp(info: ["JuancodeSourceRoot": "/checkout",
                                          "JuancodeSourceCommit": ""]))
    }

    func testAnUndatedStampStillDecodes() {
        let stamp = AppBuildStamp(info: ["JuancodeSourceRoot": "/checkout",
                                         "JuancodeSourceCommit": "abc1234",
                                         "JuancodeSourceCommitAt": ""])
        XCTAssertNotNil(stamp)
        XCTAssertNil(stamp?.commitAt)
        XCTAssertEqual(stamp?.dirty, false)
    }

    // MARK: - Staying quiet

    func testCurrentBuildSaysNothing() {
        XCTAssertNil(AppStaleness.warning(stamp: stamp(),
                                          drifts: [drift("HEAD", 0), drift("origin/main", 0)],
                                          now: built))
    }

    func testNoRefsAtAllSaysNothing() {
        XCTAssertNil(AppStaleness.warning(stamp: stamp(), drifts: [], now: built))
    }

    /// You are one commit behind the moment you commit, and two while a sibling agent
    /// lands something. Neither is worth a yellow triangle.
    func testAFreshOneCommitDriftSaysNothing() {
        let now = built.addingTimeInterval(120)
        XCTAssertNil(AppStaleness.warning(stamp: stamp(),
                                          drifts: [drift("HEAD", 1, hoursNewer: 0.03)],
                                          now: now))
        XCTAssertNil(AppStaleness.warning(stamp: stamp(),
                                          drifts: [drift("HEAD", 2, hoursNewer: 0.5)],
                                          now: now))
    }

    // MARK: - Speaking up

    func testThreeCommitsIsLoudEvenWhenFresh() {
        let warning = AppStaleness.warning(stamp: stamp(),
                                           drifts: [drift("HEAD", 3, hoursNewer: 0.1)],
                                           now: built.addingTimeInterval(400))
        XCTAssertEqual(warning?.headline, "this app is 3 commits behind the checkout")
        XCTAssertTrue(warning?.detail.contains("dev-app.sh") == true)
    }

    /// The other half of the rule: one commit that has been sitting there since
    /// yesterday morning is not the same fact as one from a minute ago.
    func testOneOldCommitIsLoud() {
        let warning = AppStaleness.warning(stamp: stamp(),
                                           drifts: [drift("HEAD", 1, hoursNewer: 14)],
                                           now: built.addingTimeInterval(14 * 3600))
        XCTAssertEqual(warning?.headline, "this app is 1 commit behind the checkout")
        XCTAssertTrue(warning?.detail.contains("14h newer") == true)
    }

    /// The case that cost the round trip on 2026-09-20, with the numbers measured off
    /// that checkout: 2 commits between the build and the checkout's own HEAD, 19
    /// between the build and origin/main, which had not been pulled. A check against
    /// HEAD alone would have been silent, and silent is exactly what the app already
    /// was.
    func testTheUpstreamDriftIsTheOneThatBurned() {
        let warning = AppStaleness.warning(
            stamp: stamp(),
            drifts: [drift("HEAD", 2, hoursNewer: 0.25), drift("origin/main", 19, hoursNewer: 29)],
            now: built.addingTimeInterval(29 * 3600))
        XCTAssertEqual(warning?.headline, "this app is 19 commits behind origin/main")
        XCTAssertTrue(warning?.detail.contains("git pull") == true,
                      "a checkout that never pulled needs a pull, not just a rebuild")
        XCTAssertFalse(warning?.detail.contains("swift build") == true,
                       "the rebuild-only instruction belongs to the local-HEAD case")
    }

    /// When both refs have moved the same distance they are the same commits, and the
    /// actionable instruction is the shorter one: rebuild.
    func testATieGoesToTheLocalCheckout() {
        let warning = AppStaleness.warning(
            stamp: stamp(),
            drifts: [drift("HEAD", 5, hoursNewer: 1), drift("origin/main", 5, hoursNewer: 1)],
            now: built.addingTimeInterval(3600))
        XCTAssertEqual(warning?.headline, "this app is 5 commits behind the checkout")
    }

    func testTheDetailNamesTheBuildItIsComplainingAbout() {
        let warning = AppStaleness.warning(stamp: stamp(dirty: true),
                                           drifts: [drift("HEAD", 4)],
                                           now: built)
        XCTAssertTrue(warning?.detail.contains("8306487") == true)
        XCTAssertTrue(warning?.detail.contains("/checkout") == true)
        XCTAssertTrue(warning?.detail.contains("dirty tree") == true)
    }

    // MARK: - Asking the checkout

    /// The probe compares against HEAD and against the upstream, and never invents a
    /// number: a ref git will not answer for is dropped, not counted as zero.
    func testProbeAsksBothRefsAndSkipsWhatGitCannotAnswer() async {
        let answers: @Sendable ([String]) async -> String? = { args in
            let verb = args.first ?? ""
            let last = args.last ?? ""
            if verb == "rev-parse" { return "origin/main" }
            if verb == "rev-list" && last.hasSuffix("..HEAD") { return "2" }
            if verb == "rev-list" && last.hasSuffix("..origin/main") { return "17" }
            if verb == "log" && last == "origin/main" { return "1700050400" }
            return nil   // no date for HEAD
        }
        let drifts = await CheckoutProbe.drifts(stamp: stamp(), git: answers)
        XCTAssertEqual(drifts.map(\.ref), ["HEAD", "origin/main"])
        XCTAssertEqual(drifts.map(\.commits), [2, 17])
        XCTAssertNil(drifts[0].tipCommittedAt)
        XCTAssertEqual(drifts[1].tipCommittedAt, Date(timeIntervalSince1970: 1_700_050_400))
    }

    /// A branch with no upstream, and a commit this clone has never heard of (a
    /// rebase, or a bundle built somewhere else). Both are "unknown", and unknown must
    /// never render as a warning.
    func testAnUnknownCommitProducesNoDriftAtAll() async {
        let drifts = await CheckoutProbe.drifts(stamp: stamp(), git: { _ in nil })
        XCTAssertTrue(drifts.isEmpty)
        XCTAssertNil(AppStaleness.warning(stamp: stamp(), drifts: drifts, now: built))
    }

    /// The live path, against this very checkout: the one thing the injected-git tests
    /// above cannot prove is that the argument strings are the ones git accepts. A
    /// build of the commit you are sitting on is not behind its own checkout, and any
    /// typo in the `rev-list` spelling makes that answer missing rather than zero.
    func testTheLiveProbeAnswersForThisCheckout() async throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
        let git = CheckoutProbe.git(in: here)
        guard let head = await git(["rev-parse", "HEAD"]), head.count == 40 else {
            throw XCTSkip("not a git checkout")
        }
        let stamp = AppBuildStamp(sourceRoot: here, commit: head, commitAt: Date(),
                                  dirty: false, bundledAt: Date())
        let drifts = await CheckoutProbe.drifts(stamp: stamp, git: git)
        let local = try XCTUnwrap(drifts.first { $0.isLocal })
        XCTAssertEqual(local.commits, 0)
        XCTAssertNotNil(local.tipCommittedAt)
    }

    /// An unstamped build asks git nothing at all — there is no checkout to ask about,
    /// and shouting "cannot verify" at `swift run` is the nagging this avoids.
    func testAnUnstampedBuildIsSilentAndCheap() async {
        let warning = await AppBuildDrift().warning(stamp: nil)
        XCTAssertNil(warning)
    }
}
