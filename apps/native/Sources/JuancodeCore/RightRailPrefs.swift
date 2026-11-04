// The right rail's stored panel preferences and the rules that change them.
//
// The rail is two groups. Worktree, the selected session's checkout, is anchored at
// the top and follows the selection; it can be collapsed but never hidden or moved,
// so the current worktree is always identifiable. Beneath it the global queues
// (Oracles, PRs, Tickets, Chains) keep the user's order and do not change with the
// selection.
//
// Among the global queues one is *selected*: it is the section the user last opened
// and it fills whatever room the others leave. One other may be *pinned*: opening a
// third section collapses everything but the selected and the pinned one.
//
// Everything is a string in UserDefaults: order, collapsed and hidden are comma lists
// of section names, heights is "name:points" pairs. Hidden is a deny-list rather than
// a list of what is shown, so a section added in a later build is visible the first
// time it exists and the user hides it from there.
//
// Schema 2 retired the standalone Diff panel into Worktree. `migrated` carries a
// schema-1 user's choices across: Diff's collapsed state and height become
// Worktree's, a hidden Diff becomes a collapsed Worktree (Worktree cannot be hidden),
// and the global order and every other choice are kept as they were.

import Foundation

public enum RightRailPrefs {
    public static let orderKey = "rightRail.order"
    public static let collapsedKey = "rightRail.collapsed"
    public static let hiddenKey = "rightRail.hidden"
    public static let heightsKey = "rightRail.heights"
    public static let selectedKey = "rightRail.selected"
    public static let pinnedKey = "rightRail.pinned"
    public static let schemaKey = "rightRail.schema"
    public static let schema = 2

    /// The anchored, selection-scoped section.
    public static let worktree = "worktree"
    /// The global queues in their default order.
    public static let globals = ["oracle", "prs", "tickets", "chains"]
    /// Every section the rail knows, Worktree first.
    public static let sections = [worktree] + globals
    /// Schema 1's standalone Diff panel, folded into Worktree.
    public static let retiredDiff = "diff"
    /// Collapsed for someone who has never stored a choice: Chains is optional.
    public static let defaultCollapsed: Set<String> = ["chains"]

    // MARK: - Generic list helpers (kept for callers typed over their own enum)

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

    // MARK: - Shortcut entry points (⌘-keys write the same keys the rail reads)

    /// Whether the rail shows `panel` open: the rail is up and the panel is neither
    /// hidden nor collapsed.
    public static func isOpen(_ panel: String, railShown: Bool, collapsedRaw: String, hiddenRaw: String) -> Bool {
        railShown && !names(collapsedRaw).contains(panel) && !names(hiddenRaw).contains(panel)
    }

    /// The collapsed and hidden lists after opening (`open`) or collapsing `panel`.
    /// Opening a hidden panel un-hides it: asking for it by name is asking to see it.
    /// Collapsing leaves the hidden list alone. Prefer `State.opening`/`collapsing`,
    /// which also keep the selected and pinned sections right.
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

    // MARK: - State

    /// The rail's whole preference state, healed: only known names, Worktree never
    /// in `order` or `hidden`, `selected` and `pinned` distinct global sections.
    public struct State: Equatable, Sendable {
        /// Global sections in the user's order. Worktree is anchored above them.
        public var order: [String]
        public var collapsed: Set<String>
        /// Global sections taken off the rail in edit mode.
        public var hidden: Set<String>
        /// Points for each section the user resized.
        public var heights: [String: Double]
        /// The global section that gets most of the space.
        public var selected: String?
        /// The one other global section kept open when another is opened.
        public var pinned: String?

        public init(order: [String] = RightRailPrefs.globals,
                    collapsed: Set<String> = RightRailPrefs.defaultCollapsed,
                    hidden: Set<String> = [],
                    heights: [String: Double] = [:],
                    selected: String? = nil,
                    pinned: String? = nil) {
            self.order = order
            self.collapsed = collapsed
            self.hidden = hidden
            self.heights = heights
            self.selected = selected
            self.pinned = pinned
            heal()
        }

        public func isOpen(_ section: String) -> Bool {
            !collapsed.contains(section) && !hidden.contains(section)
        }

        /// Open sections in display order: Worktree, then the globals.
        public var expanded: [String] {
            ([RightRailPrefs.worktree] + order).filter(isOpen)
        }

        /// The open section that takes the space the others leave: the selected
        /// one, else the last open global, else Worktree.
        public var filler: String? {
            let open = expanded
            if let s = selected, open.contains(s) { return s }
            return open.last
        }

        /// Open `section`. A global becomes the selected one and every other global
        /// except the pinned one collapses; a hidden one is un-hidden, since asking
        /// for it by name is asking to see it. Worktree only opens.
        public func opening(_ section: String) -> State {
            var s = self
            s.collapsed.remove(section)
            guard RightRailPrefs.globals.contains(section) else { return s }
            s.hidden.remove(section)
            if s.pinned == section { s.pinned = nil }
            s.selected = section
            for other in RightRailPrefs.globals where other != section && other != s.pinned {
                s.collapsed.insert(other)
            }
            return s
        }

