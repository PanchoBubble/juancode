import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { appendFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { getDispatchStatus, listDispatchStatuses, parseSessionStates } from "./dispatch-status.ts";
import { recordDispatch, type DispatchRecord } from "./dispatch-registry.ts";

const request = (overrides: Partial<DispatchRecord> = {}): DispatchRecord => ({
  dispatchId: "d-1",
  project: "/abs/repo",
  prompt: "do the thing",
  provider: "claude",
  worktree: false,
  telegramChatId: 555,
  outcome: "started",
  sessionId: "s-1",
  error: null,
  at: 1000,
  ...overrides,
});

/** Append one native-written result line (the Swift OracleDispatchResult shape). */
const appendResult = (dir: string, r: Record<string, unknown>) => {
  appendFileSync(join(dir, "dispatch-results.jsonl"), JSON.stringify(r) + "\n", "utf8");
};

describe("dispatch-status", () => {
  let dir: string;
  const prevDir = process.env.JUANCODE_ORACLE_DIR;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oracle-dispatch-status-test-"));
    process.env.JUANCODE_ORACLE_DIR = dir;
  });

  afterEach(() => {
    if (prevDir === undefined) delete process.env.JUANCODE_ORACLE_DIR;
    else process.env.JUANCODE_ORACLE_DIR = prevDir;
    rmSync(dir, { recursive: true, force: true });
  });

  it("merges the request, the durable result, and the live session state", async () => {
    await recordDispatch(request());
    appendResult(dir, {
      dispatchId: "d-1",
      project: "/abs/repo",
      ok: true,
      sessionId: "s-1",
      at: 2000,
    });
    const sessions = async () => [
      {
        id: "s-1",
        title: "fix tests",
        cwd: "/abs/repo",
        provider: "claude",
        status: "running",
        dispatchId: "d-1",
      },
    ];

    const status = await getDispatchStatus("d-1", sessions);
    expect(status.dispatchId).toBe("d-1");
    expect(status.request).toMatchObject({ prompt: "do the thing", telegramChatId: 555 });
    expect(status.result).toMatchObject({ ok: true, sessionId: "s-1" });
    expect(status.session).toMatchObject({ id: "s-1", title: "fix tests", status: "running" });
  });

  it("reports a queued dispatch whose result has not landed yet", async () => {
    await recordDispatch(request({ dispatchId: "d-q", outcome: "queued", sessionId: null }));
    const status = await getDispatchStatus("d-q", async () => []);
    expect(status.request?.outcome).toBe("queued");
    expect(status.result).toBeNull();
    expect(status.session).toBeNull();
  });

  it("surfaces a queued dispatch's eventual start from the durable results", async () => {
    await recordDispatch(request({ dispatchId: "d-q", outcome: "queued", sessionId: null }));
    appendResult(dir, {
      dispatchId: "d-q",
      project: "/abs/repo",
      ok: true,
      sessionId: "s-9",
      at: 3000,
    });
    const status = await getDispatchStatus("d-q", async () => [
      { id: "s-9", title: "later", cwd: "/abs/repo", provider: "claude", status: "running" },
    ]);
    expect(status.result?.sessionId).toBe("s-9");
    // Matched by sessionId even when the session row predates dispatchId persistence.
    expect(status.session?.id).toBe("s-9");
  });

  it("degrades to nulls for unknown ids and an unreachable native app", async () => {
    const status = await getDispatchStatus("d-ghost", async () => {
      throw new Error("down");
    });
    expect(status).toEqual({ dispatchId: "d-ghost", request: null, result: null, session: null });
  });

  it("lists recent dispatches newest first with one merged row each", async () => {
    await recordDispatch(
      request({ dispatchId: "d-old", at: 1, sessionId: null, outcome: "queued" }),
    );
    await recordDispatch(request({ dispatchId: "d-new", at: 2 }));
    appendResult(dir, {
      dispatchId: "d-old",
      project: "/abs/repo",
      ok: false,
      error: "boom",
      at: 5,
    });

    const list = await listDispatchStatuses(50, async () => []);
    expect(list.map((s) => s.dispatchId)).toEqual(["d-new", "d-old"]);
    expect(list[1]!.result).toMatchObject({ ok: false, error: "boom" });
  });
});

describe("parseSessionStates", () => {
  it("keeps well-formed rows and drops garbage", () => {
    const parsed = parseSessionStates([
      {
        id: "s-1",
        title: "t",
        cwd: "/p",
        provider: "claude",
        status: "running",
        dispatchId: "d-1",
      },
      { id: "s-2" },
      { title: "no id" },
      null,
      "nope",
    ]);
    expect(parsed).toHaveLength(2);
    expect(parsed[0]).toEqual({
      id: "s-1",
      title: "t",
      cwd: "/p",
      provider: "claude",
      status: "running",
      dispatchId: "d-1",
    });
    expect(parsed[1]!.dispatchId).toBeNull();
  });

  it("returns [] for a non-array payload", () => {
    expect(parseSessionStates({ sessions: [] })).toEqual([]);
    expect(parseSessionStates(null)).toEqual([]);
  });
});
