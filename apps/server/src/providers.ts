import type { ProviderId } from "./protocol.ts";
import { resolveBin } from "./resolveBin.ts";

/** Per-session knobs that influence the spawned CLI's argv. */
export interface SpawnOptions {
  /**
   * Run the CLI in "accept all" mode — no permission/approval prompts. Maps to
   * `--dangerously-skip-permissions` (Claude) and
   * `--dangerously-bypass-approvals-and-sandbox` (Codex). The CLI then executes
   * tools/commands unrestricted, so this is opt-in per session.
   */
  skipPermissions?: boolean;
}

export interface ProviderSpec {
  id: ProviderId;
  label: string;
  /** Absolute path to the executable, resolved at startup. */
  command: string;
  /**
   * Args for a brand-new session. We pass nothing that changes how the CLI loads
   * the user's MCP servers, auth or config — only a session-id pin where the CLI
   * supports it, so we can resume the exact conversation later, plus any opt-in
   * `SpawnOptions` (e.g. skipPermissions) the user chose for this session.
   *
   * `juancodeId` is our own session UUID; Claude lets us force it as the CLI
   * session id (`--session-id`), so resuming needs no discovery. Codex has no
   * such flag, so it starts clean and we discover its id after spawn.
   */
  startArgs: (juancodeId: string, opts?: SpawnOptions) => string[];
  /**
   * Args to resume a prior conversation by its captured CLI session id. Takes the
   * same `SpawnOptions` as `startArgs` so a resumed session can come back with a
   * different permission level than it started with (both CLIs accept the bypass
   * flag on resume) — this is how the per-session "accept all" toggle flips.
   */
  resumeArgs: (cliSessionId: string, opts?: SpawnOptions) => string[];
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

/**
 * Claude's accept-all flag — applied ONLY when active. We deliberately do NOT
 * pass `--allow-dangerously-skip-permissions` for non-bypass sessions: despite
 * the docs, on real Claude builds it activates bypass (its help text reads
 * "Enable bypassing all permission checks") and forces the interactive
 * "Yes, I accept" prompt, which broke plain resume/reactivate. So bypass is
 * strictly opt-in here; flipping it on a live session resume-restarts the CLI.
 */
const claudePermArgs = (skip?: boolean): string[] =>
  skip ? ["--dangerously-skip-permissions"] : [];

export const PROVIDERS: Record<ProviderId, ProviderSpec> = {
  claude: {
    id: "claude",
    label: "Claude Code",
    command: resolveBin("claude", process.env.JUANCODE_CLAUDE_BIN),
    // Pin the CLI session id to our own UUID so `--resume` revives this exact
    // conversation with no discovery step.
    startArgs: (juancodeId, opts) => [
      "--session-id",
      juancodeId,
      ...claudePermArgs(opts?.skipPermissions),
    ],
    resumeArgs: (cliSessionId, opts) => [
      "--resume",
      cliSessionId,
      ...claudePermArgs(opts?.skipPermissions),
    ],
    pinsSessionId: true,
  },
  codex: {
    id: "codex",
    label: "Codex",
    command: resolveBin("codex", process.env.JUANCODE_CODEX_BIN),
    // Codex has no flag to pin a session id, so it starts clean; we discover the
    // id from its rollout file and resume with `codex resume <id>`.
    startArgs: (_juancodeId, opts) =>
      opts?.skipPermissions ? ["--dangerously-bypass-approvals-and-sandbox"] : [],
    resumeArgs: (cliSessionId, opts) => [
      "resume",
      ...(opts?.skipPermissions ? ["--dangerously-bypass-approvals-and-sandbox"] : []),
      cliSessionId,
    ],
    pinsSessionId: false,
  },
};

export function isProviderId(value: string): value is ProviderId {
  return value === "claude" || value === "codex";
}
