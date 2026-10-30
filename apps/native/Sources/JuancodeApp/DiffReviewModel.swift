import Foundation
import Observation
import JuancodeCore
import JuancodeClient
import JuancodeDesktop

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

    /// A pull request under review instead of a session: its diff is the PR's net
    /// diff against the branch it merges into (`gh pr diff`), and the review goes to
    /// the agent session tracking it.
    struct PrTarget: Equatable {
        var cwd: String
        var pr: PullRequest
    }

    private(set) var snapshots: [String: Snapshot] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var loading: Set<String> = []
    private(set) var sending: Set<String> = []
    private(set) var comments: [String: [ReviewComment]] = [:] {
        didSet { persistDrafts() }
    }
    var notices: [String: Notice] = [:]
    private var bases: [String: ReviewBase] = [:] { didSet { persistDrafts() } }
    private var prTargets: [String: PrTarget] = [:] { didSet { persistDrafts() } }
    /// Explicit recipients are per PR and survive closing the panel with its notes.
    private(set) var agentSessionIds: [String: String] = [:] { didSet { persistDrafts() } }
    private let draftStore = ReviewDraftStore()
    private var canPersistDrafts = true
    private(set) var persistenceError: String?

    init() {
        do {
            let saved = try draftStore.load()
            comments = saved.mapValues(\.comments)
            bases = saved.mapValues(\.base)
            agentSessionIds = saved.compactMapValues(\.agentSessionId)
            prTargets = saved.compactMapValues { draft in
                guard let cwd = draft.cwd, let pr = draft.pr else { return nil }
                return PrTarget(cwd: cwd, pr: pr)
            }
        } catch {
            canPersistDrafts = false // Preserve unreadable saved work for recovery.
            persistenceError = "Saved reviews could not be loaded: \(error.localizedDescription)"
        }
    }

    var wipIds: [String] { comments.keys.filter { !comments($0).isEmpty }.sorted() }

    private func persistDrafts() {
        guard canPersistDrafts else { return }
        let saved = Dictionary(uniqueKeysWithValues: wipIds.map { id in
            (id, SavedReviewDraft(comments: comments(id), base: base(id),
                                  cwd: prTargets[id]?.cwd, pr: prTargets[id]?.pr,
                                  agentSessionId: agentSessionIds[id]))
        })
        do {
            try draftStore.save(saved)
            persistenceError = nil
        } catch {
            persistenceError = "Review notes could not be saved: \(error.localizedDescription)"
        }
    }
    @ObservationIgnored fileprivate var watchTokens: [String: WorktreeWatchToken] = [:]
    @ObservationIgnored fileprivate var inFlight: Set<String> = []
    /// A reload asked for while one was in flight, run when it lands.
    @ObservationIgnored fileprivate var reloadQueued: Set<String> = []

    func base(_ id: String) -> ReviewBase { bases[id] ?? .head }
    func snapshot(_ id: String) -> Snapshot? { snapshots[id] }
    func comments(_ id: String) -> [ReviewComment] { comments[id] ?? [] }
    func prTarget(_ id: String) -> PrTarget? { prTargets[id] }

    func chooseAgent(_ sessionId: String?, for id: String) {
        agentSessionIds[id] = sessionId
        notices[id] = nil
    }

    /// The review id a PR's comments and diff live under — distinct from every
    /// session id, and from the GitHub view's own basket key for the PR.
    static func prReviewId(cwd: String, number: Int) -> String {
        "pr:" + TrackedPr.key(cwd: cwd, number: number)
    }

    func add(_ comment: ReviewComment, to id: String) {
        comments[id, default: []].append(comment)
    }

    func edit(_ commentId: String, text: String, in id: String) {
        guard let i = comments[id]?.firstIndex(where: { $0.id == commentId }) else { return }
        comments[id]?[i].text = text
    }

    /// Move a staged comment between the agent and GitHub.
    func setForGitHub(_ on: Bool, _ commentId: String, in id: String) {
        guard let i = comments[id]?.firstIndex(where: { $0.id == commentId }) else { return }
        comments[id]?[i].forGitHub = on ? true : nil
    }

    func delete(_ commentId: String, in id: String) {
        comments[id]?.removeAll { $0.id == commentId }
    }

    func say(_ text: String, isError: Bool = false, in id: String) {
        notices[id] = Notice(text: text, isError: isError)
    }

    fileprivate func setPrTarget(_ target: PrTarget, for id: String) { prTargets[id] = target }
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
        diffReviewPrId = nil
        showingDiffReview = true
        loadDiffReview(id)
        diffReviewFocusToken &+= 1
    }

    /// Open the review over a pull request: the PR's diff against its base branch,
    /// with the same keys and comments as a session's, sent to the agent tracking it.
    func openPrDiffReview(_ pr: PullRequest, cwd: String) {
        let id = DiffReviewModel.prReviewId(cwd: cwd, number: pr.number)
        diffReview.setPrTarget(.init(cwd: cwd, pr: pr), for: id)
        diffReviewPrId = id
        showingDiffReview = true
        loadDiffReview(id)
        diffReviewFocusToken &+= 1
    }

    /// Close the review and hand the keyboard back to the session's terminal — or,
    /// for a PR review, back to the GitHub view it was opened from. Staged comments
    /// stay for next time.
    func closeDiffReview() {
        guard showingDiffReview else { return }
        // A PR reviewed by URL was not opened from the GitHub view, so there is no
        // detail there to go back to.
        let fromPr = diffReviewPrId.flatMap { diffReview.prTarget($0) }
            .map { !PrAddress.isRemote(cwd: $0.cwd) } ?? false
        showingDiffReview = false
        for id in Array(diffReview.watchTokens.keys) { stopWatchingDiffReview(id) }
        if fromPr { showingGitHub = true } else { focusTerminal() }
    }

    /// ⌘⇧D: over a PR's detail in the GitHub view it reviews that PR, anywhere else
    /// the session the window shows.
    func toggleDiffReview() {
        if showingDiffReview {
            closeDiffReview()
        } else if showingGitHub, let (cwd, pr) = selectedGitHubPr {
            openPrDiffReview(pr, cwd: cwd)
        } else {
            openDiffReview()
        }
    }

    /// The tracked PR at `url`, whichever checkout tracks it.
    func trackedPr(url: String) -> TrackedPr? {
        tracked.values.first { $0.url.caseInsensitiveCompare(url) == .orderedSame }
    }

    /// The review the panel shows: the open PR's, else the session's.
    var diffReviewTargetId: String? { diffReviewPrId ?? selection }

    var diffReviewAgentSessions: [SessionMeta] {
        sessions.filter { $0.kind == .agent && !$0.archived && !isExternal($0.id) }
    }

    func reopenDiffReview(_ id: String) {
        if let target = diffReview.prTarget(id) {
            openPrDiffReview(target.pr, cwd: target.cwd)
        } else if sessions.contains(where: { $0.id == id }) {
            selectSidebarSession(id)
            openDiffReview()
        } else {
            errorMessage = "This review's session is no longer available. Its notes are still saved."
        }
    }

    func prReviewDelivery(_ id: String) -> PrReviewDelivery {
        guard let target = diffReview.prTarget(id) else { return .chooseSession }
        // Keep an invalid explicit choice visible rather than silently rerouting its notes.
        let tracked = PrAddress.isRemote(cwd: target.cwd)
            ? trackedPr(url: target.pr.url)
            : trackedPr(cwd: target.cwd, number: target.pr.number)
        return .resolve(cwd: target.cwd, chosenSessionId: diffReview.agentSessionIds[id],
                        trackedSessionId: tracked?.sessionId)
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
        if let target = review.prTarget(id) {
            // The PR's inline threads, drawn under their lines, are the GitHub view's
            // conversation — the same cache, refreshed with the diff.
            github.loadDetail(cwd: target.cwd, pr: target.pr)
            Task {
                var snapshot: DiffReviewModel.Snapshot?
                var failure: String?
                if let reads = core.github {
                    do {
                        let d = try await reads.prDiff(cwd: target.cwd, number: target.pr.number)
                        snapshot = .init(base: wanted, label: "PR #\(target.pr.number) vs its base branch",
                                         files: d.files, git: d.git)
                    } catch let e as GitHubError {
                        failure = e.message
                    } catch {
                        failure = error.localizedDescription
                    }
                } else {
                    failure = core.unavailableReason(.github) ?? "This core cannot read a PR's diff."
                }
                review.inFlight.remove(id)
                review.setLoading(false, id)
                review.store(snapshot, error: failure, for: id)
                if review.reloadQueued.remove(id) != nil { loadDiffReview(id) }
            }
            return
        }
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
        if let target = review.prTarget(id) {
            sendPrDiffReview(id, target: target, staged: staged)
            return
        }
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
                    // Hand the window back to the agent so its answer is in view. Only
                    // if the review still shows this session: a switch meanwhile wins.
                    if self.selection == id { self.closeDiffReview() }
                case .rejected(let reason), .aborted(let reason):
                    review.say("Review not sent: \(reason). Your comments are kept.", isError: true, in: id)
                }
            }
        }
    }

    /// A PR review is queued on the explicitly chosen agent, the PR's tracker, or
    /// a new tracker when a local checkout is available. Comments are cleared only
    /// once the queue write is confirmed.
    ///
    /// Comments staged with `r` go to GitHub instead, first, as one COMMENT review; the
    /// rest then go to the agent. A GitHub failure stops there with everything kept.
    private func sendPrDiffReview(_ id: String, target: DiffReviewModel.PrTarget,
                                  staged: [ReviewComment]) {
        let review = diffReview
        let pr = target.pr
        let toGitHub = staged.filter(\.isForGitHub)
        let toAgent = staged.filter { !$0.isForGitHub }
        review.setSending(true, id)
        Task {
            if !toGitHub.isEmpty {
                let n = toGitHub.count
                review.say("Posting \(n) review comment\(n == 1 ? "" : "s") on GitHub…", in: id)
                guard let reads = core.github else {
                    review.setSending(false, id)
                    review.say(core.unavailableReason(.github) ?? "This core cannot write to GitHub.",
                               isError: true, in: id)
                    return
                }
                do {
                    try await reads.submitReview(cwd: target.cwd, number: pr.number,
                                                 comments: toGitHub.compactMap(githubReviewComment))
                } catch {
                    review.setSending(false, id)
                    let text = (error as? GitHubError)?.message ?? error.localizedDescription
                    review.say("GitHub review not posted: \(text). Your comments are kept.",
                               isError: true, in: id)
                    return
                }
                review.removeSent(Set(toGitHub.map(\.id)), from: id)
                // They come back as threads under their lines.
                github.loadDetail(cwd: target.cwd, pr: pr)
                review.say("Posted \(n) review comment\(n == 1 ? "" : "s") on GitHub", in: id)
            }
            guard !toAgent.isEmpty else {
                review.setSending(false, id)
                return
            }
            await queueAgentReview(id, target: target, staged: toAgent)
        }
    }

    private func queueAgentReview(_ id: String, target: DiffReviewModel.PrTarget,
                                  staged: [ReviewComment]) async {
        let review = diffReview
        let pr = target.pr
        let label = review.snapshot(id)?.label ?? "PR #\(pr.number)"
        let prompt = diffReviewPrompt(number: pr.number, url: pr.url,
                                      feedback: formatReview(staged, baseLabel: label))
        let sent = Set(staged.map(\.id))
        let delivery = prReviewDelivery(id)
        if delivery == .chooseSession {
            review.setSending(false, id)
            review.say("Choose an agent session from the Agent menu, then send again. Your comments are kept.",
                       isError: true, in: id)
            return
        }
        review.say(delivery == .trackLocal
                   ? "Tracking PR #\(pr.number) and queueing \(sent.count) comment\(sent.count == 1 ? "" : "s")…"
                   : "Queueing \(sent.count) comment\(sent.count == 1 ? "" : "s")…", in: id)
        let ok: Bool
        switch delivery {
        case .session(let sessionId):
            guard diffReviewAgentSessions.contains(where: { $0.id == sessionId }) else {
                review.setSending(false, id)
                review.say("That agent session is unavailable. Choose another from the Agent menu. Your comments are kept.",
                           isError: true, in: id)
                return
            }
            ok = await queuePrompt(sessionId: sessionId, text: prompt)
        case .trackLocal:
            ok = await trackPrAndQueue(pr, cwd: target.cwd, prompt: prompt)
        case .chooseSession:
            return
        }
        review.setSending(false, id)
        guard ok else {
            review.say("Review not sent for PR #\(pr.number). Your comments are kept.",
                       isError: true, in: id)
            return
        }
        review.removeSent(sent, from: id)
        review.say("Queued \(sent.count) comment\(sent.count == 1 ? "" : "s") on the agent session",
                   in: id)
        if diffReviewPrId == id { closeDiffReview() }
    }
}
