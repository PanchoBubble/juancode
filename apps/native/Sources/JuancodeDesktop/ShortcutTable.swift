// The pure rules behind the app's rebindable shortcuts: which persisted bindings a
// new factory layout migrates, and which action owns a chord two actions share.
//
// Generic over the binding type because `KeyBinding` lives in the JuancodeApp
// executable (it speaks SwiftUI/AppKit), which has no test target; the rules here
// are what can lose a user's choices, so they live where they can be tested.

import Foundation

public enum ShortcutTable {
    /// Drop persisted bindings that still equal a factory default the app has since
    /// moved, so those actions fall back to their new default. Anything else the user
    /// stored, including a custom choice for a displaced action, is kept as is.
    ///
    /// `displaced` maps an action's persistence key to its OLD factory binding.
    /// Run it once per layout change, not on every load: afterwards an exact match
    /// is the user's deliberate choice, not a leftover default.
    public static func migrateDisplacedDefaults<B: Equatable>(
        _ stored: [String: B], displaced: [String: B]
    ) -> [String: B] {
        stored.filter { key, binding in displaced[key] != binding }
    }

    /// The action that fires for `binding` when several share it. A binding the user
    /// chose beats one that is merely a factory default, so a new default can never
    /// steal a chord someone set on purpose; between equals, `order` decides.
    public static func owner<B: Equatable>(
        of binding: B, order: [String],
        effective: (String) -> B, isCustom: (String) -> Bool
    ) -> String? {
        let sharing = order.filter { effective($0) == binding }
        return sharing.first(where: isCustom) ?? sharing.first
    }
}
