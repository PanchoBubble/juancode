import Foundation

/// Presentation logic for the "remote is driving" pane overlay (juancode-2t4).
///
/// While a web/phone viewer owns a session's pty grid (`GridArbiter`), the
/// visible native pane shows an explicit badge with a one-click take-back
/// instead of silently rendering someone else's grid. The overlay itself is
/// SwiftUI (`RemoteDriveOverlay` in the app target); the decisions it renders —
/// which grid owners count as remote, how an opaque client id is displayed, and
/// when the badge folds away — live here so they're testable and shared with
/// whatever surface needs them next.
public enum RemoteDriveBadge {
    /// The remote owner to surface for a grid-owner change, or nil when the
    /// overlay must be hidden: the grid is unclaimed (nobody is driving) or the
    /// local pane owns it (that's just us).
    public static func remoteOwner(from gridOwner: String?) -> String? {
        RemoteGridFit.isRemote(owner: gridOwner) ? gridOwner : nil
    }

    /// Short display handle for an opaque remote client id (the WS layer mints
    /// UUIDs): the first `-` group, lowercased — enough to tell two concurrent
    /// viewers apart without dumping a full UUID onto the pane.
    public static func shortOwner(_ owner: String) -> String {
        let head = owner.split(separator: "-").first.map(String.init) ?? owner
        return String(head.prefix(8)).lowercased()
    }

    /// How long the expanded overlay lingers before collapsing to the slim
    /// glyph-only capsule (Orca's MobileDriverOverlay collapse), so it never
    /// occludes the TUI for more than a moment; hovering re-expands it.
    public static let collapseAfterSeconds: Double = 5
}
