import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { deriveClaudeUsage, deriveCodexUsage } from "./sessionUsage.ts";

const tmp = mkdtempSync(join(tmpdir(), "juancode-usage-"));
afterAll(() => rmSync(tmp, { recursive: true, force: true }));

const jsonl = (records: unknown[]) => records.map((r) => JSON.stringify(r)).join("\n") + "\n";

function claudeFixture(id: string, records: unknown[]): string {
  const root = join(tmp, `claude-${id}`);
  const dir = join(root, "-Users-someone-project");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `${id}.jsonl`), jsonl(records));
  return root;
}

function codexFixture(id: string, records: unknown[], name = "rollout-x.jsonl"): string {
  const root = join(tmp, `codex-${id}`);
  const dir = join(root, "2026", "06", "23");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, name), jsonl(records));
  return root;
}

const assistant = (
  msgId: string,
  requestId: string,
  usage: Record<string, number>,
  model = "claude-opus-4-8",
  costUSD?: number,
) => ({
  type: "assistant",
  requestId,
  ...(costUSD !== undefined ? { costUSD } : {}),
  message: { id: msgId, model, usage },
});

describe("deriveClaudeUsage", () => {
  it("sums tokens across turns and reports no cost when none is logged", async () => {
    const id = "11111111-1111-1111-1111-111111111111";
    const root = claudeFixture(id, [
      { type: "user", message: "hi" },
      assistant("m1", "r1", {
        input_tokens: 1000,
        output_tokens: 200,
        cache_read_input_tokens: 5000,
        cache_creation_input_tokens: 800,
      }),
      assistant("m2", "r2", { input_tokens: 10, output_tokens: 400 }),
    ]);
    const u = (await deriveClaudeUsage(id, root))!;
    expect(u.inputTokens).toBe(1010);
    expect(u.outputTokens).toBe(600);
    expect(u.cacheReadTokens).toBe(5000);
    expect(u.cacheWriteTokens).toBe(800);
    expect(u.totalTokens).toBe(1010 + 600 + 5000 + 800);
    // No `costUSD` in the transcript (subscription plan) → cost is null, never estimated.
    expect(u.costUsd).toBeNull();
  });

  it("sums a real per-turn cost when the transcript reports one", async () => {
    const id = "1a1a1a1a-1a1a-1a1a-1a1a-1a1a1a1a1a1a";
    const root = claudeFixture(id, [
      assistant("m1", "r1", { input_tokens: 100, output_tokens: 50 }, "claude-opus-4-8", 0.02),
      assistant("m2", "r2", { input_tokens: 10, output_tokens: 20 }, "claude-opus-4-8", 0.005),
    ]);
    const u = (await deriveClaudeUsage(id, root))!;
    expect(u.totalTokens).toBe(180);
    expect(u.costUsd).toBeCloseTo(0.025, 9);
  });

  it("dedups turns logged twice by message id + requestId", async () => {
    const id = "22222222-2222-2222-2222-222222222222";
    const dup = assistant("m1", "r1", { input_tokens: 100, output_tokens: 50 });
    const root = claudeFixture(id, [dup, dup, dup]);
    const u = (await deriveClaudeUsage(id, root))!;
    expect(u.inputTokens).toBe(100);
    expect(u.outputTokens).toBe(50);
  });

  it("ignores synthetic (local) messages", async () => {
    const id = "33333333-3333-3333-3333-333333333333";
    const root = claudeFixture(id, [
      assistant("m1", "r1", { input_tokens: 999, output_tokens: 999 }, "<synthetic>"),
      assistant("m2", "r2", { input_tokens: 10, output_tokens: 20 }),
    ]);
    const u = (await deriveClaudeUsage(id, root))!;
    expect(u.inputTokens).toBe(10);
    expect(u.outputTokens).toBe(20);
  });

  it("counts tokens regardless of model and reports null cost without a cost field", async () => {
    const id = "44444444-4444-4444-4444-444444444444";
    const root = claudeFixture(id, [
      assistant("m1", "r1", { input_tokens: 10, output_tokens: 20 }, "some-future-model"),
    ]);
    const u = (await deriveClaudeUsage(id, root))!;
    expect(u.totalTokens).toBe(30);
    expect(u.costUsd).toBeNull();
  });

  it("returns null before any assistant turn", async () => {
    const id = "55555555-5555-5555-5555-555555555555";
    const root = claudeFixture(id, [{ type: "user", message: "hi" }]);
    expect(await deriveClaudeUsage(id, root)).toBeNull();
  });

  it("returns null when the transcript is missing", async () => {
    const root = claudeFixture("present", [assistant("m", "r", { input_tokens: 1, output_tokens: 1 })]);
    expect(await deriveClaudeUsage("nope-missing", root)).toBeNull();
  });
});

describe("deriveCodexUsage", () => {
  const tokenCount = (info: Record<string, number>) => ({
    type: "event_msg",
    payload: { type: "token_count", info: { total_token_usage: info } },
  });

  it("takes the last cumulative token_count and reports no cost", async () => {
    const id = "66666666-6666-6666-6666-666666666666";
    const root = codexFixture(id, [
      { type: "session_meta", payload: { id, cwd: "/x" } },
      tokenCount({ input_tokens: 100, cached_input_tokens: 0, output_tokens: 10, total_tokens: 110 }),
      tokenCount({
        input_tokens: 5000,
        cached_input_tokens: 4000,
        output_tokens: 600,
        total_tokens: 5600,
      }),
    ]);
    const u = (await deriveCodexUsage(id, root))!;
    expect(u.inputTokens).toBe(1000); // 5000 - 4000 cached
    expect(u.cacheReadTokens).toBe(4000);
    expect(u.outputTokens).toBe(600);
    expect(u.totalTokens).toBe(5600);
    expect(u.costUsd).toBeNull();
  });

  it("returns null when the matching session has no token_count yet", async () => {
    const id = "77777777-7777-7777-7777-777777777777";
    const root = codexFixture(id, [{ type: "session_meta", payload: { id, cwd: "/x" } }]);
    expect(await deriveCodexUsage(id, root)).toBeNull();
  });

  it("ignores rollouts for other sessions", async () => {
    const root = codexFixture("other", [
      { type: "session_meta", payload: { id: "other", cwd: "/x" } },
      tokenCount({ input_tokens: 1, cached_input_tokens: 0, output_tokens: 1, total_tokens: 2 }),
    ]);
    expect(await deriveCodexUsage("not-me", root)).toBeNull();
  });
});
