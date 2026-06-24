import { randomUUID } from "node:crypto";
import { basename } from "node:path";
import * as pty from "node-pty";
import { SCROLLBACK_LIMIT } from "./config.ts";
import { appendScrollback } from "./scrollback.ts";
import { captureCodexSessionId } from "./codexSession.ts";
import { sessionDb } from "./db.ts";
import { PROVIDERS } from "./providers.ts";
import type { SpawnOptions } from "./providers.ts";
import { deriveSessionTitle } from "./sessionTitle.ts";
import { ActivityDetector } from "./activityDetector.ts";
import type { ProviderId, SessionActivity, SessionMeta } from "./protocol.ts";

type OutputListener = (data: string) => void;
type ExitListener = (exitCode: number | null) => void;
type ActivityListener = (state: SessionActivity, notify: boolean) => void;

const PERSIST_DEBOUNCE_MS = 2000;
const TITLE_POLL_MS = 4000;

export class Session {
  readonly meta: SessionMeta;
  private readonly proc: pty.IPty;
  private scrollback = "";
  private readonly outputListeners = new Set<OutputListener>();
  private readonly exitListeners = new Set<ExitListener>();
  private readonly activityListeners = new Set<ActivityListener>();
  private readonly detector = new ActivityDetector((state, notify) => {
    for (const l of this.activityListeners) l(state, notify);
  });
  private persistTimer: NodeJS.Timeout | null = null;
  private titleTimer: NodeJS.Timeout | null = null;

  private constructor(
    meta: SessionMeta,
    args: string[],
    cols: number,
    rows: number,
    isNew: boolean,
    seedScrollback = "",
  ) {
    this.meta = meta;
    // Resuming an exited session carries its prior scrollback forward so the
    // history survives the new pty (and isn't clobbered by the persist below).
    this.scrollback = seedScrollback;
    const spec = PROVIDERS[meta.provider];

    this.proc = pty.spawn(spec.command, args, {
      name: "xterm-256color",
      cols,
      rows,
      cwd: meta.cwd,
      // Inherit the real environment so the CLI loads the user's auth + MCPs.
      env: process.env as Record<string, string>,
    });

    if (isNew) sessionDb.insert(this.meta);
    else sessionDb.update(this.meta, this.scrollback);

    // For Codex we can't pin the session id, so discover it from the rollout file.
    if (!spec.pinsSessionId && this.meta.cliSessionId === null) {
      this.captureCliSessionId();
    }

    this.proc.onData((data) => {
      this.appendScrollback(data);
      this.detector.feed(data);
      for (const l of this.outputListeners) l(data);
      this.schedulePersist();
    });

    this.proc.onExit(({ exitCode }) => {
      this.meta.status = "exited";
      this.meta.exitCode = exitCode;
      this.meta.updatedAt = Date.now();
      this.detector.reset();
      this.stopTitleWatch();
      void this.refreshTitle(); // one last read to catch a late-generated title
      this.persistNow();
      for (const l of this.exitListeners) l(exitCode);
    });

    // Keep the title in sync with the CLI's own generated summary / first prompt.
    this.startTitleWatch();
  }

  /** Start a brand-new conversation. */
  static create(
    provider: ProviderId,
    cwd: string,
    cols: number,
    rows: number,
    opts?: SpawnOptions,
    worktreePath: string | null = null,
  ): Session {
    const spec = PROVIDERS[provider];
    const now = Date.now();
    const id = randomUUID();
    const meta: SessionMeta = {
      id,
      provider,
      cwd,
      title: `${spec.label} · ${basename(cwd) || cwd}`,
      status: "running",
      exitCode: null,
      // Claude's id is pinned to ours up front; Codex's is discovered post-spawn.
      cliSessionId: spec.pinsSessionId ? id : null,
      skipPermissions: opts?.skipPermissions ?? false,
      worktreePath,
      createdAt: now,
      updatedAt: now,
    };
    return new Session(meta, spec.startArgs(id, opts), cols, rows, true);
  }

