import { useEffect, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate, useSearch } from "@tanstack/react-router";
import { api } from "../lib/api.ts";
import { socket } from "../lib/socket.ts";
import type { ProviderId } from "../protocol.ts";
import { StatusPanel } from "./StatusPanel.tsx";

export function NewSession() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  // Optional ?cwd= (e.g. the sidebar's per-folder "+") pre-targets the picker.
  const { cwd: initialCwd } = useSearch({ strict: false }) as { cwd?: string };
  const [provider, setProvider] = useState<ProviderId>("claude");
  const [path, setPath] = useState<string | undefined>(initialCwd);
  const [query, setQuery] = useState("");
  const [debouncedQuery, setDebouncedQuery] = useState("");
  const [starting, setStarting] = useState(false);

  // Debounce the search input so we don't hammer the recursive search per keystroke.
  useEffect(() => {
    const t = setTimeout(() => setDebouncedQuery(query.trim()), 200);
    return () => clearTimeout(t);
  }, [query]);

  const providers = useQuery({ queryKey: ["providers"], queryFn: api.providers });
  const dirs = useQuery({
    queryKey: ["dirs", path, debouncedQuery],
    queryFn: () => api.dirs(path, debouncedQuery || undefined),
  });

  const cwd = dirs.data?.path;
  const searching = dirs.data?.search ?? false;

  /** Navigate into a folder (from browse or a search hit) and reset the search. */
  const enter = (next: string) => {
    setPath(next);
    setQuery("");
    setDebouncedQuery("");
  };

  const start = () => {
    if (!cwd || starting) return;
    setStarting(true);
    const unsub = socket.subscribe((msg) => {
      if (msg.type === "created") {
        unsub();
        void queryClient.invalidateQueries({ queryKey: ["sessions"] });
        void navigate({ to: "/session/$id", params: { id: msg.session.id } });
      } else if (msg.type === "error") {
        unsub();
        setStarting(false);
      }
    });
    socket.send({ type: "create", provider, cwd, cols: 80, rows: 24 });
  };

  return (
    <div className="mx-auto flex max-w-2xl flex-col gap-6 p-8">
      <div>
        <h1 className="text-xl font-semibold">New session</h1>
        <p className="text-sm text-neutral-400">
          Launches the real CLI in a terminal — your MCP servers, auth and slash commands all work.
        </p>
      </div>

      <div className="flex gap-2">
        {(providers.data ?? []).map((p) => (
          <button
            key={p.id}
            onClick={() => setProvider(p.id)}
            className={`rounded-md border px-4 py-2 text-sm ${
              provider === p.id
                ? "border-sky-500 bg-sky-500/10 text-sky-300"
                : "border-neutral-700 text-neutral-300 hover:border-neutral-500"
            }`}
          >
            {p.label}
          </button>
        ))}
      </div>

      <div className="flex flex-col gap-2">
        <label className="text-sm text-neutral-400">Working directory</label>
        <div className="rounded-md border border-neutral-700 bg-neutral-900/50">
          <div className="border-b border-neutral-800 px-3 py-2 font-mono text-xs text-neutral-400">
            {cwd ?? "…"}
          </div>
          <input
            type="text"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search folders below here…"
            className="w-full border-b border-neutral-800 bg-transparent px-3 py-2 text-sm text-neutral-200 placeholder:text-neutral-600 focus:outline-none"
          />
          <div className="max-h-64 overflow-y-auto">
            {!searching && dirs.data?.parent && (
              <button
                onClick={() => enter(dirs.data!.parent!)}
                className="block w-full px-3 py-1.5 text-left font-mono text-sm text-neutral-400 hover:bg-neutral-800"
              >
                ../
              </button>
            )}
            {dirs.data?.entries.map((e) => (
              <button
                key={e.path}
                onClick={() => enter(e.path)}
                className="block w-full px-3 py-1.5 text-left font-mono text-sm hover:bg-neutral-800"
              >
                {e.name}/
              </button>
            ))}
            {searching && dirs.data?.entries.length === 0 && (
              <div className="px-3 py-1.5 text-sm text-neutral-500">No matching folders.</div>
            )}
            {dirs.error && (
              <div className="px-3 py-1.5 text-sm text-red-400">{String(dirs.error)}</div>
            )}
          </div>
        </div>
      </div>

      <button
        onClick={start}
        disabled={!cwd || starting}
        className="self-start rounded-md bg-sky-600 px-5 py-2 text-sm font-medium text-white hover:bg-sky-500 disabled:opacity-50"
      >
        {starting ? "Starting…" : `Start ${provider}`}
      </button>

      <StatusPanel />
    </div>
  );
}
