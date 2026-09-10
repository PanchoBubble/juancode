import { describe, expect, it, vi } from "vitest";
import {
  minuteKey,
  runScheduleTick,
  scheduleRequest,
  type ScheduleStateFile,
} from "./trigger-schedules.ts";
import { EMPTY_TRIGGER_CONFIG, type TriggerConfig } from "./triggers.ts";
import type { DispatchOutcome, DispatchRequest } from "./dispatch.ts";
import type { DispatchSessionState } from "./dispatch-status.ts";

const PROJECT = "/Users/me/repos/juancode";
const AT_3AM = new Date(2026, 8, 10, 3, 0, 0, 0); // 2026-09-10 03:00 local

function config(over: Partial<TriggerConfig> = {}): TriggerConfig {
  return {
    ...EMPTY_TRIGGER_CONFIG,
    allowedProjects: [PROJECT],
    schedules: [{ id: "nightly", cron: "0 3 * * *", project: PROJECT, prompt: "do the thing" }],
    ...over,
  };
}

const started = (over: Partial<DispatchOutcome> = {}): DispatchOutcome => ({
  dispatchId: "d1",
  started: true,
  queued: false,
  sessionId: "s1",
  message: "Started claude session s1.",
  ...over,
});

const session = (over: Partial<DispatchSessionState> = {}): DispatchSessionState => ({
  id: "s1",
  title: "nightly",
  cwd: PROJECT,
  provider: "claude",
  status: "running",
  dispatchId: "d1",
  ...over,
});

/** A tick harness with an in-memory state file. */
function harness(opts: {
  config?: TriggerConfig;
  state?: ScheduleStateFile;
  sessions?: () => Promise<DispatchSessionState[]>;
  dispatch?: (req: DispatchRequest) => Promise<DispatchOutcome>;
  now?: Date;
}) {
  const state: ScheduleStateFile = { ...(opts.state ?? {}) };
  const written: ScheduleStateFile[] = [];
  const dispatch = vi.fn(opts.dispatch ?? (async () => started()));
  const run = () =>
    runScheduleTick({
      now: () => opts.now ?? AT_3AM,
      readConfig: async () => opts.config ?? config(),
      readState: async () => state,
      writeState: async (s) => {
        written.push(structuredClone(s));
      },
      sessions: opts.sessions ?? (async () => []),
      dispatch,
      env: {},
      log: () => {},
    });
  return { run, dispatch, written, state };
}

