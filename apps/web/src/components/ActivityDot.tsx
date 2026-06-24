import type { SessionActivity } from "../protocol.ts";

/**
 * The status indicator for a session: a spinner while the agent works, a pulsing
 * amber dot when it's waiting for input, otherwise the plain running/exited dot.
 */
export function ActivityDot({
  status,
  activity,
}: {
  status: "running" | "exited";
  activity: SessionActivity | undefined;
}) {
  if (status === "running" && activity === "busy") {
    return (
      <span
        title="Working…"
        className="inline-block h-3 w-3 shrink-0 animate-spin rounded-full border-2 border-sky-400 border-t-transparent"
      />
    );
  }
  if (status === "running" && activity === "waiting_input") {
    return (
      <span
        title="Waiting for your input"
        className="inline-block h-2.5 w-2.5 shrink-0 animate-pulse rounded-full bg-amber-400 shadow-[0_0_0_3px_rgba(251,191,36,0.25)]"
      />
    );
  }
  return (
    <span
      title={status === "running" ? "Idle" : "Exited"}
      className={`inline-block h-2.5 w-2.5 shrink-0 rounded-full ${
        status === "running" ? "bg-emerald-500" : "bg-neutral-600"
      }`}
    />
  );
}
