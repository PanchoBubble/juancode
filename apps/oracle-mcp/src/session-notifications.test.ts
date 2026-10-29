import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionNotifications, type NotificationEvent } from "./session-notifications.ts";

const stores: SessionNotifications[] = [];
const dirs: string[] = [];
afterEach(async () => {
  await Promise.all(stores.splice(0).map((s) => s.close()));
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});
function make(path = ":memory:") {
  const output = vi.fn(async () => "The final answer");
  const deliver = vi.fn(async (_id: string, _text: string) => {});
  const store = new SessionNotifications(path, { output, deliver });
  stores.push(store);
  return { store, output, deliver };
}
const event = (state: NotificationEvent["state"], notify = true): NotificationEvent => ({
  sessionId: "child",
  dispatchId: "dispatch-1",
  state,
  notify,
});

describe("durable session notifications", () => {
  it("ignores initial snapshots, delivers questions and completion with output, dedupes repeated events", async () => {
    const { store, deliver, output } = make();
    const row = await store.subscribe({
      subscriber: "parent",
      targetType: "session",
      targetId: "child",
    });
    await store.publish(event("idle", false));
    await store.publish(event("busy", false));
    expect(deliver).not.toHaveBeenCalled();
    await store.publish(event("waiting_input"));
    await store.publish(event("waiting_input"));
    expect(deliver).toHaveBeenCalledTimes(1);
    expect(deliver.mock.calls[0]![1]).toContain("The final answer");
    await store.publish(event("busy"));
    await store.publish(event("idle"));
    expect((await store.inbox("parent")).map((n) => n.state)).toEqual(["idle", "waiting_input"]);
    expect(output).toHaveBeenCalledTimes(2);
    expect((await store.list())[0]!.id).toBe(row.id);
  });

  it("binds queued dispatches and routes an exit frame without a dispatch id", async () => {
    const { store, deliver } = make();
    await store.subscribe({ subscriber: "parent", targetType: "dispatch", targetId: "dispatch-1" });
    await store.publish(event("busy"));
    await store.publish({ sessionId: "other", state: "idle", notify: true });
    expect(deliver).not.toHaveBeenCalled();
    await store.publish({ sessionId: "child", state: "exited", notify: true });
    expect((await store.inbox("parent"))[0]!.state).toBe("exited");
  });

  it("persists subscriptions, failed delivery and dedupe across restarts", async () => {
    const dir = mkdtempSync(join(tmpdir(), "notification-test-"));
    dirs.push(dir);
    const path = join(dir, "notifications.sqlite");
    const first = make(path);
    first.deliver.mockRejectedValue(new Error("offline"));
    await first.store.subscribe({ subscriber: "parent", targetType: "session", targetId: "child" });
    await first.store.publish(event("busy"));
    await first.store.publish(event("idle"));
    const pending = (await first.store.inbox("parent"))[0]!;
    expect(pending.delivered).toBe(false);
    expect(pending.deliveryError).toContain("offline");
    await first.store.close();
    stores.splice(stores.indexOf(first.store), 1);
    const second = make(path);
    await second.store.retry();
    expect(second.deliver).toHaveBeenCalledTimes(1);
    expect((await second.store.inbox("parent"))[0]).toMatchObject({
      id: pending.id,
      delivered: true,
    });
    await second.store.publish(event("idle"));
    expect(second.deliver).toHaveBeenCalledTimes(1);
    expect(second.deliver.mock.calls[0]![1]).toBe(first.deliver.mock.calls[0]![1]);
  });

  it("recovers a busy to idle edge missed during a disconnection", async () => {
    const { store } = make();
    await store.subscribe({ subscriber: "parent", targetType: "session", targetId: "child" });
    await store.publish(event("busy"));
    await store.publish(event("idle", false));
    expect((await store.inbox("parent"))[0]!.state).toBe("idle");
  });

  it("fans out one bounded output read and supports explicit working updates", async () => {
    const { store, output, deliver } = make();
    for (const subscriber of ["a", "b"])
      await store.subscribe({
        subscriber,
        targetType: "session",
        targetId: "child",
        states: ["busy", "idle"],
      });
    output.mockResolvedValue("x".repeat(9000));
    await Promise.all([store.publish(event("busy")), store.publish(event("idle"))]);
    expect(output).toHaveBeenCalledTimes(1);
    expect(deliver).toHaveBeenCalledTimes(4);
    expect((await store.inbox("a"))[0]!.output).toHaveLength(6000);
  });

  it("refuses self subscriptions and cycles, including late-bound dispatch cycles", async () => {
    const { store, deliver } = make();
    await expect(
      store.subscribe({ subscriber: "a", targetType: "session", targetId: "a" }),
    ).rejects.toThrow(/cycle/);
    await store.subscribe({ subscriber: "a", targetType: "session", targetId: "b" });
    await store.subscribe({ subscriber: "b", targetType: "session", targetId: "c" });
    await expect(
      store.subscribe({ subscriber: "c", targetType: "session", targetId: "a" }),
    ).rejects.toThrow(/cycle/);
    await store.subscribe({ subscriber: "c", targetType: "dispatch", targetId: "late" });
    await store.publish({ sessionId: "a", dispatchId: "late", state: "idle", notify: true });
    expect(deliver).not.toHaveBeenCalled();
  });

  it("reports unavailable output explicitly and cancels pending messages on unsubscribe", async () => {
    const { store, output, deliver } = make();
    const row = await store.subscribe({
      subscriber: "parent",
      targetType: "session",
      targetId: "child",
    });
    output.mockRejectedValue(new Error("transcript unavailable"));
    deliver.mockRejectedValue(new Error("offline"));
    await store.publish(event("idle"));
    expect((await store.inbox("parent"))[0]!.outputError).toContain("transcript unavailable");
    await store.unsubscribe(row.id);
    await store.retry();
    expect(deliver).toHaveBeenCalledTimes(1);
    expect(await store.inbox("parent")).toEqual([]);
  });

  it("retains failure reasons for queued dispatches that never get a session", async () => {
    const { store, output } = make();
    await store.subscribe({ subscriber: "parent", targetType: "dispatch", targetId: "dispatch-1" });
    await store.publish({
      sessionId: "",
      dispatchId: "dispatch-1",
      state: "failed",
      notify: true,
      error: "Invalid cwd",
    });
    expect((await store.inbox("parent"))[0]!.output).toBe("Invalid cwd");
    expect(output).not.toHaveBeenCalled();
  });
});
