import Foundation
import Testing
@testable import JuancodeCore

/// A chain as the daemon sends it, member role included (juancode-8oa5.7). Swift Testing so
/// it runs without XCTest.
@Suite struct ChainDecodeTests {
    @Test func aChainDecodesTheDaemonsShape() throws {
        let json = #"""
        {"slug":"auth-rewrite","state":"inactive","createdAt":1,"closedAt":2,
         "members":[{"kind":"tracked_pr","ref":"/repo#7","addedAt":3},
                    {"kind":"beads","ref":"juancode-dbo.1","title":"Chains core","url":"u","addedAt":4,"role":"tester"}]}
        """#
        let chain = try JSONDecoder().decode(Chain.self, from: Data(json.utf8))
        #expect(chain.state == .inactive)
        #expect(chain.closedAt == 2)
        #expect(chain.members.map(\.kind) == [.trackedPr, .beads])
        #expect(chain.members[1].title == "Chains core")
        #expect(chain.members[0].title == nil)
        #expect(chain.members[1].role == "tester")
        #expect(chain.members[0].role == nil)
        #expect(chain.parent == nil, "a top-level chain")
        let nested = try JSONDecoder().decode(Chain.self, from: Data(
            #"{"slug":"sub","state":"active","createdAt":1,"closedAt":null,"members":[],"parent":"auth-rewrite"}"#.utf8))
        #expect(nested.parent == "auth-rewrite")
        #expect(ChainBook([chain, nested]).children(of: "auth-rewrite").map(\.slug) == ["sub"])
    }
}
