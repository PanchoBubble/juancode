import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type * as DbModule from "./db.ts";

// Point the DB at a throwaway dir BEFORE importing db.ts (it opens sqlite on import).
const tmp = mkdtempSync(join(tmpdir(), "juancode-mq-"));
process.env.JUANCODE_DATA_DIR = tmp;

let messageQueueDb: typeof DbModule.messageQueueDb;

beforeAll(async () => {
  ({ messageQueueDb } = await import("./db.ts"));
});

afterAll(() => rmSync(tmp, { recursive: true, force: true }));

describe("messageQueueDb", () => {
  it("queues, lists in insertion order, peeks the head, and removes", () => {
    const s = "session-1";
    const a = messageQueueDb.add(s, "first");
    const b = messageQueueDb.add(s, "second");
    const c = messageQueueDb.add(s, "third");

    expect(messageQueueDb.list(s).map((m) => m.text)).toEqual(["first", "second", "third"]);
    expect(messageQueueDb.first(s)?.id).toBe(a.id);

    // Cancel a middle item — order of the rest is preserved.
    expect(messageQueueDb.remove(s, b.id)).toBe(true);
    expect(messageQueueDb.list(s).map((m) => m.text)).toEqual(["first", "third"]);

    // Deliver the head, then the next becomes the head.
    expect(messageQueueDb.remove(s, a.id)).toBe(true);
    expect(messageQueueDb.first(s)?.id).toBe(c.id);

    expect(messageQueueDb.remove(s, c.id)).toBe(true);
    expect(messageQueueDb.first(s)).toBeNull();
  });

  it("isolates queues per session", () => {
    messageQueueDb.add("session-A", "a-msg");
    messageQueueDb.add("session-B", "b-msg");
    expect(messageQueueDb.list("session-A").map((m) => m.text)).toEqual(["a-msg"]);
    expect(messageQueueDb.list("session-B").map((m) => m.text)).toEqual(["b-msg"]);
    // Removing by the wrong session id is a no-op.
    const [aItem] = messageQueueDb.list("session-A");
    expect(messageQueueDb.remove("session-B", aItem!.id)).toBe(false);
    expect(messageQueueDb.list("session-A")).toHaveLength(1);
  });
});
