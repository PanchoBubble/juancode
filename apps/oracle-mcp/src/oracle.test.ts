import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { appendAsk, appendDispatch, oracleDir } from "./oracle.ts";

// The dispatch/ask mailbox line shapes are a contract with the Swift
// `OracleDispatch` / `OracleAsk` decoders in apps/native — if these keys or types
// drift, the native app silently skips the malformed line. Pin them here.
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

  it("writes a dispatch line matching OracleDispatch (one JSON object + newline)", async () => {
    await appendDispatch({ project: "/abs/repo", prompt: "do the thing" });
    await appendDispatch({
      project: "/other",
      prompt: "isolated",
      provider: "codex",
      worktree: true,
    });

    const raw = readFileSync(join(dir, "dispatch.jsonl"), "utf8");
    const lines = raw.split("\n").filter(Boolean);
    expect(lines).toHaveLength(2);

    const a = JSON.parse(lines[0]!);
    expect(a).toEqual({
      project: "/abs/repo",
      prompt: "do the thing",
      provider: "claude",
      worktree: false,
    });

    const b = JSON.parse(lines[1]!);
    expect(b).toEqual({
      project: "/other",
      prompt: "isolated",
      provider: "codex",
      worktree: true,
    });
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
