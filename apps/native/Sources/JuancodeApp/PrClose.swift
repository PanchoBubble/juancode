import JuancodeClient
import JuancodeCore
import SwiftUI

extension AppModel {
    /// Close a PR on GitHub and delete its branch there. The local branch and any
    /// worktree on it are left alone (the core passes `--repo`, which stops gh from
    /// switching a checkout off the branch). A watching agent has nothing left to
    /// watch, so a tracked PR is untracked too.
    func closePr(_ pr: PullRequest, cwd: String?) {
        guard let reads = core.github else {
            errorMessage = "Can't close the PR. \(core.unavailableReason(.github) ?? "")"
            return
        }
        // Optimistic: the row goes on confirm, and comes back if GitHub refuses.
        let removed = forgetViewerPr(url: pr.url)
        let localIndex = cwd.flatMap { prsByCwd[$0]?.prs.firstIndex { $0.url == pr.url } }
        if let cwd { prsByCwd[cwd]?.prs.removeAll { $0.url == pr.url } }
        Task {
            do {
                try await reads.closePr(url: pr.url)
            } catch {
                let reason = (error as? GitHubError)?.message ?? error.localizedDescription
                errorMessage = "Couldn't close #\(pr.number): \(reason)"
                restoreViewerPr(url: pr.url, removed)
                if let cwd, let localIndex, var list = prsByCwd[cwd],
                   !list.prs.contains(where: { $0.url == pr.url }) {
                    list.prs.insert(pr, at: min(localIndex, list.prs.count))
                    prsByCwd[cwd] = list
                }
                return
            }
            if let cwd {
                if let t = trackedPr(cwd: cwd, number: pr.number) { untrackPr(t.id) }
                loadPrs(cwd)
            }
            refreshViewerPrs(force: true)
        }
    }
}

/// The context-menu item that asks before closing. Closing is outward-facing and
/// deletes a branch on GitHub, so it never happens on one click.
struct ClosePrMenuItem: View {
    @Binding var confirming: Bool

    var body: some View {
        Divider()
        Button("Close PR and Delete Branch…", role: .destructive) { confirming = true }
    }
}

extension View {
    /// The confirmation behind `ClosePrMenuItem`, naming the PR and the branch that goes.
    func closePrConfirmation(_ confirming: Binding<Bool>, pr: PullRequest,
                             cwd: String?, model: AppModel) -> some View {
        confirmationDialog(
            Text(verbatim: "Close #\(pr.number) and delete its branch?"),
            isPresented: confirming,
            titleVisibility: .visible
        ) {
            Button("Close and Delete Branch", role: .destructive) {
                model.closePr(pr, cwd: cwd)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: "\(pr.title)\n\nThe branch \(pr.branch) is deleted on GitHub. Your local branch and any worktree on it stay.")
        }
    }
}
