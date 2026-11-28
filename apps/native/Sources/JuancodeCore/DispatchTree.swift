import Foundation
import CoreGraphics

/// Nested dispatches as a tree (juancode-cmew). A dispatched agent records its
/// dispatcher in `parentSessionId`; these are the pure decisions both the sidebar's
/// indentation and the chain's web view make from it.
public enum DispatchTree {
    /// `items` reordered so each child sits right after its parent (depth-first),
    /// with its nesting depth. Siblings and roots keep their order in `items`. A
    /// parent that is not in `items` does not nest its child, and a cycle is broken
    /// at the first item reached, so every item comes out exactly once.
    public static func nest<T>(_ items: [T], id: (T) -> String,
                               parent: (T) -> String?) -> [(item: T, depth: Int)] {
        let ids = Set(items.map(id))
        var children: [String: [Int]] = [:]
        var roots: [Int] = []
        for (i, item) in items.enumerated() {
            if let p = parent(item), p != id(item), ids.contains(p) {
                children[p, default: []].append(i)
            } else {
                roots.append(i)
            }
        }
        var out: [(item: T, depth: Int)] = []
        var seen = Set<Int>()
        func walk(_ i: Int, _ depth: Int) {
            guard seen.insert(i).inserted else { return }
            out.append((items[i], depth))
            for c in children[id(items[i])] ?? [] { walk(c, depth + 1) }
        }
        for r in roots { walk(r, 0) }
        // Items only reachable through a cycle: surface them flat rather than drop them.
        for i in items.indices where !seen.contains(i) { walk(i, 0) }
        return out
    }
}

/// Radial placement for the chain web: roots around the centre, each node's
/// children fanned out on the next ring inside its parent's slice. Slices are
/// proportional to leaf count so a wide subtree gets room.
public enum ChainWeb {
    /// A spanning tree over `edges` (first parent wins; `dispatched` edges are taken
    /// first so the dispatch tree is the spine), then each node's centre point, in a
    /// coordinate space whose origin is the web's centre.
    public static func place(nodes: [ChainGraphNodeID], edges: [ChainGraphEdge],
                             ring: CGFloat) -> [ChainGraphNodeID: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        let known = Set(nodes)
        var parent: [ChainGraphNodeID: ChainGraphNodeID] = [:]
        func reaches(_ from: ChainGraphNodeID, _ to: ChainGraphNodeID) -> Bool {
            var cur: ChainGraphNodeID? = from
            var steps = 0
            while let c = cur, steps <= nodes.count {
                if c == to { return true }
                cur = parent[c]; steps += 1
            }
            return false
        }
        let ordered = edges.filter { $0.kind == .dispatched } + edges.filter { $0.kind != .dispatched }
        for e in ordered where e.from != e.to && known.contains(e.from) && known.contains(e.to) {
            // Skip an edge that would give a second parent or close a loop.
            if parent[e.to] == nil, !reaches(e.from, e.to) { parent[e.to] = e.from }
        }
        var children: [ChainGraphNodeID: [ChainGraphNodeID]] = [:]
        for n in nodes { if let p = parent[n] { children[p, default: []].append(n) } }
        let roots = nodes.filter { parent[$0] == nil }

        var leaves: [ChainGraphNodeID: Int] = [:]
        func count(_ n: ChainGraphNodeID) -> Int {
            let c = children[n] ?? []
            let v = c.isEmpty ? 1 : c.map(count).reduce(0, +)
            leaves[n] = v
            return v
        }
        roots.forEach { _ = count($0) }

        var out: [ChainGraphNodeID: CGPoint] = [:]
        func lay(_ n: ChainGraphNodeID, depth: Int, from a0: Double, to a1: Double) {
            let mid = (a0 + a1) / 2
            let r = CGFloat(depth) * ring
            out[n] = CGPoint(x: r * CGFloat(cos(mid)), y: r * CGFloat(sin(mid)))
            let kids = children[n] ?? []
            let total = Double(leaves[n] ?? 1)
            var a = a0
            for k in kids {
                let span = (a1 - a0) * Double(leaves[k] ?? 1) / total
                lay(k, depth: depth + 1, from: a, to: a + span)
                a += span
            }
        }
        // One root sits in the middle; several share the first ring.
        let start = -Double.pi / 2
        if roots.count == 1 {
            lay(roots[0], depth: 0, from: start, to: start + 2 * .pi)
        } else {
            let total = Double(roots.map { leaves[$0] ?? 1 }.reduce(0, +))
            var a = start
            for r in roots {
                let span = 2 * .pi * Double(leaves[r] ?? 1) / total
                lay(r, depth: 1, from: a, to: a + span)
                a += span
            }
        }
        return out
    }
}
