// The right rail's stored navigation and the rules that change it.
//
// The rail shows one of two full-height views, chosen from a tab bar: Worktree (the
// selected session's checkout: Files/Changes and File/Diff) or Overview (the global
// queues). Overview shows exactly one queue at a time, picked from a compact
// selector: Oracles, PRs, Tickets or Chains. So the rail always shows exactly one
// destination: Worktree, or one Overview queue.
//
// Stored in UserDefaults as plain strings: the view, the Overview queue and the
// selector's order (a comma list). Every queue is always in the selector; nothing
// can be hidden, so no stored choice can make a destination unreachable.
//
// Schema 3 replaced the stacked accordion (schema 2), which itself folded the
// standalone Diff panel (schema 1) into Worktree. `migrated` turns either into a
// valid view and queue deterministically and drops the accordion's keys.

import Foundation

public enum RightRailPrefs {
    public static let viewKey = "rightRail.view"
    public static let queueKey = "rightRail.queue"
    public static let orderKey = "rightRail.order"
    public static let schemaKey = "rightRail.schema"
    public static let schema = 3
    /// Whether the rail itself is up; shared with the window's toolbar toggle.
    public static let railShownKey = "oracle.sessionRail.shown"

    // The accordion's keys (schemas 1 and 2), read once by the migration and removed.
    static let legacyCollapsedKey = "rightRail.collapsed"
    static let legacyHiddenKey = "rightRail.hidden"
    static let legacyHeightsKey = "rightRail.heights"
    static let legacySelectedKey = "rightRail.selected"
    static let legacyPinnedKey = "rightRail.pinned"

    /// The selection-scoped destination.
    public static let worktree = "worktree"
    /// Overview's queues in their default order.
    public static let queues = ["oracle", "prs", "tickets", "chains"]
    /// Schema 1's standalone Diff panel, folded into Worktree.
    static let retiredDiff = "diff"

    public enum View: String, Sendable, CaseIterable {
        case worktree, overview
    }

    // MARK: - State

    public struct State: Equatable, Sendable {
        public var view: View
        /// The queue Overview shows. Remembered while Worktree is up.
        public var queue: String
        /// Overview's selector order: every queue, once.
        public var order: [String]

        public init(view: View = .worktree, queue: String? = nil, order: [String] = RightRailPrefs.queues) {
            var seen: [String] = []
            for name in order where RightRailPrefs.queues.contains(name) && !seen.contains(name) { seen.append(name) }
            self.order = seen + RightRailPrefs.queues.filter { !seen.contains($0) }
            self.view = view
            self.queue = queue.flatMap { RightRailPrefs.queues.contains($0) ? $0 : nil } ?? self.order[0]
        }

        /// What the rail shows: `worktree`, or the Overview queue.
        public var destination: String { view == .worktree ? RightRailPrefs.worktree : queue }

        public func isVisible(_ destination: String) -> Bool { destination == self.destination }

        /// Show `destination`: Worktree switches to the Worktree tab; a queue switches
        /// to Overview on that queue. Anything else changes nothing.
        public func showing(_ destination: String) -> State {
            var s = self
            if destination == RightRailPrefs.worktree {
                s.view = .worktree
            } else if RightRailPrefs.queues.contains(destination) {
                s.view = .overview
                s.queue = destination
            }
            return s
        }
    }

    // MARK: - Storage

    /// The stored strings, as UserDefaults holds them; nil for a key never written.
    public struct Stored: Equatable, Sendable {
        public var view: String?
        public var queue: String?
        public var order: String?
        public var schema: Int?
        // Schemas 1 and 2 only.
        public var collapsed: String?
        public var hidden: String?
        public var heights: String?
        public var selected: String?
        public var pinned: String?

        public init(view: String? = nil, queue: String? = nil, order: String? = nil, schema: Int? = nil,
                    collapsed: String? = nil, hidden: String? = nil, heights: String? = nil,
                    selected: String? = nil, pinned: String? = nil) {
            self.view = view
            self.queue = queue
            self.order = order
            self.schema = schema
            self.collapsed = collapsed
            self.hidden = hidden
            self.heights = heights
            self.selected = selected
            self.pinned = pinned
        }

        public init(_ d: UserDefaults) {
            self.init(view: d.string(forKey: viewKey),
                      queue: d.string(forKey: queueKey),
                      order: d.string(forKey: orderKey),
                      schema: d.object(forKey: schemaKey) as? Int,
                      collapsed: d.string(forKey: legacyCollapsedKey),
                      hidden: d.string(forKey: legacyHiddenKey),
                      heights: d.string(forKey: legacyHeightsKey),
                      selected: d.string(forKey: legacySelectedKey),
                      pinned: d.string(forKey: legacyPinnedKey))
        }

