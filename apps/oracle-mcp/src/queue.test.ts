import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { AddressInfo } from "node:net";
import { WebSocketServer, type WebSocket as WsSocket } from "ws";
import { queueMessages } from "./oracle.ts";

// `queueMessages` opens a short-lived WS to the native server and sends one
// `queueMessage` per text, in order. We stand up a throwaway WS server on
// 127.0.0.1 (pointed at via JUANCODE_API) and assert the wire frames — this is the
// contract the native `WireProtocol.swift` decoder relies on.
describe("queueMessages", () => {
  let wss: WebSocketServer;
  let received: unknown[];
  const prev = process.env.JUANCODE_API;

  beforeEach(async () => {
    received = [];
    wss = new WebSocketServer({ host: "127.0.0.1", port: 0, path: "/ws" });
    wss.on("connection", (sock: WsSocket) => {
      sock.on("message", (data) => {
        try {
          received.push(JSON.parse(data.toString()));
        } catch {
          /* ignore non-json */
        }
      });
    });
    await new Promise<void>((resolve) => wss.on("listening", () => resolve()));
    const { port } = wss.address() as AddressInfo;
    process.env.JUANCODE_API = `http://127.0.0.1:${port}`;
  });

  afterEach(async () => {
    if (prev === undefined) delete process.env.JUANCODE_API;
    else process.env.JUANCODE_API = prev;
    await new Promise<void>((resolve) => wss.close(() => resolve()));
  });

  it("sends one queueMessage per text, in order", async () => {
    await queueMessages("sess-1", ["first", "second", "third"]);
    // Give the server a tick to flush any in-flight frames.
    await new Promise((r) => setTimeout(r, 50));
    expect(received).toEqual([
      { type: "queueMessage", sessionId: "sess-1", text: "first" },
      { type: "queueMessage", sessionId: "sess-1", text: "second" },
      { type: "queueMessage", sessionId: "sess-1", text: "third" },
    ]);
  });

  it("trims and drops blank messages", async () => {
    await queueMessages("sess-2", ["  keep me  ", "   ", "", "also kept"]);
    await new Promise((r) => setTimeout(r, 50));
    expect(received).toEqual([
      { type: "queueMessage", sessionId: "sess-2", text: "keep me" },
      { type: "queueMessage", sessionId: "sess-2", text: "also kept" },
    ]);
  });

  it("is a no-op when there are no deliverable messages (opens no socket)", async () => {
    let connected = false;
    wss.on("connection", () => {
      connected = true;
    });
    await queueMessages("sess-3", ["", "   "]);
    await new Promise((r) => setTimeout(r, 50));
    expect(received).toEqual([]);
    expect(connected).toBe(false);
  });

  it("rejects with a clear error when the native app is unreachable", async () => {
    process.env.JUANCODE_API = "http://127.0.0.1:1"; // nothing listening
    await expect(queueMessages("sess-4", ["hi"])).rejects.toThrow();
  });
});
