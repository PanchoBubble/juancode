import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { api } from "../lib/api.ts";
import { socket } from "../lib/socket.ts";
import type { ServerMessage } from "../protocol.ts";
import { BeadsPanel } from "./BeadsPanel.tsx";
import { ChangesPanel } from "./ChangesPanel.tsx";
import { Terminal } from "./Terminal.tsx";

type Tab = "terminal" | "changes" | "issues";

export function SessionView({ id }: { id: string }) {
  const sessions = useQuery({ queryKey: ["sessions"], queryFn: api.sessions });
  const meta = sessions.data?.find((s) => s.id === id);
  const [tab, setTab] = useState<Tab>("terminal");

  // Track status live off the socket so the header reflects reality without
  // waiting for the next sessions poll (kill → exited, reactivate → running).
  const [liveStatus, setLiveStatus] = useState<"running" | "exited" | null>(null);
  useEffect(() => {
    setLiveStatus(null);
    return socket.subscribe((msg: ServerMessage) => {
      if (!("sessionId" in msg) || msg.sessionId !== id) return;
      if (msg.type === "attached") setLiveStatus(msg.session.status);
      else if (msg.type === "exit") setLiveStatus("exited");
    });
  }, [id]);

  const status = liveStatus ?? meta?.status;
  const canReactivate = status === "exited" && Boolean(meta?.cliSessionId);

  return (
    <div className="flex h-full flex-col">
      <header className="flex items-center justify-between border-b border-neutral-800 px-4 py-2">
        <div className="min-w-0">
          <div className="truncate text-sm font-medium">{meta?.title ?? id}</div>
          <div className="truncate font-mono text-[11px] text-neutral-500">{meta?.cwd}</div>
        </div>
        <nav className="mr-auto ml-4 flex gap-1 text-xs">
          {(["terminal", "changes", "issues"] as const).map((t) => (
            <button
              key={t}
              onClick={() => setTab(t)}
              className={`rounded-md px-2.5 py-1 capitalize ${
                tab === t ? "bg-neutral-800 text-neutral-100" : "text-neutral-400 hover:text-neutral-200"
              }`}
            >
              {t}
            </button>
          ))}
        </nav>
        {status === "running" && (
          <button
            onClick={() => socket.send({ type: "kill", sessionId: id })}
            className="rounded-md border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:border-red-500 hover:text-red-400"
          >
            Kill
          </button>
        )}
        {canReactivate && (
          <button
            onClick={() => {
              setLiveStatus("running"); // optimistic — pty spawn is synchronous server-side
              socket.send({ type: "reactivate", sessionId: id, cols: 80, rows: 24 });
            }}
            className="rounded-md border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:border-emerald-500 hover:text-emerald-400"
          >
            Reactivate
          </button>
        )}
      </header>
      <div className="min-h-0 flex-1 bg-[#0b0d10]">
        {/* Keep the terminal mounted across tab switches so the pty/xterm state
            and scroll position survive; just hide it when viewing changes. */}
        <div className={tab === "terminal" ? "h-full" : "hidden"}>
          <Terminal key={id} sessionId={id} />
        </div>
        {tab === "changes" && <ChangesPanel sessionId={id} />}
        {tab === "issues" && <BeadsPanel sessionId={id} />}
      </div>
    </div>
  );
}
