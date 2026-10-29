import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { AddressInfo } from "node:net";
import { WebSocketServer } from "ws";
import { deliverSessionNotification } from "./notification-delivery.ts";

describe("notification queue acceptance", () => {
  let server: WebSocketServer;
  let received: Record<string, unknown>[];
  let mode: "accept" | "already-queued" | "refuse" | "disconnect";
  const previous = process.env.JUANCODE_API;
  beforeEach(async () => {
    received = [];
    mode = "accept";
    server = new WebSocketServer({ host: "127.0.0.1", port: 0 });
    server.on("connection", (socket) => {
      socket.send(JSON.stringify({ type: "serverInfo", capabilities: ["queue"] }));
      socket.on("message", (data) => {
        const frame = JSON.parse(data.toString()) as Record<string, unknown>;
        received.push(frame);
        if (mode === "refuse") {
          socket.send(
            JSON.stringify({ type: "error", sessionId: "parent", message: "queue-item-not-found" }),
          );
          return;
        }
        if (mode === "disconnect") {
          socket.close();
          return;
        }
        socket.send(
          JSON.stringify({
            type: "queue",
            sessionId: "parent",
            items:
              frame.type === "queueMessage" || mode === "already-queued"
                ? [{ text: "event text" }]
                : [],
          }),
        );
      });
    });
    await new Promise<void>((resolve) => server.on("listening", resolve));
    process.env.JUANCODE_API = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });
  afterEach(async () => {
    if (previous === undefined) delete process.env.JUANCODE_API;
    else process.env.JUANCODE_API = previous;
    await new Promise<void>((resolve) => server.close(() => resolve()));
  });
  it("subscribes and waits for an accepted queue item", async () => {
    await deliverSessionNotification("parent", "event text");
    expect(received.map((r) => r.type)).toEqual(["subscribeQueue", "queueMessage"]);
  });
  it("reuses a notification already present in the queue", async () => {
    mode = "already-queued";
    await deliverSessionNotification("parent", "event text");
    expect(received.map((r) => r.type)).toEqual(["subscribeQueue"]);
  });
  it("preserves queue refusals as errors", async () => {
    mode = "refuse";
    await expect(deliverSessionNotification("parent", "event text")).rejects.toThrow(
      "queue-item-not-found",
    );
  });
  it("does not treat a disconnected socket as successful delivery", async () => {
    mode = "disconnect";
    await expect(deliverSessionNotification("parent", "event text")).rejects.toThrow(
      "before acknowledgement",
    );
  });
});
