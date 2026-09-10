// Cron-scheduled dispatches (juancode-chhr). One timer, ticking faster than the
// minute the cron expressions resolve to, deciding per schedule whether this
// minute is its minute — then firing through `fireTrigger` (triggers.ts), which
// is the ordinary dispatch path plus the kill switch and the repo allow list.
//
// Two properties the ticket asks for, and how they're kept:
//
//   Survives a sidecar restart. The config is a hand-edited file; the runtime
//   state (which minute each schedule last fired in, and what it started) is a
//   separate file, so a restart mid-minute cannot fire the same schedule twice
//   and a restart at any other time loses nothing. A schedule whose minute passed
//   while the sidecar was down is NOT retroactively fired — a 3am job waking up
//   at 9am is worse than a skipped one; `lastFiredAt` in the state file is how you
//   see it was missed.
//
//   No overlapping run of the same schedule. Each fire remembers its dispatchId
//   and sessionId; the next fire asks the native app for its session list and
//   skips while that session is still `running`. When the app can't be reached,
//   the previous run's fate is unknown, so the tick skips rather than stacking
//   dispatches into the offline mailbox.

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { cronMatches, parseCron } from "./cron.ts";
import { parseSessionStates, type DispatchSessionState } from "./dispatch-status.ts";
import { listSessions, oracleDir } from "./oracle.ts";
import {
  fireTrigger,
  readTriggerConfig,
  ticketPrompt,
  triggersDisabledByEnv,
  type FireTriggerDeps,
  type ScheduleConfig,
  type TriggerConfig,
} from "./triggers.ts";
import type { DispatchRequest } from "./dispatch.ts";
import type { TriggerOrigin } from "./dispatch-registry.ts";

/** What one schedule did the last time it fired. */
export interface ScheduleState {
  /** Epoch ms of the START of the minute the schedule last fired in. */
  lastFiredMinute: number;
  lastFiredAt: number;
  lastDispatchId: string | null;
  lastSessionId: string | null;
  lastOutcome: "started" | "queued" | "failed";
  lastReason: string | null;
}

export type ScheduleStateFile = Record<string, ScheduleState>;

export const triggerStateFile = (): string => join(oracleDir(), "oracle-trigger-state.json");

function isScheduleState(v: unknown): v is ScheduleState {
  if (!v || typeof v !== "object") return false;
  const r = v as Record<string, unknown>;
  return typeof r.lastFiredMinute === "number" && typeof r.lastFiredAt === "number";
}

/** Read the runtime state, tolerating a missing or corrupt file. */
export async function readScheduleState(file = triggerStateFile()): Promise<ScheduleStateFile> {
  const raw = await readFile(file, "utf8").catch(() => "");
  if (!raw.trim()) return {};
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
    const out: ScheduleStateFile = {};
    for (const [id, value] of Object.entries(parsed as Record<string, unknown>)) {
      if (isScheduleState(value)) {
        out[id] = {
          lastFiredMinute: value.lastFiredMinute,
          lastFiredAt: value.lastFiredAt,
          lastDispatchId: typeof value.lastDispatchId === "string" ? value.lastDispatchId : null,
          lastSessionId: typeof value.lastSessionId === "string" ? value.lastSessionId : null,
          lastOutcome:
            value.lastOutcome === "queued" || value.lastOutcome === "failed"
              ? value.lastOutcome
              : "started",
          lastReason: typeof value.lastReason === "string" ? value.lastReason : null,
        };
      }
    }
    return out;
  } catch {
    return {};
  }
}

export async function writeScheduleState(
  state: ScheduleStateFile,
  file = triggerStateFile(),
): Promise<void> {
  await mkdir(oracleDir(), { recursive: true });
  await writeFile(file, JSON.stringify(state, null, 2), "utf8");
}

/** Epoch ms of the start of the minute containing `at`. */
export function minuteKey(at: Date): number {
  return Math.floor(at.getTime() / 60_000) * 60_000;
}

/** The dispatch request a schedule implies. `ticket` wins over nothing else:
 *  a schedule carries a prompt, a ticket, or both (prompt first). */
export function scheduleRequest(schedule: ScheduleConfig): DispatchRequest {
  const prompt = schedule.prompt ?? ticketPrompt(schedule.ticket ?? "", schedule.id);
  return {
    project: schedule.project,
    prompt,
    provider: schedule.provider ?? "claude",
    worktree: schedule.worktree !== false,
    telegramChatId: schedule.telegramChatId ?? null,
  };
}

export function scheduleOrigin(schedule: ScheduleConfig): TriggerOrigin {
  return {
    kind: "schedule",
    id: schedule.id,
    detail: `schedule "${schedule.id}" (cron ${schedule.cron})`,
  };
}

/** One schedule's outcome in a tick — the whole report is what tests assert on. */
export interface TickEntry {
  id: string;
  fired: boolean;
  reason: string;
}

export interface TickReport {
  /** Nothing was even evaluated (kill switch / config disabled). */
  disabled: boolean;
  entries: TickEntry[];
}

export interface ScheduleTickDeps extends FireTriggerDeps {
  now?: () => Date;
  readConfig?: () => Promise<TriggerConfig>;
  readState?: () => Promise<ScheduleStateFile>;
  writeState?: (state: ScheduleStateFile) => Promise<void>;
  /** The native app's session list. Rejects when the app is unreachable — the tick
   *  treats that as "the previous run's fate is unknown" and skips. */
  sessions?: () => Promise<DispatchSessionState[]>;
  log?: (message: string) => void;
}