        /// Collapse `section`. Collapsing the selected one hands the space to the
        /// pinned one; collapsing the pinned one unpins it.
        public func collapsing(_ section: String) -> State {
            var s = self
            s.collapsed.insert(section)
            if s.pinned == section { s.pinned = nil }
            if s.selected == section {
                s.selected = s.pinned
                s.pinned = nil
            }
            return s
        }

        public func toggling(_ section: String) -> State {
            isOpen(section) ? collapsing(section) : opening(section)
        }

        /// Pin (or unpin) an open global section other than the selected one. A
        /// new pin replaces the old; the old one stays open until another opens.
        public func togglingPin(_ section: String) -> State {
            var s = self
            if s.pinned == section {
                s.pinned = nil
            } else if RightRailPrefs.globals.contains(section), section != s.selected, isOpen(section) {
                s.pinned = section
            }
            return s
        }

        /// Hide or restore a global section. Worktree cannot be hidden.
        public func settingHidden(_ section: String, _ hide: Bool) -> State {
            guard RightRailPrefs.globals.contains(section) else { return self }
            var s = self
            if hide {
                s.hidden.insert(section)
                if s.pinned == section { s.pinned = nil }
                if s.selected == section { s.selected = s.pinned; s.pinned = nil }
            } else {
                s.hidden.remove(section)
            }
            return s
        }

        /// Move `dragged` to where `target` is. Only globals move; Worktree stays
        /// anchored, so a drop on it puts `dragged` first among the globals.
        public func moving(_ dragged: String, to target: String) -> State {
            guard dragged != target, order.contains(dragged) else { return self }
            var s = self
            s.order.removeAll { $0 == dragged }
            let at = target == RightRailPrefs.worktree ? 0 : (s.order.firstIndex(of: target) ?? s.order.endIndex)
            s.order.insert(dragged, at: at)
            return s
        }

        /// Collapse every section, or open Worktree plus the selected (else first
        /// visible) global and the pinned one.
        public func settingAllCollapsed(_ collapse: Bool) -> State {
            var s = self
            if collapse {
                s.collapsed = Set(RightRailPrefs.sections)
                return s
            }
            s.collapsed.remove(RightRailPrefs.worktree)
            let visible = order.filter { !hidden.contains($0) }
            if let lead = selected.flatMap({ visible.contains($0) ? $0 : nil }) ?? visible.first {
                s = s.opening(lead)
            }
            if let p = s.pinned { s.collapsed.remove(p) }
            return s
        }

        mutating func heal() {
            let globals = RightRailPrefs.globals
            var seen: [String] = []
            for name in order where globals.contains(name) && !seen.contains(name) { seen.append(name) }
            order = seen + globals.filter { !seen.contains($0) }
            collapsed = collapsed.intersection(RightRailPrefs.sections)
            hidden = hidden.intersection(globals)
            heights = heights.filter { RightRailPrefs.sections.contains($0.key) && $0.value > 0 }
            if let s = selected, !globals.contains(s) || hidden.contains(s) { selected = nil }
            if let p = pinned, !globals.contains(p) || hidden.contains(p) || p == selected { pinned = nil }
        }
    }

    // MARK: - Storage

    /// The stored strings, as UserDefaults holds them; nil for a key never written.
    public struct Stored: Equatable, Sendable {
        public var order: String?
        public var collapsed: String?
        public var hidden: String?
        public var heights: String?
        public var selected: String?
        public var pinned: String?
        public var schema: Int?

        public init(order: String? = nil, collapsed: String? = nil, hidden: String? = nil,
                    heights: String? = nil, selected: String? = nil, pinned: String? = nil,
                    schema: Int? = nil) {
            self.order = order
            self.collapsed = collapsed
            self.hidden = hidden
            self.heights = heights
            self.selected = selected
            self.pinned = pinned
            self.schema = schema
        }

        public init(_ d: UserDefaults) {
            self.init(order: d.string(forKey: orderKey),
                      collapsed: d.string(forKey: collapsedKey),
                      hidden: d.string(forKey: hiddenKey),
                      heights: d.string(forKey: heightsKey),
                      selected: d.string(forKey: selectedKey),
                      pinned: d.string(forKey: pinnedKey),
                      schema: d.object(forKey: schemaKey) as? Int)
        }

        public func write(to d: UserDefaults) {
            func put(_ v: String?, _ k: String) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
            put(order, orderKey)
            put(collapsed, collapsedKey)
            put(hidden, hiddenKey)
            put(heights, heightsKey)
            put(selected, selectedKey)
            put(pinned, pinnedKey)
            if let schema { d.set(schema, forKey: schemaKey) } else { d.removeObject(forKey: schemaKey) }
        }
    }

