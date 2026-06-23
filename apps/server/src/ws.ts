import type { Server } from "node:http";
import { WebSocketServer } from "ws";
import { sessionDb } from "./db.ts";
import { registry } from "./registry.ts";
import { isProviderId } from "./providers.ts";
import type { ClientMessage, ServerMessage } from "./protocol.ts";

export function setupWebSocket(server: Server): void {
  const wss = new WebSocketServer({ server, path: "/ws" });

  wss.on("connection", (ws) => {
    // sessionId -> cleanup functions for this connection's subscriptions.
    const subscriptions = new Map<string, () => void>();

    const send = (msg: ServerMessage) => {
      if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(msg));
    };

    const subscribe = (sessionId: string) => {
      if (subscriptions.has(sessionId)) return;
      const session = registry.get(sessionId);
      if (!session) return;
      const offOutput = session.onOutput((data) => send({ type: "output", sessionId, data }));
      const offExit = session.onExit((exitCode) => send({ type: "exit", sessionId, exitCode }));
      subscriptions.set(sessionId, () => {
        offOutput();
        offExit();
      });
    };

    ws.on("message", (raw) => {
      let msg: ClientMessage;
      try {
        msg = JSON.parse(raw.toString()) as ClientMessage;
      } catch {
        send({ type: "error", message: "Invalid JSON" });
        return;
      }

      switch (msg.type) {
        case "create": {
          if (!isProviderId(msg.provider)) {
            send({ type: "error", message: `Unknown provider: ${msg.provider}` });
            return;
          }
          try {
            const session = registry.create(msg.provider, msg.cwd, msg.cols, msg.rows);
            send({ type: "created", session: session.meta });
            subscribe(session.id);
            send({ type: "attached", sessionId: session.id, scrollback: "", session: session.meta });
          } catch (err) {
            send({ type: "error", message: `Failed to start ${msg.provider}: ${asMessage(err)}` });
          }
          return;
        }

        case "attach": {
          const live = registry.get(msg.sessionId);
          if (live) {
            live.resize(msg.cols, msg.rows);
            subscribe(msg.sessionId);
            send({
              type: "attached",
              sessionId: msg.sessionId,
              scrollback: live.getScrollback(),
              session: live.meta,
            });
            return;
          }
          // Not live: replay persisted history for an exited session.
          const meta = sessionDb.get(msg.sessionId);
          if (!meta) {
            send({ type: "error", sessionId: msg.sessionId, message: "Session not found" });
            return;
          }
          send({
            type: "attached",
            sessionId: msg.sessionId,
            scrollback: sessionDb.getScrollback(msg.sessionId),
            session: meta,
          });
          send({ type: "exit", sessionId: msg.sessionId, exitCode: meta.exitCode });
          return;
        }

        case "input": {
          registry.get(msg.sessionId)?.write(msg.data);
          return;
        }

        case "resize": {
          registry.get(msg.sessionId)?.resize(msg.cols, msg.rows);
          return;
        }

        case "kill": {
          registry.get(msg.sessionId)?.kill();
          return;
        }

        default: {
          send({ type: "error", message: "Unknown message type" });
        }
      }
    });

    ws.on("close", () => {
      for (const cleanup of subscriptions.values()) cleanup();
      subscriptions.clear();
    });
  });
}

function asMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
