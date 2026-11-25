import { describe, expect, it } from "vitest";
import { ackHandoff, closeChainHandoff, handOff, type HandoffDeps } from "./chain-handoff.ts";
import type { Handoff } from "./native-events.ts";

const H: Handoff = {
  id: "h1",
  chainSlug: "c",
  source: { kind: "session", sessionId: "a" },
  target: { kind: "session", sessionId: "b" },
  summary: "s",
  createdAt: 0,
  updatedAt: 0,
  state: "pending",
};

function setup(over: Partial<HandoffDeps> = {}) {
  const calls: string[] = [];
  const d: HandoffDeps = {
    origin: async (g) => g ?? null,
    chainSlugOf: (id) => (id === "outsider" ? null : id === "other" ? "c2" : "c"),
    supported: () => true,
    find: (id) => (id === "h1" ? H : null),
    create: async (h) => (
      calls.push(`create:${h.source.kind}>${JSON.stringify(h.target)}`),
      { ok: true, op: "create" }
    ),
    acknowledge: async (id) => (calls.push(`ack:${id}`), { ok: true, op: "acknowledge" }),
    close: async (id, r) => (calls.push(`close:${id}:${r}`), { ok: true, op: "close" }),
    newId: () => "new",
    ...over,
  };
  return { d, calls };
}

describe("chain handoff tools", () => {
  it("hands off to a session in the same chain only", async () => {
    const { d, calls } = setup();
    await handOff({ sessionId: "a", to: "b", summary: "go" }, d);
    expect(calls).toEqual(['create:session>{"kind":"session","sessionId":"b"}']);
    await expect(handOff({ sessionId: "a", to: "other", summary: "go" }, d)).rejects.toThrow(
      /not in your chain/,
    );
    await expect(handOff({ sessionId: "outsider", to: "b", summary: "go" }, d)).rejects.toThrow(
      /not in a chain/,
    );
    expect(calls).toHaveLength(1);
  });

  it("lets only the target acknowledge", async () => {
    const { d, calls } = setup();
    await expect(ackHandoff({ sessionId: "a", handoffId: "h1" }, d)).rejects.toThrow(
      /addressed to/,
    );
    await ackHandoff({ sessionId: "b", handoffId: "h1" }, d);
    expect(calls).toEqual(["ack:h1"]);
  });

  it("lets either party close with evidence, nobody else", async () => {
    const { d, calls } = setup();
    await expect(
      closeChainHandoff({ sessionId: "c", handoffId: "h1", evidence: "e" }, d),
    ).rejects.toThrow(/not yours/);
    await closeChainHandoff({ sessionId: "a", handoffId: "h1", evidence: "done: abc123" }, d);
    expect(calls).toEqual(["close:h1:done: abc123"]);
  });

  it("surfaces the daemon's refusal", async () => {
    const { d } = setup({
      close: async () => ({ ok: false, op: "close", error: "handoff-closed" }),
    });
    await expect(
      closeChainHandoff({ sessionId: "b", handoffId: "h1", evidence: "e" }, d),
    ).rejects.toThrow(/handoff-closed/);
  });
});
