/**
 * WebSocket wire protocol — mirror of `apps/server/src/protocol.ts`.
 * Keep the two files in sync.
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

export type ClientMessage =
  | { type: "create"; provider: ProviderId; cwd: string; cols: number; rows: number }
  | { type: "attach"; sessionId: string; cols: number; rows: number }
  | { type: "input"; sessionId: string; data: string }
  | { type: "resize"; sessionId: string; cols: number; rows: number }
  | { type: "kill"; sessionId: string };

export type ServerMessage =
  | { type: "created"; session: SessionMeta }
  | { type: "attached"; sessionId: string; scrollback: string; session: SessionMeta }
  | { type: "output"; sessionId: string; data: string }
  | { type: "exit"; sessionId: string; exitCode: number | null }
  | { type: "error"; sessionId?: string; message: string };
