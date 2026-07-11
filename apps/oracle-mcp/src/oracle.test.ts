import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { appendAsk, deleteSession, oracleDir, originSystemPrompt } from "./oracle.ts";

// The ask mailbox line shape is a contract with the Swift `OracleAsk` decoder in
// apps/native — if these keys or types drift, the native app silently skips the
// malformed line. Pin it here. (The dispatch mailbox shape is pinned in
// dispatch.test.ts alongside the WS-first path.)
describe("Oracle mailbox line shapes", () => {
  let dir: string;
  const prev = process.env.JUANCODE_ORACLE_DIR;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oracle-mcp-test-"));
    process.env.JUANCODE_ORACLE_DIR = dir;
  });

  afterEach(() => {
    if (prev === undefined) delete process.env.JUANCODE_ORACLE_DIR;
    else process.env.JUANCODE_ORACLE_DIR = prev;
    rmSync(dir, { recursive: true, force: true });
  });

  it("resolves the control dir from JUANCODE_ORACLE_DIR", () => {
    expect(oracleDir()).toBe(dir);
  });

  it("writes an ask line matching OracleAsk", async () => {
    await appendAsk("what's on the board?");
    const raw = readFileSync(join(dir, "ask.jsonl"), "utf8");
    const lines = raw.split("\n").filter(Boolean);
    expect(lines).toHaveLength(1);
    expect(JSON.parse(lines[0]!)).toEqual({ text: "what's on the board?" });
  });

  it("appends (does not overwrite) across calls", async () => {
    await appendAsk("first");
    await appendAsk("second");
    const lines = readFileSync(join(dir, "ask.jsonl"), "utf8").split("\n").filter(Boolean);
    expect(lines.map((l) => JSON.parse(l).text)).toEqual(["first", "second"]);
  });
});

describe("originSystemPrompt", () => {
  it("tells the Oracle to attribute dispatches to the originating Telegram chat", () => {
    const prompt = originSystemPrompt({ telegramChatId: 555 });
    expect(prompt).toContain("Telegram chat 555");
    expect(prompt).toContain('"telegramChatId": 555');
    expect(prompt).toContain("/api/dispatch");
  });

  it("is empty for turns with no known origin", () => {
    expect(originSystemPrompt()).toBe("");
    expect(originSystemPrompt({})).toBe("");
  });
});

describe("deleteSession", () => {
  const prev = process.env.JUANCODE_API;
  const realFetch = globalThis.fetch;

  beforeEach(() => {
    process.env.JUANCODE_API = "http://native.test";
  });
  afterEach(() => {
    if (prev === undefined) delete process.env.JUANCODE_API;
    else process.env.JUANCODE_API = prev;
    globalThis.fetch = realFetch;
    vi.restoreAllMocks();
  });

  it("DELETEs the session by id against the native app", async () => {
    const fetchMock = vi.fn(
      async (_url: string | URL, _init?: RequestInit) => new Response(null, { status: 204 }),
    );
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    await deleteSession("sess 1/weird");

    expect(fetchMock).toHaveBeenCalledOnce();
    const [url, init] = fetchMock.mock.calls[0]!;
    expect(url).toBe("http://native.test/api/sessions/sess%201%2Fweird");
    expect(init?.method).toBe("DELETE");
  });

  it("reports a clear error when the session is unknown", async () => {
    globalThis.fetch = (async () => new Response(null, { status: 404 })) as unknown as typeof fetch;
    await expect(deleteSession("nope")).rejects.toThrow(/not found/i);
  });

  it("reports a clear error when the native app is unreachable", async () => {
    globalThis.fetch = (async () => {
      throw new Error("ECONNREFUSED");
    }) as unknown as typeof fetch;
    await expect(deleteSession("x")).rejects.toThrow(/is the native app running/i);
  });
});
