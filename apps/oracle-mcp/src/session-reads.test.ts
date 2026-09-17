import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  digest,
  fetchMessages,
  fetchScrollback,
  fetchTranscript,
  NoSuchSession,
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
