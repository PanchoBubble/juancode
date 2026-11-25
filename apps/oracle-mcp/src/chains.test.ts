import { describe, expect, it } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { registerChainTools } from "./chain-tools.ts";
import {
  chainListText,
  chainTokens,
  membersByKind,
  readBook,
  resolveMemberRef,
  sessionChainTokens,
} from "./chains.ts";
import { fakeChainDeps, type FakeChainDeps } from "./chains-fake.ts";
import type { Chain, Handoff } from "./native-events.ts";
import { parseSessionList, type SessionSummary } from "./telegram-format.ts";

const session = (id: string, title: string, status = "running"): SessionSummary => ({
  id,
  provider: "claude",
  cwd: `/Users/juan/workdir/${title}`,
  title,
  status,
  archived: false,
  updatedAt: 1,
});

const SESSIONS = [
  session("1111-aaaa", "api"),
  session("2222-bbbb", "web"),
  session("2222-cccc", "oracle"),
  session("3333-dddd", "old", "exited"),
];

const BOOK: Chain[] = [
  {
    slug: "auth-rewrite",
    state: "active",
    createdAt: Date.UTC(2026, 9, 20),
    closedAt: null,
    members: [
      { kind: "session", ref: "1111-aaaa", addedAt: 1 },
      { kind: "beads", ref: "juancode-dbo.10", title: "chain tools", addedAt: 2 },
      { kind: "tracked_pr", ref: "/Users/juan/workdir/api#42", addedAt: 3 },
      { kind: "session", ref: "3333-dddd", addedAt: 4 },
      { kind: "linear", ref: "ENG-7", url: "https://linear.app/x/ENG-7", addedAt: 5 },
      { kind: "session", ref: "gone-0000", addedAt: 6 },
    ],
  },
  { slug: "billing", state: "active", createdAt: 1, closedAt: null, members: [] },
  { slug: "launch", state: "inactive", createdAt: 1, closedAt: 9, members: [] },
];

/** The real chain tools, bound to `deps`, driven by a real MCP client. */
async function connect(deps: FakeChainDeps) {
  const server = new McpServer({ name: "test", version: "0" });
  registerChainTools(server, () => deps);
  const [clientSide, serverSide] = InMemoryTransport.createLinkedPair();
  await server.connect(serverSide);
  const client = new Client({ name: "test-client", version: "0" });
  await client.connect(clientSide);
  return async (name: string, args: Record<string, unknown> = {}) => {
    const res = (await client.callTool({ name, arguments: args })) as {
      content: { type: string; text: string }[];
      isError?: boolean;
    };
    return { text: res.content.map((c) => c.text).join("\n"), isError: res.isError === true };
  };
}

