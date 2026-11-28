import Foundation
import CoreGraphics
import Testing
@testable import JuancodeCore

/// Nested dispatches (juancode-cmew): children follow their dispatcher, and the web
/// places every node exactly once even with loops in the records.
@Suite struct DispatchTreeTests {
    private struct S { let id: String; let parent: String? }

    @Test func childrenFollowParentsDepthFirst() {
        let items = [S(id: "c2", parent: "a"), S(id: "a", parent: nil), S(id: "b", parent: nil),
                     S(id: "g", parent: "c2"), S(id: "c1", parent: "a"), S(id: "x", parent: "missing")]
        let out = DispatchTree.nest(items, id: \.id, parent: \.parent)
        #expect(out.map(\.item.id) == ["a", "c2", "g", "c1", "b", "x"])
        #expect(out.map(\.depth) == [0, 1, 2, 1, 0, 0])
    }

    @Test func cycleStillEmitsEveryItemOnce() {
        let items = [S(id: "a", parent: "b"), S(id: "b", parent: "a"), S(id: "s", parent: "s")]
        let out = DispatchTree.nest(items, id: \.id, parent: \.parent)
        #expect(out.map(\.item.id).sorted() == ["a", "b", "s"])
    }

    @Test func webPlacesNestedDispatchesOnRings() {
        func n(_ id: String) -> ChainGraphNodeID { .member(ChainMemberRef(kind: .session, ref: id)) }
        func e(_ a: String, _ b: String) -> ChainGraphEdge {
            ChainGraphEdge(id: "\(a)>\(b)", from: n(a), to: n(b), kind: .dispatched)
        }
        // root → child → grandchild, plus a loop back that must not break placement.
        let nodes = ["root", "child", "grand", "lone"].map(n)
        let pos = ChainWeb.place(nodes: nodes, edges: [e("root", "child"), e("child", "grand"), e("grand", "root")],
                                 ring: 100)
        #expect(pos.count == 4)
        func r(_ id: String) -> CGFloat { let p = pos[n(id)]!; return (p.x * p.x + p.y * p.y).squareRoot() }
        // Two roots (root, lone) share ring 1; the dispatch chain goes outward.
        #expect(abs(r("root") - 100) < 0.01)
        #expect(abs(r("lone") - 100) < 0.01)
        #expect(abs(r("child") - 200) < 0.01)
        #expect(abs(r("grand") - 300) < 0.01)
    }
}
