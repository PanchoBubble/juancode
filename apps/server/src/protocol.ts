/**
 * WebSocket wire protocol shared between server and web.
 *
 * Keep this file dependency-free and in sync with `apps/web/src/protocol.ts`.
 */

export type ProviderId = "claude" | "codex";

/**
 * Inferred live activity of a running session: `busy` while the agent works,
 * `waiting_input` when it has stopped to ask a question/permission, `idle` when
 * a turn is simply done. Derived from the pty stream (see `activityDetector.ts`)
 * and not persisted — it only exists for live sessions.
 */
export type SessionActivity = "busy" | "idle" | "waiting_input";

/**
 * Health of a session as judged by the periodic health-check sweep (pillar 3 of
 * the orchestration loop — see `sessionHealth.ts`). `dead`: the pty is gone —
 * either the store reports it `exited`, or the store still says `running` while
 * the live registry no longer holds it (a crash/desync where `onExit` never
 * fired) — offer reactivation. `stale`: live and mid-turn (`busy`) but no output
 * for a long time, a likely hung turn worth surfacing. Healthy sessions are
 * simply absent from the sweep, so there is no `healthy` member on the wire.
 */
export type SessionHealthState = "dead" | "stale";

/**
 * An unhealthy session the sweep surfaced. `resumable` is carried through so the
 * UI knows whether to offer "Reactivate" (a dead, resumable session) vs. only a
 * "Go to" link.
 */
export interface SessionHealthReport {
  id: string;
  state: SessionHealthState;
  resumable: boolean;
}

/**
 * Per-session token usage, parsed from the CLI's transcript (see
 * `sessionUsage.ts`). `inputTokens` is fresh (uncached) input; cache reads and
 * writes are tracked separately. `costUsd` is a best-effort estimate from
 * published per-token rates and is null when the figure can't be computed
 * (Codex has no per-token price; an unknown Claude model). Persisted on
 * `SessionMeta` so it survives a restart and feeds the sidebar aggregate.
 */
export interface SessionUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  /** input + output + cache read + cache write. */
  totalTokens: number;
  /** Estimated USD cost, or null when not computable. */
  costUsd: number | null;
}

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
  /**
   * "Accept all" mode for this session — the CLI runs with no permission/approval
   * prompts (`--dangerously-skip-permissions` / `--dangerously-bypass-approvals-and-sandbox`).
   * Persisted so it survives reactivation; can be flipped on a live session (see
   * the `setSkipPermissions` client message), which resume-restarts the CLI.
   */
  skipPermissions: boolean;
  /**
   * Absolute path of a git worktree juancode auto-created for this session and
   * owns — its `cwd` is this path, and the worktree is removed when the session
   * is deleted. Null for sessions that run in an existing directory. Lets many
   * agents work the same repo in parallel without sharing a working tree.
   */
  worktreePath: string | null;
  /**
   * Latest token usage + estimated cost for the session, refreshed from the
   * CLI transcript on the same poll as the title. Null until the first turn
   * produces usage (or when the transcript can't be read).
   */
  usage: SessionUsage | null;
}

/** Messages sent from the browser to the server. */
export type ClientMessage =
  | {
      type: "create";
      provider: ProviderId;
      cwd: string;
      cols: number;
      rows: number;
      /** Optional text auto-submitted to the fresh session (e.g. PR context). */
      initialInput?: string;
      /**
       * Launch the CLI in "accept all" mode (no permission/approval prompts).
       * Maps to `--dangerously-skip-permissions` (Claude) /
       * `--dangerously-bypass-approvals-and-sandbox` (Codex).
       */
      skipPermissions?: boolean;
      /**
       * Run this session in a fresh git worktree off `cwd` (on a new
       * `juancode/<id>` branch) instead of the directory itself, so it can't
       * clobber other sessions' working tree. The worktree is removed on delete.
       * Errors the create if `cwd` isn't a git repo with a commit to branch from.
       */
      isolateWorktree?: boolean;
    }
  | { type: "attach"; sessionId: string; cols: number; rows: number }
  | { type: "reactivate"; sessionId: string; cols: number; rows: number }
  /**
   * Flip "accept all" on a live session. The server resume-restarts the CLI with
   * the new permission level (the conversation + scrollback are preserved) and
   * replies with a fresh `attached` for the revived session.
   */
  | {
      type: "setSkipPermissions";
      sessionId: string;
      skipPermissions: boolean;
      cols: number;
      rows: number;
    }
  | { type: "input"; sessionId: string; data: string }
  | { type: "resize"; sessionId: string; cols: number; rows: number }
  | { type: "kill"; sessionId: string }
  /**
   * Open a file in the user's real editor ($VISUAL/$EDITOR, default nvim) in an
   * ephemeral pty (not a persisted session). The server replies with the pty's
   * id via `editorReady`; thereafter input/resize/kill/output/exit address it by
   * that id exactly like a session.
   */
  | { type: "openEditor"; cwd: string; file: string; cols: number; rows: number }
  /**
   * Spawn a plain interactive shell ($SHELL, default zsh/bash) in `cwd` in an
   * ephemeral pty (not a persisted session) — the VS Code-style integrated
   * terminal. `requestId` is echoed back in `terminalReady` so a client opening
   * several terminals at once can match each reply to its request. Thereafter
   * input/resize/kill/output/exit address the pty by its `terminalId`.
   */
  | { type: "openTerminal"; cwd: string; cols: number; rows: number; requestId: string };