describe("chain MCP tools", () => {
  it("registers exactly the chain tools", async () => {
    const server = new McpServer({ name: "test", version: "0" });
    registerChainTools(server, () => fakeChainDeps());
    const [clientSide, serverSide] = InMemoryTransport.createLinkedPair();
    await server.connect(serverSide);
    const client = new Client({ name: "c", version: "0" });
    await client.connect(clientSide);
    const { tools } = await client.listTools();
    expect(tools.map((t) => t.name).sort()).toEqual([
      "chain_add",
      "chain_close",
      "chain_create",
      "chain_list",
      "chain_remove",
      "chain_show",
    ]);
  });

  it("chain_list filters by state, active by default", async () => {
    const call = await connect(fakeChainDeps({ book: BOOK }));
    const active = await call("chain_list");
    expect(active.text).toBe(
      "1. auth-rewrite · 3 sessions, 1 PR, 1 beads issue, 1 Linear ticket\n2. billing · empty",
    );
    expect((await call("chain_list", { state: "inactive" })).text).toBe(
      "1. launch (closed) · empty",
    );
    expect((await call("chain_list", { state: "all" })).text.split("\n")).toHaveLength(3);
  });

  it("chain_show groups members by kind and gives each session its live status", async () => {
    const deps = fakeChainDeps({
      book: BOOK,
      sessions: SESSIONS,
      activity: { "1111-aaaa": "waiting_input" },
    });
    const { text, isError } = await (await connect(deps))("chain_show", { slug: "auth-rewrite" });
    expect(isError).toBe(false);
    expect(text).toBe(
      [
        "auth-rewrite · active since 2026-10-20",
        "Sessions (3):\n" +
          "- 🟡 api · api · claude · waiting for input · 1111-aaaa\n" +
          "- ⚫ old · old · claude · exited · 3333-dddd\n" +
          "- gone-0000 · gone-0000 · not in the session list",
        "PRs (1):\n- api #42 · /Users/juan/workdir/api#42",
        "Beads issues (1):\n- juancode-dbo.10 · chain tools",
        "Linear tickets (1):\n- ENG-7\n    https://linear.app/x/ENG-7",
      ].join("\n\n"),
    );
  });

  it("a chain's token total sums its sessions and every nested chain's, once (juancode-8oa5.12)", async () => {
    const sessions = parseSessionList([
      { id: "orch", usage: { totalTokens: 100 } },
      { id: "impl", usage: { totalTokens: 20 } },
      { id: "deep", usage: { totalTokens: 3 } },
      { id: "fresh" },
    ]);
    const chain = (slug: string, refs: string[], parent?: string): Chain => ({
      slug,
      state: "active",
      createdAt: 1,
      closedAt: null,
      members: refs.map((ref, i) => ({ kind: "session", ref, addedAt: i })),
      ...(parent ? { parent } : {}),
    });
    // "loop" -> "sub" -> "subsub" -> back to "loop": a parent cycle must still end.
    const book = [
      chain("loop", ["orch", "fresh"], "subsub"),
      chain("sub", ["impl"], "loop"),
      chain("subsub", ["deep"], "sub"),
      chain("other", ["gone"]),
    ];
    const bySession = new Map(sessions.map((s) => [s.id, s] as const));
    expect(chainTokens(book, "sub", bySession)).toBe(123);
    expect(chainTokens(book, "other", bySession)).toBe(0);
    const deps = fakeChainDeps({ book: book.slice(1).concat(chain("loop", ["orch"])), sessions });
    expect(await sessionChainTokens(deps, "orch")).toEqual({ slug: "loop", totalTokens: 123 });
    await expect(sessionChainTokens(deps, "nobody")).rejects.toThrow(/in no chain/);
    const { text } = await (await connect(deps))("chain_show", { slug: "loop" });
    expect(text.split("\n")[0]).toBe(
      "loop · active since 1970-01-01 · 123 tokens incl. nested chains",
    );
  });

  it("chain_show lists open handoffs as next actions, stalled only when the owner is known idle", async () => {
    const h = (id: string, target: Handoff["target"], extra: Partial<Handoff> = {}): Handoff => ({
      id,
      chainSlug: "auth-rewrite",
      source: { kind: "session", sessionId: "2222-bbbb" },
      target,
      summary: `do ${id}\nmore detail`,
      createdAt: Number(id.slice(1)),
      updatedAt: 1,
      state: "pending",
      ...extra,
    });
    const to = (sessionId: string) => ({ kind: "session" as const, sessionId });
    const deps = fakeChainDeps({
      book: BOOK,
      sessions: [...SESSIONS, { ...session("4444-eeee", "asleep"), dormant: true }],
      activity: { "1111-aaaa": "idle", "2222-cccc": "busy" },
      handoffs: [
        h("h1", to("1111-aaaa"), { beadsIssue: "juancode-043.3", evidenceRef: "abc123" }),
        h("h2", to("2222-cccc"), { state: "acknowledged" }),
        h("h3", to("2222-bbbb")),
        h("h4", to("4444-eeee")),
        h("h5", to("3333-dddd")),
        h("h6", to("gone-0000")),
        h("h7", { kind: "human" }),
        h("h8", to("1111-aaaa"), { state: "closed", closureReason: "done" }),
        { ...h("h9", to("1111-aaaa")), chainSlug: "billing" },
      ],
    });
    const { text } = await (await connect(deps))("chain_show", { slug: "auth-rewrite" });
    expect(text.split("\n\n").at(-1)).toBe(
      [
        "Next actions (7):",
        "- 🟠 stalled · web → api · juancode-043.3",
        "    do h1",
        "    evidence: abc123",
        "- 🔵 working · web → oracle · acknowledged",
        "    do h2",
        "- ❔ unknown · web → web",
        "    do h3",
        "- 💤 on hold · web → asleep",
        "    do h4",
        "- 🟠 stalled · web → old",
        "    do h5",
        "- ⚫ owner gone · web → gone-0000",
        "    do h6",
        "- ❗ needs you · web → you",
        "    do h7",
        "1 closed handoff in history.",
      ].join("\n"),
    );
  });

  it("chain_show still answers when the session list is unreachable", async () => {
    const deps = fakeChainDeps({ book: BOOK });
    deps.sessions = async () => {
      throw new Error("app down");
    };
    const { text, isError } = await (await connect(deps))("chain_show", { slug: "auth-rewrite" });
    expect(isError).toBe(false);
    expect(text).toContain("- 1111-aaaa · 1111-aaaa · not in the session list");
  });

  it("chain_show of an unknown slug is an error", async () => {
    const res = await (await connect(fakeChainDeps({ book: BOOK })))("chain_show", { slug: "x" });
    expect(res).toEqual({ isError: true, text: 'No chain named "x".' });
  });

  it("creates UUID chains and displays their names", async () => {
    const deps = fakeChainDeps();
    const call = await connect(deps);
    const reply = await call("chain_create", { name: "Fix café login" });
    expect(reply.isError).toBe(false);
    const chain = deps.book()![0]!;
    expect(chain.slug).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
    );
    expect(chain.name).toBe("Fix café login");
    expect(chainListText(deps.book()!, "active")).toContain("Fix café login");
    expect(chainListText(deps.book()!, "active")).not.toContain(chain.slug);
  });

  it("creates, tags, moves, untags and closes", async () => {
    const deps = fakeChainDeps({ book: BOOK, sessions: SESSIONS });
    const call = await connect(deps);

    expect((await call("chain_create", { slug: "infra" })).text).toBe('Created chain "infra".');
    // A session by unique prefix, the Oracle tagging its own work.
    expect((await call("chain_add", { slug: "infra", kind: "session", ref: "2222-c" })).text).toBe(
      'Added session 2222-cccc to "infra".',
    );
    // An item already in another chain moves, and the answer says so.
    expect(
      (await call("chain_add", { slug: "infra", kind: "session", ref: "1111-aaaa" })).text,
    ).toBe('Added session 1111-aaaa to "infra" (moved out of "auth-rewrite").');
    expect(
      (
        await call("chain_add", {
          slug: "infra",
          kind: "tracked_pr",
          ref: "#17",
          prCwd: "/Users/juan/workdir/web/",
          title: "Fix login",
        })
      ).text,
    ).toBe('Added tracked_pr /Users/juan/workdir/web#17 to "infra".');
    expect(deps.writes.at(-1)).toEqual({
      type: "setChainMember",
      kind: "tracked_pr",
      ref: "/Users/juan/workdir/web#17",
      slug: "infra",
      title: "Fix login",
    });
    expect(
      (await call("chain_add", { slug: "infra", kind: "beads", ref: "juancode-dbo.10" })).text,
    ).toContain('(moved out of "auth-rewrite")');
    expect(
      (await call("chain_add", { slug: "infra", kind: "beads", ref: "juancode-dbo.10" })).text,
    ).toBe('beads juancode-dbo.10 is already in "infra".');

    expect((await call("chain_remove", { kind: "session", ref: "2222-cccc" })).text).toBe(
      'Removed session 2222-cccc from "infra".',
    );
    expect(deps.writes.at(-1)).toEqual({
      type: "setChainMember",
      kind: "session",
      ref: "2222-cccc",
    });
    expect((await call("chain_remove", { kind: "session", ref: "2222-cccc" })).text).toBe(
      "session 2222-cccc is not in any chain.",
    );

    expect((await call("chain_close", { slug: "infra" })).text).toContain('Closed chain "infra"');
    expect((await call("chain_list")).text).not.toContain("infra");
    expect((await call("chain_list", { state: "inactive" })).text).toContain("infra (closed)");
  });

  it("chain_remove with a slug refuses when the item is in a different chain", async () => {
    const deps = fakeChainDeps({ book: BOOK, sessions: SESSIONS });
    const res = await (
      await connect(deps)
    )("chain_remove", {
      kind: "beads",
      ref: "juancode-dbo.10",
      slug: "billing",
    });
    expect(res).toEqual({
      isError: true,
      text: 'beads juancode-dbo.10 is in "auth-rewrite", not "billing"; nothing was removed.',
    });
    expect(deps.writes).toEqual([]);
  });

  it("turns the daemon's refusals into words", async () => {
    const call = await connect(fakeChainDeps({ book: BOOK, sessions: SESSIONS }));
    expect(await call("chain_create", { slug: "Auth Rewrite" })).toEqual({
      isError: true,
      text: 'Could not create "Auth Rewrite": slugs are lowercase letters and digits in dash-separated words, e.g. auth-rewrite.',
    });
    expect((await call("chain_create", { slug: "launch" })).text).toBe(
      'Chain "launch" already exists (closed). Use chain_add to tag work into it.',
    );
    expect(await call("chain_add", { slug: "nope", kind: "beads", ref: "x-1" })).toEqual({
      isError: true,
      text: 'No chain named "nope". Create it with chain_create first.',
    });
    expect(await call("chain_add", { slug: "billing", kind: "session", ref: "zzzz" })).toEqual({
      isError: true,
      text: 'Could not add session zzzz to "billing": the core has no session with that id.',
    });
    expect(await call("chain_close", { slug: "nope" })).toEqual({
      isError: true,
      text: 'Could not close "nope": no chain with that slug.',
    });
  });

  it("fails closed when the daemon does not keep chains", async () => {
    const res = await (await connect(fakeChainDeps({ supported: false })))("chain_list");
    expect(res.isError).toBe(true);
    expect(res.text).toMatch(/^Chains are unavailable/);
  });
});

