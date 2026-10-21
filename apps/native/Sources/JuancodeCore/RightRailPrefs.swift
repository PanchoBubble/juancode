// The right rail's stored panel preferences: order, collapsed and hidden, each a
// comma-joined list of panel names in UserDefaults.
//
// Hidden is a deny-list rather than a list of what is shown, so a panel added in a
// later build is visible the first time it exists and the user hides it from there.

import Foundation

public enum RightRailPrefs {
    public static let orderKey = "rightRail.order"
    public static let collapsedKey = "rightRail.collapsed"
    public static let hiddenKey = "rightRail.hidden"

    /// Stored order, healed: unknown names dropped, duplicates dropped, missing
    /// panels appended in `known` order.
    public static func order<P: RawRepresentable & Equatable>(from raw: String, known: [P]) -> [P]
    where P.RawValue == String {
        var seen = names(raw).compactMap(P.init(rawValue:))
        seen = seen.enumerated().filter { i, p in !seen[..<i].contains(p) }.map(\.1)
        return seen + known.filter { !seen.contains($0) }
    }

    /// The set a comma list names, unknown names dropped.
    public static func set<P: RawRepresentable & Hashable>(from raw: String) -> Set<P>
    where P.RawValue == String {
        Set(names(raw).compactMap(P.init(rawValue:)))
    }

    /// `set` written back, in `known` order so the stored string is stable.
    public static func raw<P: RawRepresentable & Hashable>(_ set: Set<P>, known: [P]) -> String
    where P.RawValue == String {
        known.filter(set.contains).map(\.rawValue).joined(separator: ",")
    }

    /// Whether the rail shows `panel` open: the rail is up and the panel is neither
    /// hidden nor collapsed.
    public static func isOpen(_ panel: String, railShown: Bool, collapsedRaw: String, hiddenRaw: String) -> Bool {
        railShown && !names(collapsedRaw).contains(panel) && !names(hiddenRaw).contains(panel)
    }

    /// The collapsed and hidden lists after opening (`open`) or collapsing `panel`.
    /// Opening a hidden panel un-hides it: asking for it by name is asking to see it.
    /// Collapsing leaves the hidden list alone.
    public static func setting(_ panel: String, open: Bool, collapsedRaw: String, hiddenRaw: String)
        -> (collapsed: String, hidden: String) {
        var collapsed = names(collapsedRaw)
        var hidden = names(hiddenRaw)
        if open {
            collapsed.removeAll { $0 == panel }
            hidden.removeAll { $0 == panel }
        } else if !collapsed.contains(panel) {
            collapsed.append(panel)
        }
        return (collapsed.joined(separator: ","), hidden.joined(separator: ","))
    }

    private static func names(_ raw: String) -> [String] {
        raw.split(separator: ",").map(String.init)
    }
}
