import Testing
@testable import JuancodeCore

/// Attention bucketing, smart sort, and fuzzy matching for the ⌘K jump palette
/// and the sidebar's within-project ordering (juancode-dr0).
@Suite struct JumpPaletteTests {
    // MARK: attention bucketing

    @Test func attentionMirrorsTheSidebarGlyphVocabulary() {
        #expect(sessionAttention(live: true, activity: .waitingInput, unseenDone: false) == .waitingInput)
        #expect(sessionAttention(live: true, activity: .idle, unseenDone: true) == .doneUnseen)
        #expect(sessionAttention(live: true, activity: .busy, unseenDone: false) == .working)
        #expect(sessionAttention(live: true, activity: .idle, unseenDone: false) == .idle)
        #expect(sessionAttention(live: true, activity: nil, unseenDone: false) == .idle)
        #expect(sessionAttention(live: false, activity: nil, unseenDone: false) == .exited)
    }

    @Test func waitingBeatsDoneUnseenEvenWhenBothApply() {
        // A waiting prompt is the louder signal; done-unseen only marks idle sessions.
        #expect(sessionAttention(live: true, activity: .waitingInput, unseenDone: true) == .waitingInput)
    }

    @Test func busyWithStaleUnseenFlagStillReadsWorking() {
        #expect(sessionAttention(live: true, activity: .busy, unseenDone: true) == .working)
    }

    @Test func deadSessionIsExitedRegardlessOfLastActivity() {
        #expect(sessionAttention(live: false, activity: .busy, unseenDone: true) == .exited)
    }

    // MARK: smart sort

    private func key(_ attention: SessionAttention, updated: Int = 0, created: Int = 0) -> SessionSortKey {
        SessionSortKey(attention: attention, updatedAt: updated, createdAt: created)
    }

    @Test func attentionOrderIsWaitingDoneWorkingIdleExited() {
        let keys: [SessionAttention] = [.exited, .idle, .working, .doneUnseen, .waitingInput]
        let sorted = keys.map { key($0) }.sorted(by: smartSortPrecedes).map(\.attention)
        #expect(sorted == [.waitingInput, .doneUnseen, .working, .idle, .exited])
    }

    @Test func withinABucketMostRecentlyActiveWins() {
        let older = key(.working, updated: 100)
        let newer = key(.working, updated: 200)
        #expect(smartSortPrecedes(newer, older))
        #expect(!smartSortPrecedes(older, newer))
    }

    @Test func attentionOutranksRecency() {
        let staleWaiting = key(.waitingInput, updated: 10)
        let freshWorking = key(.working, updated: 99_999)
        #expect(smartSortPrecedes(staleWaiting, freshWorking))
    }

    @Test func identicalUpdatedAtFallsBackToCreatedAt() {
        let a = key(.idle, updated: 100, created: 5)
        let b = key(.idle, updated: 100, created: 9)
        #expect(smartSortPrecedes(b, a))
    }

    // MARK: stable sink order (juancode-05u)

    @Test func liveSessionsPrecedeDeadOnes() {
        let live = SinkSortKey(down: false, createdAt: 1, id: "a")
        let dead = SinkSortKey(down: true, createdAt: 9_999, id: "b")
        #expect(sinkDownPrecedes(live, dead))
        #expect(!sinkDownPrecedes(dead, live))
    }

    @Test func amongLiveNewestComesFirst() {
        let older = SinkSortKey(down: false, createdAt: 100, id: "a")
        let newer = SinkSortKey(down: false, createdAt: 200, id: "b")
        #expect(sinkDownPrecedes(newer, older))
        #expect(!sinkDownPrecedes(older, newer))
    }

    @Test func activityIsIrrelevantToTheOrder() {
        // A busy and an idle session with the same liveness + createdAt sort only
        // by id — nothing about their activity can reorder them (no jumping).
        let a = SinkSortKey(down: false, createdAt: 100, id: "a")
        let b = SinkSortKey(down: false, createdAt: 100, id: "b")
        #expect(sinkDownPrecedes(a, b))
        #expect(!sinkDownPrecedes(b, a))
    }

