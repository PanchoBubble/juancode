import { describe, expect, it } from "vitest";
import { askHuman, type AskDeps, type AskInput } from "./chain-ask.ts";
import type { HandoffInput } from "./native-events.ts";

const INPUT: AskInput = {
  sessionId: "s1",
  question: "Ship now?",
  options: ["yes", "wait"],
  recommended: "wait",
  blocked: "release",
};

function deps(over: Partial<AskDeps> = {}) {
  const handoffs: HandoffInput[] = [];
  const pings: string[] = [];
  const d: AskDeps = {
    origin: async (g) => g ?? null,
    chainSlugOf: () => "chain-a",
    supported: () => true,
    createHandoff: async (h) => {
      handoffs.push(h);
      return { ok: true, op: "create", id: h.id };
    },
    notify: async (_id, text, handoffId) => {
      pings.push(`${handoffId}:${text}`);
      return { chatIds: [1] };
    },
    newId: () => "h1",
    ...over,
  };
  return { d, handoffs, pings };
}

describe("askHuman", () => {
  it("creates one pending human handoff and pings once", async () => {
    const { d, handoffs, pings } = deps();
    await askHuman(INPUT, d);
    expect(handoffs).toHaveLength(1);
    expect(handoffs[0]).toMatchObject({
      chainSlug: "chain-a",
      source: { kind: "session", sessionId: "s1" },
      target: { kind: "human" },
    });
    expect(handoffs[0]!.summary).toContain("2. wait (recommended)");
    // The ping carries the handoff id, so a Telegram reply to it answers the question.
    expect(pings).toEqual([`h1:${handoffs[0]!.summary}`]);
  });

  it("refuses a session outside a chain without writing or pinging", async () => {
    const { d, handoffs, pings } = deps({ chainSlugOf: () => null });
    await expect(askHuman(INPUT, d)).rejects.toThrow(/not in a chain/);
    expect(handoffs).toHaveLength(0);
    expect(pings).toHaveLength(0);
  });

  it("does not ping when the daemon refuses the handoff", async () => {
    const { d, pings } = deps({
      createHandoff: async () => ({ ok: false, op: "create", error: "chain-not-found" }),
    });
    await expect(askHuman(INPUT, d)).rejects.toThrow(/chain-not-found/);
    expect(pings).toHaveLength(0);
  });
});
