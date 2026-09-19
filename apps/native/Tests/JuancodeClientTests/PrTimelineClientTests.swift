import XCTest
import JuancodeCore

@testable import JuancodeClient

/// The PR conversation as this app decodes it off the daemon.
///
/// The two fixtures are not written by hand: they are what `juancoded` answered at
/// `/api/pr/timeline` and `/api/pr/checks` on 2026-09-19, against the same recorded
/// `gh` output the conformance suite's 45-github scenario uses. A fixture somebody
/// typed would test these types against an idea of the wire; this one tests them
/// against the wire.
///
/// What is asserted is what the panel reads: the chronology's order, the threads the
/// core folded under the review that started them, the reply target a composer needs,
/// and the outcome a check row draws. None of those are computed here any more, so a
/// decode that silently lost one would take the card it feeds with it.
final class PrTimelineClientTests: XCTestCase {

    private static let timelineJSON = #"""
    {
      "state": "OPEN",
      "body": "Fixes the redirect loop.",
      "items": [
        {
          "kind": "commit",
          "id": "commit:abc123def4567890",
          "createdAt": 1788260400000,
          "commit": {
            "oid": "abc123def4567890",
            "abbreviatedOid": "abc123d",
            "messageHeadline": "fix the redirect",
            "author": "octocat",
            "committedDate": 1788260400000
          }
        },
        {
          "kind": "comment",
          "id": "comment:IC_1",
          "createdAt": 1788264000000,
          "comment": {
            "id": "IC_1",
            "databaseId": 111,
            "author": "hubber",
            "authorAvatarUrl": "https://avatars.invalid/hubber.png",
            "body": "Looks good overall",
            "createdAt": 1788264000000,
            "url": "https://github.com/conformance/repo/pull/42#issuecomment-111",
            "reactions": [
              {
                "content": "THUMBS_UP",
                "count": 2
              }
            ]
          }
        },
        {
          "kind": "review",
          "id": "review:PRR_1",
          "createdAt": 1788267600000,
          "review": {
            "id": "PRR_1",
            "author": "hubber",
            "state": "CHANGES_REQUESTED",
            "body": "Needs a test",
            "createdAt": 1788267600000,
            "url": "https://github.com/conformance/repo/pull/42#pullrequestreview-1",
            "comments": [
              {
                "id": "RC_1",
                "databaseId": 222,
                "author": "hubber",
                "body": "This can crash on nil",
                "createdAt": 1788267660000,
                "url": "https://github.com/conformance/repo/pull/42#discussion_r222",
                "path": "Sources/App/Login.swift",
                "line": 42,
                "diffHunk": "@@ -38,6 +38,7 @@ func load() {",
                "reactions": []
              }
            ],
            "reactions": []
          },
          "threadGroups": [
            {
              "id": "RT_1",
              "path": "Sources/App/Login.swift",
              "line": 42,
              "isResolved": false,
              "isOutdated": false,
              "replyTargetId": 222,
              "comments": [
                {
                  "id": "RC_1",
                  "databaseId": 222,
                  "author": "hubber",
                  "body": "This can crash on nil",
                  "createdAt": 1788267660000,
                  "url": "https://github.com/conformance/repo/pull/42#discussion_r222",
                  "path": "Sources/App/Login.swift",
                  "line": 42,
                  "diffHunk": "@@ -38,6 +38,7 @@ func load() {",
                  "reactions": []
                },
                {
                  "id": "RC_2",
                  "databaseId": 333,
                  "author": "octocat",
                  "body": "Fixed",
                  "createdAt": 1788267900000,
                  "url": "https://github.com/conformance/repo/pull/42#discussion_r333",
                  "path": "Sources/App/Login.swift",
                  "line": 42,
                  "reactions": []
                }
              ]
            }
          ]
        }
      ],
      "threads": [
        {
          "id": "RT_1",
          "isResolved": false,
          "isOutdated": false,
          "path": "Sources/App/Login.swift",
          "line": 42,
          "comments": [
            {
              "id": "RC_1",
              "databaseId": 222,
              "author": "hubber",
              "body": "This can crash on nil",
              "createdAt": 1788267660000,
              "url": "https://github.com/conformance/repo/pull/42#discussion_r222",
              "path": "Sources/App/Login.swift",
              "line": 42,
              "diffHunk": "@@ -38,6 +38,7 @@ func load() {",
              "reactions": []
            },
            {
              "id": "RC_2",
              "databaseId": 333,
              "author": "octocat",
              "body": "Fixed",
              "createdAt": 1788267900000,
              "url": "https://github.com/conformance/repo/pull/42#discussion_r333",
              "path": "Sources/App/Login.swift",
              "line": 42,
              "reactions": []
            }
          ]
        }
      ]
    }
    """#

    private static let checksJSON = #"""
    {
      "checks": [
        {
          "name": "build",
          "state": "SUCCESS",
          "bucket": "pass",
          "link": "https://github.com/conformance/repo/actions/runs/900/job/1",
          "outcome": "pass"
        },
        {
          "name": "test",
          "state": "FAILURE",
          "bucket": "fail",
          "link": "https://github.com/conformance/repo/actions/runs/901/job/2",
          "outcome": "fail"
        },
        {
          "name": "flaky",
          "state": "IN_PROGRESS",
          "bucket": "pending",
          "link": "",
          "outcome": "pending"
        },
        {
          "name": "old-status",
          "state": "NEUTRAL",
          "bucket": "",
          "link": "",
          "outcome": "skipped"
        }
      ]
    }
    """#

    private func decodeTimeline() throws -> PrTimeline {
        try JSONDecoder().decode(
            PrTimeline.self, from: Data(Self.timelineJSON.utf8))
    }

    // MARK: - the chronology

    func testTheHeaderAndTheDescriptionComeOffTheTimelineRoute() throws {
        let t = try decodeTimeline()
        XCTAssertEqual(t.state, "OPEN")
        XCTAssertEqual(t.body, "Fixes the redirect loop.")
    }

    func testItemsArriveInTheOrderTheCoreMergedThem() throws {
        let t = try decodeTimeline()
        // The commit landed at 11:00, the issue comment at 12:00, the review at 13:00.
        XCTAssertEqual(t.items.map(\.id),
                       ["commit:abc123def4567890", "comment:IC_1", "review:PRR_1"])
        // PRR_2 is absent: GitHub writes a bare COMMENTED review for every inline
        // reply, and the core drops the ones that would draw as an empty card.
        XCTAssertFalse(t.items.contains { $0.id.contains("PRR_2") })
    }

    func testATimestampIsMillisecondsWithADateBesideIt() throws {
        let t = try decodeTimeline()
        guard case .comment(let c, _, let at) = t.items[1] else {
            return XCTFail("expected the issue comment, got \(t.items[1])")
        }
        XCTAssertEqual(at, 1_788_264_000_000)
        XCTAssertEqual(c.createdAt, at)
        XCTAssertEqual(c.created?.timeIntervalSince1970, 1_788_264_000)
    }

    func testAnIssueCommentCarriesItsAuthorAvatarAndReactions() throws {
        let t = try decodeTimeline()
        guard case .comment(let c, _, _) = t.items[1] else {
            return XCTFail("expected the issue comment, got \(t.items[1])")
        }
        XCTAssertEqual(c.author, "hubber")
        XCTAssertEqual(c.authorAvatarUrl, "https://avatars.invalid/hubber.png")
        XCTAssertEqual(c.reactions.map(\.content), ["THUMBS_UP"])
        XCTAssertEqual(c.reactions.first?.count, 2)
        XCTAssertEqual(c.reactions.first?.emoji, "\u{1F44D}")
        // An issue comment has no location, so no hunk to draw either.
        XCTAssertNil(c.path)
        XCTAssertNil(c.diffHunk)
    }

    // MARK: - the threads the review started

    func testAReviewCarriesTheThreadItStartedWithBothTurnsInIt() throws {
        let t = try decodeTimeline()
        guard case .review(let review, let groups, _, _) = t.items[2] else {
            return XCTFail("expected the review, got \(t.items[2])")
        }
        XCTAssertEqual(review.state, "CHANGES_REQUESTED")
        XCTAssertEqual(review.body, "Needs a test")
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.id, "RT_1")
        XCTAssertEqual(group.path, "Sources/App/Login.swift")
        XCTAssertEqual(group.line, 42)
        XCTAssertFalse(group.isResolved)
        // The reply target is the thread's FIRST comment: GitHub's replies API 422s on
        // a reply to a reply, so a composer aimed at RC_2 would post nothing.
        XCTAssertEqual(group.replyTargetId, 222)
        XCTAssertEqual(group.comments.map(\.id), ["RC_1", "RC_2"])
        XCTAssertEqual(group.root?.id, "RC_1")
        XCTAssertEqual(group.root?.diffHunk, "@@ -38,6 +38,7 @@ func load() {")
        XCTAssertEqual(group.replies.map(\.id), ["RC_2"])
    }

    func testTheRawThreadsTravelAlongsideTheItems() throws {
        let t = try decodeTimeline()
        XCTAssertEqual(t.threads.map(\.id), ["RT_1"])
        XCTAssertEqual(t.threads.first?.comments.count, 2)
        XCTAssertEqual(t.threads.first?.path, "Sources/App/Login.swift")
    }

    func testACommitRowHasItsShaHeadlineAndAuthor() throws {
        let t = try decodeTimeline()
        guard case .commit(let c, _, _) = t.items[0] else {
            return XCTFail("expected the commit, got \(t.items[0])")
        }
        XCTAssertEqual(c.oid, "abc123def4567890")
        XCTAssertEqual(c.abbreviatedOid, "abc123d")
        XCTAssertEqual(c.messageHeadline, "fix the redirect")
        XCTAssertEqual(c.author, "octocat")
        XCTAssertEqual(c.committed?.timeIntervalSince1970, 1_788_260_400)
    }

    // MARK: - what a partial or unknown payload does

    func testAnItemWithOnlyTheFieldsTheCoreAlwaysSendsStillDecodes() throws {
        // Every `Option` field the core skips when it is None, skipped at once.
        let json = #"""
        {"items":[{"kind":"comment","id":"comment:X",
                   "comment":{"id":"X","author":"","body":"","url":"","reactions":[]}}]}
        """#
        let t = try JSONDecoder().decode(PrTimeline.self, from: Data(json.utf8))
        XCTAssertEqual(t.state, "")
        XCTAssertTrue(t.threads.isEmpty)
        guard case .comment(let c, let id, let at) = t.items[0] else {
            return XCTFail("expected a comment, got \(t.items[0])")
        }
        XCTAssertEqual(id, "comment:X")
        XCTAssertNil(at)
        XCTAssertNil(c.created)
        XCTAssertNil(c.databaseId)
    }

    func testAKindThisBuildCannotDrawIsRefusedRatherThanSkipped() {
        // A hole in the middle of a conversation reads as something missing from it,
        // so the whole decode fails and the pane says it could not load.
        let json = #"{"items":[{"kind":"deployment","id":"d:1"}]}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(PrTimeline.self, from: Data(json.utf8)))
    }

    // MARK: - the checks

    func testEachCheckRowArrivesWithItsOutcomeDecided() throws {
        struct Body: Decodable { let checks: [PrCheckRow] }
        let rows = try JSONDecoder()
            .decode(Body.self, from: Data(Self.checksJSON.utf8)).checks
        XCTAssertEqual(rows.map(\.name), ["build", "test", "flaky", "old-status"])
        XCTAssertEqual(rows.map(\.outcome), [.pass, .fail, .pending, .skipped])
        // `failed` is read off the outcome, so the icon and "is CI red" cannot part
        // company the way two separate rules would.
        XCTAssertEqual(rows.filter(\.failed).map(\.name), ["test"])
        // The bucketless commit-status shape is collapsed by the core, not here.
        XCTAssertEqual(rows[3].bucket, "")
        XCTAssertEqual(rows[3].state, "NEUTRAL")
    }
}

/// The same two reads against a REAL `juancoded`, because a fixture can only prove
/// that the types match bytes somebody once captured — not that `GitHubReads` builds
/// the url the core answers on, or that the core still answers it.
///
/// Opt-in and skipped otherwise, like the other live tests here: it needs a daemon,
/// and never :4280 or :4281 (a developer's live app and sidecar own those). Boot one
/// on its own port with the conformance suite's recorded `gh` output, so nothing
/// reaches GitHub:
///
///     cargo build -p juancoded --manifest-path apps/juancoded/Cargo.toml
///     mkdir -p /tmp/gh-ws && cp -R <the suite's .gh-fixtures> /tmp/gh-ws/
///     JUANCODED_PORT=4377 JUANCODE_PORT=4377 \
///     JUANCODE_DATA_DIR=/tmp/juancoded-gh JUANCODED_SOCKET=/tmp/jc-gh.sock \
///     JUANCODE_GH_BIN=apps/wire-conformance/fixtures/fake-gh.sh \
///     ./apps/juancoded/target/debug/juancoded &
///
///     JUANCODE_GH_LIVE_URL=http://127.0.0.1:4377 JUANCODE_GH_LIVE_CWD=/tmp/gh-ws \
///     swift test --package-path apps/native --filter GitHubReadsLiveTests
final class GitHubReadsLiveTests: XCTestCase {
    private var reads: GitHubReads!
    private var cwd: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["JUANCODE_GH_LIVE_URL"], !url.isEmpty,
              let cwd = env["JUANCODE_GH_LIVE_CWD"], !cwd.isEmpty else {
            throw XCTSkip(
                "set JUANCODE_GH_LIVE_URL and JUANCODE_GH_LIVE_CWD to run these")
        }
        self.reads = GitHubReads(baseURL: url, timeout: 20)
        self.cwd = cwd
    }

    func testTheTimelineComesBackOffARunningCore() async throws {
        let fetched = await reads.timeline(
            cwd: cwd, number: 42, prUrl: "https://github.com/conformance/repo/pull/42")
        let timeline = try XCTUnwrap(fetched)
        XCTAssertEqual(timeline.state, "OPEN")
        XCTAssertEqual(timeline.items.map(\.id),
                       ["commit:abc123def4567890", "comment:IC_1", "review:PRR_1"])
        guard case .review(_, let groups, _, _) = timeline.items[2] else {
            return XCTFail("expected the review last, got \(timeline.items[2])")
        }
        XCTAssertEqual(groups.first?.replyTargetId, 222)
        XCTAssertEqual(groups.first?.comments.count, 2)
    }

    func testTheChecksComeBackWithTheirOutcomes() async throws {
        let fetched = await reads.checks(cwd: cwd, number: 42)
        let rows = try XCTUnwrap(fetched)
        XCTAssertEqual(rows.first(where: { $0.name == "test" })?.outcome, .fail)
        XCTAssertEqual(rows.first(where: { $0.name == "build" })?.outcome, .pass)
    }

    func testAPrTheCoreCannotReachIsNilRatherThanAnEmptyConversation() async {
        // The core answers 502 for a PR `gh` cannot read. An empty timeline would draw
        // as a PR nobody has said anything about, so the read has to come back nil.
        let timeline = await reads.timeline(cwd: cwd, number: 42,
                                            prUrl: "https://example.invalid/not-a-pr")
        XCTAssertNil(timeline)
    }

    // The reads and writes juancode-h0l6 moved off this machine. Live rather than
    // fixture-decoded for the same reason the two above are: a fixture cannot prove
    // the app builds the url the core answers on, and half of these are POSTs whose
    // body shape only the core can refuse.

    func testTheListComesBackWithTheTriageAnswerAlreadyDecided() async throws {
        let fetched = await reads.prs(cwd: cwd)
        let body = try XCTUnwrap(fetched)
        XCTAssertTrue(body.available)
        XCTAssertEqual(body.viewer, "octocat")
        XCTAssertEqual(body.prs.map(\.number), [42, 7])
        XCTAssertEqual(body.needsYou.map(\.reason), [.ciFailing, .reviewRequested])
        // The label travels with the reason, so this side keeps no table of them.
        XCTAssertEqual(body.needsYou.first?.text, "CI failing")
        XCTAssertEqual(body.listResult.prs.count, 2)
    }

    func testTheSearchReachesPastThePageAndTheBranchLookupIsItsOwnCall() async throws {
        let searched = await reads.searchPrs(cwd: cwd, query: "author:@me")
        let found = try XCTUnwrap(searched)
        XCTAssertEqual(found.map(\.number), [7])
        let branch = await reads.prForBranch(cwd: cwd, branch: "octocat/fix-login")
        XCTAssertEqual(branch?.number, 42)
    }

    func testTheRepoIdentityComesBack() async {
        let nwo = await reads.repoNwo(cwd: cwd)
        XCTAssertEqual(nwo, "conformance/repo")
    }

    func testThePrDiffIsThePerFileShapeThePanelAlreadyDraws() async throws {
        let diff = try await reads.prDiff(cwd: cwd, number: 42)
        XCTAssertTrue(diff.git)
        XCTAssertEqual(diff.files.map(\.path), ["docs/README.md", "Sources/App/Login.swift"])
        // A rename is one entry at its new path, not a delete and an add.
        XCTAssertEqual(diff.files.first?.oldPath, "README.md")
    }

    func testTheViewerQueueComesBackWithEachRowsAttention() async throws {
        let fetched = await reads.viewerPrs(cwd: cwd)
        let queue = try XCTUnwrap(fetched)
        XCTAssertTrue(queue.available)
        XCTAssertEqual(queue.viewer, "octocat")
        XCTAssertEqual(queue.mine.map(\.pr.number), [42])
        XCTAssertEqual(queue.reviewing.map(\.pr.number), [31])
        XCTAssertEqual(queue.rows.map(\.attention), [.ciFailing, .reviewRequested])
        XCTAssertEqual(viewerPrsNeedingYou(queue), 2)
    }

    func testTheWritesAnswerAndTheirRefusalsCarryAReason() async throws {
        let created = try await reads.createPr(cwd: cwd, title: "t", body: "b", draft: false)
        XCTAssertEqual(created.url, "https://github.com/conformance/repo/pull/99")
        XCTAssertTrue(created.created)
        try await reads.comment(cwd: cwd, number: 42, body: "looks right")
        try await reads.comment(cwd: cwd, number: 42, body: "fixed", replyTo: 222)
        try await reads.rerunChecks(cwd: cwd, number: 42, failedOnly: true)

        // And the refusal path, which is the half a button depends on: the thrown
        // message has to be the core's sentence, not "the request failed".
        do {
            _ = try await reads.createPr(cwd: cwd, title: "  ", body: "b", draft: false)
            XCTFail("a PR with no title must be refused")
        } catch let e as GitHubError {
            XCTAssertTrue(e.message.contains("title"), e.message)
        }
    }
}
