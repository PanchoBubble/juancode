import { useQuery } from "@tanstack/react-query";
import { api } from "../lib/api.ts";
import { socket } from "../lib/socket.ts";
import { Terminal } from "./Terminal.tsx";

export function SessionView({ id }: { id: string }) {
  const sessions = useQuery({ queryKey: ["sessions"], queryFn: api.sessions });
  const meta = sessions.data?.find((s) => s.id === id);

  return (
    <div className="flex h-full flex-col">
      <header className="flex items-center justify-between border-b border-neutral-800 px-4 py-2">
        <div className="min-w-0">
          <div className="truncate text-sm font-medium">{meta?.title ?? id}</div>
          <div className="truncate font-mono text-[11px] text-neutral-500">{meta?.cwd}</div>
        </div>
        {meta?.status === "running" && (
          <button
            onClick={() => socket.send({ type: "kill", sessionId: id })}
            className="rounded-md border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:border-red-500 hover:text-red-400"
          >
            Kill
          </button>
        )}
      </header>
      <div className="min-h-0 flex-1 bg-[#0b0d10]">
        <Terminal key={id} sessionId={id} />
      </div>
    </div>
  );
}
