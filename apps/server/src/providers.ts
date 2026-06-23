import type { ProviderId } from "./protocol.ts";
import { resolveBin } from "./resolveBin.ts";

export interface ProviderSpec {
  id: ProviderId;
  label: string;
  /** Absolute path to the executable, resolved at startup. */
  command: string;
  /**
   * Args for a brand-new session. We pass nothing that changes how the CLI loads
   * the user's MCP servers, auth or config — only a session-id pin where the CLI
   * supports it, so we can resume the exact conversation later.
   *
   * `juancodeId` is our own session UUID; Claude lets us force it as the CLI
   * session id (`--session-id`), so resuming needs no discovery. Codex has no
   * such flag, so it starts clean and we discover its id after spawn.
   */
  startArgs: (juancodeId: string) => string[];
  /** Args to resume a prior conversation by its captured CLI session id. */
  resumeArgs: (cliSessionId: string) => string[];
  /**
   * True when `startArgs` pins the CLI session id to our own UUID, so the
   * resumable id is known immediately (Claude). False when it must be discovered
   * from the CLI's session files after spawn (Codex).
   */
  pinsSessionId: boolean;
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
    command: resolveBin("claude", process.env.JUANCODE_CLAUDE_BIN),
    // Pin the CLI session id to our own UUID so `--resume` revives this exact
    // conversation with no discovery step.
    startArgs: (juancodeId) => ["--session-id", juancodeId],
    resumeArgs: (cliSessionId) => ["--resume", cliSessionId],
    pinsSessionId: true,
  },
  codex: {
    id: "codex",
    label: "Codex",
    command: resolveBin("codex", process.env.JUANCODE_CODEX_BIN),
    // Codex has no flag to pin a session id, so it starts clean; we discover the
    // id from its rollout file and resume with `codex resume <id>`.
    startArgs: () => [],
    resumeArgs: (cliSessionId) => ["resume", cliSessionId],
    pinsSessionId: false,
  },
};

export function isProviderId(value: string): value is ProviderId {
  return value === "claude" || value === "codex";
}
