import { describe, expect, it } from "vitest";

import type { Chain, HandoffInput, SessionActivityEvent } from "./native-events.ts";
import type { SessionMessage } from "./session-reads.ts";
import {
  extractHandoffNote,
  HANDOFF_BEGIN,
  HANDOFF_END,
  handOffSession,
  HandoffRefused,
  handoffRequestPrompt,
  parseHandoffSources,
  type HandoffDeps,
  type HandoffSource,
} from "./session-handoff.ts";

const NOTE = "Goal: ship X.\nNext: run the tests at src/a.ts:12.";

const SOURCE: HandoffSource = {
  id: "old-session",
  title: "Fix the thing",
  provider: "claude",
  cwd: "/repo",
  worktreePath: "/repo-worktrees/slot-01",
  skipPermissions: true,
  status: "running",
  kind: "agent",
};

type State = SessionActivityEvent["state"];

/** A fake world: one session whose agent answers the queued request with `reply`
 *  (or goes to `answerState` instead), and a core that records every write. */
function world(opts: {
  source?: HandoffSource | null;
  state?: State;
  reply?: string | null;
  answerState?: State;
  book?: Chain[];
  supported?: boolean;
  createFails?: boolean;
}) {
  let state: State = opts.state ?? "idle";
  const messages: SessionMessage[] = [
    { seq: 1, role: "user", text: "start" },
    // An old note from before the request must never be taken for the reply.
    { seq: 2, role: "assistant", text: `${HANDOFF_BEGIN}\nstale\n${HANDOFF_END}` },
  ];
  const listeners: ((ev: SessionActivityEvent) => void)[] = [];
  const queued: string[] = [];
  const creates: Record<string, unknown>[] = [];
  const chainsCreated: { id: string; name: string }[] = [];
  const members: { ref: string; slug: string }[] = [];
  const handoffs: HandoffInput[] = [];
  const slept: string[] = [];
  let ids = 0;

  const settle = (next: State) => {
    state = next;
    for (const l of listeners) l({ sessionId: SOURCE.id, state: next, notify: false });
  };

  const deps: HandoffDeps = {
    source: async () => (opts.source === undefined ? SOURCE : opts.source),
    supported: () => opts.supported ?? true,
    activity: () => state,
    subscribe: (l) => {
      listeners.push(l);
      return () => listeners.splice(listeners.indexOf(l), 1);
    },
    messages: async () => [...messages],
    model: async () => "claude-opus-5-5",
    queue: async (_id, text) => {
      queued.push(text);
      // The queue delivers on idle; the agent works, then settles.
      setTimeout(() => {
        messages.push({ seq: messages.length + 1, role: "user", text });
        settle("busy");
        setTimeout(() => {
          if (opts.reply !== null) {
            messages.push({
              seq: messages.length + 1,
              role: "assistant",
              text: opts.reply ?? `Here it is.\n${HANDOFF_BEGIN}\n${NOTE}\n${HANDOFF_END}`,
            });
          }
          settle(opts.answerState ?? "idle");
        }, 5);
      }, 5);
    },
    create: async (frame) => {
      creates.push(frame);
      return opts.createFails
        ? { kind: "rejected", message: "bad path" }
        : { kind: "created", sessionId: "new-session" };
    },
    book: async () => opts.book ?? [],
    createChain: async (id, name) => {
      chainsCreated.push({ id, name });
      return { ok: true, op: "create", slug: id };
    },
    setMember: async (m) => {
      members.push({ ref: m.ref, slug: m.slug });
      return { ok: true, op: "setMember" };
    },
    createHandoff: async (h) => {
      handoffs.push(h);
      return { ok: true, op: "create", id: h.id };
    },
    sleep: (id) => {
      slept.push(id);
      return true;
    },
    newId: () => `id-${++ids}`,
    recheckMs: 2,
  };
  return { deps, queued, creates, chainsCreated, members, handoffs, slept };
}

describe("extractHandoffNote", () => {
  it("takes the text between the last pair of markers", () => {
    const text = `quoting ${HANDOFF_BEGIN} … ${HANDOFF_END}\n${HANDOFF_BEGIN}\n  the note \n${HANDOFF_END}\nbye`;
    expect(extractHandoffNote(text)).toBe("the note");
  });

  it("is null without both markers or with an empty note", () => {
    expect(extractHandoffNote("no markers")).toBeNull();
    expect(extractHandoffNote(`${HANDOFF_BEGIN} only the start`)).toBeNull();
    expect(extractHandoffNote(`${HANDOFF_BEGIN}\n  \n${HANDOFF_END}`)).toBeNull();
  });

  it("asks for a short note with the markers, on one line", () => {
    const prompt = handoffRequestPrompt();
    expect(prompt).toContain(HANDOFF_BEGIN);
    expect(prompt).toContain(HANDOFF_END);
    expect(prompt).toContain("at most 60 lines");
    expect(prompt).not.toContain("\n");
  });
});