describe("resolveMemberRef", () => {
  const deps = fakeChainDeps({ sessions: SESSIONS });

  it("refuses an ambiguous session prefix rather than picking one", async () => {
    await expect(resolveMemberRef(deps, "session", "2222")).rejects.toThrow("matches 2 sessions");
  });

  it("takes a PR's tracked key as is, or builds it from prCwd and a number", async () => {
    expect(await resolveMemberRef(deps, "tracked_pr", "/r/a#3")).toBe("/r/a#3");
    expect(await resolveMemberRef(deps, "tracked_pr", "3", "/r/a")).toBe("/r/a#3");
    await expect(resolveMemberRef(deps, "tracked_pr", "3")).rejects.toThrow("tracked key");
    await expect(
      resolveMemberRef(deps, "tracked_pr", "https://github.com/o/r/pull/3"),
    ).rejects.toThrow("tracked key");
  });

  it("passes beads and Linear refs through trimmed", async () => {
    expect(await resolveMemberRef(deps, "linear", " ENG-1 ")).toBe("ENG-1");
  });
});

describe("readBook", () => {
  it("waits for the first book after the handshake", async () => {
    let book: Chain[] | null = null;
    let subscribed = 0;
    const deps = {
      ...fakeChainDeps(),
      waitMs: 1000,
      subscribe: () => {
        subscribed++;
        return true;
      },
      book: () => book,
    };
    setTimeout(() => (book = BOOK), 50);
    expect((await readBook(deps)).map((c) => c.slug)).toEqual([
      "auth-rewrite",
      "billing",
      "launch",
    ]);
    expect(subscribed).toBeGreaterThan(0);
  });
});

describe("chainListText and membersByKind", () => {
  it("orders kinds session, PR, beads, Linear whatever the join order", () => {
    expect(membersByKind(BOOK[0]!).map(([kind]) => kind)).toEqual([
      "session",
      "tracked_pr",
      "beads",
      "linear",
    ]);
  });

  it("says when there is nothing to list", () => {
    expect(chainListText([], "all")).toBe("No chains yet.");
    expect(chainListText(BOOK, "inactive")).toBe("1. launch (closed) · empty");
    expect(chainListText(BOOK.slice(0, 2), "inactive")).toBe("No inactive chains.");
  });
});
