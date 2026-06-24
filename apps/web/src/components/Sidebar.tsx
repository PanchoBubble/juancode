import { useEffect, useState, useSyncExternalStore } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useNavigate } from "@tanstack/react-router";
import { api } from "../lib/api.ts";
import { socket } from "../lib/socket.ts";
import { registerSessionTitles, useActivityMap } from "../lib/activity.ts";
import { notifications } from "../lib/notifications.ts";
import type { ProviderId, SessionMeta } from "../protocol.ts";
import { ActivityDot } from "./ActivityDot.tsx";
import { FolderPrs } from "./FolderPrs.tsx";
import { SearchPanel } from "./SearchPanel.tsx";

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
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const sessions = useQuery({
    queryKey: ["sessions"],
    queryFn: api.sessions,
    refetchInterval: 4000,
  });
  const providers = useQuery({ queryKey: ["providers"], queryFn: api.providers });
  const activity = useActivityMap();

  // Mirror session titles into the activity store so notifications can name them.
  useEffect(() => {
    if (sessions.data) registerSessionTitles(sessions.data);
  }, [sessions.data]);

  // Notification on/off toggle, reflecting the persisted notifications state.
  const notifyOn = useSyncExternalStore(
    (cb) => notifications.subscribe(cb),
    () => notifications.enabled,
  );

  // Free-text filter over folder names + session titles.
  const [query, setQuery] = useState("");
  const q = query.trim().toLowerCase();
  const filtered = q
    ? (sessions.data ?? []).filter(
        (s) => s.title.toLowerCase().includes(q) || s.cwd.toLowerCase().includes(q),
      )
    : (sessions.data ?? []);
  const groups = groupByFolder(filtered);

  // Which folder's "+" agent menu is open (keyed by cwd), if any.
  const [menuFor, setMenuFor] = useState<string | null>(null);
  // "Accept all" (skip permission prompts) toggle for the open "+" menu.
  const [menuYolo, setMenuYolo] = useState(false);
  // "Isolate in a new git worktree" toggle for the open "+" menu.
  const [menuWorktree, setMenuWorktree] = useState(false);

  /** Permanently delete a session after confirmation. */
  const remove = (s: SessionMeta) => {
    if (!window.confirm(`Delete session "${s.title}"? This can't be undone.`)) return;
    void api.deleteSession(s.id).then(() => {
      void queryClient.invalidateQueries({ queryKey: ["sessions"] });
    });
  };

  // Close the agent menu on any outside click / Escape.
  useEffect(() => {
    if (!menuFor) return;
    const close = () => setMenuFor(null);
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setMenuFor(null);
    };
    window.addEventListener("click", close);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("click", close);
      window.removeEventListener("keydown", onKey);
    };
  }, [menuFor]);

  /**
   * Spawn a terminal for `provider` directly at `cwd`, then open it. An optional
   * `initialInput` is auto-submitted to the fresh session (e.g. PR context).
   */
  const spawn = (
    provider: ProviderId,
    cwd: string,
    initialInput?: string,
    skipPermissions?: boolean,
    isolateWorktree?: boolean,
  ) => {
    setMenuFor(null);
    const unsub = socket.subscribe((msg) => {
      if (msg.type === "created") {
        unsub();
        void queryClient.invalidateQueries({ queryKey: ["sessions"] });
        void navigate({ to: "/session/$id", params: { id: msg.session.id } });
      } else if (msg.type === "error") {
        unsub();
      }
    });
    socket.send({
      type: "create",
      provider,
      cwd,
      cols: 80,
      rows: 24,
      initialInput,
      skipPermissions,
      isolateWorktree,
    });
  };

  return (
    <aside className="flex h-full w-64 shrink-0 flex-col border-r border-neutral-800 bg-neutral-950">
      <div className="flex items-center justify-between px-4 py-3">
        <Link to="/" className="text-sm font-semibold tracking-tight">
          juancode
        </Link>
        <div className="flex items-center gap-1.5">
          <button
            type="button"
            onClick={() => notifications.setEnabled(!notifyOn)}
            title={notifyOn ? "Notifications on — click to mute" : "Notifications muted — click to enable"}
            className="rounded-md px-1.5 py-1 text-xs text-neutral-400 hover:bg-neutral-800 hover:text-neutral-200"
          >
            {notifyOn ? "🔔" : "🔕"}
          </button>
          <Link
            to="/"
            className="rounded-md bg-neutral-800 px-2 py-1 text-xs text-neutral-200 hover:bg-neutral-700"
          >
            + New
          </Link>
        </div>
      </div>
      <div className="px-3 pb-2">
        <input
          type="search"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search sessions + transcripts…"
          className="w-full rounded-md border border-neutral-800 bg-neutral-900 px-2.5 py-1.5 text-xs text-neutral-200 placeholder:text-neutral-500 focus:border-neutral-600 focus:outline-none"
        />
      </div>
      <nav className="flex-1 overflow-y-auto">
        <SearchPanel query={query} />
        {groups.map((g) => (
          <details key={g.cwd} open className="group border-b border-neutral-900">
            <summary
              title={g.cwd}
              className="flex cursor-pointer items-center gap-2 px-4 py-2 text-xs text-neutral-400 hover:bg-neutral-900"
            >
              <span className="text-neutral-600 transition-transform group-open:rotate-90">▶</span>
              <span className="truncate font-medium text-neutral-300">{g.name}</span>
              <span className="ml-auto flex shrink-0 items-center gap-1.5 text-neutral-500">
                {g.sessions.some((s) => s.status === "running" && activity[s.id] === "waiting_input") ? (
                  <span
                    title="A session needs your input"
                    className="h-1.5 w-1.5 animate-pulse rounded-full bg-amber-400"
                  />
                ) : (
                  g.running > 0 && <span className="h-1.5 w-1.5 rounded-full bg-emerald-500" />
                )}
                {g.sessions.length}
                <FolderPrs cwd={g.cwd} onNewSession={spawn} />
                <span className="relative">
                  <button
                    type="button"
                    title={`New terminal in ${g.cwd}`}
                    onClick={(e) => {
                      e.preventDefault();
                      e.stopPropagation();
                      setMenuYolo(false);
                      setMenuWorktree(false);
                      setMenuFor((cur) => (cur === g.cwd ? null : g.cwd));
                    }}
                    className="rounded px-1 text-neutral-500 hover:bg-neutral-800 hover:text-neutral-200"
                  >
                    +
                  </button>
                  {menuFor === g.cwd && (
                    <div
                      onClick={(e) => e.stopPropagation()}
                      className="absolute top-full right-0 z-10 mt-1 min-w-28 overflow-hidden rounded-md border border-neutral-700 bg-neutral-900 py-1 shadow-lg"
                    >
                      {(providers.data ?? []).map((p) => (
                        <button
                          key={p.id}
                          type="button"
                          onClick={(e) => {
                            e.preventDefault();
                            e.stopPropagation();
                            spawn(p.id, g.cwd, undefined, menuYolo, menuWorktree);
                          }}
                          className="block w-full px-3 py-1 text-left text-xs text-neutral-300 hover:bg-neutral-800 hover:text-neutral-100"
                        >
                          {p.label}
                        </button>
                      ))}
                      <label
                        title="Skip permission/approval prompts (--dangerously-skip-permissions / --dangerously-bypass-approvals-and-sandbox)"
                        className="mt-1 flex cursor-pointer items-center gap-1.5 border-t border-neutral-800 px-3 py-1.5 text-xs text-neutral-400 hover:text-neutral-200"
                      >
                        <input
                          type="checkbox"
                          checked={menuYolo}
                          onChange={(e) => setMenuYolo(e.target.checked)}
                          className="accent-amber-500"
                        />
                        <span className={menuYolo ? "text-amber-300" : undefined}>Accept all</span>
                      </label>
                      <label
                        title="Run in a fresh git worktree on a new juancode/ branch (removed on delete)"
                        className="flex cursor-pointer items-center gap-1.5 px-3 py-1.5 text-xs text-neutral-400 hover:text-neutral-200"
                      >
                        <input
                          type="checkbox"
                          checked={menuWorktree}
                          onChange={(e) => setMenuWorktree(e.target.checked)}
                          className="accent-sky-500"
                        />
                        <span className={menuWorktree ? "text-sky-300" : undefined}>New worktree</span>
                      </label>
                    </div>
                  )}
                </span>
              </span>
            </summary>
            <div className="max-h-64 overflow-y-auto">
              {g.sessions.map((s) => (
                <Link
                  key={s.id}
                  to="/session/$id"
                  params={{ id: s.id }}
                  className="group/item flex items-center gap-2 py-1.5 pr-2 pl-6 hover:bg-neutral-900 [&.active]:bg-neutral-900"
                >
                  <ActivityDot status={s.status} activity={activity[s.id]} />
                  {s.worktreePath && (
                    <span
                      title={`Isolated worktree: ${s.worktreePath}`}
                      className="shrink-0 text-xs text-sky-500"
                    >
                      ⎇
                    </span>
                  )}
                  <span className="truncate text-sm">{s.title}</span>
                  <span className="ml-auto flex shrink-0 items-center">
                    {s.status === "exited" && (
                      <button
                        title="Resume session"
                        onClick={(e) => {
                          e.preventDefault();
                          e.stopPropagation();
                          // Open it — the session view resumes (recovering an old
                          // CLI id if needed) and shows a fallback if it can't.
                          void navigate({ to: "/session/$id", params: { id: s.id } });
                        }}
                        className="rounded px-1 text-neutral-500 hover:bg-neutral-800 hover:text-emerald-400"
                      >
                        ↻
                      </button>
                    )}
                    <button
                      title="Delete session"
                      onClick={(e) => {
                        e.preventDefault();
                        e.stopPropagation();
                        remove(s);
                      }}
                      className="rounded px-1 text-neutral-500 opacity-0 group-hover/item:opacity-100 hover:bg-neutral-800 hover:text-red-400"
                    >
                      ✕
                    </button>
                  </span>
                </Link>
              ))}
            </div>
          </details>
        ))}
        {groups.length === 0 && (
          <p className="px-4 py-3 text-xs text-neutral-500">
            {q ? "No matching sessions." : "No sessions yet."}
          </p>
        )}
      </nav>
    </aside>
  );
}
