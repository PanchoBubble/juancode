import Foundation
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
        guard let session = appState.registry.get(id), session.isRunning else { return }
        session.markDormant()
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
            return appState.registry.get(meta.id)?.activity == .idle
        }
        for meta in targets { sleepSession(meta.id) }
        return targets.count
    }
}
