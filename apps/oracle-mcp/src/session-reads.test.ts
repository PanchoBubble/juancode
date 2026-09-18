import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  digest,
  fetchDiff,
  fetchGitState,
  fetchMessages,
  fetchScreen,
  fetchScreenText,
  fetchScrollback,
  fetchTranscript,
  fetchWorktreeFile,
  fetchWorktrees,
  NoSuchSession,
  SessionNotRunning,
  UnservedRead,
  type SessionMessage,
} from "./session-reads.ts";

const realFetch = globalThis.fetch;
const prevApi = process.env.JUANCODE_API;

/** Answer every read with `body` at `status`, recording the URL it was asked for. */
function stubFetch(status: number, body: unknown): { urls: string[] } {
  const urls: string[] = [];
  globalThis.fetch = (async (url: string) => {
    urls.push(String(url));
    return new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    });
  }) as unknown as typeof fetch;
  return { urls };
}

/** The same, for the text/plain body `/screen` answers by default. */
function stubText(status: number, body: string): { urls: string[] } {
  const urls: string[] = [];
  globalThis.fetch = (async (url: string) => {
    urls.push(String(url));
    return new Response(body, { status, headers: { "content-type": "text/plain" } });
  }) as unknown as typeof fetch;
  return { urls };
}

describe("the native server's per-session reads", () => {
  beforeEach(() => {
    process.env.JUANCODE_API = "http://native.test";
  });

  afterEach(() => {
    globalThis.fetch = realFetch;
    if (prevApi === undefined) delete process.env.JUANCODE_API;
    else process.env.JUANCODE_API = prevApi;
  });

  // The grid is the whole reason this read is not just "give me the bytes": a byte
  // ring replayed at a width it was not parsed at is garbled in every line that
  // wrapped, and the width is not recoverable from the bytes.
  it("carries the grid the scrollback was parsed at", async () => {
    const { urls } = stubFetch(200, {
      sessionId: "s1",
      cols: 132,
      rows: 43,
      scrollback: "hello\r\n",
    });
    const read = await fetchScrollback("s1");
    expect(read).toEqual({ sessionId: "s1", cols: 132, rows: 43, scrollback: "hello\r\n" });
    expect(urls).toEqual(["http://native.test/api/sessions/s1/scrollback"]);
  });

  it("percent-encodes the session id and passes a limit through", async () => {
    const { urls } = stubFetch(200, { sessionId: "s 1/weird", records: [] });
    await fetchTranscript("s 1/weird", 25);
    expect(urls).toEqual(["http://native.test/api/sessions/s%201%2Fweird/transcript?limit=25"]);
  });

  it("omits the query entirely when no limit is asked for", async () => {
    const { urls } = stubFetch(200, { sessionId: "s1", messages: [] });
    await fetchMessages("s1");
    expect(urls).toEqual(["http://native.test/api/sessions/s1/messages"]);
  });

  // The three distinct outcomes a caller has to tell apart: no such session, a core
  // that does not serve the read at all, and an empty-but-real session. Collapsing
  // the middle one into "empty" is exactly what made juancode-ag1e look like a
  // session with nothing in it rather than a route that was never wired.
  it("separates a missing session from a core that does not serve the read", async () => {
    stubFetch(404, { error: "no session s1" });
    await expect(fetchMessages("s1")).rejects.toBeInstanceOf(NoSuchSession);

    stubFetch(501, { error: "/api/sessions/s1/messages is not served with the rust core" });
    const unserved = await fetchMessages("s1").catch((e: unknown) => e);
    expect(unserved).toBeInstanceOf(UnservedRead);
    expect((unserved as Error).message).toContain("not served with the rust core");

    stubFetch(200, { sessionId: "s1", messages: [] });
    await expect(fetchMessages("s1")).resolves.toEqual({ sessionId: "s1", messages: [] });
  });

  // The rendered screen is the read that does NOT need a width to travel with it: it
  // is the parsed grid, so there is nothing left to replay at the wrong one.
  it("reads the rendered screen as text, with history only when asked for", async () => {
    const { urls } = stubText(200, "hello from the grid");
    expect(await fetchScreenText("s1")).toBe("hello from the grid");
    await fetchScreenText("s1", 200);
    expect(urls).toEqual([
      "http://native.test/api/sessions/s1/screen",
      "http://native.test/api/sessions/s1/screen?scrollback=200",
    ]);
  });

  // The git reads (juancode-52e8.14.5). The distinction that matters here is the same
  // one the transcript reads make and for a sharper reason: a 501 rendered as an empty
  // diff tells somebody the agent changed nothing, which is the one wrong thing a
  // Changes view can say.
  it("reads the working tree, and tells a core that cannot from a tree with nothing in it", async () => {
    const { urls } = stubFetch(200, {
      git: true,
      root: "/repo",
      files: [
        {
          path: "a.txt",
          status: "modified",
          additions: 1,
          deletions: 0,
          binary: false,
          diff: "@@ -1 +1,2 @@\n keep\n+added\n",
          truncated: false,
        },
      ],
    });
    const diff = await fetchDiff("s1");
    expect(diff.git).toBe(true);
    expect(diff.files[0]?.path).toBe("a.txt");
    expect(urls).toEqual(["http://native.test/api/sessions/s1/diff"]);

    stubFetch(200, { git: true, files: [] });
    await expect(fetchDiff("s1")).resolves.toEqual({ git: true, files: [] });

    stubFetch(501, { error: "the swift core does not serve /diff" });
    await expect(fetchDiff("s1")).rejects.toBeInstanceOf(UnservedRead);
  });

  it("reads branch state, the worktree list and one file out of the tree", async () => {
    const { urls } = stubFetch(200, {
      git: true,
      branch: "main",
      detached: false,
      upstream: null,
      ahead: 1,
      behind: 0,
      dirty: true,
      remote: false,
    });
    expect((await fetchGitState("s1")).branch).toBe("main");

    stubFetch(200, [{ path: "/repo", branch: "main", head: "abc", main: true }]);
    expect((await fetchWorktrees("s1"))[0]?.main).toBe(true);

    const file = stubFetch(200, { path: "a.txt", content: "one\n" });
    expect((await fetchWorktreeFile("s1", "a.txt")).content).toBe("one\n");
    expect(file.urls).toEqual(["http://native.test/api/sessions/s1/file?path=a.txt"]);
    expect(urls).toEqual(["http://native.test/api/sessions/s1/git"]);
  });

  it("asks for the stream's row shape with json=1", async () => {
    const { urls } = stubFetch(200, {
      sessionId: "s1",
      cols: 80,
      rows: 24,
      cursor: { x: 0, y: 1, visible: true },
      alt: false,
      scrollback: 0,
      lines: [{ row: 0, segs: [{ text: "hi" }] }],
    });
    const screen = await fetchScreen("s1");
    expect(screen.lines[0]).toEqual({ row: 0, segs: [{ text: "hi" }] });
    expect(urls).toEqual(["http://native.test/api/sessions/s1/screen?json=1"]);
  });

  // A reaped pty has no screen to read — that is its own outcome, not "no session"
  // and not "this core can't", because the caller's answer differs: fall back to the
  // stored bytes.
  it("tells a reaped session apart from a missing one", async () => {
    stubFetch(409, { error: "session is not running — its screen died with the pty" });
    const err = await fetchScreenText("s1").catch((e: unknown) => e);
    expect(err).toBeInstanceOf(SessionNotRunning);
    expect((err as Error).message).toContain("not running");
  });

  it("names the app when it is not reachable at all", async () => {
    globalThis.fetch = (async () => {
      throw new Error("ECONNREFUSED");
    }) as unknown as typeof fetch;
    await expect(fetchScrollback("s1")).rejects.toThrow(/native app running/);
  });
});

describe("the chat digest", () => {
  const message = (over: Partial<SessionMessage>): SessionMessage => ({
    seq: 0,
    role: "assistant",
    text: "",
    ...over,
  });

  it("labels each role and names the tool on both tool rows", () => {
    const text = digest([
      message({ seq: 0, role: "user", text: "land the ticket" }),
      message({ seq: 1, role: "toolCall", tool: "Bash", text: "cargo test" }),
      message({ seq: 2, role: "toolResult", tool: "Bash", ok: false, text: "boom" }),
      message({ seq: 3, role: "assistant", text: "fixing" }),
    ]);
    expect(text).toBe(
      "user: land the ticket\n\ntool Bash: cargo test\n\ntool Bash failed: boom\n\nassistant: fixing",
    );
  });

  it("clips a long message so one tool result cannot bury the turn", () => {
    const text = digest([message({ text: "x".repeat(50) })], 10);
    expect(text).toBe(`assistant: ${"x".repeat(10)}…`);
  });

  it("says so rather than rendering nothing when there are no records", () => {
    expect(digest([])).toContain("no transcript records");
  });
});
