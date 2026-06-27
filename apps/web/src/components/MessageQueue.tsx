import { useState } from "react";
import type { QueuedMessage } from "../protocol.ts";

/**
 * Compose and manage a session's message queue (ticket oracle-cj3): line up one
 * or more follow-up instructions while the agent is still busy, see them pending
 * in order, and cancel any before it's sent. The queue is persisted server-side
 * and flushed in order on the next idle, so this is just a thin view over the
 * `queue` snapshots the server pushes — the actual delivery happens on the server.
 */
export function MessageQueue({
  items,
  onQueue,
  onRemove,
}: {
  /** The session's pending messages, in delivery order. */
  items: QueuedMessage[];
  /** Queue a new message for delivery on the next idle. */
  onQueue: (text: string) => void;
  /** Cancel a still-pending message by id. */
  onRemove: (id: string) => void;
}) {
  const [draft, setDraft] = useState("");

  const submit = () => {
    const text = draft.trim();
    if (!text) return;
    onQueue(text);
    setDraft("");
  };

  return (
    <div className="border-t border-neutral-800 bg-neutral-900/40">
      {items.length > 0 && (
        <ul className="flex flex-col gap-1 px-3 pt-2">
          {items.map((item, i) => (
            <li
              key={item.id}
              className="flex items-center gap-2 rounded-md border border-neutral-800 bg-neutral-950/60 px-2 py-1 text-xs"
            >
              <span className="flex h-4 w-4 shrink-0 items-center justify-center rounded bg-sky-500/15 text-[10px] font-medium text-sky-300">
                {i + 1}
              </span>
              <span className="min-w-0 flex-1 truncate text-neutral-300" title={item.text}>
                {item.text}
              </span>
              <button
                onClick={() => onRemove(item.id)}
                className="shrink-0 rounded px-1.5 py-0.5 text-neutral-500 hover:text-red-400"
                title="Cancel this queued message"
                aria-label="Cancel queued message"
              >
                ✕
              </button>
            </li>
          ))}
        </ul>
      )}
      <div className="flex items-center gap-2 px-3 py-2">
        <input
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              submit();
            }
          }}
          placeholder={
            items.length > 0
              ? "Queue another message…"
              : "Queue a follow-up to send when the agent is ready…"
          }
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
    </div>
  );
}
