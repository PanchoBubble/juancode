import Foundation

/// Saved prompt templates for the ⌘K command palette (juancode-2vd): quick-insert
/// reusable prompts into the active session's composer.
///
/// These are **juancode-side** templates — distinct from the CLI's own slash
/// commands (`/clear`, `/compact`, …), which pass through the pty untouched. A
/// template is just a named blob of text the user saves once and inserts (or
/// inserts-and-submits) into a live session whenever they want it.
///
/// This file holds the persisted model + the pure search/ordering math, kept here
/// (alongside `RecurringTask`) so it's unit-testable without a pty or UI. The store
/// driver — persistence to `UserDefaults` and the insert/submit wiring — lives in
/// `AppModel`, mirroring how tracked PRs and recurring tasks are handled.

/// One saved prompt template: a title and the prompt body. `createdAt`/`updatedAt`
/// are ms-since-epoch, used for stable ordering and "recently edited" sorting.
public struct PromptTemplate: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    /// Short human label shown in the palette list.
    public var title: String
    /// The prompt text inserted into the composer.
    public var body: String
    public var createdAt: Int
    public var updatedAt: Int

    public init(id: String = UUID().uuidString, title: String, body: String,
                createdAt: Int, updatedAt: Int) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - pure search / ordering

/// Templates ordered for the palette's default (no-query) view: most recently
/// edited first, so a just-saved template surfaces at the top. Pure.
public func orderedTemplates(_ templates: [PromptTemplate]) -> [PromptTemplate] {
    templates.sorted { $0.updatedAt > $1.updatedAt }
}

/// Case-insensitive subsequence match: every character of `query` appears in
/// `text` in order (fuzzy, like a command palette). An empty query matches
/// everything. Pure.
public func fuzzyMatches(_ query: String, in text: String) -> Bool {
    let q = query.lowercased()
    guard !q.isEmpty else { return true }
    var qi = q.startIndex
    for ch in text.lowercased() {
        if ch == q[qi] {
            qi = q.index(after: qi)
            if qi == q.endIndex { return true }
        }
    }
    return false
}

/// The templates matching `query` (fuzzy over title + body), in palette order.
/// With an empty query this is just `orderedTemplates`. Pure — drives the palette
/// list and is unit-testable without UI.
public func filteredTemplates(_ templates: [PromptTemplate], query: String) -> [PromptTemplate] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let matched = trimmed.isEmpty
        ? templates
        : templates.filter { fuzzyMatches(trimmed, in: $0.title) || fuzzyMatches(trimmed, in: $0.body) }
    return orderedTemplates(matched)
}
