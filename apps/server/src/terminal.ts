import { randomUUID } from "node:crypto";
import * as pty from "node-pty";

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
 */
export class ShellPty {
  readonly id = randomUUID();
  private readonly proc: pty.IPty;
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
      for (const l of this.outputListeners) l(data);
    });
    this.proc.onExit(({ exitCode }) => {
      this.alive = false;
      for (const l of this.exitListeners) l(exitCode);
    });
  }

  write(data: string): void {
    if (this.alive) this.proc.write(data);
  }

  resize(cols: number, rows: number): void {
    if (this.alive && cols > 0 && rows > 0) this.proc.resize(cols, rows);
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
