import { execFileSync } from "node:child_process";

/**
 * Resolve a CLI to the SAME absolute path the user's interactive terminal would.
 *
 * A GUI/server process often has a different (or stripped) PATH than the user's
 * login shell — e.g. `bd` installed in `~/.local/bin`, or `claude` in an nvm bin
 * dir. We ask the user's login shell to resolve the command so juancode uses the
 * exact binary (and version) they see in their terminal. Faithful-environment
 * is the whole point of this project — we never inject a shadow HOME/PATH.
 */
export function resolveBin(cmd: string, override: string | undefined): string {
  if (override) return override;
  const shell = process.env.SHELL ?? "/bin/zsh";
  try {
    const out = execFileSync(shell, ["-lic", `command -v ${cmd} 2>/dev/null`], {
      encoding: "utf8",
      timeout: 5000,
      stdio: ["ignore", "pipe", "ignore"],
    });
    const resolved = out
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean)
      .pop();
    if (resolved && resolved.startsWith("/")) return resolved;
  } catch {
    // Login-shell resolution failed (no shell, timeout, not found) — fall back
    // to the bare command name and let PATH/posix_spawnp handle it.
  }
  return cmd;
}
