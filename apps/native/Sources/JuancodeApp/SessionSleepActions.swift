import Foundation
import JuancodeClient
import JuancodeCore

/// Sleeping a session on demand: kill the CLI process tree to free its RAM while
/// keeping the row, its scrollback and its resume id, so selecting it brings the
/// conversation back. This is what the idle `SessionReaper` does on a timer —
/// exposed here so a machine under memory pressure doesn't have to wait out an
/// idle window (or hunt sessions down and kill them, which loses the dormant flag
/// the sidebar reads to tell "asleep" from "died").
///
/// Lives in its own file rather than in `AppModel` proper: it is a self-contained
/// action pair, and keeping it separate keeps the 4000-line model from growing
/// another section.
extension AppModel {
    /// Put one session to sleep. No-op when it isn't live.
    func sleepSession(_ id: String) {
        guard let session = core.liveSession(id), session.isRunning else { return }
        session.markDormant(reason: .manual, audit: [:])
        killSession(id)
    }

    /// Sleep every idle session in `cwd`'s project — the "I need my RAM back now"
    /// button. Busy sessions, the selected one, and anything waiting on input are
    /// left alone; `nil` sweeps every project.
    @discardableResult
    func sleepIdleSessions(inProject cwd: String? = nil) -> Int {
        let targets = sessions.filter { meta in
            guard cwd == nil || meta.cwd == cwd else { return false }
            guard meta.id != selection, isLive(meta.id) else { return false }
            return core.liveSession(meta.id)?.activity == .idle
        }
        for meta in targets { sleepSession(meta.id) }
        return targets.count
    }
}

// MARK: - Global pause / play

/// Pausing everything at once: the toolbar's pause button sleeps every live agent,
/// and play brings back exactly that set.
///
/// Built on `sleepSession` rather than freezing the processes, so the RAM comes
/// back — the reason to hit pause is usually that the Mac is under pressure or you
/// are walking away, and a frozen CLI still holds its ~300MB. The trade is that an
/// in-flight turn is lost: play runs `--resume`, which reloads the conversation
/// rather than continuing mid-thought.
extension AppModel {
    /// Sleep every live agent session and remember the set for play.
    ///
    /// Editor panes are left alone (nothing to resume — see `GlobalPause.Candidate`),
    /// and so is anything already asleep, which stays the user's own sleep rather
    /// than becoming the pause's to wake.
    @discardableResult
    func pauseAllSessions() -> Int {
        cancelGlobalResume()
        let targets = GlobalPause.targets(pauseCandidates())
        guard !targets.isEmpty else { return 0 }
        for id in targets { sleepSession(id) }
        // Union, not assignment: pausing again after a partial play (some rows woken
        // by hand) must not drop the ones still asleep from the set.
        pausedSessionIds.formUnion(targets)
        core.logSessionEvent("globalPause", sessionId: "-", project: "-",
                             fields: ["count": "\(targets.count)"])
        refresh()
        return targets.count
    }

    /// Bring back everything the pause put to sleep, then clear the paused state.
    ///
    /// Revivals run over the same bounded lanes as the launch sweep: each one is a
    /// real CLI process, so firing forty at once is the RAM spike and pty burst that
    /// bound exists to avoid, while a single lane leaves the last row dead a minute in.
    func resumeAllSessions() {
        cancelGlobalResume()
        let ordered = GlobalPause.revivals(paused: pausedSessionIds,
                                           present: pauseCandidates(),
                                           focus: selection)
        // Clear up front: the button must read "paused" for exactly as long as the
        // pause is in effect, and a revival that fails leaves a sleeping row the user
        // can click — not a pause that never lifts.
        pausedSessionIds = []
        guard !ordered.isEmpty else { refresh(); return }
        core.logSessionEvent("globalResume", sessionId: "-", project: "-",
                             fields: ["count": "\(ordered.count)"])
        globalResumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Unstructured tasks rather than a task group: a group child can't be
            // expressed as `@MainActor` here, the same constraint the launch sweep
            // hits. They are awaited below, so cancelling the parent still lands.
            self.globalResumeLanes = GlobalPause.lanes(ordered, lanes: GlobalResume.lanes).map { lane in
                Task { @MainActor [weak self] in
                    for id in lane {
                        guard !Task.isCancelled, let self else { return }
                        await self.reactivate(id, quiet: true,
                                              settleMs: AppModel.ResumeGrace.settleMs)
                        await Nap.ms(GlobalResume.gapMs)
                    }
                }
            }
            for lane in self.globalResumeLanes { await lane.value }
            self.globalResumeLanes = []
            self.refresh()
        }
    }

    /// Pause if anything is running, play if a pause is in effect — the single
    /// toolbar button.
    func toggleGlobalPause() {
        if isGloballyPaused { resumeAllSessions() } else { pauseAllSessions() }
    }

    /// Stop a play that is still working through its lanes, so a pause landing
    /// mid-play doesn't race half-spawned ptys back to life.
    func cancelGlobalResume() {
        globalResumeTask?.cancel()
        globalResumeTask = nil
        for lane in globalResumeLanes { lane.cancel() }
        globalResumeLanes = []
    }

    /// Every sidebar session as the pause planner sees it. External (adopted) rows
    /// are excluded: their pty belongs to a terminal we don't own, so sleeping one
    /// kills a process the user started elsewhere.
    private func pauseCandidates() -> [GlobalPause.Candidate] {
        sessions.filter { !isExternal($0.id) }.map { meta in
            .init(id: meta.id, isLive: isLive(meta.id), isAgent: !isEditorSession(meta.id))
        }
    }

    /// How many sessions a play would bring back right now — the button's badge.
    var pausedSessionCount: Int { pausedSessionIds.count }
}

/// Lane bounds for a global play. Same shape and the same reason as the launch
/// sweep's `LaunchRevive`: a play after pausing forty sessions is the same forty
/// `--resume` processes the launch sweep spreads out.
private enum GlobalResume {
    static let lanes = 4
    static let gapMs = 150
}
