import Foundation

/// What a rail tap — or the chat's start/resume CTA — should do to the Oracle chat.
public enum OracleChatAction: Equatable, Sendable {
    /// Already the active chat and already running: nothing to do.
    case none
    /// Point the chat at a live Oracle; no revive needed.
    case focus(String)
    /// Point the chat at an exited Oracle and resume its CLI conversation.
    case revive(String)
    /// Nothing was selected worth reviving, but another Oracle is already up — use it.
    case adopt(String)
    /// No Oracle to continue: spawn a new one.
    case spawnFresh
}

/// Where the Oracle chat should point after a rail tap or a start/resume click.
///
/// Both entry points used to short-circuit on "is this already the active chat?",
/// which conflated *active* with *alive*: an Oracle whose pty had exited while it
/// was the active chat became unrevivable in place. Tapping its row hit the
/// equality guard and returned; the chat's CTA fell through to a generic
/// "ensure an agent" path that adopted whatever other Oracle happened to be
/// running. The only way back into that conversation was to select a different
/// Oracle and then re-select it, which cleared the equality guard.
///
/// Liveness, not identity, is what decides here. The decisions are pure so they
/// can be tested without an app; `OracleModel` is the thin executor.
public enum OracleChatRouting {
    /// A rail tap on `id`, given the currently-active chat and whether `id` is live.
    public static func select(_ id: String, active: String?, isLive: Bool) -> OracleChatAction {
        if isLive { return active == id ? .none : .focus(id) }
        return .revive(id)
    }

    /// The chat's start/resume CTA, which is only offered when the chat has no live
    /// pty. Reviving the Oracle the user is actually looking at wins over adopting a
    /// different live one — otherwise the button silently swaps the conversation out
    /// from under them.
    ///
    /// - `activeIsResumable`: the active id still has a persisted Oracle row to resume.
    /// - `otherLive`: any other already-running Oracle.
    /// - `mostRecent`: the newest persisted Oracle, as the last resort before a spawn.
    public static func start(active: String?, activeIsResumable: Bool,
                             otherLive: String?, mostRecent: String?) -> OracleChatAction {
        if let active, activeIsResumable { return .revive(active) }
        if let otherLive { return .adopt(otherLive) }
        if let mostRecent { return .revive(mostRecent) }
        return .spawnFresh
    }
}
