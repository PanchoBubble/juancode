import AppKit
import Testing
@testable import JuancodeApp

@Suite struct HintLabelTests {
    private func prefixFree(_ labels: [String]) -> Bool {
        for (i, a) in labels.enumerated() {
            for (j, b) in labels.enumerated() where i != j && b.hasPrefix(a) { return false }
        }
        return true
    }

    @Test func labelsAreUniqueAndNeverPrefixesOfEachOther() {
        for count in [1, 2, 13, 14, 15, 40, 120, 196] {
            let labels = HintLabels.make(count: count)
            #expect(labels.count == count)
            #expect(Set(labels).count == count)
            #expect(prefixFree(labels))
            #expect(labels.allSatisfy { !$0.isEmpty })
        }
    }

    @Test func fewTargetsGetSingleLetters() {
        #expect(HintLabels.make(count: 1).allSatisfy { $0.count == 1 })
        #expect(HintLabels.make(count: HintLabels.alphabet.count).allSatisfy { $0.count == 1 })
        #expect(HintLabels.make(count: 0).isEmpty)
    }
}

@Suite struct HintSessionTests {
    private func session(_ n: Int) -> HintSession {
        HintSession(frames: (0..<n).map { CGRect(x: 0, y: CGFloat($0) * 30, width: 20, height: 20) })
    }

    @Test func exactLabelActivatesExactlyThatTarget() {
        var s = session(5)
        let wanted = s.entries[3]
        var outcome = HintSession.Outcome.ignored
        for letter in wanted.label { outcome = s.type(letter) }
        #expect(outcome == .activate(3))
    }

    @Test func typingNarrowsTheLabelsStillShown() {
        var s = session(30)
        let first = s.entries.first { $0.label.count == 2 }!
        #expect(s.matching.count == 30)
        #expect(s.type(first.label.first!) == .narrowed)
        #expect(s.matching.allSatisfy { $0.label.hasPrefix(String(first.label.first!)) })
        #expect(s.matching.contains(first))
        s.backspace()
        #expect(s.matching.count == 30)
    }

    @Test func aLetterNoLabelContinuesWithIsIgnored() {
        var s = session(3)
        let unused = HintLabels.alphabet.first { ch in !s.entries.contains { $0.label.first == ch } }!
        #expect(s.type(unused) == .ignored)
        #expect(s.typed.isEmpty)
        #expect(s.matching.count == 3)
    }

    @Test func uppercaseLettersTypeLikeLowercase() {
        var s = session(2)
        let wanted = s.entries[0]
        let outcome = s.type(Character(wanted.label.uppercased()))
        #expect(outcome == .activate(0))
    }
}

@Suite struct HintKeyRoutingTests {
    private func decide(_ chars: String?, key: UInt16 = 1, _ mods: NSEvent.ModifierFlags = [],
                        active: Bool = true, toggle: Bool = false) -> HintKeyDecision {
        HintKeyRouter.decide(active: active, keyCode: key, characters: chars, modifiers: mods,
                             isToggleChord: toggle)
    }

    @Test func inactiveHintsNeverClaimAKey() {
        #expect(decide("s", active: false) == .passThrough)
        #expect(decide("s", .control, active: false) == .passThrough)
    }

    @Test func hintLettersTypeWithOrWithoutShift() {
        for letter in HintLabels.alphabet {
            #expect(decide(String(letter)) == .type(letter))
            #expect(decide(String(letter).uppercased(), .shift) == .type(letter))
        }
    }

    @Test func everyOtherKeyIsConsumedSoNoneReachesThePty() {
        // Letters outside the alphabet, digits, punctuation, Return, Tab, arrows,
        // Ctrl/Option chords: all consumed.
        for chars in ["q", "z", "1", ";", "\r", "\t", " ", nil] {
            #expect(decide(chars) == .swallow)
        }
        for key: UInt16 in [36, 48, 123, 124, 125, 126, 49] {
            #expect(decide(nil, key: key) == .swallow)
        }
        #expect(decide("s", .control) == .swallow)
        #expect(decide("f", .option) == .swallow)
        #expect(decide("s", [.control, .shift]) == .swallow)
    }

