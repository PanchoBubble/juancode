import JuancodeCore
import SwiftUI

/// Shared status colors and descriptions for sidebar and Oracle session rows.
enum SessionStatusAppearance {
    static func color(live: Bool, activity: SessionActivity?, unread: Bool,
                      unseenDone: Bool, activating: Bool = false) -> Color {
        if activating { return .accentColor }
        if showsDone(live: live, activity: activity, unseenDone: unseenDone) { return .green }
        if unread { return .red }
        return sessionDotColor(live: live, activity: activity)
    }

    static func help(live: Bool, activity: SessionActivity?, unread: Bool,
                     unseenDone: Bool, activating: Bool = false) -> String {
        if activating { return "Resuming session…" }
        if showsDone(live: live, activity: activity, unseenDone: unseenDone) {
            return "Finished since you last looked — click to view"
        }
        let status: String
        if !live {
            status = "Session has exited"
        } else {
            switch activity {
            case .busy: status = "Agent is working"
            case .waitingInput: status = "Waiting for your reply"
            case .idle, .none: status = "Agent is running"
            }
        }
        return unread ? "\(status) — unread" : status
    }

    private static func showsDone(live: Bool, activity: SessionActivity?, unseenDone: Bool) -> Bool {
        live && activity != .busy && activity != .waitingInput && unseenDone
    }
}
