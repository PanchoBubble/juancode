/**
 * WebSocket wire protocol — mirror of `apps/server/src/protocol.ts`.
 * Keep the two files in sync.
 *
 * The Mac app's embedded server speaks this same wire format via its Codable
 * mirror `apps/native/Sources/JuancodeServer/WireProtocol.swift`, so this one
 * web app is a remote client for either backend (see `lib/socket.ts` /
 * `lib/api.ts`, which use same-origin relative URLs). Changes here must land in
 * all three.
 */

export type ProviderId = "claude" | "codex";

/**
 * Inferred live activity of a running session: `busy` while the agent works,
 * `waiting_input` when it has stopped to ask a question/permission, `idle` when
 * a turn is simply done. Live-only; never persisted.
 */
export type SessionActivity = "busy" | "idle" | "waiting_input";

/** One selectable choice in a session's pending question (a numbered menu item). */
export interface PromptOption {
  /** The keypress that selects it (the menu's own number, 1-9). */
  index: number;
  /** The human-readable choice, e.g. "Yes, and don't ask again". */
  label: string;
}

/**
 * The pending question a `waiting_input` session is blocked on, parsed best-effort
 * from its rendered screen (see the server's `promptParse.ts`). Lets the UI offer
 * tappable options + a free-text note on a phone. `options` is empty for a plain
 * yes/no or free-text prompt.
 */
export interface SessionPrompt {
  question: string;
  options: PromptOption[];
}

/**
 * Health of a session as judged by the periodic health-check sweep (pillar 3 of
 * the orchestration loop). `dead`: the pty is gone — either the store reports it
 * `exited`, or it still says `running` while the live registry no longer holds it
 * (a crash/desync where `onExit` never fired) — offer reactivation. `stale`: live
 * and mid-turn (`busy`) but no output for a long time, a likely hung turn. Healthy
 * sessions are absent from the sweep, so there is no `healthy` member on the wire.
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
 * Per-session token usage parsed from the CLI transcript. `inputTokens` is
 * fresh (uncached) input; cache reads/writes tracked separately. `costUsd` is a
 * best-effort estimate (null for Codex / unknown models). See server's
 * `sessionUsage.ts`.
 */
export interface SessionUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  totalTokens: number;
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
   * prompts. Persisted; can be flipped on a live session via `setSkipPermissions`.
   */
  skipPermissions: boolean;
  /**
   * Absolute path of a git worktree juancode auto-created for this session and
   * owns (its `cwd` is this path); removed when the session is deleted. Null for
   * sessions that run in an existing directory.
   */
  worktreePath: string | null;
  /**
   * Latest token usage + estimated cost, refreshed from the CLI transcript on
   * the same poll as the title. Null until the first turn produces usage.
   */
  usage: SessionUsage | null;
}

/**
 * One normalized item in the structured (non-TUI) rendering of a session — the
 * opt-in alternative to the raw xterm view, derived from the CLI's stream-json
 * transcript and normalized across providers. `id` is stable across re-reads so
 * the client can dedup appends and use it as a render key. See server protocol.
 */
export type StructuredEventKind = "user" | "assistant" | "thinking" | "tool_use" | "tool_result";

export interface StructuredEvent {
  id: string;
  kind: StructuredEventKind;
  /** Body text for user / assistant / thinking / tool_result; empty for tool_use. */
  text: string;
  /** Tool name — `tool_use` only. */
  toolName?: string;
  /** Pretty-printed tool input — `tool_use` only. */
  toolInput?: string;
  /** The `tool_use` id this result answers, pairing the two in the UI. */
  toolUseId?: string;
  /** True for an errored `tool_result`. */
  isError?: boolean;
  /** ISO timestamp when the transcript records one, else null. */
  ts: string | null;
}

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
       * `juancode/<id>` branch), removed when the session is deleted. Errors the
       * create if `cwd` isn't a git repo with a commit to branch from.
       */
      isolateWorktree?: boolean;
    }
  | { type: "attach"; sessionId: string; cols: number; rows: number }
  | { type: "reactivate"; sessionId: string; cols: number; rows: number }
  /**
   * Flip "accept all" on a live session. The server resume-restarts the CLI with
   * the new permission level (conversation + scrollback preserved) and replies
   * with a fresh `attached` for the revived session.
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
  | { type: "openTerminal"; cwd: string; cols: number; rows: number; requestId: string }
  // ── BEGIN shell-terminal persistence (ticket juancode-iwi) — additive ────────
  /**
   * Re-attach to a shell pty that is still alive server-side (its `terminalId`
   * was learned from an earlier `terminalReady`). Used when the integrated
   * terminal's xterm was torn down — e.g. the panel's React tree remounted on a
   * session switch — but the pty itself was kept running. The server re-subscribes
   * this connection and replies with `terminalReattached` carrying the captured
   * shell scrollback so the fresh xterm can replay it. `requestId` routes the
   * reply to the pane that asked. If the pty is gone the server replies with
   * `exit` for `terminalId` instead.
   */
  | { type: "reattachTerminal"; terminalId: string; cols: number; rows: number; requestId: string }
  // ── END shell-terminal persistence ───────────────────────────────────────────
  /**
   * Opt into the structured (message/tool-bubble) view of a session — the server
   * tails the session's stream-json transcript and pushes `structured` messages.
   * Works for live and exited sessions alike (the transcript is read from disk).
   */
  | { type: "subscribeStructured"; sessionId: string }
  /** Stop the structured tail for a session (the client closed that view). */
  | { type: "unsubscribeStructured"; sessionId: string }
  // ── BEGIN tracked-PR registry (ticket juancode-bt2) — additive ───────────────
  /**
   * Subscribe to the tracked-PR registry. The server replies with the current
   * `trackedPrs` snapshot and pushes further updates + per-escalation
   * `trackNotification`s until the connection closes.
   */
  | { type: "subscribeTrackedPrs" }
  /**
   * Start tracking `pr` in `cwd`: the server spawns a dedicated agent session
   * seeded with the PR context + auto-fix-vs-escalate contract and polls it.
   * No-op if already tracked.
   */
  | { type: "trackPr"; cwd: string; pr: PullRequest }
  /** Stop tracking the PR `trackedId` (its agent session is left alone). */
  | { type: "untrackPr"; trackedId: string }
  /** Dismiss a surfaced needs-decision notification. */
  | { type: "resolveTrackNotification"; trackedId: string; notificationId: string };
  // ── END tracked-PR registry ──────────────────────────────────────────────────

