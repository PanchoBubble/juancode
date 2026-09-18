import Foundation

// Freshness policy for the GitHub view's selected PR (juancode-zp29). The detail
// pane used to fetch a PR's conversation/checks/diff once and keep them for the
// app's lifetime, so a review comment posted while the pane was open only showed
// up after a restart. The pane now ticks and asks this policy whether the data it
// is showing has gone stale.

/// Cadence while the app is frontmost — a PR you are actually reading.
public let prDetailRefreshInterval: TimeInterval = 45
/// Backoff while the app is in the background: the pane may still be on screen,
/// but nobody is reading it, so don't spend `gh` round-trips at the full rate.
public let prDetailBackgroundRefreshInterval: TimeInterval = 300
/// Floor between two refetches of the same PR, whatever the trigger. A single
/// GitHub push fans out into several poller/webhook signals; without a floor each
/// one would cost its own round of `gh` spawns.
public let prDetailRefreshFloor: TimeInterval = 8

/// Whether the selected PR's detail should be refetched now.
///
/// - `lastFetched`: when this PR's detail last landed, nil if never.
/// - `pollerActivity`: the tracked-PR poller saw the PR move since that fetch, so
///   the pane is known-stale rather than merely old.
/// - `focused`: whether the app is frontmost.
public func prDetailRefreshDue(lastFetched: Date?, now: Date, focused: Bool,
                               pollerActivity: Bool) -> Bool {
    guard let lastFetched else { return true }
    let age = now.timeIntervalSince(lastFetched)
    // Clock moved backwards (sleep/wake, NTP step): the age is meaningless, so
    // refetch rather than sit on the cache until the stamp is passed again.
    if age < 0 { return true }
    if age < prDetailRefreshFloor { return false }
    if pollerActivity { return true }
    return age >= (focused ? prDetailRefreshInterval : prDetailBackgroundRefreshInterval)
}

// Freshness policy for the viewer's own PR queue (the Tools-menu GitHub count).
// One GitHub search round trip answers the whole queue, so this is a single
// cadence rather than a per-PR one — but it runs whether or not the GitHub view is
// open, so the background rate has to be genuinely cheap.

/// Cadence while the app is frontmost — the count you might glance at.
public let viewerPrRefreshInterval: TimeInterval = 300
/// Backoff while the app is in the background. Nobody is looking at the count, and
/// anything urgent still arrives through the tracked-PR poller and notifications.
public let viewerPrBackgroundRefreshInterval: TimeInterval = 1200
/// Floor between two fetches, whatever the trigger (opening the Tools menu, opening
/// the GitHub view, the tick). The search costs seconds, so a burst of triggers
/// must collapse into one call.
public let viewerPrRefreshFloor: TimeInterval = 60

/// Whether the viewer PR queue should be refetched now.
///
/// - `lastFetched`: when the queue last landed, nil if never.
/// - `focused`: whether the app is frontmost.
/// - `force`: a manual refresh — still floored, so a held-down refresh button can't
///   stampede `gh`.
public func viewerPrRefreshDue(lastFetched: Date?, now: Date, focused: Bool,
                               force: Bool = false) -> Bool {
    guard let lastFetched else { return true }
    let age = now.timeIntervalSince(lastFetched)
    // Clock moved backwards (sleep/wake, NTP step): the age says nothing, so refetch.
    if age < 0 { return true }
    if age < viewerPrRefreshFloor { return false }
    if force { return true }
    return age >= (focused ? viewerPrRefreshInterval : viewerPrBackgroundRefreshInterval)
}
