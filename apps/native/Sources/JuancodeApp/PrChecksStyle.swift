// One vocabulary for a PR's CI state, shared by every row that draws it.
//
// The dot, the glyph and the "4/11" were copied into each PR row as it was written
// — the folder row, the queue row, the session capsule — so a fourth row could have
// invented a fourth green. There is one mapping now, and rows differ only in size.

import SwiftUI
import JuancodeCore

extension PrChecks {
    /// The colour the dot, glyph and fraction all paint in.
    var color: Color {
        switch self {
        case .passing: return .green
        case .failing: return .red
        case .pending: return .orange
        case .none: return .secondary
        }
    }

    /// Status-adaptive glyph paired with the fraction; colour comes from `color`.
    var icon: String {
        switch self {
        case .passing: return "checkmark.circle.fill"
        case .failing: return "xmark.circle.fill"
        case .pending: return "clock.fill"
        case .none: return "minus.circle"
        }
    }
}

extension PullRequest {
    /// The check summary shown in a row: "passed/total" (e.g. "4/11"), or "No
    /// checks" when there are none.
    var checksText: String {
        checkCount == 0 ? "No checks" : "\(passedCount)/\(checkCount)"
    }
}
