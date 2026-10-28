import { describe, expect, it } from "vitest";
import type { DispatchStatus } from "./dispatch-status.ts";
import type { SessionActivityEvent } from "./native-events.ts";
import { SETTLED_IDLE_AGE_MS, waitForDispatch, type WaitDeps } from "./dispatch-wait.ts";

const T0 = 1_000_000_000_000;

function status(over: Partial<DispatchStatus["session"]> | null, ok = true): DispatchStatus {
  return {
    dispatchId: "d-1",
    request: null,
    result: ok
      ? null
      : { dispatchId: "d-1", project: "/p", ok: false, sessionId: null, error: "bad path", at: T0 },
    session:
      over === null
        ? null
        : {
            id: "s-1",
            title: "t",
            cwd: "/p",
            provider: "claude",
            status: "running",
            dispatchId: "d-1",
            createdAt: T0,
            ...over,
          },
  };
}

function harness(initial: DispatchStatus, state?: SessionActivityEvent["state"]) {
  const listeners: ((ev: SessionActivityEvent) => void)[] = [];
  let current = initial;
  let activity = state;
  let clock = T0 + 1_000;
  const deps: WaitDeps = {
    getStatus: async () => current,
    activity: () => activity,
    subscribe: (l) => {
      listeners.push(l);
      return () => listeners.splice(listeners.indexOf(l), 1);
    },
    now: () => clock,
    recheckMs: 1,
  };
  return {
    deps,
    listeners,
    emit(ev: Partial<SessionActivityEvent>) {
      activity = ev.state;
      for (const l of [...listeners]) {
        l({ sessionId: "s-1", state: "busy", notify: false, dispatchId: "d-1", ...ev });
      }
    },
    set(s: DispatchStatus) {
      current = s;
    },
    advance(ms: number) {
      clock += ms;
    },
  };
}

const tick = () => new Promise((r) => setTimeout(r, 5));

describe("waitForDispatch", () => {
  it("returns failed for a dispatch whose start failed", async () => {
    const h = harness(status(null, false));
    expect((await waitForDispatch("d-1", 10_000, h.deps)).outcome).toBe("failed");
  });

  it("returns exited once the session exits", async () => {
    const h = harness(status({}), "busy");
    const p = waitForDispatch("d-1", 10_000, h.deps);
    await tick();
    h.set(status({ status: "exited" }));
    expect((await p).outcome).toBe("exited");
  });

  it("returns idle on the settle edge after the agent worked", async () => {
    const h = harness(status({}), "idle");
    const p = waitForDispatch("d-1", 10_000, h.deps);
    await tick();
    h.emit({ state: "busy" });
    await tick();
    h.emit({ state: "idle" });
    expect((await p).outcome).toBe("idle");
    expect(h.listeners).toHaveLength(0);
  });

  it("does not treat a freshly spawned idle session as finished", async () => {
    const h = harness(status({ createdAt: T0 }), "idle");
    const p = waitForDispatch("d-1", 10_000, h.deps);
    await tick();
    h.advance(20_000);
    expect((await p).outcome).toBe("timeout");
  });

  it("returns idle at once for a session that settled before the wait began", async () => {
    const h = harness(status({ createdAt: T0 - SETTLED_IDLE_AGE_MS }), "idle");
    expect((await waitForDispatch("d-1", 10_000, h.deps)).outcome).toBe("idle");
  });

  it("returns waiting_input whenever the agent asks for input", async () => {
    const h = harness(status(null));
    const p = waitForDispatch("d-1", 10_000, h.deps);
    await tick();
    h.emit({ state: "waiting_input" });
    expect((await p).outcome).toBe("waiting_input");
  });
});
