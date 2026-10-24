import { describe, expect, it, vi } from "vitest";
import {
  AttentionMirror,
  actionableAttention,
  parseAttention,
  type AttentionItem,
} from "./attention.ts";
const item: AttentionItem = {
  id: "a",
  sessionId: "session-a",
  kind: "completion",
  createdAt: 1,
  updatedAt: 1,
  acknowledged: false,
  resolved: false,
};
describe("shared attention", () => {
  it("orders oldest first and keeps waiting actionable after acknowledgment", () => {
    expect(
      actionableAttention([
        { ...item, id: "z", createdAt: 3 },
        item,
        { ...item, id: "read", acknowledged: true },
        { ...item, id: "resolved", resolved: true },
        { ...item, id: "waiting", kind: "waiting", acknowledged: true, createdAt: 2 },
      ]).map((i) => i.id),
    ).toEqual(["a", "waiting", "z"]);
  });
  it("validates full snapshots while tolerating future kinds", () => {
    expect(parseAttention([{ ...item, kind: "future" }])?.[0]?.kind).toBe("future");
    expect(parseAttention([item, { ...item, acknowledged: "false" }])).toBeNull();
    expect(parseAttention({})).toBeNull();
  });
  it("feature detects old daemons, replaces duplicates and resubscribes after reconnect", async () => {
    const send = vi.fn();
    const mirror = new AttentionMirror(send);
    mirror.handle({ type: "serverInfo", capabilities: [] });
    expect(send).not.toHaveBeenCalled();
    expect(await mirror.acknowledge("a")).toEqual({ ok: false, error: "attention-unavailable" });
    mirror.handle({ type: "serverInfo", capabilities: ["attention"] });
    expect(send).toHaveBeenLastCalledWith({ type: "subscribeAttention" });
    mirror.handle({ type: "attention", items: [item] });
    mirror.handle({ type: "attention", items: [item] });
    expect(mirror.items).toEqual([item]);
    const pending = mirror.acknowledge("a");
    const frame = send.mock.calls.at(-1)![0];
    expect(mirror.items?.[0]?.acknowledged).toBe(false);
    mirror.handle({ type: "attentionResult", requestId: frame.requestId, ok: true });
    expect(await pending).toEqual({ ok: true });
    mirror.reset();
    expect(mirror.items).toBeNull();
    mirror.handle({ type: "serverInfo", capabilities: ["attention"] });
    mirror.handle({ type: "attention", items: [{ ...item, acknowledged: true }] });
    expect(actionableAttention(mirror.items!)).toEqual([]);
    const lost = mirror.acknowledge("a");
    mirror.reset();
    expect(await lost).toEqual({ ok: false, error: "attention-connection-lost" });
  });
  it("times out unconfirmed writes and surfaces storage errors", async () => {
    vi.useFakeTimers();
    try {
      const send = vi.fn();
      const mirror = new AttentionMirror(send);
      mirror.handle({ type: "serverInfo", capabilities: ["attention"] });
      mirror.handle({ type: "attention", items: [item] });
      const timed = mirror.acknowledge("a");
      await vi.advanceTimersByTimeAsync(10_000);
      expect(await timed).toEqual({ ok: false, error: "attention-timeout" });
      const failed = mirror.acknowledge("a");
      mirror.handle({
        type: "attentionResult",
        requestId: send.mock.calls.at(-1)![0].requestId,
        ok: false,
        error: "disk failed",
      });
      expect(await failed).toEqual({ ok: false, error: "disk failed" });
      expect(mirror.items).toEqual([item]);
    } finally {
      vi.useRealTimers();
    }
  });
});
