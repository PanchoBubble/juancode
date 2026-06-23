import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { PROVIDERS, type ProviderSpec } from "./providers.ts";
import type { ProviderId } from "./protocol.ts";

const execFileAsync = promisify(execFile);

/** `claude mcp list` health-checks every server, so give it room before timing out. */
const LIST_TIMEOUT_MS = 20_000;
const VERSION_TIMEOUT_MS = 5_000;

/** Normalized health of a single MCP server, unified across the two CLIs. */
export type McpHealth =
  | "connected"
  | "needs-auth"
  | "pending"
  | "failed"
  | "enabled"
  | "disabled"
  | "unknown";

export interface McpServerStatus {
  name: string;
  /** URL (HTTP/SSE) or command line (stdio) — whatever the CLI reports. */
  detail: string;
  /** Transport kind when known: "stdio" | "http" | "sse". */
  transport: string | null;
  health: McpHealth;
  /** Raw status text from the CLI, shown verbatim as a tooltip. */
  statusLabel: string;
  /** Auth scheme when the CLI reports it (codex): "oauth" | "bearer" | "unsupported". */
  auth: string | null;
}

export interface ProviderStatus {
  id: ProviderId;
  label: string;
  /** Absolute path (or bare name) the harness will actually launch. */
  command: string;
  /** True when `<command> --version` succeeded. */
  available: boolean;
  version: string | null;
  /** Non-fatal notice surfaced by the CLI (e.g. claude's connectors-disabled banner). */
  warning: string | null;
  /** Set when listing MCP servers failed; mcpServers will be empty. */
  error: string | null;
  mcpServers: McpServerStatus[];
}

/** Map claude's status glyph/text to a normalized health value. */
function claudeHealth(label: string): McpHealth {
  const l = label.toLowerCase();
  if (l.includes("connected") || label.includes("✔")) return "connected";
  if (l.includes("needs authentication") || l.includes("authenticate")) return "needs-auth";
  if (l.includes("pending")) return "pending";
  if (l.includes("failed") || label.includes("✗")) return "failed";
  return "unknown";
}

/**
 * Parse the human-readable `claude mcp list` output. Lines look like:
 *   `name: https://host/mcp (HTTP) - ✔ Connected`
 * The name itself may contain colons (e.g. `plugin:linear:linear`), so we split
 * on the FIRST ": " (colon + space) and take the status after the LAST " - ".
 */
export function parseClaudeList(stdout: string): {
  servers: McpServerStatus[];
  warning: string | null;
} {
  const servers: McpServerStatus[] = [];
  let warning: string | null = null;
  for (const raw of stdout.split("\n")) {
    const line = raw.trim();
    if (!line) continue;
    if (line.startsWith("⚠")) {
      warning = line.replace(/^⚠\s*/, "");
      continue;
    }
    if (line.startsWith("Checking MCP server health")) continue;
    if (line.startsWith("No MCP servers")) continue;
    const sep = line.indexOf(": ");
    if (sep === -1) continue;
    const name = line.slice(0, sep);
    const rest = line.slice(sep + 2);
    const lastDash = rest.lastIndexOf(" - ");
    const detail = lastDash === -1 ? rest : rest.slice(0, lastDash);
    const statusLabel = lastDash === -1 ? "" : rest.slice(lastDash + 3);
    const marked = /\((HTTP|SSE|STDIO)\)/i.exec(detail)?.[1]?.toLowerCase();
    // No explicit marker → a command line is stdio; a URL is http.
    const transport = marked ?? (/^https?:\/\//.test(detail) ? "http" : "stdio");
    servers.push({
      name,
      detail: detail.trim(),
      transport,
      health: claudeHealth(statusLabel),
      statusLabel: statusLabel.trim(),
      auth: null,
    });
  }
  return { servers, warning };
}

interface CodexEntry {
  name: string;
  enabled: boolean;
  disabled_reason: string | null;
  transport: {
    type: string;
    command?: string;
    args?: string[];
    url?: string;
  };
  auth_status: string | null;
}

/** Parse `codex mcp list --json`. Codex reports config, not live connection health. */
export function parseCodexList(stdout: string): McpServerStatus[] {
  let entries: CodexEntry[];
  try {
    entries = JSON.parse(stdout) as CodexEntry[];
  } catch {
    return [];
  }
  if (!Array.isArray(entries)) return [];
  return entries.map((e) => {
    const t = e.transport ?? { type: "" };
    const transport =
      t.type === "streamable_http" || t.type === "http" ? "http" : t.type === "sse" ? "sse" : "stdio";
    const detail =
      transport === "stdio" ? [t.command, ...(t.args ?? [])].filter(Boolean).join(" ") : (t.url ?? "");
    const auth = e.auth_status && e.auth_status !== "unsupported" ? e.auth_status.replace(/_/g, "") : null;
    return {
      name: e.name,
      detail,
      transport,
      health: e.enabled ? "enabled" : "disabled",
      statusLabel: e.enabled ? "enabled" : (e.disabled_reason ?? "disabled"),
      auth,
    } satisfies McpServerStatus;
  });
}

async function getVersion(spec: ProviderSpec): Promise<string | null> {
  try {
    const { stdout } = await execFileAsync(spec.command, ["--version"], {
      timeout: VERSION_TIMEOUT_MS,
    });
    return stdout.split("\n")[0]?.trim() || null;
  } catch {
    return null;
  }
}

async function getProviderStatus(id: ProviderId): Promise<ProviderStatus> {
  const spec = PROVIDERS[id];
  const base: ProviderStatus = {
    id,
    label: spec.label,
    command: spec.command,
    available: false,
    version: null,
    warning: null,
    error: null,
    mcpServers: [],
  };

  const version = await getVersion(spec);
  if (version === null) {
    return { ...base, error: `${spec.label} CLI not found or not runnable at ${spec.command}` };
  }
  base.available = true;
  base.version = version;

  try {
    if (id === "codex") {
      const { stdout } = await execFileAsync(spec.command, ["mcp", "list", "--json"], {
        timeout: LIST_TIMEOUT_MS,
        maxBuffer: 4 * 1024 * 1024,
      });
      base.mcpServers = parseCodexList(stdout);
    } else {
      const { stdout, stderr } = await execFileAsync(spec.command, ["mcp", "list"], {
        timeout: LIST_TIMEOUT_MS,
        maxBuffer: 4 * 1024 * 1024,
      });
      // claude prints its connectors-disabled banner to stderr; fold it in so the
      // panel can surface it. Servers are on stdout; the parser classifies per line.
      const { servers, warning } = parseClaudeList(`${stderr}\n${stdout}`);
      base.mcpServers = servers;
      base.warning = warning;
    }
  } catch (err) {
    base.error = err instanceof Error ? err.message : String(err);
  }
  return base;
}

/** Gather auth/MCP status for every provider, run concurrently. */
export function getAllStatus(): Promise<ProviderStatus[]> {
  return Promise.all((Object.keys(PROVIDERS) as ProviderId[]).map(getProviderStatus));
}