export type ServerMessage =
  | { type: "created"; session: SessionMeta }
  | { type: "attached"; sessionId: string; scrollback: string; session: SessionMeta }
  | { type: "output"; sessionId: string; data: string }
  | { type: "exit"; sessionId: string; exitCode: number | null }
  /**
   * A session's inferred activity changed. Broadcast for every live session so
   * the sidebar can show per-session progress / done / input-required icons.
   * `notify` is true only on a turn boundary worth alerting on (work finished or
   * a question appeared).
   */
  | {
      type: "activity";
      sessionId: string;
      state: SessionActivity;
      notify: boolean;
      /** Parsed pending question + options, present only when state is waiting_input. */
      prompt?: SessionPrompt;
    }
  /**
   * The full set of sessions the periodic health-check sweep currently considers
   * unhealthy (dead / stale). Sent on connect and after every sweep; an empty
   * array means nothing needs attention. Always the complete set — not a delta.
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
  // ── BEGIN shell-terminal persistence (ticket juancode-iwi) — additive ────────
  /**
   * Reply to `reattachTerminal` for a still-alive shell pty: `scrollback` is the
   * pty's captured output to replay into the freshly-mounted xterm. `requestId`
   * echoes the request so the client routes it to the right pane.
   */
  | { type: "terminalReattached"; terminalId: string; requestId: string; scrollback: string }
  // ── END shell-terminal persistence ───────────────────────────────────────────
  /**
   * A batch of structured-view events. `reset` is true on the first message
   * after `subscribeStructured` (full backlog — replace the list); later
   * messages carry only newly appended events with `reset: false` (append +
   * dedup by `id`).
   */
  | { type: "structured"; sessionId: string; events: StructuredEvent[]; reset: boolean }
  /** A reactivate couldn't be honoured: no prior CLI conversation to resume. */
  | { type: "unresumable"; sessionId: string; reason: string }
  | { type: "error"; sessionId?: string; message: string }
  // ── BEGIN tracked-PR registry (ticket juancode-bt2) — additive ───────────────
  /**
   * The full tracked-PR watch list — sent on `subscribeTrackedPrs` and after every
   * change/poll. Always the complete set, not a delta — replace wholesale.
   */
  | { type: "trackedPrs"; tracked: TrackedPrInfo[] }
  /**
   * A single needs-decision escalation fired for a tracked PR — a ping the client
   * can alert on without diffing the list (also reflected in the next snapshot).
   */
  | { type: "trackNotification"; trackedId: string; prNumber: number; notification: TrackNotification };
  // ── END tracked-PR registry ──────────────────────────────────────────────────

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

// ── BEGIN tracked-PR registry data types (ticket juancode-bt2) — additive ────

/**
 * Badge state of a tracked PR: `watching` (CI green / nothing outstanding),
 * `fixing` (CI red/running or new comments just handed to the agent),
 * `needs_decision` (a change needs the user — not auto-applied).
 */
export type TrackState = "watching" | "fixing" | "needs_decision";

/** A surfaced decision the agent should not make autonomously. */
export interface TrackNotification {
  id: string;
  prNumber: number;
  message: string;
  /** Epoch ms when it was raised. */
  createdAt: number;
}

/**
 * One PR under continuous watch. `id` is the stable `cwd#number` key used by
 * `untrackPr` / `resolveTrackNotification`; `sessionId` is the agent session
 * driving its fixes; `state`/`checks` drive the badge.
 */
export interface TrackedPrInfo {
  id: string;
  number: number;
  title: string;
  branch: string;
  url: string;
  cwd: string;
  sessionId: string;
  state: TrackState;
  checks: PrChecks;
  notifications: TrackNotification[];
  /** Epoch ms of the last successful poll, or null before the first. */
  lastPolledAt: number | null;
}

// ── END tracked-PR registry data types ───────────────────────────────────────

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
