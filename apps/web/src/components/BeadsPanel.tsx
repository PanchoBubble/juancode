import { useMemo, type ReactNode } from "react";
import { useQuery } from "@tanstack/react-query";
import { api } from "../lib/api.ts";
import type { BeadsIssue } from "../protocol.ts";

const PRIORITY_LABEL: Record<number, string> = { 0: "P0", 1: "P1", 2: "P2", 3: "P3", 4: "P4" };
const PRIORITY_STYLE: Record<number, string> = {
  0: "bg-red-500/20 text-red-300",
  1: "bg-orange-500/20 text-orange-300",
  2: "bg-neutral-700/60 text-neutral-300",
  3: "bg-neutral-800 text-neutral-500",
  4: "bg-neutral-800 text-neutral-600",
};

const STATUS_STYLE: Record<string, string> = {
  open: "text-neutral-400",
  in_progress: "text-sky-400",
  blocked: "text-red-400",
  closed: "text-emerald-500",
  done: "text-emerald-500",
};

const TYPE_STYLE: Record<string, string> = {
  bug: "text-red-400",
  feature: "text-sky-400",
  task: "text-neutral-400",
  epic: "text-violet-400",
  chore: "text-neutral-500",
};

/** Sort: actionable first (ready), then by priority, then id for stability. */
function compareIssues(a: BeadsIssue, b: BeadsIssue): number {
  if (a.ready !== b.ready) return a.ready ? -1 : 1;
  if (a.priority !== b.priority) return a.priority - b.priority;
  return a.id.localeCompare(b.id);
}

export function BeadsPanel({ sessionId }: { sessionId: string }) {
  const beads = useQuery({
    queryKey: ["beads", sessionId],
    queryFn: () => api.beads(sessionId),
    refetchInterval: 8000,
  });

  const sorted = useMemo(
    () => [...(beads.data?.issues ?? [])].sort(compareIssues),
    [beads.data?.issues],
  );

  if (beads.isLoading) return <Centered>Loading issues…</Centered>;
  if (beads.error) return <Centered tone="error">{String(beads.error)}</Centered>;
  if (beads.data && !beads.data.available) {
    return <Centered>{beads.data.error ?? "No beads tracker in this folder."}</Centered>;
  }
  if (sorted.length === 0) return <Centered>No issues in this tracker.</Centered>;

  const open = sorted.filter((i) => i.status !== "closed" && i.status !== "done").length;
  const ready = sorted.filter((i) => i.ready).length;
  const blocked = sorted.filter((i) => i.blocked).length;

  return (
    <div className="h-full overflow-y-auto bg-neutral-950">
      <div className="sticky top-0 z-10 flex items-center gap-3 border-b border-neutral-800 bg-neutral-950 px-4 py-2 text-xs text-neutral-400">
        <span>
          {open} open / {sorted.length}
        </span>
        {ready > 0 && <span className="text-emerald-400">{ready} ready</span>}
        {blocked > 0 && <span className="text-red-400">{blocked} blocked</span>}
        <button
          onClick={() => beads.refetch()}
          className="ml-auto rounded border border-neutral-700 px-2 py-0.5 hover:border-neutral-500 hover:text-neutral-200"
        >
          Refresh
        </button>
      </div>
      <ul className="flex flex-col">
        {sorted.map((issue) => (
          <IssueRow key={issue.id} issue={issue} />
        ))}
      </ul>
    </div>
  );
}

function IssueRow({ issue }: { issue: BeadsIssue }) {
  const closed = issue.status === "closed" || issue.status === "done";
  return (
    <li
      className={`flex items-center gap-3 border-b border-neutral-900 px-4 py-2 text-sm hover:bg-neutral-900/50 ${
        closed ? "opacity-50" : ""
      }`}
    >
      <span
        className={`shrink-0 rounded px-1.5 py-0.5 font-mono text-[10px] ${
          PRIORITY_STYLE[issue.priority] ?? PRIORITY_STYLE[2]
        }`}
        title={`Priority ${issue.priority}`}
      >
        {PRIORITY_LABEL[issue.priority] ?? `P${issue.priority}`}
      </span>
      <span className="shrink-0 font-mono text-[11px] text-neutral-500">{issue.id}</span>
      <span className="min-w-0 flex-1 truncate text-neutral-200" title={issue.title}>
        {issue.parent && <span className="text-neutral-600">↳ </span>}
        {issue.title}
      </span>
      {issue.dependencyCount > 0 && (
        <span className="shrink-0 text-[11px] text-neutral-600" title="dependencies">
          ⛓ {issue.dependencyCount}
        </span>
      )}
      <span className={`shrink-0 text-[11px] ${TYPE_STYLE[issue.issueType] ?? "text-neutral-500"}`}>
        {issue.issueType}
      </span>
      <span
        className={`w-20 shrink-0 text-right text-[11px] ${STATUS_STYLE[issue.status] ?? "text-neutral-400"}`}
      >
        {issue.ready && !closed ? (
          <span className="text-emerald-400">● ready</span>
        ) : issue.blocked ? (
          <span className="text-red-400">⛔ blocked</span>
        ) : (
          issue.status.replace("_", " ")
        )}
      </span>
    </li>
  );
}

function Centered({ children, tone }: { children: ReactNode; tone?: "error" }) {
  return (
    <div
      className={`flex h-full items-center justify-center p-6 text-sm ${
        tone === "error" ? "text-red-400" : "text-neutral-500"
      }`}
    >
      {children}
    </div>
  );
}