    @Test func escapeAndTheShortcutLeaveHintMode() {
        #expect(decide(nil, key: 53) == .cancel)
        #expect(decide("f", .control, toggle: true) == .cancel)
    }

    @Test func backspaceIsConsumed() {
        #expect(decide(nil, key: 51) == .backspace)
    }

    @Test func commandChordsEndHintsAndRunNormally() {
        #expect(decide("n", .command) == .cancelAndPassThrough)
        #expect(decide("c", [.command, .shift]) == .cancelAndPassThrough)
    }
}

@Suite @MainActor struct HintEngineTests {
    private final class Counter { var hits: [Int] = [] }

    private func engine(_ n: Int, _ counter: Counter) -> HintEngine {
        HintEngine(targets: (0..<n).map { i in
            HintEngine.Target(frame: CGRect(x: 0, y: CGFloat(i) * 30, width: 20, height: 20),
                              activate: { counter.hits.append(i) })
        })!
    }

    /// Feeds a label through the router the way the key monitor does.
    private func type(_ label: String, into engine: HintEngine) -> HintEngine.Step {
        var last = HintEngine.Step(consumed: false, finished: false)
        for letter in label {
            let decision = HintKeyRouter.decide(
                active: true, keyCode: 1, characters: String(letter), modifiers: [], isToggleChord: false)
            last = engine.apply(decision)
            #expect(last.consumed)
        }
        return last
    }

    @Test func typingALabelActivatesThatOneTargetOnce() {
        let counter = Counter()
        let e = engine(20, counter)
        let label = e.session.entries[7].label
        let step = type(label, into: e)
        #expect(step.finished)
        step.activation?()
        #expect(counter.hits == [7])
    }

    @Test func aPartialLabelActivatesNothing() {
        let counter = Counter()
        let e = engine(40, counter)
        let label = e.session.entries.first { $0.label.count == 2 }!.label
        let step = type(String(label.first!), into: e)
        #expect(!step.finished)
        #expect(step.activation == nil)
        #expect(counter.hits.isEmpty)
    }

    @Test func escapeFinishesWithoutActivating() {
        let counter = Counter()
        let e = engine(5, counter)
        let step = e.apply(HintKeyRouter.decide(
            active: true, keyCode: 53, characters: nil, modifiers: [], isToggleChord: false))
        #expect(step.finished)
        #expect(step.consumed)
        #expect(step.activation == nil)
        #expect(counter.hits.isEmpty)
    }

    @Test func noTargetsMeansNoSession() {
        #expect(HintEngine(targets: []) == nil)
    }
}

@Suite struct HintActivationTests {
    @Test func theEditorKeepsEveryControlKeyButNotCommandChords() {
        #expect(!HintActivation.allows(modifiers: .control, inEditor: true,
                                       editingText: false, reviewActive: false))
        #expect(!HintActivation.allows(modifiers: [.control, .shift], inEditor: true,
                                       editingText: false, reviewActive: false))
        // A user who rebinds hints to a ⌘ chord can still open them from the editor.
        #expect(HintActivation.allows(modifiers: .command, inEditor: true,
                                      editingText: false, reviewActive: false))
        #expect(HintActivation.allows(modifiers: [.command, .control], inEditor: true,
                                      editingText: false, reviewActive: false))
    }

    @Test func agentTerminalsAndPanelsOpenHints() {
        #expect(HintActivation.allows(modifiers: .control, inEditor: false,
                                      editingText: false, reviewActive: false))
    }

    @Test func textFieldsAndTheReviewKeepTheirOwnInput() {
        #expect(!HintActivation.allows(modifiers: .control, inEditor: false,
                                       editingText: true, reviewActive: false))
        #expect(!HintActivation.allows(modifiers: .control, inEditor: false,
                                       editingText: false, reviewActive: true))
    }
}

