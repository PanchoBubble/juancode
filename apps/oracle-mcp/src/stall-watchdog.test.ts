import { describe, expect, it, vi } from "vitest";
import type { DispatchSessionState } from "./dispatch-status.ts";
import { SessionNotifications, type SessionSubscription } from "./session-notifications.ts";
import { StallWatchdog } from "./stall-watchdog.ts";

const MIN = 60_000;
const child = (over: Partial<DispatchSessionState> = {}): DispatchSessionState => ({
  id: "child",
  title: "",
  cwd: "/",
  provider: "claude",
  status: "running",
  dispatchId: "d-1",
  ...over,
});
const sub = (over: Partial<SessionSubscription> = {}): SessionSubscription => ({
  id: "sub-1",
  subscriber: "parent",
  targetType: "dispatch",
  targetId: "d-1",
  sourceSessionId: "child",
  states: ["idle"],
  mode: "done",
  responseIncludes: null,
  lastState: "busy",
  ...over,
});

function harness(s: SessionSubscription, session: DispatchSessionState, seqs: () => number) {
  let now = 0;
  const raise = vi.fn(async (_sub: string, _session: string, _text: string) => {});
  const dog = new StallWatchdog(
    {
      subscriptions: async () => [s],
      sessions: async () => [session],
      progress: async () => seqs(),
      raise,
      now: () => now,
    },
    20 * MIN,
  );
  const runFor = async (minutes: number) => {
    for (let i = 0; i < minutes; i++) {
      await dog.tick();
      now += MIN;
    }
  };
  return { raise, runFor };
}

describe("stall watchdog", () => {
  it("raises exactly one stalled notification for a busy child with no transcript progress", async () => {
    const h = harness(sub(), child(), () => 7);
    await h.runFor(90);
    expect(h.raise).toHaveBeenCalledTimes(1);
    expect(h.raise.mock.calls[0]!.slice(0, 2)).toEqual(["sub-1", "child"]);
  });

  it("stays quiet through a long turn whose transcript keeps growing", async () => {
    let seq = 0;
    const h = harness(sub(), child(), () => Math.floor(seq++ / 10));
    await h.runFor(120);
    expect(h.raise).not.toHaveBeenCalled();
  });

  it("raises for an idle child whose initial prompt was never delivered", async () => {
    const h = harness(
      sub({ lastState: "idle" }),
      child({ promptDelivery: { state: "failed", reason: "stayed in the box", at: 0 } }),
      () => -1,
    );
    await h.runFor(30);
    expect(h.raise).toHaveBeenCalledTimes(1);
    expect(h.raise.mock.calls[0]![2]).toContain("never delivered");
  });

  it("leaves a settled child and an unreadable transcript alone", async () => {
    const idle = harness(sub({ lastState: "idle" }), child(), () => 1);
    const unknown = harness(sub(), child(), () => {
      throw new Error("501");
    });
    await idle.runFor(60);
    await unknown.runFor(60);
    expect(idle.raise).not.toHaveBeenCalled();
    expect(unknown.raise).not.toHaveBeenCalled();
  });

  it("delivers the stall through the subscriber's outbox", async () => {
    const deliver = vi.fn(async (_id: string, _text: string) => {});
    const store = new SessionNotifications(":memory:", { output: async () => "", deliver });
    const row = await store.subscribe({
      subscriber: "parent",
      targetType: "dispatch",
      targetId: "d-1",
      mode: "done",
    });
    await store.raise(row.id, "child", "stalled", "Stalled: no transcript progress");
    const [item] = await store.inbox("parent");
    expect(item).toMatchObject({
      state: "stalled",
      sessionId: "child",
      dispatchId: "d-1",
      delivered: true,
    });
    expect(deliver).toHaveBeenCalledTimes(1);
    expect((await store.list("parent")).length).toBe(1);
    await store.close();
  });
});
