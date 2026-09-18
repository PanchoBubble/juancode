/// Classifies the sleep a process-exit path is about to impose, from the session's
/// live activity at that moment.
///
/// App quit is the one path that CANNOT honour the reap policy: the ptys are
/// children of this process, so they die with it whatever the agent was doing. The
/// honest fix is therefore not "spare the busy ones" but "record which ones were
/// busy" — a bulk quit-sleep of 25 sessions wrote the same flat `quit` reason for
/// the mid-turn agents and the quiet ones, so an interrupted batch still read
/// identically to a clean one after the fact.
///
/// Lives in the core, not beside a reaper: quitting is a property of the process
/// that owns the ptys, and both callers need the answer off the main actor — the
/// Swift core's graceful shutdown stamps each session, and the app's quit gate asks
/// the same question of the whole batch first. Neither depends on anything that
/// reaps, which is why this outlived the Swift reaper it used to sit next to.
public enum SessionQuitSleep {
    /// The reason to stamp on a session being slept by process exit.
    public static func reason(for activity: SessionActivity) -> SessionSleepReason {
        switch activity {
        case .idle: return .quit
        case .busy: return .quitBusy
        case .waitingInput: return .quitWaitingInput
        }
    }

    /// Whether quitting right now would abort work — the signal the confirm-on-quit
    /// gate needs. True when any session is mid-turn or holding a permission prompt.
    public static func wouldInterruptWork(_ activities: [SessionActivity]) -> Bool {
        activities.contains { reason(for: $0).workInFlight }
    }
}
