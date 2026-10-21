import Foundation
import Observation
import JuancodeCore
import JuancodeClient

/// State behind the full-width diff-review panel (juancode-a5j), per session: which
/// base it diffs against, the diff it last loaded, the comments staged on it, and the
/// last thing it has to tell the user. Comments live here rather than in the panel's
/// view state so they survive the panel closing, a session switch, and every refresh.
///
/// Separate from the Changes panel's `DiffComment` basket on purpose: these carry the
/// plugin's labels and excerpt (`ReviewComment`) and are sent with its `formatReview`,
/// straight into the prompt, not through the message queue.
@MainActor
@Observable
final class DiffReviewModel {
    struct Snapshot: Equatable {
        var base: ReviewBase
        /// What the review message calls this diff: "working tree vs HEAD", …
        var label: String
        var files: [DiffFile]
        /// False when the session's cwd is not in a git repo.
        var git: Bool
    }

    struct Notice: Equatable {
        var text: String
        var isError: Bool
    }

    private(set) var snapshots: [String: Snapshot] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var loading: Set<String> = []
    private(set) var sending: Set<String> = []
    private(set) var comments: [String: [ReviewComment]] = [:]
    var notices: [String: Notice] = [:]
    private var bases: [String: ReviewBase] = [:]
    @ObservationIgnored fileprivate var watchTokens: [String: WorktreeWatchToken] = [:]
    @ObservationIgnored fileprivate var inFlight: Set<String> = []
    /// A reload asked for while one was in flight, run when it lands.
    @ObservationIgnored fileprivate var reloadQueued: Set<String> = []

    func base(_ id: String) -> ReviewBase { bases[id] ?? .head }
    func snapshot(_ id: String) -> Snapshot? { snapshots[id] }
    func comments(_ id: String) -> [ReviewComment] { comments[id] ?? [] }

    func add(_ comment: ReviewComment, to id: String) {
        comments[id, default: []].append(comment)
    }

    func edit(_ commentId: String, text: String, in id: String) {
        guard let i = comments[id]?.firstIndex(where: { $0.id == commentId }) else { return }
        comments[id]?[i].text = text
    }

    func delete(_ commentId: String, in id: String) {
        comments[id]?.removeAll { $0.id == commentId }
    }

    func say(_ text: String, isError: Bool = false, in id: String) {
        notices[id] = Notice(text: text, isError: isError)
    }

    fileprivate func setBase(_ base: ReviewBase, for id: String) { bases[id] = base }
    fileprivate func setLoading(_ on: Bool, _ id: String) {
        if on { loading.insert(id) } else { loading.remove(id) }
    }
    fileprivate func setSending(_ on: Bool, _ id: String) {
        if on { sending.insert(id) } else { sending.remove(id) }
    }
    fileprivate func store(_ snapshot: Snapshot?, error: String?, for id: String) {
        if let snapshot { snapshots[id] = snapshot }
        errors[id] = error
    }
    fileprivate func clearSnapshot(_ id: String) { snapshots[id] = nil }
    fileprivate func removeSent(_ ids: Set<String>, from id: String) {
        comments[id]?.removeAll { ids.contains($0.id) }
    }
}

extension AppModel {

    // MARK: - Open / close

    /// Open the review over the session the window shows, loading its diff and
    /// following edits to it while open.
    func openDiffReview() {
        guard let id = selection else { return }
        showingDiffReview = true
        loadDiffReview(id)
        diffReviewFocusToken &+= 1
    }

    /// Close the review and hand the keyboard back to the session's terminal. Staged
    /// comments stay for next time.
    func closeDiffReview() {
        guard showingDiffReview else { return }
        showingDiffReview = false
        for id in Array(diffReview.watchTokens.keys) { stopWatchingDiffReview(id) }
        focusTerminal()
    }

    func toggleDiffReview() {
        if showingDiffReview { closeDiffReview() } else { openDiffReview() }
    }

    // MARK: - Loading

