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

  it("delivers only the child's RESULT block, falling back to truncated output", async () => {
    const { store, output } = make();
    await store.subscribe({ subscriber: "p", targetType: "session", targetId: "child" });
    output.mockResolvedValue("noisy log\n".repeat(50) + "RESULT\nstatus: done\nchanged: x");
    await store.publish(event("idle"));
    await store.publish(event("busy"));
    output.mockResolvedValue("y".repeat(7000));
    await store.publish(event("idle"));
    const [fallback, block] = await store.inbox("p");
    expect(block!.output).toBe("RESULT\nstatus: done\nchanged: x");
    expect(fallback!.output).toBe("y".repeat(6000));
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

  it("keeps a dispatch watch across a question turn until the child posts its RESULT", async () => {
    const { store, deliver, output } = make();
    await store.subscribe({ subscriber: "parent", targetType: "dispatch", targetId: "dispatch-1" });
    output.mockResolvedValueOnce("Should I use Postgres or SQLite?");
    await store.publish(event("busy"));
    await store.publish(event("idle"));
    expect(deliver).toHaveBeenCalledTimes(1);
    // The parent answers; the child's next turn must still reach it.
    output.mockResolvedValueOnce("RESULT\nstatus: question\nchanged: none");
    await store.publish(event("busy"));
    await store.publish(event("idle"));
    expect(deliver).toHaveBeenCalledTimes(2);
    output.mockResolvedValueOnce("Done.\nRESULT\nstatus: done\nchanged: a.ts");
    await store.publish(event("busy"));
    await store.publish(event("idle"));
    expect(deliver).toHaveBeenCalledTimes(3);
    expect(deliver.mock.calls[2]![1]).toContain("status: done");
    expect(await store.list("parent")).toEqual([]);
    await store.publish(event("busy"));
    await store.publish(event("idle"));
    await store.publish(event("exited"));
    expect(deliver).toHaveBeenCalledTimes(3);
  });

  it("ends dispatch alerts after completion while keeping explicit session watches", async () => {
    const { store, deliver, output } = make();
    output.mockResolvedValue("RESULT\nstatus: done");
    await store.subscribe({ subscriber: "parent", targetType: "dispatch", targetId: "dispatch-1" });
    await store.subscribe({ subscriber: "watcher", targetType: "session", targetId: "child" });
    await store.publish(event("idle", false));
    expect(await store.list("parent")).toHaveLength(1);
    await store.publish(event("busy"));
    await store.publish(event("waiting_input"));
    expect(await store.list("parent")).toHaveLength(1);
    await store.publish(event("busy"));
    await store.publish(event("idle", false));
    expect(await store.list("parent")).toEqual([]);
    expect((await store.inbox("parent")).map((n) => n.state)).toEqual(["idle", "waiting_input"]);
    deliver.mockClear();
    await store.publish(event("idle"));
    await store.publish(event("busy"));
    await store.publish(event("idle"));
    await store.publish({ sessionId: "child", state: "exited", notify: true });
    expect(deliver.mock.calls.map(([id]) => id)).toEqual(["watcher", "watcher"]);
  });

  it.each(["idle", "exited", "failed"] as const)(
    "retains the final %s dispatch alert for retry across restarts",
    async (state) => {
      const dir = mkdtempSync(join(tmpdir(), "dispatch-completion-"));
      dirs.push(dir);
      const path = join(dir, "notifications.sqlite");
      const first = make(path);
      first.deliver.mockRejectedValue(new Error("offline"));
      first.output.mockResolvedValue("RESULT\nstatus: done");
      await first.store.subscribe({
        subscriber: "parent",
        targetType: "dispatch",
        targetId: "dispatch-1",
      });
      await first.store.publish(event(state));
      expect(await first.store.list()).toEqual([]);
      const pending = (await first.store.inbox("parent"))[0]!;
      expect(pending.delivered).toBe(false);
      await first.store.close();
      stores.splice(stores.indexOf(first.store), 1);
      const second = make(path);
      await second.store.retry();
      await second.store.publish(event("busy"));
      await second.store.publish(event("idle"));
      await second.store.publish(event("exited"));
      expect(second.deliver).toHaveBeenCalledTimes(1);
      expect(await second.store.inbox("parent")).toEqual([
        expect.objectContaining({ id: pending.id, state, delivered: true }),
      ]);
    },
  );

  it("retires a completed dispatch even when its final state is filtered out", async () => {
    const { store, deliver, output } = make();
    output.mockResolvedValue("RESULT\nstatus: blocked");
    await store.subscribe({
      subscriber: "parent",
      targetType: "dispatch",
      targetId: "dispatch-1",
      states: ["waiting_input"],
    });
    await store.publish(event("idle"));
    await store.publish(event("waiting_input"));
    expect(await store.list()).toEqual([]);
    expect(deliver).not.toHaveBeenCalled();
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

  it("forgetting a session drops its subscriptions both ways and their pending notifications", async () => {
    const { store, deliver } = make();
    await store.subscribe({ subscriber: "parent", targetType: "session", targetId: "child" });
    await store.subscribe({ subscriber: "child", targetType: "session", targetId: "other" });
    await store.subscribe({ subscriber: "child", targetType: "dispatch", targetId: "d1" });
    await store.subscribe({ subscriber: "keep", targetType: "session", targetId: "other" });
    deliver.mockRejectedValue(new Error("offline"));
    await store.publish({ sessionId: "child", state: "idle", notify: true });
    expect(await store.inbox("parent")).toHaveLength(1);
    expect(await store.forgetSession("child")).toBe(3);
    expect(await store.inbox("parent")).toEqual([]);
    expect((await store.list()).map((r) => r.subscriber)).toEqual(["keep"]);
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

  describe("a subscriber that is no longer running (juancode-8oa5.4)", () => {
    function escalating(live: Record<string, { running: boolean; parent?: string }>) {
      const deliver = vi.fn(async (_id: string, _text: string) => {});
      const toHuman = vi.fn(async (_item: unknown, _text: string) => {});
      const sessions = vi.fn(async () => new Map(Object.entries(live)));
      const store = new SessionNotifications(":memory:", {
        output: async () => "The final answer",
        deliver,
        sessions,
        toHuman,
      });
      stores.push(store);
      return { store, deliver, toHuman, sessions };
    }

    it("hands the child's result to the human exactly once when the parent exited first", async () => {
      const { store, deliver, toHuman } = escalating({
        parent: { running: false },
        child: { running: true, parent: "parent" },
      });
      await store.subscribe({
        subscriber: "parent",
        targetType: "dispatch",
        targetId: "dispatch-1",
      });
      await store.publish(event("busy"));
      await store.publish(event("exited"));
      await store.publish({ sessionId: "other", state: "idle", notify: true });
      await store.retry();
      expect(deliver).not.toHaveBeenCalled();
      expect(toHuman).toHaveBeenCalledTimes(1);
      expect(toHuman.mock.calls[0]![1]).toContain("The final answer");
      expect(await store.inbox("parent")).toMatchObject([
        { state: "exited", delivered: true, escalatedTo: "human" },
      ]);
    });

    it("retries a failed human handoff and still records it only once", async () => {
      const { store, toHuman } = escalating({ parent: { running: false } });
      toHuman.mockRejectedValueOnce(new Error("handoff-timeout"));
      await store.subscribe({
        subscriber: "parent",
        targetType: "dispatch",
        targetId: "dispatch-1",
      });
      await store.publish(event("exited"));
      expect((await store.inbox("parent"))[0]).toMatchObject({ delivered: false });
      await store.retry();
      await store.retry();
      expect(toHuman).toHaveBeenCalledTimes(2);
      expect(toHuman.mock.calls[0]![1]).toBe(toHuman.mock.calls[1]![1]);
      expect((await store.inbox("parent"))[0]).toMatchObject({ delivered: true });
    });

    it("delivers to the nearest running ancestor instead, once, and not to the human", async () => {
      const { store, deliver, toHuman } = escalating({
        grandparent: { running: true },
        parent: { running: false, parent: "asleep" },
        asleep: { running: false, parent: "grandparent" },
      });
      await store.subscribe({
        subscriber: "parent",
        targetType: "dispatch",
        targetId: "dispatch-1",
      });
      await store.publish(event("exited"));
      await store.retry();
      expect(toHuman).not.toHaveBeenCalled();
      expect(deliver).toHaveBeenCalledTimes(1);
      expect(deliver.mock.calls[0]![0]).toBe("grandparent");
      expect(await store.inbox("parent")).toEqual([]);
      expect(await store.inbox("grandparent")).toMatchObject([
        { escalatedFrom: "parent", delivered: true },
      ]);
    });

    // juancode-8oa5.15: an orchestrator idles between child results, so the reaper
    // must not sleep it while a dispatch child is still out.
    it("keeps a subscriber with a running child off the reaper, so its result lands once", async () => {
      const protect = vi.fn((_ids: string[]) => {});
      const deliver = vi.fn(async (_id: string, _text: string) => {});
      const toHuman = vi.fn(async (_item: unknown, _text: string) => {});
      // The reaper's side: it sleeps an idle subscriber unless it is protected.
      const live = new Map([
        ["parent", { running: true }],
        ["child", { running: true }],
      ]);
      const reap = () => {
        if (!protect.mock.lastCall?.[0].includes("parent")) live.set("parent", { running: false });
      };
      const store = new SessionNotifications(":memory:", {
        output: async () => "RESULT\nstatus: done",
        deliver,
        sessions: async () => live,
        toHuman,
        protect,
      });
      stores.push(store);
      await store.subscribe({
        subscriber: "parent",
        targetType: "dispatch",
        targetId: "dispatch-1",
      });
      await store.publish(event("busy"));
      reap();
      await store.publish(event("exited"));
      expect(toHuman).not.toHaveBeenCalled();
      expect(deliver).toHaveBeenCalledTimes(1);
      expect(deliver.mock.calls[0]![0]).toBe("parent");
      // The child finished: the parent is the reaper's again.
      expect(protect).toHaveBeenLastCalledWith([]);
    });

    it("still escalates for a subscriber that exited while its child ran", async () => {
      const protect = vi.fn((_ids: string[]) => {});
      const toHuman = vi.fn(async (_item: unknown, _text: string) => {});
      const store = new SessionNotifications(":memory:", {
        output: async () => "done",
        deliver: async () => {},
        sessions: async () => new Map([["parent", { running: false }]]),
        toHuman,
        protect,
      });
      stores.push(store);
      await store.subscribe({
        subscriber: "parent",
        targetType: "dispatch",
        targetId: "dispatch-1",
      });
      expect(protect).toHaveBeenLastCalledWith(["parent"]);
      await store.publish(event("exited"));
      expect(toHuman).toHaveBeenCalledTimes(1);
    });

    // juancode-4hi6: the queue accepted the result, then the parent exited or was
    // slept before typing it; the daemon dropped the queue with the row delivered.
    describe("accepted into the parent's queue but never typed", () => {
      function accepting(typed: string[]) {
        const live = new Map<string, { running: boolean; parent?: string }>([
          ["parent", { running: true }],
        ]);
        const deliver = vi.fn(async (_id: string, _text: string) => {});
        const toHuman = vi.fn(async (_item: unknown, _text: string) => {});
        const received = vi.fn(async (_id: string) => typed.join("\n"));
        const store = new SessionNotifications(":memory:", {
          output: async () => "The final answer",
          deliver,
          sessions: async () => live,
          toHuman,
          received,
        });
        stores.push(store);
        return { store, live, deliver, toHuman, received };
      }
      const parentExits = { sessionId: "parent", state: "exited", notify: true } as const;

      it("escalates the untyped result exactly once when the parent exits", async () => {
        const { store, live, deliver, toHuman, received } = accepting([]);
        await store.subscribe({
          subscriber: "parent",
          targetType: "dispatch",
          targetId: "dispatch-1",
        });
        await store.publish(event("exited"));
        expect(deliver).toHaveBeenCalledTimes(1);
        live.set("parent", { running: false });
        await store.publish(parentExits);
        // The exit frame and the reconnect snapshot both replay the parent's exit.
        await store.publish(parentExits);
        await store.retry();
        expect(toHuman).toHaveBeenCalledTimes(1);
        expect(toHuman.mock.calls[0]![1]).toContain("The final answer");
        expect(received).toHaveBeenCalledTimes(1);
        expect(await store.inbox("parent")).toMatchObject([
          { delivered: true, escalatedTo: "human" },
        ]);
      });

      it("leaves a result the parent did type alone, and asks only once", async () => {
        const { store, live, deliver, toHuman, received } = accepting([]);
        await store.subscribe({
          subscriber: "parent",
          targetType: "dispatch",
          targetId: "dispatch-1",
        });
        await store.publish(event("exited"));
        const typed = deliver.mock.calls[0]![1];
        received.mockResolvedValue(`some prompt\n${typed}`);
        live.set("parent", { running: false });
        await store.publish(parentExits);
        await store.publish(parentExits);
        expect(toHuman).not.toHaveBeenCalled();
        expect(deliver).toHaveBeenCalledTimes(1);
        expect(received).toHaveBeenCalledTimes(1);
      });

      it("hands an untyped result to a running ancestor instead", async () => {
        const { store, live, deliver, toHuman } = accepting([]);
        await store.subscribe({
          subscriber: "parent",
          targetType: "dispatch",
          targetId: "dispatch-1",
        });
        await store.publish(event("exited"));
        live.set("parent", { running: false, parent: "grandparent" });
        live.set("grandparent", { running: true });
        await store.publish(parentExits);
        expect(toHuman).not.toHaveBeenCalled();
        expect(deliver.mock.calls.map((c) => c[0])).toEqual(["parent", "grandparent"]);
        expect(await store.inbox("grandparent")).toMatchObject([
          { escalatedFrom: "parent", delivered: true },
        ]);
      });

      it("escalates nothing, and checks again later, while the transcript cannot be read", async () => {
        const { store, live, toHuman, received } = accepting([]);
        await store.subscribe({
          subscriber: "parent",
          targetType: "dispatch",
          targetId: "dispatch-1",
        });
        await store.publish(event("exited"));
        live.set("parent", { running: false });
        received.mockRejectedValueOnce(new Error("app down"));
        await store.publish(parentExits);
        expect(toHuman).not.toHaveBeenCalled();
        await store.publish(parentExits);
        expect(toHuman).toHaveBeenCalledTimes(1);
      });
    });

    // juancode-dw1r: the daemon retired the typed-and-unsubmitted message while the
    // parent kept running, so nothing about the parent's state changes.
    describe("typed into the parent's box and never submitted", () => {
      async function undelivered() {
        const live = new Map<string, { running: boolean; parent?: string }>([
          ["parent", { running: true, parent: "grandparent" }],
          ["grandparent", { running: true }],
        ]);
        const deliver = vi.fn(async (_id: string, _text: string) => {});
        const toHuman = vi.fn(async (_item: unknown, _text: string) => {});
        const store = new SessionNotifications(":memory:", {
          output: async () => "The final answer",
          deliver,
          sessions: async () => live,
          toHuman,
        });
        stores.push(store);
        await store.subscribe({
          subscriber: "parent",
          targetType: "dispatch",
          targetId: "dispatch-1",
        });
        await store.publish(event("exited"));
        const text = deliver.mock.calls[0]![1];
        const advice = `A queued message was not submitted (x): "${text.split("\n")[0]}"`;
        return { store, live, deliver, toHuman, advice };
      }

      it("hands the result to a running ancestor, not back into the same box", async () => {
        const { store, deliver, advice } = await undelivered();
        await store.undelivered("parent", advice);
        await store.undelivered("parent", advice);
        expect(deliver.mock.calls.map((c) => c[0])).toEqual(["parent", "grandparent"]);
        expect(await store.inbox("grandparent")).toMatchObject([
          { escalatedFrom: "parent", delivered: true },
        ]);
      });

      it("gives it to the human when nobody above is running", async () => {
        const { store, live, toHuman, advice } = await undelivered();
        live.set("grandparent", { running: false });
        await store.undelivered("parent", advice);
        expect(toHuman).toHaveBeenCalledTimes(1);
        expect(toHuman.mock.calls[0]![1]).toContain("The final answer");
      });

      it("ignores an advisory that names no notification of that session", async () => {
        const { store, deliver, toHuman, advice } = await undelivered();
        await store.undelivered("parent", 'A queued message was not submitted: "hello"');
        await store.undelivered("other", advice);
        expect(deliver).toHaveBeenCalledTimes(1);
        expect(toHuman).not.toHaveBeenCalled();
      });
    });

    it("escalates nothing while the core cannot list sessions", async () => {
      const { store, deliver, toHuman, sessions } = escalating({});
      sessions.mockRejectedValue(new Error("app down"));
      await store.subscribe({
        subscriber: "parent",
        targetType: "dispatch",
        targetId: "dispatch-1",
      });
      await store.publish(event("exited"));
      expect(toHuman).not.toHaveBeenCalled();
      expect(deliver).toHaveBeenCalledTimes(1);
    });
  });
});
