import { randomUUID } from "node:crypto";
import { basename } from "node:path";
import * as pty from "node-pty";
import { SCROLLBACK_LIMIT } from "./config.ts";
import { appendScrollback } from "./scrollback.ts";
import { captureCodexSessionId } from "./codexSession.ts";
import { sessionDb } from "./db.ts";
import { PROVIDERS } from "./providers.ts";
import type { ProviderId, SessionMeta } from "./protocol.ts";

type OutputListener = (data: string) => void;
type ExitListener = (exitCode: number | null) => void;

const PERSIST_DEBOUNCE_MS = 2000;

export class Session {
  readonly meta: SessionMeta;
  private readonly proc: pty.IPty;
  private scrollback = "";
  private readonly outputListeners = new Set<OutputListener>();
  private readonly exitListeners = new Set<ExitListener>();
  private persistTimer: NodeJS.Timeout | null = null;

  private constructor(meta: SessionMeta, args: string[], cols: number, rows: number, isNew: boolean) {
    this.meta = meta;
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
      for (const l of this.outputListeners) l(data);
      this.schedulePersist();
    });

    this.proc.onExit(({ exitCode }) => {
      this.meta.status = "exited";
      this.meta.exitCode = exitCode;
      this.meta.updatedAt = Date.now();
      this.persistNow();
      for (const l of this.exitListeners) l(exitCode);
    });
  }

  /** Start a brand-new conversation. */
  static create(provider: ProviderId, cwd: string, cols: number, rows: number): Session {
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
      createdAt: now,
      updatedAt: now,
    };
    return new Session(meta, spec.startArgs(id), cols, rows, true);
  }

  /**
   * Revive an exited session by resuming its prior CLI conversation in a fresh
   * pty, keeping the same juancode id (so the route/sidebar entry is stable).
   * Requires a captured `cliSessionId`.
   */
  static resume(prev: SessionMeta, cols: number, rows: number): Session {
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
    return new Session(meta, spec.resumeArgs(prev.cliSessionId), cols, rows, false);
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

  resize(cols: number, rows: number): void {
    if (this.isRunning && cols > 0 && rows > 0) this.proc.resize(cols, rows);
  }

  kill(): void {
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