/** Messages sent from the server to the browser. */
export type ServerMessage =
  | { type: "created"; session: SessionMeta }
  | { type: "attached"; sessionId: string; scrollback: string; session: SessionMeta }
  | { type: "output"; sessionId: string; data: string }
  | { type: "exit"; sessionId: string; exitCode: number | null }
  /**
   * A session's inferred activity changed. Broadcast for every live session (not
   * just the attached one) so the sidebar can show per-session progress / done /
   * input-required indicators. `notify` is true only on a turn boundary worth
   * alerting on (work finished or a question appeared), so the client can ping
   * for those without re-pinging on every `busy`.
   */
  | { type: "activity"; sessionId: string; state: SessionActivity; notify: boolean }
  /**
   * The full set of sessions the periodic health-check sweep currently considers
   * unhealthy (dead / stale). Sent on connect and after every sweep (see
   * `healthMonitor.ts`); an empty array means nothing needs attention. Always the
   * complete set — not a delta — so the client can replace its view wholesale.
   */
  | { type: "health"; reports: SessionHealthReport[] }
  /** An editor pty was spawned; its id is used as the `sessionId` for I/O. */
  | { type: "editorReady"; editorId: string }
  /**
   * A shell terminal pty was spawned; `terminalId` is used as the `sessionId`
   * for I/O. `requestId` echoes the `openTerminal` request so the client can
   * route the reply to the pane that asked for it.
   */
  | { type: "terminalReady"; terminalId: string; requestId: string }
  /** A reactivate couldn't be honoured: no prior CLI conversation to resume. */
  | { type: "unresumable"; sessionId: string; reason: string }
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

/**
 * One linked git worktree of a session's repo, from `git worktree list`. Lets
 * the diff panel show the status of a worktree an agent is working in even when
 * the session itself was started in the main repo.
 */
export interface Worktree {
  /** Absolute path to the worktree's root. */
  path: string;
  /** Short branch name, or null when the worktree has a detached HEAD. */
  branch: string | null;
  /** The worktree's HEAD commit sha, if any. */
  head: string | null;
  /** True for the repo's main (primary) worktree. */
  main: boolean;
}

/** Which side of the diff a comment is anchored to. */
export type CommentSide = "old" | "new";

/**
 * A GitHub-PR-style inline comment on a diff. Anchored to a line range
 * [line, endLine] (inclusive) on one side; `endLine === line` for a single line.
 */
export interface DiffComment {
  id: string;
  sessionId: string;
  file: string;
  side: CommentSide;
  line: number;
  endLine: number;
  body: string;
  createdAt: number;
}

// ── REST data types ('Review with Claude' AI pass over the diff) ─────────────

export type ReviewSeverity = "critical" | "high" | "medium" | "low" | "info";

/**
 * One AI-surfaced issue, anchored to a diff line so it can overlay the viewer
 * the same way human comments do. `line` is null for a file- or change-level
 * finding with no single line, or when the model couldn't pin one.
 */
export interface ReviewFinding {
  file: string;
  side: CommentSide;
  line: number | null;
  severity: ReviewSeverity;
  title: string;
  note: string;
}

/** Cached result of one 'Review with Claude' pass over a session's diff. */
export interface ReviewResult {
  /** ok = ran and produced findings/summary; empty = nothing to review; error = the run failed. */
  status: "ok" | "empty" | "error";
  findings: ReviewFinding[];
  /** The model's short prose overview, shown above the per-line findings. */
  summary: string | null;
  /** When this review was produced (epoch ms). */
  createdAt: number;
  /** Error text when status is 'error' (CLI failure, bad output, etc.). */
  error?: string;
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

// ── REST data types (open pull requests, per work folder) ────────────────────

/** Rolled-up CI status across a PR's checks. */
export type PrChecks = "passing" | "failing" | "pending" | "none";

/** One open pull request, from `gh pr list`. */
export interface PullRequest {
  number: number;
  title: string;
  url: string;
  /** Source branch (`headRefName`). */
  branch: string;
  /** True for draft PRs. */
  draft: boolean;
  checks: PrChecks;
  /** GitHub login of the PR author (empty if unknown). */
  author: string;
}

/** Result of listing a folder's open PRs. */
export interface PrListResult {
  /** True when `gh` ran in a repo with a remote and returned a list. */
  available: boolean;
  prs: PullRequest[];
  /** Authenticated GitHub login (`gh api user`), for "created by me" filtering. */
  viewer?: string;
  /** Why PRs are unavailable (gh missing / not authed / not a repo / no remote). */
  error?: string;
}

// ── REST data types (git actions: commit / push / create PR) ─────────────────

/** Working-tree git state for a worktree, driving the commit/push/PR CTAs. */
export interface GitState {
  /** False when the cwd isn't a git work tree. */
  git: boolean;
  /** Current branch, or null on a detached HEAD. */
  branch: string | null;
  detached: boolean;
  /** Tracking branch (e.g. "origin/main"), or null when none is configured. */
  upstream: string | null;
  /** Commits ahead of the upstream (all local commits when there's no upstream). */
  ahead: number;
  /** Commits behind the upstream. */
  behind: number;
  /** True when there are staged, unstaged, or untracked changes. */
  dirty: boolean;
  /** True when the repo has at least one remote (so push/PR are meaningful). */
  remote: boolean;
}

/** Result of staging everything and committing. */
export interface CommitResult {
  /** Short sha of the new commit. */
  sha: string;
  /** The commit's subject line. */
  subject: string;
}

/** Result of pushing the current branch. */
export interface PushResult {
  branch: string;
  /** Combined stdout/stderr from git, for a short status line. */
  output: string;
}

/** An AI-generated commit message for the current diff. */
export interface CommitMessageResult {
  message: string;
}

/** Result of `gh pr create` — the PR url, and whether it was newly created. */
export interface PrCreateResult {
  url: string;
  /** False when a PR for this branch already existed (url points at it). */
  created: boolean;
}