/** Is the previous run of this schedule still going? */
function stillRunning(state: ScheduleState, sessions: DispatchSessionState[]): boolean {
  return sessions.some(
    (s) =>
      s.status !== "exited" &&
      ((state.lastSessionId !== null && s.id === state.lastSessionId) ||
        (state.lastDispatchId !== null && s.dispatchId === state.lastDispatchId)),
  );
}

/**
 * Evaluate every schedule once against the current minute and fire the ones due.
 * Resolves to a report of what happened; never throws.
 */
export async function runScheduleTick(deps: ScheduleTickDeps = {}): Promise<TickReport> {
  const now = (deps.now ?? (() => new Date()))();
  const log = deps.log ?? ((m: string) => console.log(m));

  if (triggersDisabledByEnv(deps.env)) return { disabled: true, entries: [] };
  const config = await (deps.readConfig ?? readTriggerConfig)();
  if (!config.enabled) return { disabled: true, entries: [] };
  const active = config.schedules.filter((s) => s.enabled !== false);
  if (active.length === 0) return { disabled: false, entries: [] };

  const minute = minuteKey(now);
  const due = active.filter((s) => {
    try {
      return cronMatches(parseCron(s.cron), now);
    } catch {
      return false; // normalizeTriggerConfig already dropped bad crons
    }
  });
  if (due.length === 0) return { disabled: false, entries: [] };

  const state = await (deps.readState ?? readScheduleState)();

  // One session-list fetch per tick, and only when a due schedule has something
  // to overlap with. "Unreachable" is deliberately not the same as "empty".
  let sessions: DispatchSessionState[] | null = null;
  let sessionsFetched = false;
  const fetchSessions = async (): Promise<DispatchSessionState[] | null> => {
    if (sessionsFetched) return sessions;
    sessionsFetched = true;
    try {
      const fetcher = deps.sessions ?? (async () => parseSessionStates(await listSessions()));
      sessions = await fetcher();
    } catch {
      sessions = null;
    }
    return sessions;
  };

  const entries: TickEntry[] = [];
  let dirty = false;

  for (const schedule of due) {
    const prior = state[schedule.id];
    if (prior && prior.lastFiredMinute === minute) {
      entries.push({ id: schedule.id, fired: false, reason: "already fired this minute" });
      continue;
    }
    if (prior && prior.lastOutcome !== "failed") {
      const live = await fetchSessions();
      if (live === null) {
        entries.push({
          id: schedule.id,
          fired: false,
          reason: "native app unreachable — can't tell if the previous run is still going",
        });
        continue;
      }
      if (stillRunning(prior, live)) {
        entries.push({ id: schedule.id, fired: false, reason: "previous run is still going" });
        continue;
      }
      if (prior.lastOutcome === "queued" && prior.lastSessionId === null) {
        // The last fire went into the offline mailbox and no session carrying its
        // dispatchId exists yet: the app will replay it. Don't stack another.
        entries.push({
          id: schedule.id,
          fired: false,
          reason: "previous run is still queued in the offline mailbox",
        });
        continue;
      }
    }

    const origin = scheduleOrigin(schedule);
    const result = await fireTrigger(scheduleRequest(schedule), origin, config, deps);
    const next: ScheduleState = result.fired
      ? {
          lastFiredMinute: minute,
          lastFiredAt: now.getTime(),
          lastDispatchId: result.outcome.dispatchId,
          lastSessionId: result.outcome.sessionId,
          lastOutcome: result.outcome.started ? "started" : "queued",
          lastReason: result.outcome.message,
        }
      : {
          lastFiredMinute: minute,
          lastFiredAt: now.getTime(),
          lastDispatchId: null,
          lastSessionId: null,
          lastOutcome: "failed",
          lastReason: result.reason,
        };
    state[schedule.id] = next;
    dirty = true;
    entries.push({
      id: schedule.id,
      fired: result.fired,
      reason: result.fired ? result.outcome.message : result.reason,
    });
    log(
      result.fired
        ? `trigger: ${origin.detail} → ${result.outcome.message}`
        : `trigger: ${origin.detail} did not dispatch: ${result.reason}`,
    );
  }

  // A refused fire is written too: it burns the minute, so a tick 20s later can't
  // retry the same refusal five times.
  if (dirty) {
    await (deps.writeState ?? writeScheduleState)(state).catch((e) =>
      console.warn("trigger state write failed:", e instanceof Error ? e.message : e),
    );
  }
  return { disabled: false, entries };
}

/** How often the tick runs. Well under a minute so a cron minute is never missed
 *  by drift, with the per-minute state dedupe stopping repeat fires. */
export const TICK_INTERVAL_MS = 20_000;

/**
 * Start the schedule loop. Returns a stop function. Safe to call with no config
 * file: every tick reads the config afresh, so triggers start working the moment
 * the file appears — no restart.
 */
export function startScheduleTriggers(intervalMs = TICK_INTERVAL_MS): () => void {
  if (triggersDisabledByEnv()) {
    console.log("oracle-mcp: triggers disabled (JUANCODE_TRIGGERS) — no schedule loop");
    return () => {};
  }
  let running = false;
  const tick = async () => {
    if (running) return; // never overlap ticks; a slow dispatch must not stack them
    running = true;
    try {
      await runScheduleTick();
    } catch (e) {
      console.warn("trigger tick failed:", e instanceof Error ? e.message : e);
    } finally {
      running = false;
    }
  };
  const timer = setInterval(() => void tick(), intervalMs);
  void tick();
  return () => clearInterval(timer);
}
