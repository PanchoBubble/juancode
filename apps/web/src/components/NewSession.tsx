import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import { api } from "../lib/api.ts";
import { socket } from "../lib/socket.ts";
import type { ProviderId } from "../protocol.ts";

export function NewSession() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [provider, setProvider] = useState<ProviderId>("claude");
  const [path, setPath] = useState<string | undefined>(undefined);
  const [starting, setStarting] = useState(false);

  const providers = useQuery({ queryKey: ["providers"], queryFn: api.providers });
  const dirs = useQuery({ queryKey: ["dirs", path], queryFn: () => api.dirs(path) });

  const cwd = dirs.data?.path;

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
          <div className="max-h-64 overflow-y-auto">
            {dirs.data?.parent && (
              <button
                onClick={() => setPath(dirs.data!.parent!)}
                className="block w-full px-3 py-1.5 text-left font-mono text-sm text-neutral-400 hover:bg-neutral-800"
              >
                ../
              </button>
            )}
            {dirs.data?.entries.map((e) => (
              <button
                key={e.path}
                onClick={() => setPath(e.path)}
                className="block w-full px-3 py-1.5 text-left font-mono text-sm hover:bg-neutral-800"
              >
                {e.name}/
              </button>
            ))}
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
    </div>
  );
}
