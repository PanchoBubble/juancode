import { randomUUID } from "node:crypto";
import { isAbsolute, relative, resolve } from "node:path";
import * as pty from "node-pty";

type OutputListener = (data: string) => void;
type ExitListener = (exitCode: number | null) => void;

/**
 * Resolve the editor command from the user's environment, defaulting to nvim.
 * `$VISUAL`/`$EDITOR` may carry args (e.g. "code -w"); split them off naively —
 * good enough for the common single-binary case and the nvim default.
 */
function editorCommand(): { cmd: string; args: string[] } {
  const raw = (process.env.VISUAL || process.env.EDITOR || "nvim").trim();
  const parts = raw.split(/\s+/).filter(Boolean);
  return { cmd: parts[0] ?? "nvim", args: parts.slice(1) };
}

/**
 * An ephemeral pty running the user's real editor on a single file. Unlike a
 * Session it is never persisted, titled, or resumed — it lives only while the
 * file is open, so editing in the browser uses the genuine editor (and thus the
 * user's nvim config + tree-sitter) exactly as a normal terminal would.
 */
export class EditorPty {
  readonly id = randomUUID();
  private readonly proc: pty.IPty;
  private readonly outputListeners = new Set<OutputListener>();
  private readonly exitListeners = new Set<ExitListener>();
  private alive = true;

  constructor(cwd: string, file: string, cols: number, rows: number) {
    const { cmd, args } = editorCommand();
    this.proc = pty.spawn(cmd, [...args, file], {
      name: "xterm-256color",
      cols,
      rows,
      cwd,
      // Inherit the real environment so nvim loads the user's config + plugins.
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

/** Holds the live editor ptys for the current server lifetime. */
class EditorRegistry {
  private readonly editors = new Map<string, EditorPty>();

  /** Spawn an editor on `file`, confined to `cwd` so a client can't escape it. */
  open(cwd: string, file: string, cols: number, rows: number): EditorPty {
    const root = resolve(cwd);
    const full = resolve(root, file);
    const rel = relative(root, full);
    if (rel.startsWith("..") || isAbsolute(rel)) {
      throw new Error("Refusing to open a file outside the working directory");
    }
    const ed = new EditorPty(root, full, cols, rows);
    this.editors.set(ed.id, ed);
    ed.onExit(() => this.editors.delete(ed.id));
    return ed;
  }

  get(id: string): EditorPty | undefined {
    return this.editors.get(id);
  }

  killAll(): void {
    for (const e of this.editors.values()) e.kill();
  }
}

export const editors = new EditorRegistry();
