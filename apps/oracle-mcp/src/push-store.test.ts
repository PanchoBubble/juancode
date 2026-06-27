import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  addSubscription,
  loadOrCreateVapidKeys,
  loadSubscriptions,
  removeSubscription,
  type StoredPushSubscription,
} from "./push-store.ts";

const sub = (endpoint: string, auth = "a"): StoredPushSubscription => ({
  endpoint,
  keys: { p256dh: "p", auth },
});

describe("push subscription store", () => {
  let dir: string;
  const prev = process.env.JUANCODE_ORACLE_DIR;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oracle-push-test-"));
    process.env.JUANCODE_ORACLE_DIR = dir;
  });

  afterEach(() => {
    if (prev === undefined) delete process.env.JUANCODE_ORACLE_DIR;
    else process.env.JUANCODE_ORACLE_DIR = prev;
    rmSync(dir, { recursive: true, force: true });
  });

  it("starts empty", async () => {
    expect(await loadSubscriptions()).toEqual([]);
  });

  it("adds a subscription", async () => {
    await addSubscription(sub("https://push/1"));
    const all = await loadSubscriptions();
    expect(all).toHaveLength(1);
    expect(all[0]!.endpoint).toBe("https://push/1");
  });

  it("dedupes by endpoint, replacing the keys", async () => {
    await addSubscription(sub("https://push/1", "old"));
    await addSubscription(sub("https://push/1", "new"));
    const all = await loadSubscriptions();
    expect(all).toHaveLength(1);
    expect(all[0]!.keys.auth).toBe("new");
  });

  it("keeps distinct endpoints", async () => {
    await addSubscription(sub("https://push/1"));
    await addSubscription(sub("https://push/2"));
    expect(await loadSubscriptions()).toHaveLength(2);
  });

  it("removes by endpoint", async () => {
    await addSubscription(sub("https://push/1"));
    await addSubscription(sub("https://push/2"));
    await removeSubscription("https://push/1");
    const all = await loadSubscriptions();
    expect(all.map((s) => s.endpoint)).toEqual(["https://push/2"]);
  });

  it("rejects an invalid subscription", async () => {
    await expect(
      addSubscription({ endpoint: "", keys: { p256dh: "p", auth: "a" } }),
    ).rejects.toThrow();
  });

  it("generates and persists a VAPID keypair on first call, reuses it after", async () => {
    let calls = 0;
    const gen = () => {
      calls++;
      return { publicKey: "pub", privateKey: "priv" };
    };
    const first = await loadOrCreateVapidKeys(gen);
    expect(first).toEqual({ publicKey: "pub", privateKey: "priv" });
    const second = await loadOrCreateVapidKeys(gen);
    expect(second).toEqual(first);
    expect(calls).toBe(1);
  });
});
