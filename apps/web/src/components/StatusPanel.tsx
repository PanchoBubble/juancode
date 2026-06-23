import { useQuery } from "@tanstack/react-query";
import { api, type McpHealth, type McpServerStatus, type ProviderStatus } from "../lib/api.ts";

/** Dot color + label per normalized MCP health. */
const HEALTH: Record<McpHealth, { dot: string; text: string; label: string }> = {
  connected: { dot: "bg-emerald-500", text: "text-emerald-400", label: "Connected" },
  enabled: { dot: "bg-emerald-500", text: "text-emerald-400", label: "Enabled" },
  "needs-auth": { dot: "bg-amber-500", text: "text-amber-400", label: "Needs auth" },
  pending: { dot: "bg-sky-500", text: "text-sky-400", label: "Pending approval" },
  failed: { dot: "bg-red-500", text: "text-red-400", label: "Failed" },
  disabled: { dot: "bg-neutral-600", text: "text-neutral-500", label: "Disabled" },
  unknown: { dot: "bg-neutral-500", text: "text-neutral-400", label: "Unknown" },
};

function ServerRow({ s }: { s: McpServerStatus }) {
  const h = HEALTH[s.health];
  return (
    <div className="flex items-center gap-2 px-3 py-1.5 text-sm">
      <span className={`h-2 w-2 shrink-0 rounded-full ${h.dot}`} title={s.statusLabel || h.label} />
      <span className="shrink-0 font-medium text-neutral-200">{s.name}</span>
      {s.transport && (
        <span className="shrink-0 rounded bg-neutral-800 px-1.5 py-0.5 text-[10px] tracking-wide text-neutral-400 uppercase">
          {s.transport}
        </span>
      )}
      <span className="min-w-0 flex-1 truncate font-mono text-xs text-neutral-500" title={s.detail}>
        {s.detail}
      </span>
      {s.auth && <span className="shrink-0 text-[10px] text-neutral-500">{s.auth}</span>}
      <span className={`shrink-0 text-xs ${h.text}`}>{s.statusLabel || h.label}</span>
    </div>
  );
}

function ProviderCard({ p }: { p: ProviderStatus }) {
  return (
    <div className="rounded-md border border-neutral-700 bg-neutral-900/50">
      <div className="flex items-center gap-2 border-b border-neutral-800 px-3 py-2">
        <span className={`h-2 w-2 shrink-0 rounded-full ${p.available ? "bg-emerald-500" : "bg-red-500"}`} />
        <span className="text-sm font-medium text-neutral-200">{p.label}</span>
        {p.version && <span className="text-xs text-neutral-500">{p.version}</span>}
        <span className="ml-auto truncate font-mono text-[10px] text-neutral-600" title={p.command}>
          {p.command}
        </span>
      </div>

      {p.warning && (
        <div className="border-b border-neutral-800 px-3 py-2 text-xs text-amber-400/90">⚠ {p.warning}</div>
      )}
      {p.error && <div className="px-3 py-2 text-xs text-red-400">{p.error}</div>}

      {!p.error && p.mcpServers.length === 0 && (
        <div className="px-3 py-2 text-xs text-neutral-500">No MCP servers configured.</div>
      )}
      <div className="divide-y divide-neutral-800/60">
        {p.mcpServers.map((s) => (
          <ServerRow key={s.name} s={s} />
        ))}
      </div>
    </div>
  );
}

/**
 * Per-provider auth + MCP status, so you can confirm your connectors / config
 * servers are live before starting a session. Reflects the genuine CLIs.
 */
export function StatusPanel() {
  const status = useQuery({ queryKey: ["status"], queryFn: api.status, staleTime: 30_000 });

  return (
    <details className="rounded-md border border-neutral-800 bg-neutral-950">
      <summary className="flex cursor-pointer items-center gap-2 px-3 py-2 text-sm text-neutral-300">
        <span className="font-medium">Auth &amp; MCP status</span>
        <span className="text-xs text-neutral-500">
          {status.isLoading ? "checking…" : status.data ? "confirm your servers are live" : ""}
        </span>
        <button
          type="button"
          onClick={(e) => {
            e.preventDefault();
            void status.refetch();
          }}
          className="ml-auto rounded px-2 py-0.5 text-xs text-neutral-400 hover:bg-neutral-800 hover:text-neutral-200"
        >
          {status.isFetching ? "…" : "Refresh"}
        </button>
      </summary>
      <div className="flex flex-col gap-3 px-3 pt-1 pb-3">
        {status.error && <div className="text-xs text-red-400">{String(status.error)}</div>}
        {status.data?.map((p) => (
          <ProviderCard key={p.id} p={p} />
        ))}
      </div>
    </details>
  );
}