describe("runScheduleTick", () => {
  it("fires a schedule whose minute it is", async () => {
    const h = harness({});
    const report = await h.run();
    expect(report.entries).toEqual([{ id: "nightly", fired: true, reason: expect.any(String) }]);
    expect(h.dispatch).toHaveBeenCalledWith(
      expect.objectContaining({
        project: PROJECT,
        prompt: "do the thing",
        worktree: true,
        trigger: { kind: "schedule", id: "nightly", detail: 'schedule "nightly" (cron 0 3 * * *)' },
      }),
    );
    expect(h.written.at(-1)?.nightly).toMatchObject({
      lastFiredMinute: minuteKey(AT_3AM),
      lastOutcome: "started",
      lastSessionId: "s1",
    });
  });

  it("does nothing on a minute no schedule matches", async () => {
    const h = harness({ now: new Date(2026, 8, 10, 4, 0) });
    const report = await h.run();
    expect(report.entries).toEqual([]);
    expect(h.dispatch).not.toHaveBeenCalled();
  });

  it("does not fire twice in the same minute, even across a restart", async () => {
    const h = harness({
      state: {
        nightly: {
          lastFiredMinute: minuteKey(AT_3AM),
          lastFiredAt: AT_3AM.getTime(),
          lastDispatchId: "d0",
          lastSessionId: "s0",
          lastOutcome: "started",
          lastReason: null,
        },
      },
      sessions: async () => [],
    });
    const report = await h.run();
    expect(report.entries).toEqual([
      { id: "nightly", fired: false, reason: "already fired this minute" },
    ]);
    expect(h.dispatch).not.toHaveBeenCalled();
  });

  it("skips while the previous run is still going", async () => {
    const h = harness({
      state: {
        nightly: {
          lastFiredMinute: minuteKey(new Date(2026, 8, 9, 3, 0)),
          lastFiredAt: Date.now(),
          lastDispatchId: "d1",
          lastSessionId: "s1",
          lastOutcome: "started",
          lastReason: null,
        },
      },
      sessions: async () => [session()],
    });
    const report = await h.run();
    expect(report.entries).toEqual([
      { id: "nightly", fired: false, reason: "previous run is still going" },
    ]);
    expect(h.dispatch).not.toHaveBeenCalled();
  });

  it("fires again once the previous session has exited", async () => {
    const h = harness({
      state: {
        nightly: {
          lastFiredMinute: minuteKey(new Date(2026, 8, 9, 3, 0)),
          lastFiredAt: Date.now(),
          lastDispatchId: "d1",
          lastSessionId: "s1",
          lastOutcome: "started",
          lastReason: null,
        },
      },
      sessions: async () => [session({ status: "exited" })],
    });
    expect((await h.run()).entries[0]?.fired).toBe(true);
  });

  it("skips when the native app can't say whether the previous run is alive", async () => {
    const h = harness({
      state: {
        nightly: {
          lastFiredMinute: minuteKey(new Date(2026, 8, 9, 3, 0)),
          lastFiredAt: Date.now(),
          lastDispatchId: "d1",
          lastSessionId: "s1",
          lastOutcome: "started",
          lastReason: null,
        },
      },
      sessions: async () => {
        throw new Error("connection refused");
      },
    });
    const report = await h.run();
    expect(report.entries[0]).toMatchObject({ fired: false, reason: /unreachable/ });
    expect(h.dispatch).not.toHaveBeenCalled();
  });

  it("does not stack a second dispatch behind one still queued offline", async () => {
    const h = harness({
      state: {
        nightly: {
          lastFiredMinute: minuteKey(new Date(2026, 8, 9, 3, 0)),
          lastFiredAt: Date.now(),
          lastDispatchId: "dq",
          lastSessionId: null,
          lastOutcome: "queued",
          lastReason: null,
        },
      },
      sessions: async () => [],
    });
    const report = await h.run();
    expect(report.entries[0]).toMatchObject({ fired: false, reason: /queued/ });
    expect(h.dispatch).not.toHaveBeenCalled();
  });

  it("retries a schedule whose last fire was refused", async () => {
    const h = harness({
      state: {
        nightly: {
          lastFiredMinute: minuteKey(new Date(2026, 8, 9, 3, 0)),
          lastFiredAt: Date.now(),
          lastDispatchId: null,
          lastSessionId: null,
          lastOutcome: "failed",
          lastReason: "bad path",
        },
      },
    });
    expect((await h.run()).entries[0]?.fired).toBe(true);
  });

  it("records a refusal so the same minute isn't retried every 20s", async () => {
    const h = harness({
      config: config({ allowedProjects: [] }),
    });
    const report = await h.run();
    expect(report.entries[0]).toMatchObject({ fired: false, reason: /allow list/ });
    expect(h.written.at(-1)?.nightly).toMatchObject({
      lastOutcome: "failed",
      lastFiredMinute: minuteKey(AT_3AM),
    });
  });

  it("evaluates nothing when the kill switch is set", async () => {
    const dispatch = vi.fn(async () => started());
    const report = await runScheduleTick({
      now: () => AT_3AM,
      readConfig: async () => config(),
      readState: async () => ({}),
      writeState: async () => {},
      dispatch,
      env: { JUANCODE_TRIGGERS: "0" },
      log: () => {},
    });
    expect(report).toEqual({ disabled: true, entries: [] });
    expect(dispatch).not.toHaveBeenCalled();
  });

  it("skips a schedule disabled in the config", async () => {
    const h = harness({
      config: config({
        schedules: [
          { id: "nightly", cron: "0 3 * * *", project: PROJECT, prompt: "x", enabled: false },
        ],
      }),
    });
    expect((await h.run()).entries).toEqual([]);
    expect(h.dispatch).not.toHaveBeenCalled();
  });
});

describe("scheduleRequest", () => {
  it("uses a ticket prompt when no prompt is given", () => {
    const req = scheduleRequest({
      id: "ready-sweep",
      cron: "0 3 * * *",
      project: PROJECT,
      ticket: "juancode-9",
    });
    expect(req.prompt).toContain("juancode-9");
    expect(req.worktree).toBe(true);
    expect(req.provider).toBe("claude");
  });

  it("honours an explicit provider and worktree:false", () => {
    const req = scheduleRequest({
      id: "x",
      cron: "0 3 * * *",
      project: PROJECT,
      prompt: "p",
      provider: "codex",
      worktree: false,
    });
    expect(req).toMatchObject({ provider: "codex", worktree: false });
  });
});
