import Testing
@testable import JuancodeCore

/// The pure logic behind the idle+dirty review badge (juancode-qce.1): when a
/// settle edge recomputes it, how its name-status signature debounces re-badging,
/// and when a computed stat is actually shown.
@Suite struct ChangeBadgeTests {
    private func entry(_ index: Character, _ workTree: Character, _ path: String,
                       orig: String? = nil) -> WorktreeStatusEntry {
        WorktreeStatusEntry(path: path, origPath: orig, index: index, workTree: workTree)
    }

    // MARK: signature (debounce key)

    @Test func signatureIsOrderIndependent() {
        let a = [entry("M", " ", "a.swift"), entry(" ", "M", "b.swift")]
        let b = [entry(" ", "M", "b.swift"), entry("M", " ", "a.swift")]
        #expect(changeStatSignature(a) == changeStatSignature(b))
    }

    @Test func signatureChangesWhenAFileIsAddedOrRemoved() {
        let one = [entry("M", " ", "a.swift")]
        let two = [entry("M", " ", "a.swift"), entry("?", "?", "new.txt")]
        #expect(changeStatSignature(one) != changeStatSignature(two))
    }

    @Test func signatureChangesWhenAStatusCodeChanges() {
        let modified = [entry(" ", "M", "a.swift")]
        let staged = [entry("M", " ", "a.swift")]
        #expect(changeStatSignature(modified) != changeStatSignature(staged))
    }

    @Test func signatureDistinguishesRenameSource() {
        let renamed = [entry("R", " ", "new.swift", orig: "old.swift")]
        let plain = [entry("R", " ", "new.swift")]
        #expect(changeStatSignature(renamed) != changeStatSignature(plain))
    }

    // MARK: should-compute edge

    @Test func recomputesWhenAnAgentFinishesATurn() {
        #expect(shouldComputeChangeBadge(prev: .busy, next: .idle, notify: true, isEditor: false))
        #expect(shouldComputeChangeBadge(prev: .busy, next: .waitingInput, notify: true, isEditor: false))
    }

    @Test func teardownAndMidTurnFlickerDoNotRecompute() {
        // reset() emits busy → idle with notify == false.
        #expect(!shouldComputeChangeBadge(prev: .busy, next: .idle, notify: false, isEditor: false))
        // Entering busy is the start of work, not a settle.
        #expect(!shouldComputeChangeBadge(prev: .idle, next: .busy, notify: false, isEditor: false))
        // A prompt that appears without a preceding turn isn't "the agent finished".
        #expect(!shouldComputeChangeBadge(prev: .idle, next: .waitingInput, notify: true, isEditor: false))
    }

    @Test func editorSessionsNeverBadge() {
        #expect(!shouldComputeChangeBadge(prev: .busy, next: .idle, notify: true, isEditor: true))
    }

    // MARK: visibility (post-debounce)

    private func stat(_ signature: String, files: Int = 1) -> ChangeStat {
        ChangeStat(files: files, additions: 1, deletions: 0, signature: signature)
    }

    @Test func noBadgeWhenCleanOrAbsent() {
        #expect(!changeBadgeVisible(latest: nil, viewedSignature: nil))
        #expect(!changeBadgeVisible(latest: stat("x", files: 0), viewedSignature: nil))
    }

    @Test func badgeShowsForUnseenChanges() {
        #expect(changeBadgeVisible(latest: stat("M  a.swift"), viewedSignature: nil))
        #expect(changeBadgeVisible(latest: stat("M  a.swift"), viewedSignature: "old"))
    }

    @Test func noBadgeOnceViewed() {
        #expect(!changeBadgeVisible(latest: stat("M  a.swift"), viewedSignature: "M  a.swift"))
    }

    // MARK: summary label

    @Test func summaryFormat() {
        #expect(ChangeStat(files: 3, additions: 120, deletions: 44, signature: "").summary
                == "3 files · +120 −44")
        #expect(ChangeStat(files: 1, additions: 0, deletions: 0, signature: "").summary
                == "1 file · +0 −0")
    }
}

/// The badge's number formatting (`compactCount`) and the PR-side `DiffCounts`
/// rollup — one label renders both the working tree and a pull request, so the two
/// have to agree on what "1.2k" means and on when there's nothing to show.
@Suite struct CompactCountTests {
    @Test func smallNumbersAreVerbatim() {
        #expect(compactCount(0) == "0")
        #expect(compactCount(7) == "7")
        #expect(compactCount(999) == "999")
    }

    @Test func thousandsGetOneDecimalUntilTen() {
        #expect(compactCount(1000) == "1k")
        #expect(compactCount(1200) == "1.2k")
        #expect(compactCount(9949) == "9.9k")
        #expect(compactCount(9950) == "10k")
        #expect(compactCount(12_400) == "12k")
    }

    @Test func millionsTakeOverBeforeAThousandK() {
        #expect(compactCount(999_499) == "999k")
        #expect(compactCount(999_500) == "1M")
        #expect(compactCount(3_400_000) == "3.4M")
    }

    @Test func negativesKeepTheirSign() {
        #expect(compactCount(-42) == "-42")
        #expect(compactCount(-1500) == "-1.5k")
    }

    @Test func changeStatExposesItsCounts() {
        let stat = ChangeStat(files: 3, additions: 120, deletions: 44, signature: "x")
        #expect(stat.counts == DiffCounts(files: 3, additions: 120, deletions: 44))
    }

    @Test func allZeroCountsReadAsEmpty() {
        #expect(DiffCounts(files: 0, additions: 0, deletions: 0).isEmpty)
        #expect(!DiffCounts(files: 0, additions: 2, deletions: 0).isEmpty)
    }
}
