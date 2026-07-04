import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  observeSessionForOracle,
  resolveObserverChatIds,
  unobserveSessionForOracle,
} from "./observer-trigger.ts";
import { observerChats } from "./telegram-observe.ts";
import { setTelegramSession } from "./telegram-store.ts";

// A native /api/sessions payload with one known session.
const SESSIONS = [
  { id: "sess-1", title: "Build the thing", cwd: "/Users/x/work/juancode", provider: "claude", status: "running" },
];
const fetchSessions = () => Promise.resolve(SESSIONS);

describe("observer-trigger (Oracle/MCP/HTTP observe)", () => {
  let dir: string;
  const prevDir = process.env.JUANCODE_ORACLE_DIR;
  const prevAllowed = process.env.ALLOWED_USER_IDS;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oracle-observer-trigger-test-"));
    process.env.JUANCODE_ORACLE_DIR = dir;
    delete process.env.ALLOWED_USER_IDS;
  });

  afterEach(() => {
    if (prevDir === undefined) delete process.env.JUANCODE_ORACLE_DIR;
    else process.env.JUANCODE_ORACLE_DIR = prevDir;
    if (prevAllowed === undefined) delete process.env.ALLOWED_USER_IDS;
    else process.env.ALLOWED_USER_IDS = prevAllowed;
    rmSync(dir, { recursive: true, force: true });
  });

  describe("resolveObserverChatIds", () => {
    it("is empty with no known chats and no allowlist", async () => {
      expect(await resolveObserverChatIds()).toEqual([]);
    });

    it("unions known chats with allowlisted ids, deduped, known first", async () => {
      await setTelegramSession(100, "claude-a");
      await setTelegramSession(200, "claude-b");
      process.env.ALLOWED_USER_IDS = "200, 300";
      // 200 appears in both — deduped; order is known (100,200) then new allowed (300).
      expect(await resolveObserverChatIds()).toEqual([100, 200, 300]);
    });

    it("falls back to the allowlist when no chat has messaged yet", async () => {
      process.env.ALLOWED_USER_IDS = "42";
      expect(await resolveObserverChatIds()).toEqual([42]);
    });
  });

  describe("observeSessionForOracle", () => {
    it("subscribes every resolved chat to a known session", async () => {
      await setTelegramSession(100, "claude-a");
      process.env.ALLOWED_USER_IDS = "300";
      const out = await observeSessionForOracle("sess-1", fetchSessions);
      expect(out.found).toBe(true);
      expect(out.reachable).toBe(true);
      expect(out.title).toBe("Build the thing");
      expect(out.project).toBe("juancode");
      expect(out.chatIds).toEqual([100, 300]);
      expect(out.changed).toBe(2);
      expect((await observerChats("sess-1")).sort()).toEqual([100, 300]);
    });

    it("does not subscribe an unknown id when the app is reachable", async () => {
      process.env.ALLOWED_USER_IDS = "300";
      const out = await observeSessionForOracle("nope", fetchSessions);
      expect(out.reachable).toBe(true);
      expect(out.found).toBe(false);
      expect(out.chatIds).toEqual([]);
      expect(out.changed).toBe(0);
      expect(await observerChats("nope")).toEqual([]);
    });

    it("subscribes anyway when the native app is unreachable", async () => {
      process.env.ALLOWED_USER_IDS = "300";
      const throwing = () => Promise.reject(new Error("app down"));
      const out = await observeSessionForOracle("sess-1", throwing);
      expect(out.reachable).toBe(false);
      expect(out.found).toBe(false);
      expect(out.title).toBeNull();
      expect(out.chatIds).toEqual([300]);
      expect(await observerChats("sess-1")).toEqual([300]);
    });

    it("records the observer but reports no target when no chat is set up", async () => {
      const out = await observeSessionForOracle("sess-1", fetchSessions);
      expect(out.found).toBe(true);
      expect(out.chatIds).toEqual([]);
      expect(out.changed).toBe(0);
    });

    it("is idempotent across repeat observes", async () => {
      process.env.ALLOWED_USER_IDS = "300";
      await observeSessionForOracle("sess-1", fetchSessions);
      await observeSessionForOracle("sess-1", fetchSessions);
      expect(await observerChats("sess-1")).toEqual([300]);
    });
  });

  describe("unobserveSessionForOracle", () => {
    it("clears every chat observing the session", async () => {
      await setTelegramSession(100, "claude-a");
      process.env.ALLOWED_USER_IDS = "300";
      await observeSessionForOracle("sess-1", fetchSessions);
      const out = await unobserveSessionForOracle("sess-1", fetchSessions);
      expect(out.changed).toBe(2);
      expect(out.chatIds.sort()).toEqual([100, 300]);
      expect(await observerChats("sess-1")).toEqual([]);
    });

    it("reports nothing to stop when unobserved", async () => {
      const out = await unobserveSessionForOracle("sess-1", fetchSessions);
      expect(out.changed).toBe(0);
      expect(out.chatIds).toEqual([]);
    });
  });
});
