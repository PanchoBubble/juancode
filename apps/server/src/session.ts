import { randomUUID } from "node:crypto";
import { basename } from "node:path";
import * as pty from "node-pty";
import { SCROLLBACK_LIMIT } from "./config.ts";
import { appendScrollback } from "./scrollback.ts";
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

  constructor(provider: ProviderId, cwd: string, cols: number, rows: number) {
    const spec = PROVIDERS[provider];
    const now = Date.now();
    this.meta = {
      id: randomUUID(),
      provider,
      cwd,
      title: `${spec.label} · ${basename(cwd) || cwd}`,
      status: "running",
      exitCode: null,
      createdAt: now,
      updatedAt: now,
    };

    this.proc = pty.spawn(spec.command, spec.args, {
      name: "xterm-256color",
      cols,
      rows,
      cwd,
      // Inherit the real environment so the CLI loads the user's auth + MCPs.
      env: process.env as Record<string, string>,
    });

    sessionDb.insert(this.meta);

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
