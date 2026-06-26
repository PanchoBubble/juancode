import type { Server } from "node:http";
import { randomUUID } from "node:crypto";
import { WebSocketServer } from "ws";
import { verifyWsUpgrade } from "./auth.ts";
import { sessionDb } from "./db.ts";
import { editors } from "./editor.ts";
import { terminals } from "./terminal.ts";
import { createWorktree } from "./git.ts";
import { registry } from "./registry.ts";
import { healthMonitor } from "./healthMonitor.ts";
import { isProviderId } from "./providers.ts";
import { recoverCliSessionId } from "./recoverSession.ts";
import type { Session } from "./session.ts";
import type { ClientMessage, ServerMessage } from "./protocol.ts";

export function setupWebSocket(server: Server): void {
  // `noServer` so we own the upgrade and can gate it on the auth token before
  // the handshake completes (a 401 here is rejected before any pty is touched).
  const wss = new WebSocketServer({ noServer: true });

  server.on("upgrade", (req, socket, head) => {
    const { pathname } = new URL(req.url ?? "", "http://localhost");
    if (pathname !== "/ws") {
      socket.destroy();
      return;
    }
    if (!verifyWsUpgrade(req, socket)) return; // writes 401 + destroys on failure
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit("connection", ws, req));
  });

  wss.on("connection", (ws) => {
    // sessionId -> cleanup functions for this connection's subscriptions.
    const subscriptions = new Map<string, () => void>();
    // Editor ptys this connection opened — killed when it disconnects so an
    // editor never outlives the tab that opened it (sessions, by design, do).
    const openedEditors = new Set<string>();
    // Shell terminal ptys this connection opened — same tab-scoped lifetime.
    const openedTerminals = new Set<string>();

    const send = (msg: ServerMessage) => {
      if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(msg));
    };

    // Real sessions and ephemeral editor / shell-terminal ptys are all addressed
    // by id over the same input/resize/kill/output/exit messages — resolve
    // against all three.
    const resolvePty = (id: string) => registry.get(id) ?? editors.get(id) ?? terminals.get(id);

    const subscribe = (sessionId: string) => {
      if (subscriptions.has(sessionId)) return;
      const session = resolvePty(sessionId);
      if (!session) return;
      const offOutput = session.onOutput((data) => send({ type: "output", sessionId, data }));
      const offExit = session.onExit((exitCode) => send({ type: "exit", sessionId, exitCode }));
      subscriptions.set(sessionId, () => {
        offOutput();
        offExit();
      });
    };

    // Activity (busy / done / waiting-for-input) is broadcast for *every* live
    // session, not just the attached one, so the sidebar can show a status icon
    // per session. This is independent of `subscribe` (which carries the heavy
    // output stream only for sessions this tab is actually viewing).
    const activityWatchers = new Set<() => void>();
    const watchActivity = (session: Session) => {
      send({ type: "activity", sessionId: session.id, state: session.activity, notify: false });
      activityWatchers.add(
        session.onActivity((state, notify) =>
          send({ type: "activity", sessionId: session.id, state, notify }),
        ),
      );
    };
    for (const s of registry.all()) watchActivity(s);
    activityWatchers.add(registry.onCreate(watchActivity));

    // Periodic health sweep: the full set of dead/stale sessions, pushed on
    // connect and after every sweep so the client can surface them + reactivate.
    activityWatchers.add(healthMonitor.onHealth((reports) => send({ type: "health", reports })));

    ws.on("message", (raw) => {
      let msg: ClientMessage;
      try {
        msg = JSON.parse(raw.toString()) as ClientMessage;
      } catch {
        send({ type: "error", message: "Invalid JSON" });
        return;
      }
      void handle(msg);
    });

    const handle = async (msg: ClientMessage): Promise<void> => {

      switch (msg.type) {
        case "create": {
          if (!isProviderId(msg.provider)) {
            send({ type: "error", message: `Unknown provider: ${msg.provider}` });
            return;
          }
          try {
            // Opt-in isolation: spin up a fresh worktree off cwd and run the
            // session there so it can't clobber other sessions' working tree.
            let cwd = msg.cwd;
            let worktreePath: string | null = null;
            if (msg.isolateWorktree) {
              const wt = await createWorktree(msg.cwd, randomUUID().slice(0, 8));
              cwd = wt.path;
              worktreePath = wt.path;
            }
            const session = registry.create(
              msg.provider,
              cwd,
              msg.cols,
              msg.rows,
              { skipPermissions: msg.skipPermissions },
              worktreePath,
            );
            if (msg.initialInput) {
              // Surface a delivery failure instead of leaving the session silently
              // idle with an unsent prompt (the dispatch-loop bug we guard against).
              session.autoSubmit(msg.initialInput, (outcome) => {
                if (!outcome.ok) {
                  send({ type: "error", message: `Couldn't deliver the prompt: ${outcome.reason}` });
                }
              });
            }
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

        case "reactivate": {
          if (registry.get(msg.sessionId)) return; // already live
          const meta = sessionDb.get(msg.sessionId);
          if (!meta) {
            send({ type: "error", sessionId: msg.sessionId, message: "Session not found" });
            return;
          }
          // Old sessions predate CLI-id capture; try to recover it from the
          // CLI's own transcript so they can be resumed like newer ones.
          if (!meta.cliSessionId) {
            const recovered = await recoverCliSessionId(
              meta.provider,
              meta.cwd,
              meta.createdAt,
              sessionDb.usedCliSessionIds(),
            );
            if (recovered) {
              sessionDb.setCliSessionId(meta.id, recovered);
              meta.cliSessionId = recovered;
            }
          }
          if (!meta.cliSessionId) {
            send({
              type: "unresumable",
              sessionId: msg.sessionId,
              reason: "No prior CLI conversation could be found to resume this session.",
            });
            return;
          }
          try {
            // Carry the persisted scrollback into the revived session (with a
            // separator before the resumed CLI repaints its TUI underneath) so
            // the prior conversation survives the new pty and any re-attach.
            const prior = sessionDb.getScrollback(meta.id);
            const seed = prior
              ? `${prior}\r\n\x1b[2m── session resumed ──\x1b[0m\r\n`
              : "";
            const session = registry.resume(meta, msg.cols, msg.rows, seed);
            subscribe(session.id);
            send({
              type: "attached",
              sessionId: session.id,
              scrollback: session.getScrollback(),
              session: session.meta,
            });
          } catch (err) {
            send({
              type: "error",
              sessionId: msg.sessionId,
              message: `Failed to resume: ${asMessage(err)}`,
            });
          }
          return;
        }

        case "setSkipPermissions": {
          if (!registry.get(msg.sessionId)) {
            send({ type: "error", sessionId: msg.sessionId, message: "Session is not running" });
            return;
          }
          // Drop the current subscription before the resume-restart so the client
          // doesn't observe the transient exit of the old pty.
          const cleanup = subscriptions.get(msg.sessionId);
          if (cleanup) {
            cleanup();
            subscriptions.delete(msg.sessionId);
          }
          try {
            const session = await registry.setSkipPermissions(
              msg.sessionId,
              msg.skipPermissions,
              msg.cols,
              msg.rows,
            );
            subscribe(session.id);
            send({
              type: "attached",
              sessionId: session.id,
              scrollback: session.getScrollback(),
              session: session.meta,
            });
          } catch (err) {
            // The flip failed before killing the pty (e.g. id not captured yet) —
            // re-subscribe so the still-live session keeps streaming.
            subscribe(msg.sessionId);
            send({
              type: "error",
              sessionId: msg.sessionId,
              message: `Failed to change permissions: ${asMessage(err)}`,
            });
          }
          return;
        }

        case "openEditor": {
          try {
            const ed = editors.open(msg.cwd, msg.file, msg.cols, msg.rows);
            openedEditors.add(ed.id);
            subscribe(ed.id);
            send({ type: "editorReady", editorId: ed.id });
          } catch (err) {
            send({ type: "error", message: `Failed to open editor: ${asMessage(err)}` });
          }
          return;
        }

        case "openTerminal": {
          try {
            const sh = terminals.open(msg.cwd, msg.cols, msg.rows);
            openedTerminals.add(sh.id);
            subscribe(sh.id);
            send({ type: "terminalReady", terminalId: sh.id, requestId: msg.requestId });
          } catch (err) {
            send({ type: "error", message: `Failed to open terminal: ${asMessage(err)}` });
          }
          return;
        }

        case "input": {
          resolvePty(msg.sessionId)?.write(msg.data);
          return;
        }

        case "resize": {
          resolvePty(msg.sessionId)?.resize(msg.cols, msg.rows);
          return;
        }

        case "kill": {
          resolvePty(msg.sessionId)?.kill();
          return;
        }

        default: {
          send({ type: "error", message: "Unknown message type" });
        }
      }
    };

    ws.on("close", () => {
      for (const cleanup of subscriptions.values()) cleanup();
      subscriptions.clear();
      for (const off of activityWatchers) off();
      activityWatchers.clear();
      // Editor ptys are tab-scoped — tear them down with the connection.
      for (const id of openedEditors) editors.get(id)?.kill();
      openedEditors.clear();
      // Shell terminals are likewise tab-scoped.
      for (const id of openedTerminals) terminals.get(id)?.kill();
      openedTerminals.clear();
    });
  });
}

function asMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
