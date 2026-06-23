/**
 * WebSocket wire protocol shared between server and web.
 *
 * Keep this file dependency-free and in sync with `apps/web/src/protocol.ts`.
 */

export type ProviderId = "claude" | "codex";

export interface SessionMeta {
  id: string;
  provider: ProviderId;
  cwd: string;
  title: string;
  status: "running" | "exited";
  exitCode: number | null;
  createdAt: number;
  updatedAt: number;
}

/** Messages sent from the browser to the server. */
export type ClientMessage =
  | { type: "create"; provider: ProviderId; cwd: string; cols: number; rows: number }
  | { type: "attach"; sessionId: string; cols: number; rows: number }
  | { type: "input"; sessionId: string; data: string }
  | { type: "resize"; sessionId: string; cols: number; rows: number }
  | { type: "kill"; sessionId: string };

/** Messages sent from the server to the browser. */
export type ServerMessage =
  | { type: "created"; session: SessionMeta }
  | { type: "attached"; sessionId: string; scrollback: string; session: SessionMeta }
  | { type: "output"; sessionId: string; data: string }
  | { type: "exit"; sessionId: string; exitCode: number | null }
  | { type: "error"; sessionId?: string; message: string };
