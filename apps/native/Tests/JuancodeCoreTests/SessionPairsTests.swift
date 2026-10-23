import Foundation
import Testing
@testable import JuancodeCore

/// Two sessions in one pane, made by dragging one onto the other (juancode-8rk).
@Suite struct SessionPairsTests {
    @Test func sidebarKeepsPartnersTogetherInPaneOrder() {
        var pairs = SessionPairs()
        pairs.split("a", with: "b", zone: .trailing)
        #expect(pairs.sidebarOrder(["b", "c", "a", "d"]) == ["a", "b", "c", "d"])
        #expect(pairs.sidebarOrder(["c", "a", "d", "b"]) == ["c", "a", "b", "d"])
        // Filtering and project boundaries must not bring excluded rows back.
        #expect(pairs.sidebarOrder(["b", "c"]) == ["b", "c"])
        pairs.remove(session: "a")
        #expect(pairs.sidebarOrder(["b", "c", "a"]) == ["b", "c", "a"])
    }

    @Test func droppingOnTheTrailingHalfPutsTheDroppedSessionSecond() {
        var pairs = SessionPairs()
        #expect(pairs.split("a", with: "b", zone: .trailing))
        let pair = pairs.pair(for: "a")
        #expect(pair == SessionPair(first: "a", second: "b", axis: .sideBySide))
        #expect(pairs.pair(for: "b") == pair)
        #expect(pair?.partner(of: "a") == "b")
        #expect(pair?.partner(of: "b") == "a")
        #expect(pair?.partner(of: "c") == nil)
    }

    @Test func droppingOnTheTopHalfStacksTheDroppedSessionFirst() {
        var pairs = SessionPairs()
        pairs.split("a", with: "b", zone: .top)
        #expect(pairs.pair(for: "a") == SessionPair(first: "b", second: "a", axis: .stacked))
    }

    @Test func aSessionDroppedOnItselfIsRefused() {
        var pairs = SessionPairs()
        #expect(!pairs.split("a", with: "a", zone: .leading))
        #expect(pairs.pairs.isEmpty)
    }

    @Test func aSessionIsInOnePairAtMost() {
        var pairs = SessionPairs()
        pairs.split("a", with: "b", zone: .trailing)
        pairs.split("c", with: "d", zone: .trailing)
        // b leaves a for c; a is alone again, and so is d.
        pairs.split("c", with: "b", zone: .leading)
        #expect(pairs.pairs == [SessionPair(first: "b", second: "c", axis: .sideBySide)])
        #expect(pairs.pair(for: "a") == nil)
        #expect(pairs.pair(for: "d") == nil)
    }

    @Test func removingEitherMemberEndsThePair() {
        var pairs = SessionPairs()
        pairs.split("a", with: "b", zone: .trailing)
        #expect(pairs.remove(session: "b")?.first == "a")
        #expect(pairs.pair(for: "a") == nil)
        #expect(pairs.remove(session: "a") == nil)
    }

    @Test func fractionAxisAndSwapApplyToThePair() {
        var pairs = SessionPairs()
        pairs.split("a", with: "b", zone: .trailing)
        pairs.setFraction(0.95, for: "b")
        #expect(pairs.pair(for: "a")?.fraction == SessionPaneLayout.fractionRange.upperBound)
        pairs.setAxis(.stacked, for: "a")
        #expect(pairs.pair(for: "a")?.axis == .stacked)
        pairs.swap(for: "a")
        let p = pairs.pair(for: "a")
        #expect(p?.first == "b" && p?.second == "a")
        #expect(abs((p?.fraction ?? 0) - 0.2) < 1e-9)
    }

    @Test func theDropZoneIsTheNearestEdge() {
        let size = CGSize(width: 1000, height: 600)
        #expect(SessionDropZone.at(CGPoint(x: 100, y: 300), in: size) == .leading)
        #expect(SessionDropZone.at(CGPoint(x: 900, y: 300), in: size) == .trailing)
        #expect(SessionDropZone.at(CGPoint(x: 500, y: 40), in: size) == .top)
        #expect(SessionDropZone.at(CGPoint(x: 500, y: 560), in: size) == .bottom)
        // Out-of-bounds points clamp rather than trap.
        #expect(SessionDropZone.at(CGPoint(x: -50, y: 300), in: size) == .leading)
        #expect(SessionDropZone.trailing.rect(in: size) == CGRect(x: 500, y: 0, width: 500, height: 600))
        #expect(SessionDropZone.bottom.rect(in: size) == CGRect(x: 0, y: 300, width: 1000, height: 300))
    }

    @Test func sideBySideBothMembersKeepTheFullHeight() {
        let f = SessionPairFrames.layout(size: CGSize(width: 1008, height: 600), axis: .sideBySide,
                                         fraction: 0.5, bottomInset: 200)
        #expect(f.first == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(f.second == CGRect(x: 508, y: 0, width: 500, height: 600))
        #expect(f.divider == CGRect(x: 500, y: 0, width: 8, height: 400))
    }

    @Test func stackedBothMembersShareTheHeightAboveTheShellPanel() {
        let f = SessionPairFrames.layout(size: CGSize(width: 800, height: 608), axis: .stacked,
                                         fraction: 0.5, bottomInset: 200)
        #expect(f.first == CGRect(x: 0, y: 0, width: 800, height: 200))
        #expect(f.second == CGRect(x: 0, y: 208, width: 800, height: 200))
        #expect(f.divider == CGRect(x: 0, y: 200, width: 800, height: 8))
    }

    @Test func aDraggedDividerMapsBackToTheFractionItLaidOut() {
        let size = CGSize(width: 1008, height: 600)
        let f = SessionPairFrames.layout(size: size, axis: .sideBySide, fraction: 0.3, bottomInset: 0)
        let back = SessionPairFrames.fraction(forFirstExtent: Double(f.first.width), axis: .sideBySide,
                                              size: size, bottomInset: 0)
        #expect(abs(back - 0.3) < 0.01)
    }
}
