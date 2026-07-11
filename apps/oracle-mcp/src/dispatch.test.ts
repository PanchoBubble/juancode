import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import { WebSocketServer, type WebSocket as WsSocket } from "ws";
import { appendDispatch, dispatch } from "./dispatch.ts";
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
    expect(typeof frame.cols).toBe("number");
    expect(typeof frame.rows).toBe("number");
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