    /// Load (or reload) a session's review diff against `base` (default: its current
    /// one). A base change drops the old snapshot so the panel never shows one base's
    /// files under another's label; a plain reload keeps it on screen meanwhile.
    func loadDiffReview(_ id: String, base: ReviewBase? = nil) {
        let review = diffReview
        if let base, base != review.base(id) {
            review.setBase(base, for: id)
            review.clearSnapshot(id)
        }
        if review.inFlight.contains(id) {
            review.reloadQueued.insert(id)
            return
        }
        if let reason = core.unavailableReason(.changes) {
            review.store(nil, error: reason, for: id)
            return
        }
        let wanted = review.base(id)
        review.inFlight.insert(id)
        review.setLoading(true, id)
        Task {
            await resolveAgentWorktree(id)
            var snapshot: DiffReviewModel.Snapshot?
            var failure: String?
            if let cwd = gitCwd(of: id) {
                do {
                    snapshot = try await fetchReviewDiff(cwd: cwd, base: wanted)
                } catch {
                    failure = reviewLoadError(error, base: wanted)
                }
                startWatchingDiffReview(id, cwd: cwd)
            } else {
                failure = "This session has no working directory to diff."
            }
            review.inFlight.remove(id)
            review.setLoading(false, id)
            // The base moved while this was in flight: its answer is for the old one.
            if review.base(id) == wanted { review.store(snapshot, error: failure, for: id) }
            if review.reloadQueued.remove(id) != nil { loadDiffReview(id) }
        }
    }

    private func fetchReviewDiff(cwd: String, base: ReviewBase) async throws -> DiffReviewModel.Snapshot {
        switch base {
        case .head:
            let d = try await core.diff(cwd: cwd)
            return .init(base: base, label: base.label(), files: d.files, git: d.git)
        case .staged:
            let d = try await core.stagedDiff(cwd: cwd)
            return .init(base: base, label: base.label(), files: d.files, git: d.git)
        case .main:
            do {
                let d = try await core.baseDiff(cwd: cwd, base: nil)
                return .init(base: base, label: base.label(ref: d.base), files: d.result.files,
                             git: d.result.git)
            } catch let error where error.localizedDescription.contains("No base branch") {
                // No main branch to find: the working tree vs HEAD, labelled as such —
                // what the plugin does.
                let d = try await core.diff(cwd: cwd)
                return .init(base: base, label: base.label(ref: nil), files: d.files, git: d.git)
            }
        }
    }

    private func reviewLoadError(_ error: Error, base: ReviewBase) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        if base == .staged, text.contains("404") {
            return "This juancoded predates staged diffs — `pnpm daemon:upgrade` restarts it on the current build."
        }
        return text
    }

    // MARK: - Live refresh

    /// Re-diff when the session's tree changes, while the panel is open. Shares the
    /// Changes panel's FSEvents streams (one per tree).
    private func startWatchingDiffReview(_ id: String, cwd: String) {
        guard showingDiffReview, diffReview.watchTokens[id] == nil else { return }
        let token = worktreeWatchers.watch(path: cwd) { [weak self] in
            Task { @MainActor in
                guard let self, self.showingDiffReview else { return }
                self.loadDiffReview(id)
            }
        }
        if let token { diffReview.watchTokens[id] = token }
    }

    private func stopWatchingDiffReview(_ id: String) {
        diffReview.watchTokens.removeValue(forKey: id)?.cancel()
    }

    // MARK: - Sending

    /// Send every staged comment as one review message into the session's prompt —
    /// a bracketed paste and a separate Enter, so the multi-line message lands whole
    /// before it submits. The comments are cleared only once the paste is delivered;
    /// a refusal keeps them and says why.
    func sendDiffReview(_ id: String) {
        let review = diffReview
        let staged = review.comments(id)
        guard !staged.isEmpty else {
            review.say("No comments yet: gcc on a line, or V then gc", isError: true, in: id)
            return
        }
        guard !review.sending.contains(id) else { return }
        guard let session = liveSession(id), session.isRunning else {
            review.say("Session isn't running — start it to send the review. Your comments are kept.",
                       isError: true, in: id)
            return
        }
        let label = review.snapshot(id)?.label ?? review.base(id).label()
        let text = formatReview(staged, baseLabel: label)
        let sent = Set(staged.map(\.id))
        review.setSending(true, id)
        review.say("Sending \(staged.count) comment\(staged.count == 1 ? "" : "s")…", in: id)
        session.submit(text) { outcome in
            Task { @MainActor in
                review.setSending(false, id)
                switch outcome {
                case .delivered:
                    // By id: a comment staged while the paste was in flight was not in it.
                    review.removeSent(sent, from: id)
                    review.say("Sent \(sent.count) comment\(sent.count == 1 ? "" : "s") to the session", in: id)
                case .rejected(let reason), .aborted(let reason):
                    review.say("Review not sent: \(reason). Your comments are kept.", isError: true, in: id)
                }
            }
        }
    }
}
