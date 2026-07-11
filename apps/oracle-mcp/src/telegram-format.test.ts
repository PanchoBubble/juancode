import { describe, expect, it } from "vitest";
import {
  classifyActivity,
  dispatchResultText,
  formatSessionLine,
  orderSessions,
  parseSessionList,
  projectName,
  resolveSelector,
  stateIcon,
  stateLabel,
  type SessionSummary,
} from "./telegram-format.ts";
import type { DispatchResultRecord } from "./dispatch-results.ts";

const s = (over: Partial<SessionSummary>): SessionSummary => ({
  id: "id-1",
  provider: "claude",
  cwd: "/x/proj",
  title: "t",
  status: "running",
  archived: false,
  updatedAt: 0,
  ...over,
});

describe("parseSessionList", () => {
  it("parses a bare array and a {sessions} wrapper, dropping malformed rows", () => {
    const row = {
      id: "a",
      provider: "claude",
      cwd: "/x",
      title: " hi ",
      status: "running",
      updatedAt: 5,
    };
    expect(parseSessionList([row, { nope: true }, null])).toMatchObject([
      { id: "a", title: "hi", updatedAt: 5, archived: false },
    ]);
    expect(parseSessionList({ sessions: [row] })).toHaveLength(1);
    expect(parseSessionList("garbage")).toEqual([]);
  });

  it("falls back to the id slice for a blank title", () => {
    expect(parseSessionList([{ id: "abcdefgh-123", title: "  " }])[0]!.title).toBe("abcdefgh");
  });
});

describe("orderSessions", () => {
  it("drops archived, puts running first, newest first within a group", () => {
    const list = [
      s({ id: "old-run", status: "running", updatedAt: 1 }),
      s({ id: "archived", archived: true, updatedAt: 99 }),
      s({ id: "exited", status: "exited", updatedAt: 50 }),
      s({ id: "new-run", status: "running", updatedAt: 9 }),
    ];
    expect(orderSessions(list).map((x) => x.id)).toEqual(["new-run", "old-run", "exited"]);
  });
});

describe("state rendering", () => {
  it("live activity wins over the persisted status", () => {
    expect(stateIcon("running", "waiting_input")).toBe("🟡");
    expect(stateLabel("running", "waiting_input")).toBe("waiting for input");
    expect(stateIcon("running", "busy")).toBe("🔵");
    expect(stateIcon("running", "idle")).toBe("🟢");
    expect(stateIcon("running", undefined)).toBe("⚪");
    expect(stateLabel("running", undefined)).toBe("running");
  });

  it("exited always renders as exited", () => {
    expect(stateIcon("exited", "busy")).toBe("⚫");
    expect(stateLabel("exited", "idle")).toBe("exited");
  });

  it("formats a numbered line with project, provider, state, and observed marker", () => {
    const line = formatSessionLine(
      3,
      s({ title: "fix tests", cwd: "/u/w/juancode", provider: "claude" }),
      "busy",
      true,
    );
    expect(line).toContain("3. 🔵 fix tests 👁");
    expect(line).toContain("juancode · claude · working");
  });
});

describe("projectName", () => {
  it("takes the last path segment, tolerating trailing slashes", () => {
    expect(projectName("/a/b/proj")).toBe("proj");
    expect(projectName("/a/b/proj//")).toBe("proj");
    expect(projectName("")).toBe("?");
  });
});

describe("classifyActivity", () => {
  it("only notify-flagged waiting_input/idle transitions alert", () => {
    expect(classifyActivity("waiting_input", true)).toBe("needs_input");
    expect(classifyActivity("idle", true)).toBe("finished");
    expect(classifyActivity("busy", true)).toBeNull();
    expect(classifyActivity("waiting_input", false)).toBeNull();
    expect(classifyActivity("idle", false)).toBeNull();
  });
});

describe("resolveSelector", () => {
  const ordered = [s({ id: "aaaa-1111" }), s({ id: "aabb-2222" }), s({ id: "cccc-3333" })];

  it("resolves a 1-based index against the last printed list first", () => {
    expect(resolveSelector("2", ordered, ["cccc-3333", "aaaa-1111"])).toBe("aaaa-1111");
    expect(resolveSelector("1", ordered, undefined)).toBe("aaaa-1111");
    expect(resolveSelector("9", ordered, undefined)).toBeNull();
    expect(resolveSelector("0", ordered, undefined)).toBeNull();
  });

  it("resolves exact ids and unique prefixes, rejecting ambiguity", () => {
    expect(resolveSelector("cccc-3333", ordered, undefined)).toBe("cccc-3333");
    expect(resolveSelector("cc", ordered, undefined)).toBe("cccc-3333");
    expect(resolveSelector("aa", ordered, undefined)).toBeNull();
    expect(resolveSelector("zz", ordered, undefined)).toBeNull();
    expect(resolveSelector("  ", ordered, undefined)).toBeNull();
  });
});

describe("dispatchResultText", () => {
  const r = (over: Partial<DispatchResultRecord>): DispatchResultRecord => ({
    dispatchId: "d-1",
    project: "/x/proj",
    ok: true,
    sessionId: null,
    error: null,
    at: 0,
    ...over,
  });

  it("always relays failures, with the project name and error", () => {
    const text = dispatchResultText(
      r({ ok: false, error: '"/x/proj" is not an existing directory' }),
      false,
    );
    expect(text).toContain("proj");
    expect(text).toContain("is not an existing directory");
  });

  it("relays a success only for a dispatch this sidecar queued offline", () => {
    expect(dispatchResultText(r({ sessionId: "s-9" }), false)).toBeNull();
    const confirmed = dispatchResultText(r({ sessionId: "s-9" }), true);
    expect(confirmed).toContain("proj");
    expect(confirmed).toContain("s-9");
  });

  it("handles an agent-written failure with no dispatch id", () => {
    const text = dispatchResultText(r({ dispatchId: null, ok: false, error: "boom" }), false);
    expect(text).toContain("boom");
  });
});
