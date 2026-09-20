import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import { WebSocketServer, type WebSocket as WsSocket } from "ws";
import { appendDispatch, dispatch } from "./dispatch.ts";
import { DispatchConflictError, type DispatchDeps } from "./dispatch.ts";
import { consumeQueuedDispatch } from "./dispatch-results.ts";
import { dispatchOriginChat, getDispatch, listDispatches } from "./dispatch-registry.ts";

// `dispatch` is WS-first: a `create` with an ack over the native server's WS, and
// only when that's unreachable a durable `dispatch.jsonl` fallback. These tests
// stand up a throwaway WS server (pointed at via JUANCODE_API) for the ack paths
// and pin the mailbox line shape — the contract with the Swift `OracleDispatch`
// decoder and the ledger's `dispatchId` dedup.

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

describe("dispatch (WS-first with mailbox fallback)", () => {
  let dir: string;
  let wss: WebSocketServer | null = null;
  let received: Record<string, unknown>[];
  const prevDir = process.env.JUANCODE_ORACLE_DIR;
  const prevApi = process.env.JUANCODE_API;

  /** Start a mock native WS server whose reply to a `create` is produced by `respond`. */
  const startServer = async (
    respond: (msg: Record<string, unknown>, sock: WsSocket) => void,
  ): Promise<void> => {
    wss = new WebSocketServer({ host: "127.0.0.1", port: 0, path: "/ws" });
    wss.on("connection", (sock: WsSocket) => {
      // Mirror the real server: serverInfo greets before anything else, and the
      // client must skip it while waiting for the create's outcome.
      sock.send(JSON.stringify({ type: "serverInfo", protocolVersion: 1, capabilities: [] }));
      sock.on("message", (data) => {
        const msg = JSON.parse(data.toString()) as Record<string, unknown>;
        received.push(msg);
        respond(msg, sock);
      });
    });
    await new Promise<void>((resolve) => wss!.on("listening", () => resolve()));
    const { port } = wss!.address() as AddressInfo;
    process.env.JUANCODE_API = `http://127.0.0.1:${port}`;
  };

  beforeEach(() => {
    received = [];
    dir = mkdtempSync(join(tmpdir(), "oracle-dispatch-test-"));
    process.env.JUANCODE_ORACLE_DIR = dir;
    process.env.JUANCODE_API = "http://127.0.0.1:1"; // nothing listening by default
  });

  afterEach(async () => {
    if (prevDir === undefined) delete process.env.JUANCODE_ORACLE_DIR;
    else process.env.JUANCODE_ORACLE_DIR = prevDir;
    if (prevApi === undefined) delete process.env.JUANCODE_API;
    else process.env.JUANCODE_API = prevApi;
    rmSync(dir, { recursive: true, force: true });
    if (wss) await new Promise<void>((resolve) => wss!.close(() => resolve()));
    wss = null;
  });

  const mailboxLines = (): Record<string, unknown>[] => {
    const path = join(dir, "dispatch.jsonl");
    if (!existsSync(path)) return [];
    return readFileSync(path, "utf8")
      .split("\n")
      .filter(Boolean)
      .map((l) => JSON.parse(l) as Record<string, unknown>);
  };

  it("returns the real sessionId when the app acks the create", async () => {
    await startServer((msg, sock) => {
      if (msg.type !== "create") return;
      sock.send(JSON.stringify({ type: "created", session: { id: "sess-42" } }));
    });

    const out = await dispatch({ project: "/abs/repo", prompt: "do the thing" });

    expect(out.started).toBe(true);
    expect(out.queued).toBe(false);
    expect(out.sessionId).toBe("sess-42");
    expect(out.message).toContain("sess-42");
    // WS delivery succeeded — nothing must land in the mailbox.
    expect(mailboxLines()).toEqual([]);
  });

  it("sends the create wire frame the native decoder expects", async () => {
    await startServer((msg, sock) => {
      if (msg.type !== "create") return;
      sock.send(JSON.stringify({ type: "created", session: { id: "s-1" } }));
    });

    await dispatch({ project: "/abs/repo", prompt: "seed it", provider: "codex", worktree: true });

    expect(received).toHaveLength(1);
    const frame = received[0]!;
    expect(frame.type).toBe("create");
    expect(frame.provider).toBe("codex");
    expect(frame.cwd).toBe("/abs/repo");
    expect(frame.initialInput).toBe("seed it");
    expect(frame.skipPermissions).toBe(true);
    expect(frame.isolateWorktree).toBe(true);
    // No grid is sent: the app boots the CLI at the desktop's real terminal size,
    // so the dispatched turn isn't printed at a nominal width and stuck there.
    expect(frame.cols).toBeUndefined();
    expect(frame.rows).toBeUndefined();
    expect(String(frame.dispatchId)).toMatch(UUID_RE);
  });

  it("surfaces a server-side error verbatim and does NOT queue", async () => {
    await startServer((msg, sock) => {
      if (msg.type !== "create") return;
      sock.send(JSON.stringify({ type: "error", message: '"/nope" is not an existing directory' }));
    });

    await expect(dispatch({ project: "/nope", prompt: "x" })).rejects.toThrow(
      /not an existing directory/,
    );
    // A real rejection must not fall back to the mailbox — it would just fail again.
    expect(mailboxLines()).toEqual([]);
  });

  it("queues to the mailbox (same dispatchId) when the app is unreachable", async () => {
    // Default JUANCODE_API points at a dead port.
    const out = await dispatch({ project: "/abs/repo", prompt: "later", worktree: true });

    expect(out.started).toBe(false);
    expect(out.queued).toBe(true);
    expect(out.sessionId).toBeNull();
    expect(out.message).toMatch(/queued/i);
    // "queued" must not read as "nothing happened" — that misreading is what put
    // two agents on one destructive ticket (juancode-nwrb).
    expect(out.state).toBe("queued");
    expect(out.willStart).toBe(true);
    expect(out.queuedReason).toBe("unreachable");
    expect(out.advice).toMatch(/do NOT post this dispatch again/i);
    expect(out.duplicateOf).toBeNull();

    const lines = mailboxLines();
    expect(lines).toHaveLength(1);
    expect(lines[0]).toEqual({
      project: "/abs/repo",
      prompt: "later",
      provider: "claude",
      worktree: true,
      dispatchId: out.dispatchId,
    });
    // The queued id is remembered so the results relay can confirm its start.
    expect(consumeQueuedDispatch(out.dispatchId)).toBe(true);
  });

  it("falls back to the mailbox when the app never acks (timeout)", async () => {
    await startServer(() => {
      /* accept the create, never reply */
    });

    const out = await dispatch({ project: "/abs/repo", prompt: "raced" }, 150);

    expect(out.queued).toBe(true);
    // The app answered the socket and then didn't ack: "loaded", not "down".
    expect(out.queuedReason).toBe("no-ack");
    expect(out.message).toMatch(/didn't ack/i);
    expect(out.willStart).toBe(true);
    const lines = mailboxLines();
    expect(lines).toHaveLength(1);
    // Same id on both paths — the native ledger dedupes if the create DID land.
    expect(lines[0]!.dispatchId).toBe(out.dispatchId);
  });

  it("records a Telegram-originated dispatch in the registry (chat mapping + args)", async () => {
    await startServer((msg, sock) => {
      if (msg.type !== "create") return;
      sock.send(JSON.stringify({ type: "created", session: { id: "sess-7" } }));
    });

    const out = await dispatch({
      project: "/abs/repo",
      prompt: "from telegram",
      telegramChatId: 555,
    });

    expect(await dispatchOriginChat(out.dispatchId)).toBe(555);
    expect(await getDispatch(out.dispatchId)).toMatchObject({
      project: "/abs/repo",
      prompt: "from telegram",
      provider: "claude",
      telegramChatId: 555,
      outcome: "started",
      sessionId: "sess-7",
    });
    // The chat id is sidecar-side correlation only — never on the create frame.
    expect(received[0]).not.toHaveProperty("telegramChatId");
  });

  it("records non-Telegram dispatches too, with a null origin", async () => {
    // App unreachable → queued; the registry still captures args + outcome.
    const out = await dispatch({ project: "/abs/repo", prompt: "later" });
    expect(await getDispatch(out.dispatchId)).toMatchObject({
      telegramChatId: null,
      outcome: "queued",
      sessionId: null,
    });
    expect(await dispatchOriginChat(out.dispatchId)).toBeNull();
  });

  it("records a rejection before rethrowing it", async () => {
    await startServer((msg, sock) => {
      if (msg.type !== "create") return;
      sock.send(JSON.stringify({ type: "error", message: "bad path" }));
    });
    await expect(dispatch({ project: "/nope", prompt: "x", telegramChatId: 9 })).rejects.toThrow(
      "bad path",
    );
    const recorded = (await listDispatches(1))[0]!;
    expect(recorded).toMatchObject({ outcome: "rejected", error: "bad path", telegramChatId: 9 });
  });

  it("appendDispatch writes one OracleDispatch JSON line + newline", async () => {
    await appendDispatch({ project: "/abs/repo", prompt: "do the thing" }, "id-1");
    await appendDispatch(
      { project: "/other", prompt: "isolated", provider: "codex", worktree: true },
      "id-2",
    );

    const lines = mailboxLines();
    expect(lines).toEqual([
      {
        project: "/abs/repo",
        prompt: "do the thing",
        provider: "claude",
        worktree: false,
        dispatchId: "id-1",
      },
      {
        project: "/other",
        prompt: "isolated",
        provider: "codex",
        worktree: true,
        dispatchId: "id-2",
      },
    ]);
  });
});

// The native ledger dedupes one `dispatchId`, and a retry mints a new one — so a
// caller that read "queued" as "nothing happened" and posted again got a SECOND
// agent on the same ticket (juancode-nwrb). These pin the two guards in front of
// the create: the request fingerprint and the bd ticket id.

describe("dispatch guards (one session per request, one session per ticket)", () => {
  let dir: string;
  let wss: WebSocketServer | null = null;
  let creates: Record<string, unknown>[];
  let sessions: Record<string, unknown>[];
  const prevDir = process.env.JUANCODE_ORACLE_DIR;
  const prevApi = process.env.JUANCODE_API;

  /** Sessions the fake native app reports — the guards' view of "what's live". */
  const deps: DispatchDeps = { fetchSessions: async () => sessions };

  const startServer = async (delayMs = 0): Promise<void> => {
    let n = 0;
    wss = new WebSocketServer({ host: "127.0.0.1", port: 0, path: "/ws" });
    wss.on("connection", (sock: WsSocket) => {
      sock.send(JSON.stringify({ type: "serverInfo", protocolVersion: 1, capabilities: [] }));
      sock.on("message", (data) => {
        const msg = JSON.parse(data.toString()) as Record<string, unknown>;
        if (msg.type !== "create") return;
        creates.push(msg);
        const id = `s-${++n}`;
        const reply = () => sock.send(JSON.stringify({ type: "created", session: { id } }));
        if (delayMs) setTimeout(reply, delayMs);
        else reply();
      });
    });
    await new Promise<void>((resolve) => wss!.on("listening", () => resolve()));
    const { port } = wss!.address() as AddressInfo;
    process.env.JUANCODE_API = `http://127.0.0.1:${port}`;
  };

  beforeEach(() => {
    creates = [];
    sessions = [];
    dir = mkdtempSync(join(tmpdir(), "oracle-guard-test-"));
    process.env.JUANCODE_ORACLE_DIR = dir;
    process.env.JUANCODE_API = "http://127.0.0.1:1";
  });

  afterEach(async () => {
    if (prevDir === undefined) delete process.env.JUANCODE_ORACLE_DIR;
    else process.env.JUANCODE_ORACLE_DIR = prevDir;
    if (prevApi === undefined) delete process.env.JUANCODE_API;
    else process.env.JUANCODE_API = prevApi;
    rmSync(dir, { recursive: true, force: true });
    if (wss) await new Promise<void>((resolve) => wss!.close(() => resolve()));
    wss = null;
  });

  const req = {
    project: "/abs/repo",
    prompt: "Implement bd ticket juancode-h1an.",
    worktree: true,
  };

  it("collapses a re-post of the same request onto the first dispatch", async () => {
    await startServer();

    const first = await dispatch(req, 2000, deps);
    const again = await dispatch(req, 2000, deps);

    expect(first.state).toBe("started");
    expect(again.state).toBe("duplicate");
    // The caller gets the id of the dispatch that actually exists, so tracking it
    // works — and no second session was created.
    expect(again.dispatchId).toBe(first.dispatchId);
    expect(again.duplicateOf).toBe(first.dispatchId);
    expect(again.sessionId).toBe("s-1");
    expect(again.message).toMatch(/not dispatched again/i);
    expect(creates).toHaveLength(1);
  });

  it("collapses a retry that lands while the first create is still unacked", async () => {
    // The real shape of the bug: the retry arrives inside the ack window, before
    // any registry row exists to compare against.
    await startServer(120);

    const [a, b] = await Promise.all([dispatch(req, 2000, deps), dispatch(req, 2000, deps)]);

    expect(creates).toHaveLength(1);
    const states = [a.state, b.state].sort();
    expect(states).toEqual(["duplicate", "started"]);
    expect(a.sessionId).toBe("s-1");
    expect(b.sessionId).toBe("s-1");
  });

  it("refuses a differently-worded dispatch of a ticket that already has a live session", async () => {
    await startServer();

    const first = await dispatch(req, 2000, deps);
    sessions = [{ id: "s-1", status: "running", dispatchId: first.dispatchId, cwd: "/abs/repo" }];

    const refusal = dispatch(
      { ...req, prompt: "Please work bd ticket juancode-h1an end-to-end, carefully." },
      2000,
      deps,
    );
    await expect(refusal).rejects.toThrow(/juancode-h1an already has a live agent session/);
    // Typed, so the HTTP route can answer 409 instead of 500 — a retrying caller
    // needs "you already have one", not "something broke".
    await expect(refusal).rejects.toBeInstanceOf(DispatchConflictError);
    expect(creates).toHaveLength(1);
  });

  it("lets the same ticket through once its session has exited", async () => {
    await startServer();

    const first = await dispatch(req, 2000, deps);
    sessions = [{ id: "s-1", status: "exited", dispatchId: first.dispatchId, cwd: "/abs/repo" }];

    const second = await dispatch({ ...req, prompt: "Redo bd ticket juancode-h1an." }, 2000, deps);
    expect(second.state).toBe("started");
    expect(second.sessionId).toBe("s-2");
  });

  it("force: true dispatches past both guards", async () => {
    await startServer();

    const first = await dispatch(req, 2000, deps);
    sessions = [{ id: "s-1", status: "running", dispatchId: first.dispatchId, cwd: "/abs/repo" }];

    const forced = await dispatch({ ...req, force: true }, 2000, deps);
    expect(forced.state).toBe("started");
    expect(forced.sessionId).toBe("s-2");
    expect(forced.dispatchId).not.toBe(first.dispatchId);
    expect(creates).toHaveLength(2);
  });

  it("dedupes on a caller-supplied key even when the prompt was edited", async () => {
    await startServer();

    const first = await dispatch({ ...req, idempotencyKey: "post-1" }, 2000, deps);
    const again = await dispatch(
      { ...req, prompt: "same work, reworded", idempotencyKey: "post-1" },
      2000,
      deps,
    );

    expect(again.state).toBe("duplicate");
    expect(again.dispatchId).toBe(first.dispatchId);
    expect(creates).toHaveLength(1);
  });

  it("records the ticket and fingerprint so a later process can guard on them", async () => {
    await startServer();
    const out = await dispatch(req, 2000, deps);
    const stored = await getDispatch(out.dispatchId);
    expect(stored).toMatchObject({ ticket: "juancode-h1an", idempotencyKey: null });
    expect(stored!.fingerprint).toMatch(/^req:[0-9a-f]{32}$/);
    expect(out.ticket).toBe("juancode-h1an");
  });

  it("queues a free-form dispatch with no ticket without inventing one", async () => {
    const out = await dispatch({ project: "/abs/repo", prompt: "tidy the README" }, 2000, deps);
    expect(out.ticket).toBeNull();
    expect(out.state).toBe("queued");
    expect(out.willStart).toBe(true);
  });
});
