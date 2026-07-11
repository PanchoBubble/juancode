import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  DISPATCH_REGISTRY_CAP,
  dispatchOriginChat,
  getDispatch,
  listDispatches,
  recordDispatch,
  type DispatchRecord,
} from "./dispatch-registry.ts";

const record = (overrides: Partial<DispatchRecord> = {}): DispatchRecord => ({
  dispatchId: "d-1",
  project: "/abs/repo",
  prompt: "do the thing",
  provider: "claude",
  worktree: false,
  telegramChatId: null,
  outcome: "started",
  sessionId: "s-1",
  error: null,
  at: 1000,
  ...overrides,
});

describe("dispatch-registry", () => {
  let dir: string;
  const prevDir = process.env.JUANCODE_ORACLE_DIR;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oracle-dispatch-registry-test-"));
    process.env.JUANCODE_ORACLE_DIR = dir;
  });

  afterEach(() => {
    if (prevDir === undefined) delete process.env.JUANCODE_ORACLE_DIR;
    else process.env.JUANCODE_ORACLE_DIR = prevDir;
    rmSync(dir, { recursive: true, force: true });
  });

  it("round-trips a record and resolves the originating chat", async () => {
    await recordDispatch(record({ dispatchId: "d-tg", telegramChatId: 555 }));
    expect(await getDispatch("d-tg")).toMatchObject({
      dispatchId: "d-tg",
      project: "/abs/repo",
      prompt: "do the thing",
      telegramChatId: 555,
      outcome: "started",
    });
    expect(await dispatchOriginChat("d-tg")).toBe(555);
  });

  it("returns null for unknown ids and dispatches without a Telegram origin", async () => {
    await recordDispatch(record({ dispatchId: "d-mcp", telegramChatId: null }));
    expect(await getDispatch("d-nope")).toBeNull();
    expect(await dispatchOriginChat("d-nope")).toBeNull();
    expect(await dispatchOriginChat("d-mcp")).toBeNull();
  });

  it("lists recent dispatches newest first, capped", async () => {
    await recordDispatch(record({ dispatchId: "d-a", at: 1 }));
    await recordDispatch(record({ dispatchId: "d-b", at: 2 }));
    await recordDispatch(record({ dispatchId: "d-c", at: 3 }));
    expect((await listDispatches()).map((r) => r.dispatchId)).toEqual(["d-c", "d-b", "d-a"]);
    expect((await listDispatches(2)).map((r) => r.dispatchId)).toEqual(["d-c", "d-b"]);
  });

  it("drops the oldest entries past the cap", async () => {
    for (let i = 0; i < DISPATCH_REGISTRY_CAP + 5; i++) {
      await recordDispatch(record({ dispatchId: `d-${i}`, at: i }));
    }
    const all = await listDispatches(DISPATCH_REGISTRY_CAP + 5);
    expect(all).toHaveLength(DISPATCH_REGISTRY_CAP);
    expect(all[0]!.dispatchId).toBe(`d-${DISPATCH_REGISTRY_CAP + 4}`);
    expect(await getDispatch("d-0")).toBeNull();
  });

  it("tolerates a missing or corrupt registry file", async () => {
    expect(await listDispatches()).toEqual([]);
    writeFileSync(join(dir, "oracle-dispatches.json"), "not json");
    expect(await listDispatches()).toEqual([]);
    await recordDispatch(record());
    expect(await listDispatches()).toHaveLength(1);
  });
});
