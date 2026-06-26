import { mkdtempSync, mkdirSync, writeFileSync, appendFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { TranscriptTail, resolveTranscriptFile } from "./structuredTranscript.ts";
import type { StructuredEvent } from "./protocol.ts";

const tmp = mkdtempSync(join(tmpdir(), "juancode-structured-"));
afterAll(() => rmSync(tmp, { recursive: true, force: true }));

const jsonl = (records: unknown[]) => records.map((r) => JSON.stringify(r)).join("\n") + "\n";

function claudeFixture(id: string, records: unknown[]): { root: string; file: string } {
  const root = join(tmp, `claude-${id}`);
  const dir = join(root, "-Users-someone-project");
  mkdirSync(dir, { recursive: true });
  const file = join(dir, `${id}.jsonl`);
  writeFileSync(file, jsonl(records));
  return { root, file };
}

function codexFixture(id: string, records: unknown[]): { root: string; file: string } {
  const root = join(tmp, `codex-${id}`);
  const dir = join(root, "2026", "06", "23");
  mkdirSync(dir, { recursive: true });
  const file = join(dir, "rollout-test.jsonl");
  writeFileSync(file, jsonl([{ type: "session_meta", payload: { id } }, ...records]));
  return { root, file };
}

describe("resolveTranscriptFile", () => {
  it("finds a Claude transcript by basename", async () => {
    const { root, file } = claudeFixture("sess-a", [{ type: "user", message: { content: "hi" } }]);
    expect(await resolveTranscriptFile("claude", "sess-a", { claudeProjects: root })).toBe(file);
    expect(await resolveTranscriptFile("claude", "missing", { claudeProjects: root })).toBeNull();
  });

  it("finds a Codex rollout by its session_meta id", async () => {
    const { root, file } = codexFixture("sess-c", [
      { payload: { type: "agent_message", message: "yo" } },
    ]);
    expect(await resolveTranscriptFile("codex", "sess-c", { codexSessions: root })).toBe(file);
    expect(await resolveTranscriptFile("codex", "nope", { codexSessions: root })).toBeNull();
  });
});

describe("TranscriptTail", () => {
  it("emits the full backlog with reset, then only appended events", async () => {
    const { root, file } = claudeFixture("tail-1", [
      { type: "user", message: { role: "user", content: "first" } },
      {
        type: "assistant",
        message: { role: "assistant", content: [{ type: "text", text: "hello" }] },
      },
    ]);

    const batches: { events: StructuredEvent[]; reset: boolean }[] = [];
    const tail = new TranscriptTail(
      "claude",
      "tail-1",
      (events, reset) => batches.push({ events, reset }),
      {
        claudeProjects: root,
      },
    );

    await tail.poll();
    expect(batches).toHaveLength(1);
    expect(batches[0]!.reset).toBe(true);
    expect(batches[0]!.events.map((e) => e.kind)).toEqual(["user", "assistant"]);

    // A poll with no new bytes emits nothing further.
    await tail.poll();
    expect(batches).toHaveLength(1);

    // Append a new turn; the next poll emits just the new event, reset:false.
    appendFileSync(
      file,
      jsonl([
        {
          type: "assistant",
          message: { role: "assistant", content: [{ type: "text", text: "more" }] },
        },
      ]),
    );
    await tail.poll();
    expect(batches).toHaveLength(2);
    expect(batches[1]!.reset).toBe(false);
    expect(batches[1]!.events).toHaveLength(1);
    expect(batches[1]!.events[0]!.text).toBe("more");
  });

  it("sends an empty reset backlog while the transcript is unresolved", async () => {
    const batches: { events: StructuredEvent[]; reset: boolean }[] = [];
    const tail = new TranscriptTail(
      "claude",
      "tail-missing",
      (events, reset) => batches.push({ events, reset }),
      {
        claudeProjects: join(tmp, "claude-tail-1"),
      },
    );
    // The file for "tail-missing" doesn't exist — poll resolves nothing and stays quiet.
    await tail.poll();
    expect(batches).toHaveLength(0);
  });

  it("re-reads a lazily-resolved (getter) session id until it appears", async () => {
    const { root, file } = claudeFixture("tail-late", [
      { type: "user", message: { role: "user", content: "late" } },
    ]);
    let id: string | null = null; // id not known when the view first opens
    const batches: { events: StructuredEvent[]; reset: boolean }[] = [];
    const tail = new TranscriptTail(
      "claude",
      () => id,
      (events, reset) => batches.push({ events, reset }),
      {
        claudeProjects: root,
      },
    );

    await tail.poll(); // id still null — nothing emitted yet
    expect(batches).toHaveLength(0);

    id = "tail-late"; // discovered after spawn
    await tail.poll();
    expect(batches).toHaveLength(1);
    expect(batches[0]!.events[0]!.text).toBe("late");
    expect(file).toContain("tail-late.jsonl");
  });

  it("does not duplicate events across a backlog read split over two polls", async () => {
    const { file, root } = claudeFixture("tail-split", [
      { type: "user", message: { role: "user", content: "a" } },
    ]);
    const ids: string[] = [];
    const tail = new TranscriptTail(
      "claude",
      "tail-split",
      (events) => ids.push(...events.map((e) => e.id)),
      {
        claudeProjects: root,
      },
    );
    await tail.poll();
    appendFileSync(file, jsonl([{ type: "user", message: { role: "user", content: "b" } }]));
    await tail.poll();
    expect(new Set(ids).size).toBe(ids.length); // all ids unique
    expect(ids).toHaveLength(2);
  });
});
