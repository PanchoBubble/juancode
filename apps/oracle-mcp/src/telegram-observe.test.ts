import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  OUTBOUND_CAP,
  listObserved,
  lookupOutbound,
  observeSession,
  observerChats,
  recordOutbound,
  unobserveSession,
} from "./telegram-observe.ts";

describe("telegram observe stores", () => {
  let dir: string;
  const prev = process.env.JUANCODE_ORACLE_DIR;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oracle-telegram-observe-test-"));
    process.env.JUANCODE_ORACLE_DIR = dir;
  });

  afterEach(() => {
    if (prev === undefined) delete process.env.JUANCODE_ORACLE_DIR;
    else process.env.JUANCODE_ORACLE_DIR = prev;
    rmSync(dir, { recursive: true, force: true });
  });

  describe("observers", () => {
    it("starts empty", async () => {
      expect(await listObserved(1)).toEqual([]);
      expect(await observerChats("s1")).toEqual([]);
    });

    it("observes idempotently and lists per chat", async () => {
      await observeSession(1, "s1", 10);
      await observeSession(1, "s1", 20);
      await observeSession(1, "s2", 30);
      await observeSession(2, "s1", 40);
      expect(await listObserved(1)).toEqual(["s1", "s2"]);
      expect(await listObserved(2)).toEqual(["s1"]);
      expect((await observerChats("s1")).sort()).toEqual([1, 2]);
    });

    it("unobserves one session, returning the removed count", async () => {
      await observeSession(1, "s1", 10);
      await observeSession(1, "s2", 20);
      expect(await unobserveSession(1, "s1")).toBe(1);
      expect(await listObserved(1)).toEqual(["s2"]);
      expect(await unobserveSession(1, "s1")).toBe(0);
    });

    it("unobserves everything for a chat when no session is given", async () => {
      await observeSession(1, "s1", 10);
      await observeSession(1, "s2", 20);
      await observeSession(2, "s1", 30);
      expect(await unobserveSession(1)).toBe(2);
      expect(await listObserved(1)).toEqual([]);
      expect(await listObserved(2)).toEqual(["s1"]);
    });

    it("tolerates a corrupt store file", async () => {
      writeFileSync(join(dir, "oracle-telegram-observers.json"), "{nope");
      expect(await listObserved(1)).toEqual([]);
      await observeSession(1, "s1", 10);
      expect(await listObserved(1)).toEqual(["s1"]);
    });
  });

  describe("outbound correlation", () => {
    const ref = (messageId: number, sessionId = "s1") => ({
      chatId: 1,
      messageId,
      sessionId,
      title: "t",
      at: 100,
    });

    it("records and looks up by chat + message id", async () => {
      await recordOutbound(ref(33));
      expect(await lookupOutbound(1, 33)).toMatchObject({ sessionId: "s1", title: "t" });
      expect(await lookupOutbound(1, 34)).toBeNull();
      expect(await lookupOutbound(2, 33)).toBeNull();
    });

    it("caps the log, dropping the oldest entries", async () => {
      for (let i = 0; i < OUTBOUND_CAP + 5; i++) await recordOutbound(ref(i));
      expect(await lookupOutbound(1, 0)).toBeNull();
      expect(await lookupOutbound(1, OUTBOUND_CAP + 4)).not.toBeNull();
    });
  });
});
