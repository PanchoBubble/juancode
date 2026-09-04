import { describe, expect, it } from "vitest";

import type { Frame } from "./client.ts";
import {
  announcedSessionIds,
  bumpAttempt,
  frameSessionId,
  makeSessionScope,
  repeatCount,
  seedVars,
} from "./runner.ts";

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

describe("which frames a scenario is asserting about", () => {
  it("claims the session a created reply announces", () => {
    const scope = makeSessionScope("create#1");
    scope.claim({ type: "created", session: { id: "s1" } });
    expect(scope.owned.has("s1")).toBe(true);
    expect(scope.isForeign({ type: "exit", sessionId: "s1", exitCode: 0 })).toBe(false);
  });

  it("ignores a late frame about a previous scenario's session", () => {
    // juancode-a3ck: the previous scenario's kill is reaped while the next
    // scenario's socket is the one open, so its exit lands mid-step.
    const earlier = makeSessionScope("exit-codes#1");
    earlier.claim({ type: "created", session: { id: "old" } });
    const later = makeSessionScope("seeded-input#1");
    later.claim({ type: "created", session: { id: "new" } });
    expect(later.isForeign({ type: "exit", sessionId: "old", exitCode: -1 })).toBe(true);
    expect(later.isForeign({ type: "activity", sessionId: "old", state: "idle" })).toBe(true);
    expect(later.isForeign({ type: "exit", sessionId: "new", exitCode: 0 })).toBe(false);
  });

  it("treats a previous ATTEMPT at the same scenario as somebody else", () => {
    const first = makeSessionScope("seeded-input#1");
    first.claim({ type: "created", session: { id: "attempt-1" } });
    const second = makeSessionScope("seeded-input#2");
    expect(second.isForeign({ type: "exit", sessionId: "attempt-1", exitCode: -1 })).toBe(true);
  });

  it("never calls an unrecognised session foreign", () => {
    // An activity broadcast can beat its own `created` reply, so an id nobody has
    // claimed yet may still be this scenario's. Dropping it would turn the fix
    // into a timeout.
    const scope = makeSessionScope("dispatch-correlation#1");
    expect(scope.isForeign({ type: "activity", sessionId: "not-yet-known", state: "busy" })).toBe(
      false,
    );
  });

  it("never calls a frame about no session foreign", () => {
    const scope = makeSessionScope("handshake#1");
    makeSessionScope("other#1").claim({ type: "created", session: { id: "x" } });
    expect(scope.isForeign({ type: "serverInfo", protocolVersion: 1 })).toBe(false);
    expect(scope.isForeign({ type: "error", message: "already processed" })).toBe(false);
  });

  it("announces ownership from replies only, never from a broadcast", () => {
    expect(announcedSessionIds({ type: "created", session: { id: "s" } })).toEqual(["s"]);
    expect(announcedSessionIds({ type: "editorReady", editorId: "e" })).toEqual(["e"]);
    expect(announcedSessionIds({ type: "terminalReady", terminalId: "t" })).toEqual(["t"]);
    expect(announcedSessionIds({ type: "activity", sessionId: "s", state: "busy" })).toEqual([]);
  });

  it("reads the session a frame is about from whichever key names it", () => {
    const cases: Array<[Frame, string | undefined]> = [
      [{ type: "exit", sessionId: "s" }, "s"],
      [{ type: "output", editorId: "e" }, "e"],
      [{ type: "terminalReady", terminalId: "t" }, "t"],
      [{ type: "created", session: { id: "c" } }, "c"],
      [{ type: "serverInfo" }, undefined],
    ];
    for (const [frame, want] of cases) expect(frameSessionId(frame)).toBe(want);
  });
});

describe("how many times each scenario is measured", () => {
  it("is once when nothing asks for more", () => {
    expect(repeatCount({})).toBe(1);
    expect(repeatCount({ JUANCODE_CONFORMANCE_REPEAT: "" })).toBe(1);
  });

  it("is whatever the env asks for", () => {
    expect(repeatCount({ JUANCODE_CONFORMANCE_REPEAT: "3" })).toBe(3);
  });

  it("refuses a value that would silently measure nothing", () => {
    for (const raw of ["0", "-1", "2.5", "three"]) {
      expect(() => repeatCount({ JUANCODE_CONFORMANCE_REPEAT: raw })).toThrow(/positive integer/);
    }
  });
});