    /// Read the state. Stored strings from schema 1 are interpreted through the
    /// migration, so a read never shows a retired Diff even before `migrate` ran.
    public static func state(_ stored: Stored) -> State {
        let s = (stored.schema ?? 0) >= schema ? stored : migrated(stored)
        return State(order: names(s.order ?? ""),
                     collapsed: s.collapsed.map { Set(names($0)) } ?? defaultCollapsed,
                     hidden: Set(names(s.hidden ?? "")),
                     heights: heights(from: s.heights ?? ""),
                     selected: s.selected.flatMap { $0.isEmpty ? nil : $0 },
                     pinned: s.pinned.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// `state` written back, every key present and in a stable order.
    public static func stored(_ state: State) -> Stored {
        Stored(order: state.order.joined(separator: ","),
               collapsed: sections.filter(state.collapsed.contains).joined(separator: ","),
               hidden: globals.filter(state.hidden.contains).joined(separator: ","),
               heights: sections.compactMap { k in state.heights[k].map { "\(k):\(Int($0.rounded()))" } }
                   .joined(separator: ","),
               selected: state.selected ?? "",
               pinned: state.pinned ?? "",
               schema: schema)
    }

    /// Carry schema-1 strings into schema 2. Everything stored is kept except Diff,
    /// whose choices pass to Worktree; a collapsed list never written gets the
    /// defaults (Chains collapsed). Idempotent on schema-2 input.
    public static func migrated(_ old: Stored) -> Stored {
        guard (old.schema ?? 0) < schema else { return old }
        var out = old
        out.schema = schema
        let wasHidden = names(old.hidden ?? "").contains(retiredDiff)
        if let order = old.order {
            out.order = names(order).filter { $0 != retiredDiff && $0 != worktree }.joined(separator: ",")
        }
        if let hidden = old.hidden {
            out.hidden = names(hidden).filter { $0 != retiredDiff && $0 != worktree }.joined(separator: ",")
        }
        if let collapsed = old.collapsed {
            var c = names(collapsed).map { $0 == retiredDiff ? worktree : $0 }
            if wasHidden { c.append(worktree) }
            var seen: [String] = []
            for n in c where !seen.contains(n) { seen.append(n) }
            out.collapsed = seen.joined(separator: ",")
        } else {
            // Never stored: write the defaults, so the ⌘-key shortcuts that read
            // the raw strings agree with what the rail shows.
            var c = sections.filter(defaultCollapsed.contains)
            if wasHidden { c.insert(worktree, at: 0) }
            out.collapsed = c.joined(separator: ",")
        }
        if let raw = old.heights {
            var h = heights(from: raw)
            if let d = h.removeValue(forKey: retiredDiff), h[worktree] == nil { h[worktree] = d }
            out.heights = sections.compactMap { k in h[k].map { "\(k):\(Int($0.rounded()))" } }
                .joined(separator: ",")
        }
        // Schema 1 had no selection: the first open global takes the space, and
        // nothing open is collapsed underneath the user.
        if old.selected == nil {
            let st = State(order: names(out.order ?? ""),
                           collapsed: Set(names(out.collapsed ?? "")),
                           hidden: Set(names(out.hidden ?? "")))
            out.selected = st.order.first(where: st.isOpen) ?? ""
        }
        return out
    }

    /// Migrate `d` in place if it still holds schema-1 strings. Safe to call on
    /// every launch; a fresh install is left to the defaults.
    @discardableResult
    public static func migrate(_ d: UserDefaults) -> Bool {
        let old = Stored(d)
        guard (old.schema ?? 0) < schema else { return false }
        migrated(old).write(to: d)
        return true
    }

    /// Open or collapse `section` in `d` the way the rail would, for the ⌘-key
    /// shortcuts. Opening also shows the rail.
    public static func setOpen(_ section: String, _ open: Bool, in d: UserDefaults = .standard) {
        migrate(d)
        let s = state(Stored(d))
        stored(open ? s.opening(section) : s.collapsing(section)).write(to: d)
        if open { d.set(true, forKey: railShownKey) }
    }

    public static func isOpen(_ section: String, in d: UserDefaults = .standard) -> Bool {
        (d.object(forKey: railShownKey) as? Bool ?? true) && state(Stored(d)).isOpen(section)
    }

    /// Whether the rail itself is up; owned by the window's toolbar toggle.
    public static let railShownKey = "oracle.sessionRail.shown"

    /// "name:points" pairs, unknown or malformed pairs kept out by the caller.
    public static func heights(from raw: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for pair in raw.split(separator: ",") {
            let kv = pair.split(separator: ":")
            guard kv.count == 2, let v = Double(kv[1]) else { continue }
            out[String(kv[0])] = v
        }
        return out
    }

    static func names(_ raw: String) -> [String] {
        raw.split(separator: ",").map(String.init)
    }
}
