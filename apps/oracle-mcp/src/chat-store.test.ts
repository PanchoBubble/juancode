import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  listChatSessions,
  removeChatSession,
  touchChatSession,
  upsertChatSession,
} from "./chat-store.ts";

describe("phone-chat session store", () => {
  let dir: string;
  const prev = process.env.JUANCODE_ORACLE_DIR;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oracle-chat-test-"));
    process.env.JUANCODE_ORACLE_DIR = dir;
  });

  afterEach(() => {
    if (prev === undefined) delete process.env.JUANCODE_ORACLE_DIR;
    else process.env.JUANCODE_ORACLE_DIR = prev;
    rmSync(dir, { recursive: true, force: true });
  });

  it("starts empty", async () => {
    expect(await listChatSessions()).toEqual([]);
  });

  it("creates a session with a title on first upsert", async () => {
    await upsertChatSession("s1", "Plan the release", 1000);
    const all = await listChatSessions();
    expect(all).toHaveLength(1);
    expect(all[0]!).toMatchObject({ id: "s1", title: "Plan the release", createdAt: 1000 });
  });

  it("falls back to a default title when none is given", async () => {
    await upsertChatSession("s1", undefined, 1000);
    expect((await listChatSessions())[0]!.title).toBe("New chat");
  });

  it("keeps the title and bumps updatedAt when re-upserting the same id", async () => {
    await upsertChatSession("s1", "Original", 1000);
    await upsertChatSession("s1", undefined, 2000);
    const all = await listChatSessions();
    expect(all).toHaveLength(1);
    expect(all[0]!).toMatchObject({ title: "Original", createdAt: 1000, updatedAt: 2000 });
  });

  it("lists most-recently-updated first", async () => {
    await upsertChatSession("s1", "first", 1000);
    await upsertChatSession("s2", "second", 3000);
    await upsertChatSession("s3", "third", 2000);
    expect((await listChatSessions()).map((s) => s.id)).toEqual(["s2", "s3", "s1"]);
  });

  it("touch bumps updatedAt for a known id and no-ops otherwise", async () => {
    await upsertChatSession("s1", "a", 1000);
    await touchChatSession("s1", 5000);
    expect((await listChatSessions())[0]!.updatedAt).toBe(5000);
    await touchChatSession("nope", 9000);
    expect(await listChatSessions()).toHaveLength(1);
  });

  it("removes by id", async () => {
    await upsertChatSession("s1", "a", 1000);
    await upsertChatSession("s2", "b", 2000);
    await removeChatSession("s1");
    expect((await listChatSessions()).map((s) => s.id)).toEqual(["s2"]);
  });

  it("migrates the legacy single-session pointer once", async () => {
    writeFileSync(join(dir, "phone-chat-session.txt"), "legacy-id\n");
    const all = await listChatSessions(1234);
    expect(all).toHaveLength(1);
    expect(all[0]!).toMatchObject({ id: "legacy-id", title: "Earlier chat", createdAt: 1234 });
    // Subsequent reads see the persisted store, not a re-migration.
    expect((await listChatSessions()).map((s) => s.id)).toEqual(["legacy-id"]);
  });

  it("tolerates a corrupt store file", async () => {
    writeFileSync(join(dir, "oracle-chat-sessions.json"), "{ not json");
    expect(await listChatSessions()).toEqual([]);
  });
});
