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