describe("handOffSession", () => {
  it("collects the note, spawns the successor with it, records the handoff and sleeps the old one", async () => {
    const w = world({});
    const outcome = await handOffSession("old", w.deps);

    expect(w.queued).toEqual([handoffRequestPrompt()]);
    expect(outcome.note).toBe(NOTE);
    expect(outcome.successorId).toBe("new-session");
    expect(outcome.warnings).toEqual([]);

    const [create] = w.creates;
    expect(create).toMatchObject({
      type: "create",
      provider: "claude",
      cwd: "/repo-worktrees/slot-01",
      skipPermissions: true,
      model: "claude-opus-5-5",
    });
    expect(create!.initialInput).toContain(NOTE);
    expect(create!.isolateWorktree).toBeUndefined();

    // No chain before: one is made for the old session, and both sessions join it.
    expect(w.chainsCreated).toEqual([{ id: "id-1", name: "Fix the thing (slot-01)" }]);
    expect(w.members).toEqual([
      { ref: "old-session", slug: "id-1" },
      { ref: "new-session", slug: "id-1" },
    ]);
    expect(w.handoffs).toEqual([
      {
        id: "id-2",
        chainSlug: "id-1",
        source: { kind: "session", sessionId: "old-session" },
        target: { kind: "session", sessionId: "new-session" },
        summary: NOTE,
      },
    ]);
    expect(w.slept).toEqual(["old-session"]);
    expect(outcome.slept).toBe(true);
  });

  it("reuses the chain the old session is already in", async () => {
    const book: Chain[] = [
      {
        slug: "auth",
        state: "active",
        createdAt: 0,
        closedAt: null,
        members: [{ kind: "session", ref: "old-session", addedAt: 0 }],
      },
    ];
    const w = world({ book });
    const outcome = await handOffSession("old", w.deps);
    expect(outcome.chainSlug).toBe("auth");
    expect(w.chainsCreated).toEqual([]);
    expect(w.members).toEqual([{ ref: "new-session", slug: "auth" }]);
    expect(w.handoffs[0]!.chainSlug).toBe("auth");
  });

  it("refuses, spawning nothing, when the reply has no note", async () => {
    const w = world({ reply: "I'd rather keep going." });
    await expect(handOffSession("old", w.deps)).rejects.toThrow(/without a handoff note/);
    expect(w.creates).toEqual([]);
    expect(w.handoffs).toEqual([]);
    expect(w.slept).toEqual([]);
  });

  it("refuses when the agent stops to ask for input instead", async () => {
    const w = world({ reply: null, answerState: "waiting_input" });
    await expect(handOffSession("old", w.deps)).rejects.toThrow(/ask for input/);
    expect(w.creates).toEqual([]);
    expect(w.slept).toEqual([]);
  });

  it("refuses up front when the session is already waiting for input", async () => {
    const w = world({ state: "waiting_input" });
    await expect(handOffSession("old", w.deps)).rejects.toThrow(/waiting for input/);
    expect(w.queued).toEqual([]);
  });

  it("refuses a session that is not running, or a core without handoffs", async () => {
    await expect(
      handOffSession("old", world({ source: { ...SOURCE, status: "exited" } }).deps),
    ).rejects.toThrow(/not running/);
    await expect(handOffSession("old", world({ supported: false }).deps)).rejects.toThrow(
      /does not record handoffs/,
    );
    await expect(handOffSession("old", world({ source: null }).deps)).rejects.toBeInstanceOf(
      HandoffRefused,
    );
  });

  it("leaves the old session running and returns the note when the spawn fails", async () => {
    const w = world({ createFails: true });
    await expect(handOffSession("old", w.deps)).rejects.toThrow(/bad path[\s\S]*Goal: ship X/);
    expect(w.handoffs).toEqual([]);
    expect(w.slept).toEqual([]);
  });

  it("times out when the request never gets an answer", async () => {
    const w = world({ state: "busy" });
    w.deps.queue = async () => {};
    await expect(handOffSession("old", w.deps, { timeoutMs: 20 })).rejects.toThrow(/Timed out/);
  });

  it("joins a handoff already in flight instead of asking twice", async () => {
    const w = world({});
    const [a, b] = await Promise.all([
      handOffSession("old", w.deps),
      handOffSession("old", w.deps),
    ]);
    expect(a).toBe(b);
    expect(w.queued).toHaveLength(1);
  });
});

describe("parseHandoffSources", () => {
  it("reads the fields a handoff needs off /api/sessions rows", () => {
    const [row] = parseHandoffSources([
      {
        id: "s1",
        title: "T",
        provider: "codex",
        cwd: "/r",
        worktreePath: "/w",
        skipPermissions: true,
        status: "running",
        kind: "agent",
        usage: { contextWindow: 1_000_000 },
      },
    ]);
    expect(row).toEqual({
      id: "s1",
      title: "T",
      provider: "codex",
      cwd: "/r",
      worktreePath: "/w",
      skipPermissions: true,
      status: "running",
      kind: "agent",
      contextWindow: 1_000_000,
    });
  });
});
