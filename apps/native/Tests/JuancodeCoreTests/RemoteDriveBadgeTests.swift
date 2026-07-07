import Testing
@testable import JuancodeCore

/// Presentation decisions behind the "remote is driving" pane overlay
/// (juancode-2t4): only a genuinely remote grid owner surfaces the badge, and
/// opaque WS client UUIDs are shown as a short stable handle.
@Suite struct RemoteDriveBadgeTests {
    @Test func onlyARemoteOwnerSurfacesTheBadge() {
        #expect(RemoteDriveBadge.remoteOwner(from: "ws-client-7") == "ws-client-7")
        // The local pane owning its own grid is the normal visible state.
        #expect(RemoteDriveBadge.remoteOwner(from: GridArbiter.localOwner) == nil)
        // An unclaimed grid has no driver to warn about.
        #expect(RemoteDriveBadge.remoteOwner(from: nil) == nil)
    }

    @Test func shortOwnerTrimsAWsUuidToItsFirstGroup() {
        #expect(RemoteDriveBadge.shortOwner("9A2B3C4D-1111-2222-3333-444455556666") == "9a2b3c4d")
    }

    @Test func shortOwnerPassesNonUuidIdsThrough() {
        #expect(RemoteDriveBadge.shortOwner("phone") == "phone")
        #expect(RemoteDriveBadge.shortOwner("") == "")
        // Never longer than the 8-char handle even without `-` groups.
        #expect(RemoteDriveBadge.shortOwner("abcdefghijkl") == "abcdefgh")
    }
}
