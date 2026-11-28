import { describe, expect, it, vi } from "vitest";
import { AutoHandoff, autoHandoffFraction } from "./auto-handoff.ts";
import type { HandoffSource } from "./session-handoff.ts";

const sample = {
  sessionId: "old",
  totalTokens: 1_000_000,
  contextTokens: 160_000,
  contextWindow: 200_000,
};
function fixture(provider = "claude") {
  const source: HandoffSource = {
    id: "old",
    title: "Task",
    provider,
    cwd: "/repo",
    skipPermissions: false,
    status: "running",
  };
  const deps = {
    activity: vi.fn<() => "busy" | "idle" | "waiting_input">(() => "busy"),
    source: vi.fn(async () => source),
    handoff: vi.fn(async (_id: string) => undefined),
    report: vi.fn(),
  };
  return { deps, controller: new AutoHandoff(0.8, deps) };
}

describe("automatic context handoff", () => {
  it.each(["claude", "codex"])(
    "hands off %s once despite concurrent usage events",
    async (provider) => {
      const { deps, controller } = fixture(provider);
      await Promise.all([controller.sample(sample), controller.sample(sample)]);
      await controller.sample(sample);
      expect(deps.handoff).toHaveBeenCalledExactlyOnceWith("old");
      await controller.sample({ ...sample, sessionId: "successor" });
      expect(deps.handoff).toHaveBeenCalledWith("successor");
    },
  );

  it("does not rotate idle or waiting sessions, but can rotate when work resumes", async () => {
    const { deps, controller } = fixture();
    deps.activity.mockReturnValue("idle");
    await controller.sample(sample);
    deps.activity.mockReturnValue("waiting_input");
    await controller.sample(sample);
    expect(deps.source).not.toHaveBeenCalled();
    deps.activity.mockReturnValue("busy");
    await controller.sample(sample);
    expect(deps.handoff).toHaveBeenCalledOnce();
  });

  it("uses current context, requires valid window telemetry, and supports disabling", async () => {
    const { deps, controller } = fixture();
    for (const reading of [
      { ...sample, contextTokens: 20 },
      { sessionId: "old", totalTokens: 1_000_000 },
      { ...sample, contextWindow: 0 },
      { ...sample, contextWindow: NaN },
      { ...sample, contextTokens: Infinity },
    ])
      await controller.sample(reading);
    await new AutoHandoff(0, deps).sample(sample);
    expect(deps.source).not.toHaveBeenCalled();
  });

  it("does not start unsupported providers or stopped sessions", async () => {
    const { deps, controller } = fixture("opencode");
    await controller.sample(sample);
    expect(deps.handoff).not.toHaveBeenCalled();
    const stopped = fixture();
    stopped.deps.source.mockResolvedValue({ ...(await stopped.deps.source()), status: "exited" });
    await stopped.controller.sample(sample);
    expect(stopped.deps.handoff).not.toHaveBeenCalled();
  });

  it("reports failure without retrying a potentially queued note", async () => {
    const { deps, controller } = fixture();
    deps.handoff.mockRejectedValue(new Error("no note"));
    await controller.sample(sample);
    await controller.sample({ ...sample, contextTokens: 180_000 });
    expect(deps.handoff).toHaveBeenCalledOnce();
    expect(deps.report).toHaveBeenLastCalledWith(expect.stringContaining("no note"));
  });

  it("reads the configured threshold", () => {
    expect(autoHandoffFraction({})).toBe(0.8);
    expect(autoHandoffFraction({ JUANCODE_AUTO_HANDOFF_PERCENT: "0" })).toBe(0);
    expect(autoHandoffFraction({ JUANCODE_AUTO_HANDOFF_PERCENT: "70" })).toBe(0.7);
    for (const value of ["garbage", "100", "-1", "Infinity"])
      expect(autoHandoffFraction({ JUANCODE_AUTO_HANDOFF_PERCENT: value })).toBe(0.8);
  });
});
