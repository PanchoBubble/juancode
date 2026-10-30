import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import {
  latestAssistantResponse,
  SessionNotifications,
  type NotificationEvent,
} from "./session-notifications.ts";

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
  it("supports all transitions or completion only, intersected with explicit states", async () => {
    const { store } = make();
    for (const mode of ["all", "done"] as const)
      await store.subscribe({ subscriber: mode, targetType: "session", targetId: "child", mode });
    await store.subscribe({
      subscriber: "exit",
      targetType: "session",
      targetId: "child",
      mode: "done",
      states: ["exited"],
    });
    await store.publish(event("idle", false));
    await store.publish(event("busy", false));
    await store.publish(event("waiting_input"));
    await store.publish(event("busy"));
    await store.publish(event("idle", false));
    await store.publish(event("exited"));
    await store.publish(event("failed"));
    expect((await store.inbox("all")).map((n) => n.state)).toEqual([
      "failed",
      "exited",
      "idle",
      "busy",
      "waiting_input",
      "busy",
    ]);
    expect((await store.inbox("done")).map((n) => n.state)).toEqual(["failed", "exited", "idle"]);
    expect((await store.inbox("exit")).map((n) => n.state)).toEqual(["exited"]);
  });

  it("filters each listener by literal case-insensitive response text before truncation", async () => {
    const { store, output } = make();
    await store.subscribe({
      subscriber: "match",
      targetType: "session",
      targetId: "child",
      mode: "includes",
      responseIncludes: "ready [yes]",
    });
    await store.subscribe({
      subscriber: "other",
      targetType: "session",
      targetId: "child",
      responseIncludes: "ship it",
    });
    output.mockResolvedValue("Not ready yet");
    await store.publish(event("idle"));
    await store.publish(event("busy"));
    output.mockResolvedValue("READY [yes] " + "x".repeat(7000));
    await store.publish(event("waiting_input"));
    await store.publish(event("waiting_input"));
    expect(await store.inbox("other")).toEqual([]);
    expect(await store.inbox("match")).toHaveLength(1);
    expect(output).toHaveBeenCalledTimes(2);
    await store.publish(event("busy"));
    output.mockRejectedValue(new Error("unavailable"));
    await store.publish(event("idle"));
    expect(await store.inbox("match")).toHaveLength(1);
  });

  it("persists filters and updates a subscription without changing its identity", async () => {
    const dir = mkdtempSync(join(tmpdir(), "notification-filter-"));
    dirs.push(dir);
    const path = join(dir, "notifications.sqlite");
    const first = make(path);
    const row = await first.store.subscribe({
      subscriber: "parent",
      targetType: "dispatch",
      targetId: "dispatch-1",
      mode: "done",
    });
    const updated = await first.store.subscribe({
      subscriber: "parent",
      targetType: "dispatch",
      targetId: "dispatch-1",
      responseIncludes: " final answer ",
    });
    expect(updated).toMatchObject({
      id: row.id,
      mode: "includes",
      responseIncludes: "final answer",
    });
    await first.store.close();
    stores.splice(stores.indexOf(first.store), 1);
    const second = make(path);
    expect(await second.store.list()).toEqual([updated]);
    await second.store.publish(event("idle"));
    expect(second.deliver).toHaveBeenCalledTimes(1);
  });

  it("migrates existing subscriptions without changing their states or dedupe", async () => {
    const dir = mkdtempSync(join(tmpdir(), "notification-migration-"));
    dirs.push(dir);
    const path = join(dir, "notifications.sqlite");
    const db = new DatabaseSync(path);
    db.exec(`CREATE TABLE subscriptions (
      id TEXT PRIMARY KEY, subscriber TEXT NOT NULL, target_type TEXT NOT NULL,
      target_id TEXT NOT NULL, source_session_id TEXT, states TEXT NOT NULL,
      last_state TEXT, UNIQUE(subscriber, target_type, target_id));
      INSERT INTO subscriptions VALUES ('legacy', 'parent', 'session', 'child', 'child', '["idle"]', 'idle');`);
    db.close();
    const { store, deliver } = make(path);
    expect((await store.list())[0]).toMatchObject({
      id: "legacy",
      mode: "all",
      responseIncludes: null,
      states: ["idle"],
      lastState: "idle",
    });
    await store.publish(event("idle"));
    expect(deliver).not.toHaveBeenCalled();
    await store.publish(event("busy"));
    await store.publish(event("idle"));
    expect(deliver).toHaveBeenCalledTimes(1);
  });

  it("rejects missing phrases and contradictory filters", async () => {
    const { store } = make();
    for (const filter of [
      { mode: "includes" as const },
      { responseIncludes: "  " },
      { mode: "done" as const, responseIncludes: "ready" },
    ])
      await expect(
        store.subscribe({
          subscriber: "parent",
          targetType: "session",
          targetId: "child",
          ...filter,
        }),
      ).rejects.toThrow("Invalid subscription");
  });

  it("reads the latest assistant turn and excludes earlier responses and user text", () => {
    const messages = [
      { seq: 1, role: "assistant" as const, text: "old match", turn: "old" },
      { seq: 2, role: "user" as const, text: "user match", turn: "new" },
      { seq: 3, role: "assistant" as const, text: "new part", turn: "new" },
      { seq: 4, role: "toolResult" as const, text: "tool match", turn: "new" },
      { seq: 5, role: "assistant" as const, text: "new answer", turn: "new" },
    ];
    expect(latestAssistantResponse(messages)).toBe("new part\n\nnew answer");
    expect(latestAssistantResponse(messages.slice(0, 2))).toBe("");
    expect(latestAssistantResponse(messages.map((m) => ({ ...m, turn: undefined })))).toBe(
      "new answer",
    );
    expect(latestAssistantResponse([])).toBe("");
  });

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
