import { execFile as execFileCb } from "node:child_process";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { promisify } from "node:util";

import { describe, expect, it } from "vitest";

import type { Frame } from "./client.ts";
import {
  announcedSessionIds,
  bumpAttempt,
  frameSessionId,
  httpBaseOf,
  interpolate,
  makeSessionScope,
  makeWorkspace,
  repeatCount,
  seedVars,
} from "./runner.ts";

const execFile = promisify(execFileCb);

const workspace = {
  cwd: "/w/plain",
  gitCwd: "/w/repo",
  gitRemoteCwd: "/w/remote-repo",
  ghCwd: "/w/gh-repo",
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

describe("addressing a core's HTTP reads", () => {
  it("derives the base from the socket URL, because they are one process", () => {
    expect(httpBaseOf({ wsUrl: "ws://127.0.0.1:4300/ws" } as never)).toBe("http://127.0.0.1:4300");
    expect(httpBaseOf({ wsUrl: "wss://host/ws" } as never)).toBe("https://host");
  });

  it("prefers a base the boot handed it over one it could guess", () => {
    const ctx = { wsUrl: "ws://127.0.0.1:4300/ws", httpBase: "http://127.0.0.1:9/" } as never;
    expect(httpBaseOf(ctx)).toBe("http://127.0.0.1:9");
  });

  it("substitutes a bound id INSIDE a path, which a frame value never needs", () => {
    expect(interpolate("/api/sessions/$session/screen?json=1", { session: "s-1" })).toBe(
      "/api/sessions/s-1/screen?json=1",
    );
    // A session id is one path segment, so it is encoded as one.
    expect(interpolate("/api/sessions/$session/screen", { session: "a/b c" })).toBe(
      "/api/sessions/a%2Fb%20c/screen",
    );
    // Nothing bound is left alone rather than blanked: the failure then names the
    // path the scenario actually asked for.
    expect(interpolate("/api/sessions/$nope/screen", {})).toBe("/api/sessions/$nope/screen");
  });
});

describe("the git identity the changes fixture carries", () => {
  it("lets the CORE commit in a linked worktree of it, on a machine with no global one", async () => {
    const ws = makeWorkspace();
    try {
      // The core is a separate process with no fixture environment, and on a CI
      // runner it has no global `user.email` either. Scrubbing both is what makes
      // this test the CI machine rather than this one.
      const bare: NodeJS.ProcessEnv = { ...process.env };
      for (const key of [
        "GIT_AUTHOR_NAME",
        "GIT_AUTHOR_EMAIL",
        "GIT_COMMITTER_NAME",
        "GIT_COMMITTER_EMAIL",
      ]) {
        delete bare[key];
      }
      bare.GIT_CONFIG_GLOBAL = "/dev/null";
      bare.GIT_CONFIG_SYSTEM = "/dev/null";
      // `execFile` and not `execFileSync`: this file runs in a vitest worker whose
      // reporter RPC shares the event loop, and a fork costs 257ms on the machine
      // this was written on. A second of blocking per git call is how a worker
      // times out calling `onTaskUpdate` and fails a run that passed.
      const git = (cwd: string, ...args: string[]) =>
        execFile("git", args, { cwd, env: bare }).then((r) => r.stdout);

      const wt = join(ws.gitRemoteCwd, "..", "identity-probe");
      await git(ws.gitRemoteCwd, "worktree", "add", "--quiet", "-b", "probe", wt);
      writeFileSync(join(wt, "wide.txt"), "line 1 EDITED\n");
      await git(wt, "add", "-A");
      await git(wt, "commit", "--quiet", "-m", "fix: the thirty-seventh line");
      expect((await git(wt, "log", "-1", "--pretty=%s")).trim()).toBe(
        "fix: the thirty-seventh line",
      );
    } finally {
      ws.dispose();
    }
    // Generous on purpose: `makeWorkspace` is a dozen `git` invocations, and a
    // fork+exec costs 257ms on the machine this was written on.
  }, 120_000);
});
