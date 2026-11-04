// What in the global PR queue wants you, read from facts the app already holds.
//
// The daemon decides each row's `attention` from GitHub (changes requested, red CI,
// open threads, a review you owe). The one ask it cannot see is a tracking agent that
// stopped for you: that lives in the tracked-PR engine's open decisions and in the
// agent session's own activity. This joins the two so every surface showing the queue
// — the toolbar badge, the right rail — counts and filters the same rows.

import JuancodeCore

extension AppModel {
    /// Queue rows (`ViewerPr.id`) whose tracking agent is waiting on you: the engine
    /// holds an open decision for it, or its session sits at a prompt. A tracked PR
    /// whose agent is busy or idle asks nothing.
    var viewerPrDecisionIDs: Set<String> {
        var ids: Set<String> = []
        for row in viewerPrs.rows {
            guard let cwd = folder(forRepo: row.repo),
                  let tracked = trackedPr(cwd: cwd, number: row.pr.number) else { continue }
            if tracked.state == .needsDecision || activity(tracked.sessionId) == .waitingInput {
                ids.insert(row.id)
            }
        }
        return ids
    }

    /// The queue's actionable count beside its quiet total, decisions included.
    var viewerPrQueueTally: ViewerPrTally {
        viewerPrTally(viewerPrs, decisions: viewerPrDecisionIDs)
    }
}
