import Foundation
import JuancodeCore

/// The global pause a launch on the Rust core performs when no desktop is attached.
///
/// The twin of `RegistryGlobalPause`, and it exists for the same reason: a headless
/// `juancode-serve --core rust` is exactly the launch a phone talks to when nobody
/// is at the Mac, which is the moment you want to pause everything. Sleeping goes
/// through `markDormant`, so it is the `sleepSession` frame the first half of
/// juancode-nizo added and not a plain kill; waking is `resume`, which is
/// `reactivate` on the wire.
///
/// The desktop replaces this at startup with the model's own pause, so with the app
/// up a pause from the phone runs the toolbar button's code.
final class RemoteGlobalPause: GlobalPauseDriver, @unchecked Sendable {
    private unowned let core: RustCoreClient
    private let book: GlobalPauseBook

    init(core: RustCoreClient, book: GlobalPauseBook) {
        self.core = core
        self.book = book
    }

    @discardableResult
    func pauseAll() async -> Int {
        let targets = GlobalPause.targets(candidates())
        guard !targets.isEmpty else { return 0 }
        // Recorded before a single pty dies, for the reason spelled out in
        // `RegistryGlobalPause`: a session killed before the record landed is one
        // nothing remembers pausing.
        book.record(targets)
        for id in targets {
            core.liveSession(id)?.markDormant(reason: .manual, audit: ["path": "globalPause"])
        }
        return targets.count
    }

    func resumeAll() async {
        let recorded = book.take()
        let ordered = GlobalPause.revivals(paused: recorded, present: candidates(), focus: nil)
        guard !ordered.isEmpty else { return }
        // One at a time, unlike the desktop's play, which spreads its revivals over
        // `GlobalResume.lanes`. Nothing would be gained by lanes here: every
        // `resume` on this core takes the client's lifecycle gate (the daemon answers
        // a create/reactivate with an uncorrelated `created` + `attached` pair, so
        // exactly one may be in flight), and it is a BLOCKING call — four of them on
        // task-group threads would queue on that lock while holding four threads of
        // the cooperative pool.
        for id in ordered {
            if let meta = core.session(id) {
                // Prior scrollback comes from the mirror: the daemon reprints its own
                // on resume, and an empty one here would blank a pane that is watching.
                _ = try? core.resume(meta, cols: Self.grid.cols, rows: Self.grid.rows,
                                     priorScrollback: core.storedScrollback(id) ?? [])
            }
            await Nap.ms(GlobalResume.gapMs)
        }
    }

    /// The grid a revival with no viewport boots at. Same default `RustCoreClient`
    /// uses for its own discovery attaches, so a pause/play round trip cannot narrow
    /// a session's transcript.
    private static let grid = (cols: 120, rows: 40)

    private func candidates() -> [GlobalPause.Candidate] {
        let live = Set(core.liveSessions().map(\.id))
        return core.sessions().map { meta in
            .init(id: meta.id, isLive: live.contains(meta.id), isAgent: meta.kind != .editor)
        }
    }
}
