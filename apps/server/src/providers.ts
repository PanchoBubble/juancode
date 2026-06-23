import { execFileSync } from "node:child_process";
import type { ProviderId } from "./protocol.ts";

export interface ProviderSpec {
  id: ProviderId;
  label: string;
  /** Absolute path to the executable, resolved at startup. */
  command: string;
  /** Extra args. We intentionally pass none so the CLI runs exactly as it does
   *  in a terminal — loading the user's real MCP servers, auth and config. */
  args: string[];
}

/**
 * Resolve a CLI to the SAME absolute path the user's interactive terminal would.
 *
 * A GUI/server process often has a different (or stripped) PATH than the user's
 * login shell — that's why juancode initially launched a stale `claude` from an
 * old nvm bin dir. We ask the user's login shell to resolve the command so the
 * panel uses the exact binary (and version) they see in their terminal.
 */
function resolveBinary(cmd: string, override: string | undefined): string {
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

/**
 * The whole point of juancode: launch the genuine CLIs with their native config
 * untouched. We do NOT inject a shadow HOME, CODEX_HOME, or override mcpServers,
 * so `~/.claude.json`, account connectors, `~/.codex/config.toml` and project
 * `.mcp.json` all load identically to running `claude` / `codex` yourself.
 */
export const PROVIDERS: Record<ProviderId, ProviderSpec> = {
  claude: {
    id: "claude",
    label: "Claude Code",
    command: resolveBinary("claude", process.env.JUANCODE_CLAUDE_BIN),
    args: [],
  },
  codex: {
    id: "codex",
    label: "Codex",
    command: resolveBinary("codex", process.env.JUANCODE_CODEX_BIN),
    args: [],
  },
};

export function isProviderId(value: string): value is ProviderId {
  return value === "claude" || value === "codex";
}
