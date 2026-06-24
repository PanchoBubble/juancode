import { useState } from "react";

/**
 * A small composer for queueing a follow-up instruction while the agent is still
 * mid-turn (busy or waiting for input). The text is buffered by the caller and
 * auto-sent on the next transition to `idle` for the session — so the user can
 * line up their next message without watching for the turn to finish.
 *
 * Rendered only while the session is busy/waiting; the actual send + idle-edge
 * detection live in SessionView, which owns the activity subscription.
 */
export function MessageQueue({
  queued,
  onQueue,
  onCancel,
}: {
  /** The currently queued message, or null when nothing is waiting to send. */
  queued: string | null;
  /** Buffer a message to auto-send on the next idle transition. */
  onQueue: (text: string) => void;
  /** Drop the queued message before it sends. */
  onCancel: () => void;
}) {
  const [draft, setDraft] = useState("");

  const submit = () => {
    const text = draft.trim();
    if (!text) return;
    onQueue(text);
    setDraft("");
  };

  if (queued !== null) {
    return (
      <div className="flex items-center gap-2 border-t border-neutral-800 bg-neutral-900/40 px-3 py-2 text-xs">
        <span className="shrink-0 rounded bg-sky-500/15 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-sky-300">
          Queued
        </span>
        <span className="min-w-0 flex-1 truncate text-neutral-300" title={queued}>
          {queued}
        </span>
        <span className="shrink-0 text-neutral-500">sends when the agent is idle</span>
        <button
          onClick={onCancel}
          className="shrink-0 rounded-md border border-neutral-700 px-2 py-0.5 text-neutral-400 hover:border-red-500 hover:text-red-400"
          title="Cancel queued message"
        >
          Cancel
        </button>
      </div>
    );
  }

  return (
    <div className="flex items-center gap-2 border-t border-neutral-800 bg-neutral-900/40 px-3 py-2">
      <input
        value={draft}
        onChange={(e) => setDraft(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && !e.shiftKey) {
            e.preventDefault();
            submit();
          }
        }}
        placeholder="Queue a follow-up to send when the agent is done…"
        className="min-w-0 flex-1 rounded-md border border-neutral-700 bg-neutral-950 px-2.5 py-1.5 text-xs text-neutral-200 placeholder:text-neutral-600 focus:border-neutral-500 focus:outline-none"
      />
      <button
        onClick={submit}
        disabled={!draft.trim()}
        className="shrink-0 rounded-md border border-neutral-700 px-3 py-1.5 text-xs text-neutral-300 enabled:hover:border-sky-500 enabled:hover:text-sky-400 disabled:opacity-40"
      >
        Queue
      </button>
    </div>
  );
}
