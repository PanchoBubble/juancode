import Foundation
import Observation
import JuancodeCore
import JuancodeClient
import JuancodeDesktop

/// Observable face of `WorktreeViewStore`: the Worktree viewer's navigation per
/// checkout (section, File/Diff, comparison, open file, scroll line), persisted across
/// relaunches. Sessions in the same checkout share it; review comments do not live
/// here (they stay per session in `DiffReviewModel`).
@MainActor
@Observable
final class WorktreeViewModel {
    @ObservationIgnored private let store: WorktreeViewStore
    /// Bumped on every write so views reading `state(_:)` re-render.
    private(set) var revision = 0
    /// The section the next panel to appear should land on, set by an entry point
    /// (⌘C, the review badge, Files) that asked for one. Consumed once.
    var requestedSection: WorktreeSection?

    init(store: WorktreeViewStore = WorktreeViewStore()) {
        self.store = store
    }

    func state(_ worktree: String) -> WorktreeViewState {
        _ = revision
        return store.state(worktree)
    }

    func update(_ worktree: String, _ change: (inout WorktreeViewState) -> Void) {
        let before = store.state(worktree)
        store.update(worktree, change)
        if store.state(worktree) != before { revision &+= 1 }
    }
}

/// What the Worktree viewer is looking at: one session (the agent its feedback goes
/// to) in one checkout (whose files and navigation it shows).
struct WorktreeContext: Equatable {
    /// The session review feedback is sent to. Always the selected session, never
    /// "whichever session shares this checkout".
    var sessionId: String
    /// Canonical path of the checkout the session works in.
    var checkout: String
}

extension AppModel {
    /// The rail section that hosts the Worktree viewer.
    static var worktreeRailPanel: RightRailPanel { .worktree }

    /// Whether the right rail mounts `WorktreeRailPanel`. When it does not, the viewer
    /// floats in the session's side panel instead, never in both places at once.
    static let worktreeInRail = true

    /// The selected session and the checkout it really works in: an agent-cut worktree
    /// first, then where its pty runs, then its recorded worktree — never the repo's
    /// main checkout unless the session is actually there.
    var worktreeContext: WorktreeContext? {
        guard let id = selection, let meta = sessions.first(where: { $0.id == id }) else { return nil }
        return worktreeContext(for: meta)
    }

    func worktreeContext(for meta: SessionMeta) -> WorktreeContext? {
        let live = liveSession(meta.id)?.meta.cwd
        guard let checkout = WorktreeIdentity.checkout(agentWorktree: agentWorktree(meta.id),
                                                        liveCwd: live ?? meta.cwd,
                                                        recorded: meta.effectiveCwd) else { return nil }
        return WorktreeContext(sessionId: meta.id, checkout: checkout)
    }

    /// Show the Worktree viewer on `section` (and on `path`, when given) for the
    /// selected session's checkout.
    func openWorktree(section: WorktreeSection, path: String? = nil) {
        if let ctx = worktreeContext {
            worktreeViews.update(ctx.checkout) { s in
                s.section = section
                if let path { s.select(path) }
            }
        }
        worktreeViews.requestedSection = section
        setWorktreeShown(true)
    }

    var isWorktreeShown: Bool {
        if Self.worktreeInRail { return isRailPanelOpen(Self.worktreeRailPanel) }
        return UserDefaults.standard.object(forKey: SessionSidePanel.shownKey) as? Bool ?? true
    }

    func setWorktreeShown(_ shown: Bool) {
        if Self.worktreeInRail {
            setRailPanelShown(Self.worktreeRailPanel, shown)
        } else {
            UserDefaults.standard.set(shown, forKey: SessionSidePanel.shownKey)
        }
    }

    /// Toggle the viewer onto `section`: hides it only when it is already showing that
    /// section for this checkout; from anywhere else it switches.
    func toggleWorktree(section: WorktreeSection) {
        let onSection = worktreeContext.map { worktreeViews.state($0.checkout).section == section } ?? true
        if isWorktreeShown && onSection {
            setWorktreeShown(false)
        } else {
            openWorktree(section: section)
        }
    }

    /// Expand: the full-width review over the same session, same comparison and same
    /// open file. Its comments are the session's, so nothing is copied.
    func expandWorktreeReview() {
        guard let ctx = worktreeContext else { return }
        let state = worktreeViews.state(ctx.checkout)
        if diffReview.base(ctx.sessionId) != state.comparison {
            loadDiffReview(ctx.sessionId, base: state.comparison)
        }
        openDiffReview()
    }

    /// Change the checkout's comparison and reload the session's review diff on it.
    func setWorktreeComparison(_ base: ReviewBase, context ctx: WorktreeContext) {
        worktreeViews.update(ctx.checkout) { $0.comparison = base }
        loadDiffReview(ctx.sessionId, base: base)
    }
}

/// Keys of the session side panel that hosts the viewer while the rail does not.
enum SessionSidePanel {
    static let shownKey = "session.sidePanel.shown"
}
