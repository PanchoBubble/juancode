// The right rail's persisted tab navigation and optional stacked layout.
// Tabs show Worktree or one Overview queue. Stacking stores an independent order,
// visible set and panel sizes, so switching modes preserves both arrangements.
// Schema 3 tab migration still upgrades the older accordion and Diff layouts.

import Foundation

public enum RightRailPrefs {
    public static let viewKey = "rightRail.view"
    public static let queueKey = "rightRail.queue"
    public static let orderKey = "rightRail.order"
    /// Stacking is opt-in; existing tab navigation remains the default.
    public static let stackedKey = "rightRail.stacked"
    public static let visibleKey = "rightRail.stack.visible"
    public static let stackOrderKey = "rightRail.stack.order"
    public static let stackSizesKey = "rightRail.stack.sizes"
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

    /// Independent of tab selection so switching layouts preserves both setups.
    public struct Stack: Equatable, Sendable {
        public var order: [String]
        public var visible: Set<String>
        public var shown: [String] { order.filter(visible.contains) }

        public init(order: [String] = [], visible: [String] = ["oracle", "prs"]) {
            let all = [RightRailPrefs.worktree] + RightRailPrefs.queues
            var unique: [String] = []
            for name in order where all.contains(name) && !unique.contains(name) { unique.append(name) }
            self.order = unique + all.filter { !unique.contains($0) }
            self.visible = Set(visible.filter(all.contains))
        }

        public func setting(_ name: String, shown: Bool) -> Stack {
            var next = self
            guard order.contains(name) else { return next }
            if shown { next.visible.insert(name) } else { next.visible.remove(name) }
            return next
        }

        public func moving(_ name: String, before target: String) -> Stack {
            guard name != target, order.contains(name), order.contains(target) else { return self }
            var next = self
            next.order.removeAll { $0 == name }
            next.order.insert(name, at: next.order.firstIndex(of: target)!)
            return next
        }
    }

    public static func stack(in d: UserDefaults = .standard) -> Stack {
        Stack(order: names(d.string(forKey: stackOrderKey) ?? ""),
              visible: d.string(forKey: visibleKey).map(names) ?? ["oracle", "prs"])
    }

    public static func storeStack(_ stack: Stack, in d: UserDefaults = .standard) {
        d.set(stack.order.joined(separator: ","), forKey: stackOrderKey)
        d.set(stack.shown.joined(separator: ","), forKey: visibleKey)
    }

    // MARK: - Shortcut entry points

    /// Show `destination` and the rail, or hide it. In stacked mode, other panels
    /// stay visible. In tab mode, hiding the current destination hides the rail.
    public static func setOpen(_ destination: String, _ open: Bool, in d: UserDefaults = .standard) {
        migrate(d)
        let s = state(Stored(d))
        if d.bool(forKey: stackedKey) {
            storeStack(stack(in: d).setting(destination, shown: open), in: d)
            if open { d.set(true, forKey: railShownKey) }
            return
        }
        if open {
            stored(s.showing(destination)).write(to: d)
            d.set(true, forKey: railShownKey)
        } else if railShown(d), s.isVisible(destination) {
            d.set(false, forKey: railShownKey)
        }
    }

    /// Whether `destination` is what the rail shows right now.
    public static func isOpen(_ destination: String, in d: UserDefaults = .standard) -> Bool {
        railShown(d) && (d.bool(forKey: stackedKey)
            ? stack(in: d).visible.contains(destination)
            : state(Stored(d)).isVisible(destination))
    }

    static func railShown(_ d: UserDefaults) -> Bool {
        d.object(forKey: railShownKey) as? Bool ?? true
    }

    static func names(_ raw: String) -> [String] {
        raw.split(separator: ",").map(String.init)
    }
}
