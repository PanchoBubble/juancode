import { randomUUID } from "node:crypto";
import * as pty from "node-pty";
import { SCROLLBACK_LIMIT } from "./config.ts";
import { Scrollback } from "./scrollback.ts";

type OutputListener = (data: string) => void;
type ExitListener = (exitCode: number | null) => void;

/**
 * Resolve the user's interactive shell from the environment, defaulting to zsh
 * then bash. We launch it as an interactive shell (`-i`) so it sources the
 * user's rc files and behaves exactly like a terminal they'd open themselves.
 */
function shellCommand(): { cmd: string; args: string[] } {
  const cmd = (process.env.SHELL || "/bin/zsh").trim() || "/bin/zsh";
  return { cmd, args: ["-i"] };
}

/**
 * An ephemeral pty running a plain interactive shell. Like {@link EditorPty}
 * and unlike a Session it is never persisted, titled, or resumed — it lives
 * only while its pane is open, so the shell loads the user's real config and
 * env exactly as a normal terminal would. This is the integrated terminal.
 *
 * Unlike an editor pty it captures a capped {@link Scrollback} of its output —
 * the same mechanism a persisted {@link Session} uses — so a pane that survives a
 * session switch (the pty is kept alive while its xterm is torn down) can be
 * re-attached and have its history replayed via `reattachTerminal`. The buffer is
 * in-memory only: shell terminals are never persisted across server restarts.
 */
export class ShellPty {
  readonly id = randomUUID();
  private readonly proc: pty.IPty;
  private readonly scrollback = new Scrollback(SCROLLBACK_LIMIT);
  private readonly outputListeners = new Set<OutputListener>();
  private readonly exitListeners = new Set<ExitListener>();
  private alive = true;

  constructor(cwd: string, cols: number, rows: number) {
    const { cmd, args } = shellCommand();
    this.proc = pty.spawn(cmd, args, {
      name: "xterm-256color",
      cols,
      rows,
      cwd,
      // Inherit the real environment so the shell loads the user's config + PATH.
      env: process.env as Record<string, string>,
    });
    this.proc.onData((data) => {
      this.scrollback.append(data);
      for (const l of this.outputListeners) l(data);
    });
    this.proc.onExit(({ exitCode }) => {
      this.alive = false;
      for (const l of this.exitListeners) l(exitCode);
    });
  }

  /** Captured output to replay into a freshly re-attached xterm. */
  getScrollback(): string {
    return this.scrollback.replay;
  }

  get isAlive(): boolean {
    return this.alive;
  }

  write(data: string): void {
    if (this.alive) this.proc.write(data);
  }

  /** Resize the pty grid; returns whether it reached the live pty (juancode-uz6). */
  resize(cols: number, rows: number): boolean {
    const applied = this.alive && cols > 0 && rows > 0;
    if (applied) this.proc.resize(cols, rows);
    return applied;
  }

  kill(): void {
    if (this.alive) this.proc.kill();
  }

  onOutput(listener: OutputListener): () => void {
    this.outputListeners.add(listener);
    return () => this.outputListeners.delete(listener);
  }

  onExit(listener: ExitListener): () => void {
    this.exitListeners.add(listener);
    return () => this.exitListeners.delete(listener);
  }
}

/** Holds the live shell ptys for the current server lifetime. */
class TerminalRegistry {
  private readonly terminals = new Map<string, ShellPty>();

  /** Spawn an interactive shell in `cwd`. */
  open(cwd: string, cols: number, rows: number): ShellPty {
    const sh = new ShellPty(cwd, cols, rows);
    this.terminals.set(sh.id, sh);
    sh.onExit(() => this.terminals.delete(sh.id));
    return sh;
  }

  get(id: string): ShellPty | undefined {
    return this.terminals.get(id);
  }

  killAll(): void {
    for (const t of this.terminals.values()) t.kill();
  }
}

export const terminals = new TerminalRegistry();
