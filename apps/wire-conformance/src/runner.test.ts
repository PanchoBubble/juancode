import { describe, expect, it } from "vitest";

import { bumpAttempt, seedVars } from "./runner.ts";

const workspace = {
  cwd: "/w/plain",
  gitCwd: "/w/repo",
  missingCwd: "/w/nope",
  file: "/w/note.txt",
};

describe("the ids a scenario claims in a core", () => {
  it("are the same for every step of one attempt", () => {
    const a = seedVars(workspace, "dispatch-correlation", 1);
    const b = seedVars(workspace, "dispatch-correlation", 1);
    expect(a).toEqual(b);
  });

  it("differ between attempts, so a repeat run is a fresh claim", () => {
    const first = seedVars(workspace, "dispatch-correlation", 1);
    const second = seedVars(workspace, "dispatch-correlation", 2);
    expect(second.dispatchId).not.toEqual(first.dispatchId);
    expect(second.cliSessionId).not.toEqual(first.cliSessionId);
  });

  it("differ between scenarios in the same attempt", () => {
    expect(seedVars(workspace, "adopt-external", 1).dispatchId).not.toEqual(
      seedVars(workspace, "dispatch-correlation", 1).dispatchId,
    );
  });

  it("stay recognisable as conformance artifacts", () => {
    const vars = seedVars(workspace, "adopt-external", 3);
    expect(String(vars.dispatchId)).toMatch(/^conformance-adopt-external-/);
    expect(String(vars.cliSessionId)).toMatch(/^conformance-adopted-adopt-external-/);
  });

  it("count attempts per scenario, not globally", () => {
    const id = `probe-${Math.random()}`;
    expect(bumpAttempt(id)).toBe(1);
    expect(bumpAttempt(id)).toBe(2);
    expect(bumpAttempt(`${id}-other`)).toBe(1);
  });
});
