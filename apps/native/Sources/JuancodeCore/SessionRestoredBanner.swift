import Foundation

/// Banner state machine for a pane restored from persisted scrollback after an app
/// restart (juancode-mya).
///
/// On a cold launch the pty registry is empty, so opening a persisted session paints
/// its replayed scrollback and then auto-revives via `AppModel.reactivate` — either
/// resuming the prior CLI conversation or, if it can't, degrading to a replay-only
/// view. Either way the pane can look frozen: a wall of old output with no cursor
/// moving. This banner makes that self-explaining, distinguishing:
///
///   (a) `.resuming`    — the resume-spawn is booting; live output is imminent. It
///                        auto-dismisses on the first LIVE (non-replay) pty byte or
///                        after a short grace, so it never lingers over a live TUI.
///   (b) `.unresumable` — the prior conversation couldn't be resumed (no CLI session
///                        id, spawn failed, or the resume died fast). The pane stays
///                        replay-only, so this one only clears when the user dismisses
///                        it with the X.
///
/// The decisions live here (pure, testable); the SwiftUI overlay is a thin renderer
/// (`SessionRestoredOverlay`), keyed per session id by `AppModel.restoredBanners` so
/// switching sessions never leaks one pane's banner onto another.
public enum SessionRestoredBanner {
    /// What the banner is telling the user; the absence of a phase means hidden.
    public enum Phase: Equatable, Sendable {
        /// (a) resume-spawn booting after a disk restore.
        case resuming
        /// (b) replay-only; the prior CLI conversation couldn't be resumed.
        case unresumable
    }

    /// Inputs that move a session's banner between phases.
    public enum Event: Equatable, Sendable {
        /// A disk-restore was opened and its auto-revive is booting.
        case restoreBegan
        /// The auto-revive couldn't resume the prior conversation (replay-only).
        case resumeFailed
        /// The first LIVE (non-replay) pty byte arrived after a successful resume.
        case liveOutput
        /// The post-resume grace window elapsed with no live output.
        case graceElapsed
        /// The user tapped the banner's dismiss control.
        case dismissed
    }

    /// Next banner phase given the current one (nil = hidden) and an event.
    ///
    /// Only a fresh `restoreBegan` can turn a hidden banner on; every other event
    /// merely settles or clears an already-showing one. That keeps a late, stale
    /// signal (a resume result that lands after the user already dismissed, or live
    /// output on a pane that was never restored) from resurrecting the banner.
    public static func reduce(_ phase: Phase?, on event: Event) -> Phase? {
        switch event {
        case .restoreBegan:
            return .resuming
        case .resumeFailed:
            // Only a booting restore degrades to unresumable — a failure that lands
            // after a manual dismiss stays hidden.
            return phase == .resuming ? .unresumable : phase
        case .liveOutput, .graceElapsed:
            // The resume produced life (or ran out its grace): the pane is no longer
            // frozen, so drop the "resuming" banner. The replay-only `.unresumable`
            // case has no live pty, so these never touch it.
            return phase == .resuming ? nil : phase
        case .dismissed:
            return nil
        }
    }

    /// Headline copy for a phase.
    public static func title(for phase: Phase) -> String {
        switch phase {
        case .resuming: return "Restored — resuming conversation"
        case .unresumable: return "Restored from disk — agent exited; couldn't resume"
        }
    }

    /// How long the `.resuming` banner lingers before self-dismissing when no live
    /// output arrives — long enough to cover a resumed-but-idle agent, short enough
    /// that it never sits over a working TUI. Paired with the `confirmResumeSucceeded`
    /// grace so a banner can't outlast the resume it describes.
    public static let resumeGraceSeconds: Double = 6
}