    @Test func deadOnesSinkAndStayNewestFirstAmongThemselves() {
        let keys = [
            SinkSortKey(down: true, createdAt: 300, id: "d-new"),
            SinkSortKey(down: false, createdAt: 100, id: "l-old"),
            SinkSortKey(down: true, createdAt: 50, id: "d-old"),
            SinkSortKey(down: false, createdAt: 200, id: "l-new"),
        ]
        let order = keys.sorted(by: sinkDownPrecedes).map(\.id)
        #expect(order == ["l-new", "l-old", "d-new", "d-old"])
    }

    // MARK: fuzzy matching

    @Test func emptyQueryMatchesEverything() {
        #expect(fuzzyScore(query: "", in: "anything") == 0)
    }

    @Test func nonSubsequenceIsNil() {
        #expect(fuzzyScore(query: "xyz", in: "juancode") == nil)
        #expect(fuzzyScore(query: "cba", in: "abc") == nil)
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(fuzzyScore(query: "FIX", in: "fix the sidebar") != nil)
        #expect(fuzzyScore(query: "fix", in: "FIX THE SIDEBAR") != nil)
    }

    @Test func prefixBeatsScatteredSubsequence() {
        let prefix = fuzzyScore(query: "jump", in: "jump palette")!
        let scattered = fuzzyScore(query: "jump", in: "januray dump")!
        #expect(prefix > scattered)
    }

    @Test func wordBoundaryHitBeatsMidWordHit() {
        let boundary = fuzzyScore(query: "pal", in: "bd-palette")!
        let midWord = fuzzyScore(query: "pal", in: "bdpalette")!
        #expect(boundary > midWord)
    }

    @Test func shorterHaystackBeatsLongerForTheSameHit() {
        let short = fuzzyScore(query: "dr0", in: "dr0")!
        let long = fuzzyScore(query: "dr0", in: "dr0 and a very long tail")!
        #expect(short > long)
    }

    // MARK: palette results

    private func candidate(
        _ id: String, title: String, subtitle: String = "",
        attention: SessionAttention = .idle, updated: Int = 0
    ) -> JumpCandidate {
        JumpCandidate(id: id, title: title, subtitle: subtitle,
                      key: key(attention, updated: updated))
    }

    @Test func emptyQueryReturnsSmartOrder() {
        let out = jumpResults([
            candidate("a", title: "one", attention: .idle),
            candidate("b", title: "two", attention: .waitingInput),
            candidate("c", title: "three", attention: .working),
        ], query: "")
        #expect(out.map(\.id) == ["b", "c", "a"])
    }

    @Test func queryDropsNonMatches() {
        let out = jumpResults([
            candidate("a", title: "fix sidebar"),
            candidate("b", title: "review pr"),
        ], query: "sidebar")
        #expect(out.map(\.id) == ["a"])
    }

    @Test func queryMatchesSubtitleToo() {
        let out = jumpResults([
            candidate("a", title: "untitled", subtitle: "~/workdir/juancode"),
            candidate("b", title: "untitled", subtitle: "~/workdir/other"),
        ], query: "juanc")
        #expect(out.map(\.id) == ["a"])
    }

    @Test func attentionStaysPrimaryUnderAQuery() {
        // Both match "fix"; the waiting session tops the better textual match.
        let out = jumpResults([
            candidate("a", title: "fix", attention: .idle),
            candidate("b", title: "fix flaky build", attention: .waitingInput),
        ], query: "fix")
        #expect(out.map(\.id) == ["b", "a"])
    }

    @Test func withinABucketMatchQualityWins() {
        let out = jumpResults([
            candidate("a", title: "prefixed later fix", attention: .idle, updated: 999),
            candidate("b", title: "fix now", attention: .idle, updated: 1),
        ], query: "fix")
        #expect(out.map(\.id) == ["b", "a"])
    }
}
