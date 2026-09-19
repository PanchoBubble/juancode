import Foundation
import JuancodeCore

/// A saved session preset (juancode-a2r): a named starter config — agent, folder,
/// spawn knobs, and an optional seed prompt — that spawns one or many sessions in a
/// single action. Where `PromptTemplate` reuses a *prompt*, this reuses the whole
/// *launch* ("another Claude in ~/work/api, accept-all, in a fresh worktree, kicked
/// off with this brief").
///
/// This file holds the persisted model + pure ordering math, kept alongside
/// `PromptTemplate`/`RecurringTask` so it's unit-testable without a pty or UI. The
/// store driver — `UserDefaults` persistence and the spawn wiring — lives in
/// `AppModel`, mirroring how prompt templates and tracked PRs are handled.
///
/// Faithful to the prime directive: a template only carries the knobs juancode
/// already passes (`--session-id` pin + opt-in skip-permissions) plus an initial
/// prompt seeded through the normal `autoSubmit` path. It never injects extra CLI
/// argv or a shadow env, so a templated session launches identically to a hand-made
/// one.
public struct SessionTemplate: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    /// Short human label shown in the launcher list.
    public var name: String
    public var provider: ProviderId
    /// Working directory the session opens in.
    public var cwd: String
    /// Launch in "accept all" mode (skip permission prompts).
    public var skipPermissions: Bool
    /// Isolate each spawned session in a fresh git worktree.
    public var isolateWorktree: Bool
    /// Optional prompt seeded into the session once its TUI is up (empty = none).
    public var initialPrompt: String
    public var createdAt: Int
    public var updatedAt: Int

    public init(id: String = UUID().uuidString, name: String, provider: ProviderId,
                cwd: String, skipPermissions: Bool = true, isolateWorktree: Bool = false,
                initialPrompt: String = "", createdAt: Int, updatedAt: Int) {
        self.id = id
        self.name = name
        self.provider = provider
        self.cwd = cwd
        self.skipPermissions = skipPermissions
        self.isolateWorktree = isolateWorktree
        self.initialPrompt = initialPrompt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - pure search / ordering

/// Session templates ordered for the launcher's default view: most recently edited
/// first, so a just-saved template surfaces at the top. Pure.
public func orderedSessionTemplates(_ templates: [SessionTemplate]) -> [SessionTemplate] {
    templates.sorted { $0.updatedAt > $1.updatedAt }
}

/// The templates matching `query` (fuzzy over name + folder), in launcher order.
/// With an empty query this is just `orderedSessionTemplates`. Pure — reuses the
/// palette's `fuzzyMatches` so the launcher filters like the prompt palette.
public func filteredSessionTemplates(_ templates: [SessionTemplate], query: String) -> [SessionTemplate] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let matched = trimmed.isEmpty
        ? templates
        : templates.filter { fuzzyMatches(trimmed, in: $0.name) || fuzzyMatches(trimmed, in: $0.cwd) }
    return orderedSessionTemplates(matched)
}
