import Foundation
import JuancodeCore

/// Recurring-task scheduler for juancode-dgp (pillar 2 of juancode-0me): re-run a
/// given prompt against a project on a fixed interval. Each fire spawns a *fresh*
/// agent session in the task's folder with the prompt as its initial input — the
/// same `AppModel.create(...)` path a manual new-session uses.
///
/// This file holds the persisted model + the pure scheduling math (which tasks are
/// due, and when each should next fire). The driver (the tick loop + spawning) lives
/// in `AppModel`; keeping the decisions pure here makes them unit-testable without a
/// clock or a pty. v1 is fixed-interval only and project-spawn only; calendar
/// schedules and an "existing session" target are deliberately out of scope.

/// One recurring task: what to run, where, and how often. `nextFireAt` is the
/// absolute time (ms since epoch) of the next scheduled run, persisted so the
/// schedule survives an app restart without drifting or replaying missed slots.
public struct RecurringTask: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    /// A human label for the task (shown in the future management UI).
    public var title: String
    /// The project folder a fresh session is spawned in on each run.
    public var cwd: String
    public var provider: ProviderId
    /// The prompt sent as the new session's initial input.
    public var prompt: String
    /// How often to re-run, in seconds.
    public var intervalSeconds: Int
    /// Spawn with "accept all" (no permission prompts) — recurring runs are unattended.
    public var skipPermissions: Bool
    /// Paused tasks stay in the list but never fire.
    public var enabled: Bool
    public var createdAt: Int
    public var lastFiredAt: Int?
    /// Absolute time (ms since epoch) of the next scheduled run.
    public var nextFireAt: Int

    public init(id: String = UUID().uuidString, title: String, cwd: String, provider: ProviderId,
                prompt: String, intervalSeconds: Int, skipPermissions: Bool = true, enabled: Bool = true,
                createdAt: Int, lastFiredAt: Int? = nil, nextFireAt: Int) {
        self.id = id; self.title = title; self.cwd = cwd; self.provider = provider
        self.prompt = prompt; self.intervalSeconds = intervalSeconds
        self.skipPermissions = skipPermissions; self.enabled = enabled
        self.createdAt = createdAt; self.lastFiredAt = lastFiredAt; self.nextFireAt = nextFireAt
    }
}

// MARK: - pure scheduling math

/// The interval clamped to a sane floor (≥ 1s) and expressed in milliseconds, so a
/// zero/negative interval can never busy-loop the scheduler.
public func recurringIntervalMs(_ intervalSeconds: Int) -> Int { max(1, intervalSeconds) * 1000 }

/// The first scheduled fire time for a brand-new task: one interval after `now`
/// (we don't fire on creation — that's a surprise the future "Run now" UI handles).
public func initialFireTime(createdAt: Int, intervalSeconds: Int) -> Int {
    createdAt + recurringIntervalMs(intervalSeconds)
}

/// The next fire time strictly after `now`, stepping by the interval from `firedAt`.
/// When the app was asleep for several intervals, this skips the missed slots and
/// schedules the next *future* one — so a long gap fires once on wake, not a backlog.
/// Pure.
public func nextRecurringFireTime(firedAt: Int, intervalSeconds: Int, now: Int) -> Int {
    let interval = recurringIntervalMs(intervalSeconds)
    var next = firedAt + interval
    if next <= now {
        let behind = now - next
        next += (behind / interval + 1) * interval
    }
    return next
}

/// The enabled tasks whose next fire time has arrived (`nextFireAt <= now`). Pure.
public func dueRecurringTasks(_ tasks: [RecurringTask], now: Int) -> [RecurringTask] {
    tasks.filter { $0.enabled && $0.nextFireAt <= now }
}