        public func write(to d: UserDefaults) {
            func put(_ v: String?, _ k: String) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
            put(view, viewKey)
            put(queue, queueKey)
            put(order, orderKey)
            if let schema { d.set(schema, forKey: schemaKey) } else { d.removeObject(forKey: schemaKey) }
            put(collapsed, legacyCollapsedKey)
            put(hidden, legacyHiddenKey)
            put(heights, legacyHeightsKey)
            put(selected, legacySelectedKey)
            put(pinned, legacyPinnedKey)
        }
    }

    /// Read the state. Older schemas are read through the migration, so a read is
    /// valid even before `migrate` has run.
    public static func state(_ stored: Stored) -> State {
        guard (stored.schema ?? 0) >= schema else { return migrated(stored) }
        return State(view: stored.view.flatMap(View.init(rawValue:)) ?? .worktree,
                     queue: stored.queue,
                     order: names(stored.order ?? ""))
    }

    /// `state` written back: every current key present, the accordion's removed.
    public static func stored(_ state: State) -> Stored {
        Stored(view: state.view.rawValue, queue: state.queue,
               order: state.order.joined(separator: ","), schema: schema)
    }

    /// An accordion (schema 2) or Diff-panel (schema 1) layout as one valid view.
    ///
    /// - The selector keeps the stored order; Diff and Worktree drop out of it.
    /// - Overview's queue is the accordion's selected section, else its first open
    ///   queue, else the first queue in order. A hidden section is not skipped:
    ///   nothing is hidden any more, so it is as reachable as the rest.
    /// - The view is Worktree unless the stored layout had Worktree (or Diff)
    ///   collapsed or hidden while some queue was open. A fresh install, which
    ///   stored nothing, starts on Worktree.
    public static func migrated(_ old: Stored) -> State {
        let fromDiff = (old.schema ?? 0) < 2
        func mapped(_ n: String) -> String { fromDiff && n == retiredDiff ? worktree : n }
        let order = names(old.order ?? "").map(mapped).filter(queues.contains)
        let hidden = Set(names(old.hidden ?? "").map(mapped))
        // A never-written collapsed list meant the accordion's default: only Chains.
        let collapsed = old.collapsed.map { Set(names($0).map(mapped)) } ?? ["chains"]
        let base = State(order: order)
        let open = base.order.filter { !collapsed.contains($0) && !hidden.contains($0) }
        let selected = old.selected.flatMap { queues.contains($0) ? $0 : nil }
        let worktreeShown = !collapsed.contains(worktree) && !hidden.contains(worktree)
        let anyStored = old.order != nil || old.collapsed != nil || old.hidden != nil
        let view: View = (!anyStored || worktreeShown || open.isEmpty) ? .worktree : .overview
        return State(view: view, queue: selected ?? open.first ?? base.order[0], order: base.order)
    }

    /// Rewrite `d` in the current schema if it holds an older one. Safe on every
    /// launch; returns whether it wrote.
    @discardableResult
    public static func migrate(_ d: UserDefaults) -> Bool {
        let old = Stored(d)
        guard (old.schema ?? 0) < schema else { return false }
        stored(migrated(old)).write(to: d)
        return true
    }

    // MARK: - Shortcut entry points

    /// Show `destination` (and the rail), or hide it. Hiding a destination that is
    /// on screen hides the rail; hiding one that is not on screen changes nothing,
    /// so a toggle never flips the user to a different view.
    public static func setOpen(_ destination: String, _ open: Bool, in d: UserDefaults = .standard) {
        migrate(d)
        let s = state(Stored(d))
        if open {
            stored(s.showing(destination)).write(to: d)
            d.set(true, forKey: railShownKey)
        } else if railShown(d), s.isVisible(destination) {
            d.set(false, forKey: railShownKey)
        }
    }

    /// Whether `destination` is what the rail shows right now.
    public static func isOpen(_ destination: String, in d: UserDefaults = .standard) -> Bool {
        railShown(d) && state(Stored(d)).isVisible(destination)
    }

    static func railShown(_ d: UserDefaults) -> Bool {
        d.object(forKey: railShownKey) as? Bool ?? true
    }

    static func names(_ raw: String) -> [String] {
        raw.split(separator: ",").map(String.init)
    }
}
