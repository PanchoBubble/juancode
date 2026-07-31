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

    // MARK: manual order + attention bubbling

    private func manualKey(
        _ id: String, attention: SessionAttention = .idle,
        slot: Int? = nil, created: Int = 0, updated: Int = 0
    ) -> ManualSortKey {
        ManualSortKey(key: key(attention, updated: updated, created: created),
                      manualIndex: slot, id: id)
    }

    private func sortedIds(_ keys: [ManualSortKey]) -> [String] {
        keys.sorted(by: manualWithBubblePrecedes).map(\.id)
    }

    @Test func manualOrderIsRespectedRegardlessOfAgeOrLiveness() {
        // Slots win over createdAt, and a placed dead session holds its slot.
        let out = sortedIds([
            manualKey("c", attention: .idle, slot: 2, created: 999),
            manualKey("a", attention: .exited, slot: 0, created: 1),
            manualKey("b", attention: .working, slot: 1, created: 500),
        ])
        #expect(out == ["a", "b", "c"])
    }

    @Test func waitingForInputBubblesAboveTheManualOrder() {
        let out = sortedIds([
            manualKey("a", attention: .idle, slot: 0),
            manualKey("b", attention: .waitingInput, slot: 2),
            manualKey("c", attention: .doneUnseen, slot: 1),
        ])
        // Only the waiting row bubbles; a finished-but-unseen turn holds its slot.
        #expect(out == ["b", "a", "c"])
    }

    @Test func aFinishedTurnDoesNotMoveTheRow() {
        // Same group, before and after "b" finishes a turn: identical order, so
        // the row only re-glyphs (green check) instead of jumping to the top.
        let before = sortedIds([
            manualKey("a", attention: .idle, slot: 0),
            manualKey("b", attention: .working, slot: 1),
            manualKey("c", attention: .idle, slot: 2),
        ])
        let after = sortedIds([
            manualKey("a", attention: .idle, slot: 0),
            manualKey("b", attention: .doneUnseen, slot: 1),
            manualKey("c", attention: .idle, slot: 2),
        ])
        #expect(before == after)
        #expect(after == ["a", "b", "c"])
    }

    @Test func clearedAttentionReturnsToTheManualSlot() {
        // Same sessions as above once handled: pure slot order again — the
        // bubble never rewrote anything.
        let out = sortedIds([
            manualKey("a", attention: .idle, slot: 0),
            manualKey("b", attention: .idle, slot: 2),
            manualKey("c", attention: .idle, slot: 1),
        ])
        #expect(out == ["a", "c", "b"])
    }

    @Test func bubbledSessionsKeepTheirRelativeRestingOrder() {
        let out = sortedIds([
            manualKey("a", attention: .waitingInput, slot: 2),
            manualKey("b", attention: .waitingInput, slot: 0),
            manualKey("c", attention: .idle, slot: 1),
        ])
        #expect(out == ["b", "a", "c"])
    }

    @Test func unplacedLiveSessionsRestOnTopNewestFirst() {
        // Ids the user never dragged go where the old sort put them: fresh live
        // spawns above the placed rows, newest first, id as the stable tie-break.
        let out = sortedIds([
            manualKey("placed", attention: .idle, slot: 0),
            manualKey("new-old", attention: .idle, created: 100),
            manualKey("new-new", attention: .working, created: 200),
            manualKey("tie-b", attention: .idle, created: 200),
        ])
        #expect(out == ["new-new", "tie-b", "new-old", "placed"])
    }

    @Test func unplacedDeadSessionsSinkBelowThePlaced() {
        let out = sortedIds([
            manualKey("dead-unplaced", attention: .exited, created: 999),
            manualKey("placed", attention: .idle, slot: 0),
        ])
        #expect(out == ["placed", "dead-unplaced"])
    }

    @Test func noManualOrderMatchesTheOldSinkSort() {
        // With no slots at all (and nothing bubbling), the resting order is the
        // juancode-05u one: live newest-first, dead sinking newest-first.
        let out = sortedIds([
            manualKey("d-new", attention: .exited, created: 300),
            manualKey("l-old", attention: .idle, created: 100),
            manualKey("d-old", attention: .exited, created: 50),
            manualKey("l-new", attention: .working, created: 200),
        ])
        #expect(out == ["l-new", "l-old", "d-new", "d-old"])
    }

    // MARK: persisting a drag

    @Test func moveWithNothingBubbledPersistsTheDisplayedOrder() {
        let out = manualOrderAfterMove(
            displayed: ["b", "a", "c"], resting: ["a", "b", "c"],
            bubbled: [], moved: "b")
        #expect(out == ["b", "a", "c"])
    }

    @Test func bubbledRowsKeepTheirRestingSlotThroughAnUnrelatedDrag() {
        // "w" is bubbled to the top of the display but rests at slot 2; dragging
        // "c" above "a" must not capture "w" at the top.
        let out = manualOrderAfterMove(
            displayed: ["w", "c", "a", "b"], resting: ["a", "b", "w", "c"],
            bubbled: ["w"], moved: "c")
        #expect(out == ["c", "a", "b", "w"])
    }

    @Test func droppingAboveEveryRestingRowLandsAtTheFront() {
        let out = manualOrderAfterMove(
            displayed: ["c", "a", "b"], resting: ["a", "b", "c"],
            bubbled: [], moved: "c")
        #expect(out == ["c", "a", "b"])
    }

    @Test func draggingABubbledRowPlacesItExplicitly() {
        // An explicit drop of the bubbled row itself is the user choosing its
        // slot: it lands after its displayed predecessor.
        let out = manualOrderAfterMove(
            displayed: ["a", "w", "b"], resting: ["a", "b", "w"],
            bubbled: ["w"], moved: "w")
        #expect(out == ["a", "w", "b"])
    }

    @Test func unknownMovedIdLeavesTheRestingOrderAlone() {
        let out = manualOrderAfterMove(
            displayed: ["a", "b"], resting: ["a", "b"],
            bubbled: [], moved: "ghost")
        #expect(out == ["a", "b"])
    }

    // MARK: pruning

    @Test func pruningDropsDeletedIdsAndEmptiedProjects() {
        let out = prunedSessionOrder(
            ["/p1": ["a", "gone", "b"], "/p2": ["dead"], "/p3": ["c"]],
            keeping: ["a", "b", "c"])
        #expect(out == ["/p1": ["a", "b"], "/p3": ["c"]])
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

    @Test func crashOrphanRestsLikeLiveInsteadOfSinking() {
        #expect(restingAttention(.exited, crashOrphan: true) == .idle)
        #expect(restingAttention(.exited, crashOrphan: false) == .exited)
        #expect(restingAttention(.working, crashOrphan: true) == .working)

        // An unrevived crash orphan (dead, unplaced) precedes both a manually
        // placed row and a plain dead row — after a crash/reboot yesterday's
        // active sessions must not hide behind "Load more".
        let orphan = ManualSortKey(
            key: SessionSortKey(attention: restingAttention(.exited, crashOrphan: true),
                                updatedAt: 10, createdAt: 10),
            manualIndex: nil, id: "orphan")
        let placed = ManualSortKey(
            key: SessionSortKey(attention: .exited, updatedAt: 99, createdAt: 99),
            manualIndex: 0, id: "placed")
        let dead = ManualSortKey(
            key: SessionSortKey(attention: .exited, updatedAt: 50, createdAt: 50),
            manualIndex: nil, id: "dead")
        #expect(manualRestingPrecedes(orphan, placed))
        #expect(manualRestingPrecedes(orphan, dead))
        #expect(manualRestingPrecedes(placed, dead))
    }

    @Test func restingOrderRanksByLastActivityNotCreation() {
        // Within a tier, the session worked in most recently wins even when it is by
        // far the oldest — the whole point of ordering on (snapshotted) `updatedAt`.
        func row(_ id: String, updated: Int, created: Int) -> ManualSortKey {
            ManualSortKey(key: SessionSortKey(attention: .exited, updatedAt: updated,
                                              createdAt: created),
                          manualIndex: nil, id: id)
        }
        let oldButActive = row("old", updated: 900, created: 100)
        let newButStale = row("new", updated: 200, created: 800)
        #expect(manualRestingPrecedes(oldButActive, newButStale))
        #expect(!manualRestingPrecedes(newButStale, oldButActive))

        // Equal activity (nothing recorded since creation) falls back to newest-created,
        // then to id — so bulk-spawned rows stay deterministic.
        #expect(manualRestingPrecedes(row("a", updated: 5, created: 9),
                                      row("b", updated: 5, created: 1)))
        #expect(manualRestingPrecedes(row("a", updated: 5, created: 5),
                                      row("b", updated: 5, created: 5)))
    }

    @Test func restingOrderStillPutsRecencyBelowTierAndManualOrder() {
        // Recency is the *last* word, not the first: a live row outranks a more
        // recently active dead one, and a manually placed row keeps its slot against
        // an unplaced row that was touched later.
        func row(_ id: String, _ attention: SessionAttention, updated: Int,
                 manual: Int? = nil) -> ManualSortKey {
            ManualSortKey(key: SessionSortKey(attention: attention, updatedAt: updated,
                                              createdAt: 0),
                          manualIndex: manual, id: id)
        }
        #expect(manualRestingPrecedes(row("live", .idle, updated: 1),
                                      row("dead", .exited, updated: 999)))
        #expect(manualRestingPrecedes(row("placed", .exited, updated: 1, manual: 0),
                                      row("unplaced", .exited, updated: 999)))
    }

    @Test func sidebarOrderIgnoresBusyIdleChurn() {
        // The whole point of the projection (juancode-2n0): a live agent working and
        // the same agent resting land on the SAME bucket, so its busy↔idle flips never
        // change what the sidebar observes.
        let busy = sidebarOrderAttention(live: true, activity: .busy,
                                         unseenDone: false, crashOrphan: false)
        let idle = sidebarOrderAttention(live: true, activity: .idle,
                                         unseenDone: false, crashOrphan: false)
        #expect(busy == idle)
        #expect(busy == .idle)
    }

    @Test func sidebarOrderIgnoresAFinishedTurn() {
        // A turn ending no longer moves a row, so it must not change the projection
        // either — the green check comes from the row's own activity read.
        #expect(sidebarOrderAttention(live: true, activity: .idle,
                                      unseenDone: true, crashOrphan: false) == .idle)
    }

    @Test func sidebarOrderKeepsTheBucketsThatMoveRows() {
        // The one bubbling state and the dead-sink still come through, and a crash
        // orphan still rests instead of sinking.
        #expect(sidebarOrderAttention(live: true, activity: .waitingInput,
                                      unseenDone: false, crashOrphan: false) == .waitingInput)
        #expect(sidebarOrderAttention(live: false, activity: nil,
                                      unseenDone: false, crashOrphan: false) == .exited)
        #expect(sidebarOrderAttention(live: false, activity: nil,
                                      unseenDone: false, crashOrphan: true) == .idle)
    }

    @Test func sidebarOrderPreservesEveryOrderingDecision() {
        // Belt-and-braces: for every input combination the projected bucket must sort
        // identically to the un-collapsed resting attention it replaces. If a future
        // ordering rule starts distinguishing `.working`, this fails.
        let states: [SessionActivity?] = [nil, .idle, .busy, .waitingInput]
        var cases: [(SessionAttention, SessionAttention)] = []
        for live in [true, false] {
            for activity in states {
                for unseenDone in [true, false] {
                    for crashOrphan in [true, false] {
                        let projected = sidebarOrderAttention(live: live, activity: activity,
                                                              unseenDone: unseenDone,
                                                              crashOrphan: crashOrphan)
                        let raw = restingAttention(
                            sessionAttention(live: live, activity: activity, unseenDone: unseenDone),
                            crashOrphan: crashOrphan)
                        cases.append((projected, raw))
                    }
                }
            }
        }
        for (i, a) in cases.enumerated() {
            for b in cases[i...] {
                func key(_ attention: SessionAttention, _ manual: Int?, _ id: String) -> ManualSortKey {
                    ManualSortKey(key: SessionSortKey(attention: attention, updatedAt: 1, createdAt: 1),
                                  manualIndex: manual, id: id)
                }
                for manualA in [nil, 0] as [Int?] {
                    for manualB in [nil, 1] as [Int?] {
                        #expect(manualWithBubblePrecedes(key(a.0, manualA, "a"), key(b.0, manualB, "b"))
                                == manualWithBubblePrecedes(key(a.1, manualA, "a"), key(b.1, manualB, "b")))
                    }
                }
            }
        }
    }
}
