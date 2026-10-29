import { WebSocket } from "ws";
import { nativeWsUrl } from "./oracle.ts";

/** Confirm acceptance from a queue snapshot, rather than treating a socket write
 * as success. IDs embedded in the text let a retry reuse a still-queued item.
 * A crash after acceptance but before the outbox update can redeliver; consumers
 * must treat a repeated notification ID as the same event. */
export function deliverSessionNotification(sessionId: string, text: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(nativeWsUrl());
    let sent = false;
    const finish = (error?: Error) => {
      clearTimeout(timer);
      socket.removeAllListeners();
      socket.on("error", () => {});
      socket.close();
      if (error) reject(error);
      else resolve();
    };
    const timer = setTimeout(
      () => finish(new Error("Notification queue acknowledgement timed out")),
      5000,
    );
    socket.on("error", (e) => finish(e));
    socket.on("close", () =>
      finish(new Error("Notification connection closed before acknowledgement")),
    );
    socket.on("message", (data) => {
      let frame: Record<string, unknown>;
      try {
        frame = JSON.parse(data.toString()) as Record<string, unknown>;
      } catch {
        return;
      }
      if (frame.type === "serverInfo") {
        if (!Array.isArray(frame.capabilities) || !frame.capabilities.includes("queue")) {
          finish(new Error("Native server does not support the session queue"));
          return;
        }
        socket.send(JSON.stringify({ type: "subscribeQueue", sessionId }));
      } else if (frame.type === "error" && frame.sessionId === sessionId) {
        finish(new Error(String(frame.message)));
      } else if (
        frame.type === "queue" &&
        frame.sessionId === sessionId &&
        Array.isArray(frame.items)
      ) {
        if (frame.items.some((item: { text?: string }) => item.text === text)) {
          finish();
          return;
        }
        if (!sent) {
          sent = true;
          socket.send(JSON.stringify({ type: "queueMessage", sessionId, text }));
        }
      }
    });
  });
}
