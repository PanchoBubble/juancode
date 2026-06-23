import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { api } from "../lib/api.ts";

export function Sidebar() {
  const sessions = useQuery({
    queryKey: ["sessions"],
    queryFn: api.sessions,
    refetchInterval: 4000,
  });

  return (
    <aside className="flex h-full w-64 shrink-0 flex-col border-r border-neutral-800 bg-neutral-950">
      <div className="flex items-center justify-between px-4 py-3">
        <Link to="/" className="text-sm font-semibold tracking-tight">
          juancode
        </Link>
        <Link
          to="/"
          className="rounded-md bg-neutral-800 px-2 py-1 text-xs text-neutral-200 hover:bg-neutral-700"
        >
          + New
        </Link>
      </div>
      <nav className="flex-1 overflow-y-auto">
        {(sessions.data ?? []).map((s) => (
          <Link
            key={s.id}
            to="/session/$id"
            params={{ id: s.id }}
            className="flex flex-col gap-0.5 border-b border-neutral-900 px-4 py-2 hover:bg-neutral-900 [&.active]:bg-neutral-900"
          >
            <div className="flex items-center gap-2">
              <span
                className={`h-2 w-2 shrink-0 rounded-full ${
                  s.status === "running" ? "bg-emerald-500" : "bg-neutral-600"
                }`}
              />
              <span className="truncate text-sm">{s.title}</span>
            </div>
            <span className="truncate pl-4 font-mono text-[11px] text-neutral-500">{s.cwd}</span>
          </Link>
        ))}
        {sessions.data?.length === 0 && (
          <p className="px-4 py-3 text-xs text-neutral-500">No sessions yet.</p>
        )}
      </nav>
    </aside>
  );
}
