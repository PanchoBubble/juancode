import { useState } from "react";
import { api } from "../lib/api.ts";
import type { SessionPrompt } from "../protocol.ts";

/**
 * The in-UI decision affordance for a session stuck on `waiting_input`. Surfaces
 * the parsed pending question with tappable option buttons plus a free-text note,
 * and routes the answer back into the live session by id via the reply channel
 * (`POST /api/sessions/:id/respond`). Built for a phone: big tap targets, no need
 * to fiddle the raw terminal. The card unmounts on its own once the session moves
 * off waiting_input (the server stops sending a prompt).
 */
export function DecisionCard({ sessionId, prompt }: { sessionId: string; prompt: SessionPrompt }) {
  const [note, setNote] = useState("");
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const send = async (answer: { option?: number; text?: string }) => {
    if (sending) return;
    setSending(true);
    setError(null);
    try {
      await api.respond(sessionId, answer);
      setNote("");
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setSending(false);
    }
  };

  const trimmedNote = note.trim();

  return (
    <div className="border-t border-amber-500/30 bg-amber-500/5 px-3 py-3">
      <div className="mb-2 flex items-center gap-2">
        <span className="shrink-0 rounded bg-amber-500/15 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-amber-300">
          Needs you
        </span>
        {prompt.question && (
          <span className="min-w-0 flex-1 text-sm text-neutral-100">{prompt.question}</span>
        )}
      </div>

      {prompt.options.length > 0 && (
        <div className="mb-2 flex flex-col gap-1.5">
          {prompt.options.map((o) => (
            <button
              key={o.index}
              disabled={sending}
              onClick={() => void send({ option: o.index, text: trimmedNote || undefined })}
              className="flex items-center gap-2 rounded-md border border-neutral-700 bg-neutral-900 px-3 py-2 text-left text-sm text-neutral-200 transition-colors enabled:hover:border-amber-500 enabled:hover:text-amber-200 disabled:opacity-50"
            >
              <span className="flex h-5 w-5 shrink-0 items-center justify-center rounded bg-neutral-800 text-[11px] text-neutral-400">
                {o.index}
              </span>
              <span className="min-w-0">{o.label}</span>
            </button>
          ))}
        </div>
      )}

      <div className="flex items-end gap-2">
        <textarea
          value={note}
          onChange={(e) => setNote(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
              e.preventDefault();
              if (trimmedNote) void send({ text: trimmedNote });
            }
          }}
          rows={1}
          placeholder={
            prompt.options.length > 0
              ? "Add a note (sent with your choice), or send on its own…"
              : "Type your answer…"
          }
          className="min-h-[2.25rem] min-w-0 flex-1 resize-y rounded-md border border-neutral-700 bg-neutral-950 px-2.5 py-1.5 text-sm text-neutral-200 placeholder:text-neutral-600 focus:border-amber-500 focus:outline-none"
        />
        <button
          onClick={() => trimmedNote && void send({ text: trimmedNote })}
          disabled={sending || !trimmedNote}
          className="shrink-0 rounded-md border border-neutral-700 px-3 py-2 text-sm text-neutral-300 enabled:hover:border-amber-500 enabled:hover:text-amber-300 disabled:opacity-40"
        >
          {sending ? "Sending…" : "Send"}
        </button>
      </div>

      {error && <div className="mt-1.5 text-[11px] text-red-400">{error}</div>}
    </div>
  );
}