  /**
   * Revive an exited session by resuming its prior CLI conversation in a fresh
   * pty, keeping the same juancode id (so the route/sidebar entry is stable).
   * Requires a captured `cliSessionId`. `priorScrollback` is the persisted
   * history to carry forward so reactivation never loses the conversation.
   */
  static resume(prev: SessionMeta, cols: number, rows: number, priorScrollback = ""): Session {
    if (!prev.cliSessionId) {
      throw new Error("Session has no captured CLI session id to resume");
    }
    const spec = PROVIDERS[prev.provider];
    const meta: SessionMeta = {
      ...prev,
      status: "running",
      exitCode: null,
      updatedAt: Date.now(),
    };
    return new Session(
      meta,
      spec.resumeArgs(prev.cliSessionId, { skipPermissions: meta.skipPermissions }),
      cols,
      rows,
      false,
      priorScrollback,
    );
  }

  get id(): string {
    return this.meta.id;
  }

  get isRunning(): boolean {
    return this.meta.status === "running";
  }

  getScrollback(): string {
    return this.scrollback;
  }

  write(data: string): void {
    if (this.isRunning) this.proc.write(data);
  }

  /**
   * Type `text` into the session and submit it, once the CLI's TUI has rendered.
   * Used to seed a fresh session with context (e.g. a PR to work on). We wait for
   * the first output so the TUI has entered raw mode before we type, then add a
   * short delay and a carriage return to submit.
   */
  autoSubmit(text: string): void {
    const trimmed = text.trim();
    if (!trimmed) return;
    const off = this.onOutput(() => {
      off();
      setTimeout(() => this.write(`${trimmed}\r`), 500);
    });
  }

  resize(cols: number, rows: number): void {
    if (this.isRunning && cols > 0 && rows > 0) this.proc.resize(cols, rows);
  }

  kill(): void {
    this.stopTitleWatch();
    if (this.isRunning) this.proc.kill();
  }

  onOutput(listener: OutputListener): () => void {
    this.outputListeners.add(listener);
    return () => this.outputListeners.delete(listener);
  }

  onExit(listener: ExitListener): () => void {
    this.exitListeners.add(listener);
    return () => this.exitListeners.delete(listener);
  }

  /** Current inferred activity (busy / idle / waiting_input). */
  get activity(): SessionActivity {
    return this.detector.activity;
  }

  onActivity(listener: ActivityListener): () => void {
    this.activityListeners.add(listener);
    return () => this.activityListeners.delete(listener);
  }

  /** Poll the CLI's transcript so the title reflects what the session is doing. */
  private startTitleWatch(): void {
    if (this.titleTimer) return;
    this.titleTimer = setInterval(() => void this.refreshTitle(), TITLE_POLL_MS);
    void this.refreshTitle();
  }

  private stopTitleWatch(): void {
    if (this.titleTimer) {
      clearInterval(this.titleTimer);
      this.titleTimer = null;
    }
  }

  /** Read the CLI's generated title (or first prompt) and persist if it changed. */
  private async refreshTitle(): Promise<void> {
    const { cliSessionId, provider } = this.meta;
    if (!cliSessionId) return; // Codex id not discovered yet
    let title: string | null;
    try {
      title = await deriveSessionTitle(provider, cliSessionId);
    } catch {
      return; // best-effort; a parse/read failure just leaves the title as-is
    }
    if (title && title !== this.meta.title) {
      this.meta.title = title;
      this.persistNow();
    }
  }

  private captureCliSessionId(): void {
    const since = Date.now();
    void captureCodexSessionId(this.meta.cwd, since)
      .then((cliSessionId) => {
        // Don't clobber a value set by a later resume, and ignore if the session
        // is long gone without ever producing a rollout file.
        if (cliSessionId && this.meta.cliSessionId === null) {
          this.meta.cliSessionId = cliSessionId;
          sessionDb.setCliSessionId(this.meta.id, cliSessionId);
        }
      })
      .catch(() => {
        // Discovery is best-effort; failure just leaves the session non-resumable.
      });
  }

  private appendScrollback(data: string): void {
    this.scrollback = appendScrollback(this.scrollback, data, SCROLLBACK_LIMIT);
  }

  private schedulePersist(): void {
    if (this.persistTimer) return;
    this.persistTimer = setTimeout(() => {
      this.persistTimer = null;
      this.persistNow();
    }, PERSIST_DEBOUNCE_MS);
  }

  private persistNow(): void {
    if (this.persistTimer) {
      clearTimeout(this.persistTimer);
      this.persistTimer = null;
    }
    this.meta.updatedAt = Date.now();
    sessionDb.update(this.meta, this.scrollback);
  }
}