@Suite struct HintGeometryTests {
    private let window = CGRect(x: 0, y: 0, width: 800, height: 600)

    @Test func slivers_andOffscreenFramesAreNotVisible() {
        #expect(HintGeometry.isVisible(CGRect(x: 10, y: 10, width: 40, height: 20), within: window))
        #expect(!HintGeometry.isVisible(CGRect(x: 10, y: 10, width: 2, height: 20), within: window))
        #expect(!HintGeometry.isVisible(CGRect(x: 900, y: 10, width: 40, height: 20), within: window))
        #expect(!HintGeometry.isVisible(CGRect(x: 10, y: -100, width: 40, height: 20), within: window))
        #expect(!HintGeometry.isVisible(.null, within: window))
    }

    @Test func readingOrderIsTopRowFirstThenLeftToRight() {
        // AppKit window coordinates: larger y is higher on screen.
        let topRight = CGRect(x: 300, y: 500, width: 20, height: 20)
        let topLeftNudged = CGRect(x: 100, y: 503, width: 20, height: 20)
        let lower = CGRect(x: 10, y: 200, width: 20, height: 20)
        let sorted = [lower, topRight, topLeftNudged].sorted(by: HintGeometry.readingOrder)
        #expect(sorted == [topLeftNudged, topRight, lower])
    }
}

@Suite @MainActor struct HintRegistryTests {
    private func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                 styleMask: [.borderless], backing: .buffered, defer: false)
    }

    private func anchor(_ frame: NSRect, enabled: Bool = true, in parent: NSView) -> HintAnchorView {
        let anchor = HintAnchorView(frame: frame)
        anchor.isActionEnabled = enabled
        anchor.activate = {}
        parent.addSubview(anchor)
        return anchor
    }

    @Test func onlyEnabledVisibleOnScreenControlsAreOffered() throws {
        let window = window()
        let content = try #require(window.contentView)
        defer { window.contentView = nil }

        let shown = anchor(NSRect(x: 20, y: 250, width: 60, height: 24), in: content)
        _ = anchor(NSRect(x: 120, y: 250, width: 60, height: 24), enabled: false, in: content)
        let hidden = anchor(NSRect(x: 220, y: 250, width: 60, height: 24), in: content)
        hidden.isHidden = true
        _ = anchor(NSRect(x: 1000, y: 250, width: 60, height: 24), in: content)

        let targets = HintRegistry.shared.targets(in: window)
        #expect(targets.count == 1)
        let frame = try #require(targets.first?.frame)
        #expect(frame == content.convert(shown.frame, to: nil))
    }

    @Test func controlsScrolledOutOfASurroundingScrollViewAreLeftOut() throws {
        let window = window()
        let content = try #require(window.contentView)
        defer { window.contentView = nil }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 1000))
        scroll.documentView = document
        content.addSubview(scroll)
        _ = anchor(NSRect(x: 10, y: 20, width: 80, height: 20), in: document)
        _ = anchor(NSRect(x: 10, y: 700, width: 80, height: 20), in: document)

        #expect(HintRegistry.shared.targets(in: window).count == 1)
    }

    @Test func controlsOfAnotherWindowAreNotOffered() throws {
        let mine = window(), theirs = window()
        defer { mine.contentView = nil; theirs.contentView = nil }
        _ = anchor(NSRect(x: 20, y: 20, width: 60, height: 24), in: try #require(theirs.contentView))
        #expect(HintRegistry.shared.targets(in: mine).isEmpty)
    }

    @Test func aRemovedControlLeavesTheRegistry() throws {
        let window = window()
        let content = try #require(window.contentView)
        defer { window.contentView = nil }
        let gone = anchor(NSRect(x: 20, y: 20, width: 60, height: 24), in: content)
        #expect(HintRegistry.shared.targets(in: window).count == 1)
        gone.removeFromSuperview()
        #expect(HintRegistry.shared.targets(in: window).isEmpty)
    }
}
