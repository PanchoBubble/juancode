import { useCallback, useLayoutEffect, useRef, useState } from "react";
import type { QueuedMessage } from "../protocol.ts";

/**
 * The session message composer (ticket oracle-cj3 + steering addendum). Two ways
 * to send a follow-up while the agent is running:
 *
 *  - **Queue** — line the message up; it's persisted server-side and flushed in
 *    order on the next idle (or promptly if the session is already idle). Pending
 *    items show below in delivery order and can be cancelled before they're sent.
 *  - **Steer now** — inject the message into the *busy* agent immediately to
 *    redirect it mid-task, instead of waiting for the turn to end. Offered only
 *    when there's a live turn to interrupt (`canSteer`).
 *
 * Delivery happens entirely server-side; this is a thin view over the `queue`
 * snapshots plus the two send actions. The textarea auto-grows up to a cap (no
 * drag handle), and buttons are sized as big tap targets for phone use.
 */
export function MessageQueue({
  items,
  canSteer,
  onQueue,
  onSteer,
  onRemove,
}: {
  /** The session's pending messages, in delivery order. */
  items: QueuedMessage[];
  /** Whether there's a live turn to interrupt — gates the "Steer now" button. */
  canSteer: boolean;
  /** Queue a new message for delivery on the next idle. */
  onQueue: (text: string) => void;
  /** Inject a message into the busy agent right now to redirect it. */
  onSteer: (text: string) => void;
  /** Cancel a still-pending message by id. */
  onRemove: (id: string) => void;
}) {
  const [draft, setDraft] = useState("");
  const taRef = useRef<HTMLTextAreaElement>(null);

  // Auto-grow the textarea to fit its content up to the CSS max-height, so the
  // composer has no drag handle and stays a comfortable size on a phone.
  const autoGrow = useCallback(() => {
    const el = taRef.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${el.scrollHeight}px`;
  }, []);
  useLayoutEffect(autoGrow, [draft, autoGrow]);

  const queue = () => {
    const text = draft.trim();
    if (!text) return;
    onQueue(text);
    setDraft("");
  };

  const steer = () => {
    const text = draft.trim();
    if (!text) return;
    onSteer(text);
    setDraft("");
  };

  const empty = !draft.trim();

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
                className="flex h-7 w-7 shrink-0 items-center justify-center rounded text-neutral-500 hover:text-red-400"
                title="Cancel this queued message"
                aria-label="Cancel queued message"
              >
                ✕
              </button>
            </li>
          ))}
        </ul>
      )}
      <div className="flex items-end gap-2 px-3 py-2">
        <textarea
          ref={taRef}
          value={draft}
          rows={1}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            // Enter sends the default action: steer when there's a live turn to
            // redirect, otherwise queue. Shift+Enter inserts a newline.
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              if (canSteer) steer();
              else queue();
            }
          }}
          placeholder={
            canSteer
              ? "Steer the agent, or queue a follow-up…"
              : items.length > 0
                ? "Queue another message…"
                : "Queue a follow-up to send when the agent is ready…"
          }
          className="max-h-40 min-h-[2.5rem] min-w-0 flex-1 resize-none rounded-md border border-neutral-700 bg-neutral-950 px-2.5 py-2 text-sm text-neutral-200 placeholder:text-neutral-600 focus:border-neutral-500 focus:outline-none"
        />
        {canSteer && (
          <button
            onClick={steer}
            disabled={empty}
            title="Inject this now to redirect the running agent"
            className="shrink-0 rounded-md border border-amber-600/60 bg-amber-500/10 px-3 py-2 text-sm font-medium text-amber-300 enabled:hover:border-amber-500 enabled:hover:bg-amber-500/20 disabled:opacity-40"
          >
            Steer&nbsp;now
          </button>
        )}
        <button
          onClick={queue}
          disabled={empty}
          title="Queue this for the next time the agent is ready"
          className="shrink-0 rounded-md border border-neutral-700 px-3 py-2 text-sm text-neutral-300 enabled:hover:border-sky-500 enabled:hover:text-sky-400 disabled:opacity-40"
        >
          Queue
        </button>
      </div>
    </div>
  );
}
