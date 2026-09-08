import Foundation
import JuancodeCore
import JuancodeServices

/// The global pause a core performs on its own, over its session registry.
///
/// Installed by `AppState` so a core answers `pauseAll`/`resumeAll` with no desktop
/// attached — which is the whole point of the frames: the reason to pause everything
/// is that you are walking away from the Mac, and a headless `juancode-serve` is
/// exactly the launch a phone is talking to when nobody is at the desk.
///
/// The desktop replaces it at startup (`GlobalPauseBook.driver`) with the model's own
/// pause, so with the app up a pause from the phone runs the toolbar button's code
/// rather than a second implementation of the same rule. The two agree because both
/// plan with `GlobalPause`; this one differs only in what it cannot see — the
/// sidebar's not-yet-adopted external rows, which are not in the registry anyway.
final class RegistryGlobalPause: GlobalPauseDriver, @unchecked Sendable {
    private let registry: SessionRegistry
    private let store: PersistentStore
    private let book: GlobalPauseBook
    private let log: SessionActivityLogging

    init(registry: SessionRegistry, store: PersistentStore, book: GlobalPauseBook,
         log: SessionActivityLogging) {
        self.registry = registry
        self.store = store
        self.book = book
        self.log = log
    }

    @discardableResult
    func pauseAll() async -> Int {
        let targets = GlobalPause.targets(candidates())
        guard !targets.isEmpty else { return 0 }
        // The set is recorded BEFORE a single pty dies, which is the same ordering
        // rule the first half of this ticket established for the dormant flag and it
        // is load-bearing for the same reason: a process that died before the record
        // landed is a killed session nothing remembers pausing. It also means a
        // client sees `pauseState` and then the exits, rather than the two racing.
        // Recording an id whose sleep then fails is harmless - a play skips anything
        // still live.
        book.record(targets)
        log.log("globalPause", sessionId: "-", project: "-", fields: ["count": "\(targets.count)"])
        for id in targets {
            guard let session = registry.get(id), session.isRunning else { continue }
            // And the flag before the kill, so the row `handleExit` finalises reads
            // "asleep" rather than "died".
            session.markDormant(reason: .manual, audit: ["path": "globalPause"])
            session.kill()
        }
        return targets.count
    }

    func resumeAll() async {
        // Read-and-clear before any revival: the button must stop reading "paused"
        // the moment the play starts, and a revival that fails leaves a sleeping row
        // somebody can click rather than a pause that never lifts.
        let recorded = book.take()
        let ordered = GlobalPause.revivals(paused: recorded, present: candidates(), focus: nil)
        guard !ordered.isEmpty else { return }
        log.log("globalResume", sessionId: "-", project: "-", fields: ["count": "\(ordered.count)"])
        await withTaskGroup(of: Void.self) { group in
            for lane in GlobalPause.lanes(ordered, lanes: GlobalResume.lanes) {
                group.addTask { [registry, store, log] in
                    for id in lane {
                        _ = await reviveSession(id, registry: registry, store: store, log: log)
                        await Nap.ms(GlobalResume.gapMs)
                    }
                }
            }
        }
    }

    /// Every row this core knows about as the pause planner sees it.
    ///
    /// The union of live sessions and persisted rows, because a play has to find the
    /// rows a pause left exited — `revivals` filters on `isLive`, and a candidate
    /// list built from the registry alone would be empty exactly when it matters.
    private func candidates() -> [GlobalPause.Candidate] {
        var seen: Set<String> = []
        var out: [GlobalPause.Candidate] = []
        for session in registry.all() {
            seen.insert(session.id)
            out.append(.init(id: session.id, isLive: session.isRunning,
                             isAgent: session.meta.kind != .editor))
        }
        for meta in store.list() where !seen.contains(meta.id) {
            out.append(.init(id: meta.id, isLive: false, isAgent: meta.kind != .editor))
        }
        return out
    }
}
