import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { api } from "../lib/api.ts";
import type { SessionMeta } from "../protocol.ts";

interface FolderGroup {
  cwd: string;
  /** Last path segment of the cwd, shown as the header label. */
  name: string;
  sessions: SessionMeta[];
  running: number;
}

/** Group sessions by their work folder, sorted by folder path. */
function groupByFolder(sessions: SessionMeta[]): FolderGroup[] {
  const byCwd = new Map<string, SessionMeta[]>();
  for (const s of sessions) {
    const list = byCwd.get(s.cwd);
    if (list) list.push(s);
    else byCwd.set(s.cwd, [s]);
  }
  return [...byCwd.entries()]
    .map(([cwd, group]) => ({
      cwd,
      name: cwd.split("/").filter(Boolean).pop() ?? cwd,
      sessions: group.sort((a, b) => b.updatedAt - a.updatedAt),
      running: group.filter((s) => s.status === "running").length,
    }))
    .sort((a, b) => a.cwd.localeCompare(b.cwd));
}

export function Sidebar() {
  const sessions = useQuery({
    queryKey: ["sessions"],
    queryFn: api.sessions,
    refetchInterval: 4000,
  });

  const groups = groupByFolder(sessions.data ?? []);

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
        {groups.map((g) => (
          <details key={g.cwd} open className="group border-b border-neutral-900">
            <summary
              title={g.cwd}
              className="flex cursor-pointer items-center gap-2 px-4 py-2 text-xs text-neutral-400 hover:bg-neutral-900"
            >
              <span className="text-neutral-600 transition-transform group-open:rotate-90">▶</span>
              <span className="truncate font-medium text-neutral-300">{g.name}</span>
              <span className="ml-auto flex shrink-0 items-center gap-1.5 text-neutral-500">
                {g.running > 0 && <span className="h-1.5 w-1.5 rounded-full bg-emerald-500" />}
                {g.sessions.length}
              </span>
            </summary>
            {g.sessions.map((s) => (
              <Link
                key={s.id}
                to="/session/$id"
                params={{ id: s.id }}
                className="flex items-center gap-2 py-1.5 pr-4 pl-6 hover:bg-neutral-900 [&.active]:bg-neutral-900"
              >
                <span
                  className={`h-2 w-2 shrink-0 rounded-full ${
                    s.status === "running" ? "bg-emerald-500" : "bg-neutral-600"
                  }`}
                />
                <span className="truncate text-sm">{s.title}</span>
              </Link>
            ))}
          </details>
        ))}
        {sessions.data?.length === 0 && (
          <p className="px-4 py-3 text-xs text-neutral-500">No sessions yet.</p>
        )}
      </nav>
    </aside>
  );
}
