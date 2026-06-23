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
  /**
   * The CLI's own resumable conversation id, used to revive an exited session
   * via `claude --resume` / `codex resume`. Known immediately for Claude (we
   * force it with `--session-id`); discovered after spawn for Codex. Null until
   * captured — when null the session can be viewed but not reactivated.
   */
  cliSessionId: string | null;
}

export type ClientMessage =
  | { type: "create"; provider: ProviderId; cwd: string; cols: number; rows: number }
  | { type: "attach"; sessionId: string; cols: number; rows: number }
  | { type: "reactivate"; sessionId: string; cols: number; rows: number }
  | { type: "input"; sessionId: string; data: string }
  | { type: "resize"; sessionId: string; cols: number; rows: number }
  | { type: "kill"; sessionId: string };

export type ServerMessage =
  | { type: "created"; session: SessionMeta }
  | { type: "attached"; sessionId: string; scrollback: string; session: SessionMeta }
  | { type: "output"; sessionId: string; data: string }
  | { type: "exit"; sessionId: string; exitCode: number | null }
  | { type: "error"; sessionId?: string; message: string };

// ── REST data types (diff viewer + inline review comments) ───────────────────

export type FileStatus = "modified" | "added" | "deleted" | "renamed" | "untracked";

export interface DiffFile {
  path: string;
  oldPath: string | null;
  status: FileStatus;
  additions: number;
  deletions: number;
  binary: boolean;
  diff: string;
  truncated: boolean;
}

export interface DiffResult {
  git: boolean;
  root?: string;
  files: DiffFile[];
  truncatedFiles?: boolean;
}

/** Which side of the diff a comment is anchored to. */
export type CommentSide = "old" | "new";

/** A GitHub-PR-style inline comment on a specific diff line. */
export interface DiffComment {
  id: string;
  sessionId: string;
  file: string;
  side: CommentSide;
  line: number;
  body: string;
  createdAt: number;
}

// ── REST data types (beads issue tracker, per work folder) ───────────────────

/** One bd issue as surfaced in the UI. Mirrors `bd list --json` fields we use. */
export interface BeadsIssue {
  id: string;
  title: string;
  status: string;
  priority: number;
  issueType: string;
  parent: string | null;
  dependencyCount: number;
  dependentCount: number;
  /** Unblocked and actionable now (from `bd ready`). */
  ready: boolean;
  /** Has unsatisfied dependencies (from `bd blocked`). */
  blocked: boolean;
}

/** Result of listing a folder's bd issues. */
export interface BeadsResult {
  /** True when a bd tracker was found and queried successfully. */
  available: boolean;
  issues: BeadsIssue[];
  /** Why the tracker is unavailable (bd not installed / no .beads here). */
  error?: string;
}
