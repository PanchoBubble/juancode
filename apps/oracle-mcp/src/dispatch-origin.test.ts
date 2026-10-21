import { describe, expect, it } from "vitest";
import { resolveDispatchOrigin, type OriginDeps } from "./dispatch-origin.ts";
import type { LiveActivity, SessionSummary } from "./telegram-format.ts";

// The MCP endpoint cannot see which Oracle is calling, so the dispatching session is
// worked out from the live sessions. A wrong guess tags someone else's work into a
// chain, so every case that cannot be told apart must come back null.

const CONTROL = "/Users/me/.juancode/oracle";

const session = (id: string, over: Partial<SessionSummary> = {}): SessionSummary => ({
  id,
  provider: "claude",
  cwd: CONTROL,
  title: id,
  status: "running",
  archived: false,
  updatedAt: 0,
  ...over,
});

const deps = (
  sessions: SessionSummary[] | null,
  activity: Record<string, LiveActivity> = {},
): OriginDeps => ({
  sessions: async () => {
    if (!sessions) throw new Error("app down");
    return sessions;
  },
  activity: (id) => activity[id],
  controlDir: () => CONTROL,
});

describe("resolveDispatchOrigin", () => {
  it("takes the id the Oracle gave, resolving a unique prefix", async () => {
    const list = [session("abc123"), session("abd456")];
    expect(await resolveDispatchOrigin("abc", deps(list))).toBe("abc123");
    expect(await resolveDispatchOrigin("abd456", deps(list))).toBe("abd456");
  });

  it("maps a CLI session id to the juancode session that runs it", async () => {
    const list = [session("abc123", { cliSessionId: "cli-1" }), session("cli-1x")];
    expect(await resolveDispatchOrigin("cli-1", deps(list))).toBe("abc123");
  });

  it("refuses a prefix that names several sessions", async () => {
    const list = [session("abc123"), session("abd456")];
    await expect(resolveDispatchOrigin("ab", deps(list))).rejects.toThrow(/matches 2 sessions/);
  });

  it("passes an unknown id, or any id with the app down, through as written", async () => {
    expect(await resolveDispatchOrigin("zzz", deps([session("abc")]))).toBe("zzz");
    expect(await resolveDispatchOrigin(" zzz ", deps(null))).toBe("zzz");
  });

  it("infers the one busy Oracle in the control dir", async () => {
    const list = [
      session("oracle", { cwd: `${CONTROL}/` }),
      session("worker", { cwd: "/repo" }),
      session("old-oracle", { status: "exited" }),
      session("shelved", { archived: true }),
    ];
    const busy = { oracle: "busy", worker: "busy", "old-oracle": "busy", shelved: "busy" } as const;
    expect(await resolveDispatchOrigin(undefined, deps(list, busy))).toBe("oracle");
  });

  it("picks the busy one of several Oracles", async () => {
    const list = [session("a"), session("b")];
    expect(await resolveDispatchOrigin(null, deps(list, { a: "idle", b: "busy" }))).toBe("b");
  });

  it("names nobody when it cannot tell", async () => {
    const two = [session("a"), session("b")];
    // Two mid-turn Oracles: either could be the caller.
    expect(await resolveDispatchOrigin(null, deps(two, { a: "busy", b: "busy" }))).toBeNull();
    // A lone idle Oracle is not the caller: the headless phone chat dispatches from
    // the control dir without being a session.
    expect(await resolveDispatchOrigin(null, deps([session("a")], { a: "idle" }))).toBeNull();
    expect(await resolveDispatchOrigin(null, deps([session("a")]))).toBeNull();
    expect(await resolveDispatchOrigin("", deps([]))).toBeNull();
    expect(await resolveDispatchOrigin(null, deps(null))).toBeNull();
  });
});
