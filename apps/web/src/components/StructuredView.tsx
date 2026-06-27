import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { socket } from "../lib/socket.ts";
import type { ServerMessage, StructuredEvent } from "../protocol.ts";

/**
 * The opt-in structured rendering of a session: message and tool bubbles parsed
 * from the CLI's stream-json transcript, the alternative to the raw xterm/ANSI
 * view. Read-only history plus a composer that sends a prompt to the live pty
 * (the genuine interactive CLI remains the source of truth underneath).
 */
export function StructuredView({ sessionId, running }: { sessionId: string; running: boolean }) {
  const [events, setEvents] = useState<StructuredEvent[]>([]);
  const seen = useRef<Set<string>>(new Set());
  const scrollRef = useRef<HTMLDivElement>(null);
  // Only auto-scroll when the user is already at the bottom, so reading back
  // through history isn't yanked away by a fresh event.
  const pinnedToBottom = useRef(true);
  const [draft, setDraft] = useState("");
  const taRef = useRef<HTMLTextAreaElement>(null);

  // Auto-grow the composer to fit its content up to the CSS max-height (no drag
  // handle), so multi-line prompts are comfortable to read on a phone.
  useLayoutEffect(() => {
    const el = taRef.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${el.scrollHeight}px`;
  }, [draft]);

  useEffect(() => {
    setEvents([]);
    seen.current = new Set();
    pinnedToBottom.current = true;
    const unsubscribe = socket.subscribe((msg: ServerMessage) => {
      if (msg.type !== "structured" || msg.sessionId !== sessionId) return;
      if (msg.reset) {
        seen.current = new Set(msg.events.map((e) => e.id));
        setEvents(msg.events);
        return;
      }
      const fresh = msg.events.filter((e) => !seen.current.has(e.id));
      if (fresh.length === 0) return;
      for (const e of fresh) seen.current.add(e.id);
      setEvents((cur) => [...cur, ...fresh]);
    });
    socket.send({ type: "subscribeStructured", sessionId });
    return () => {
      socket.send({ type: "unsubscribeStructured", sessionId });
      unsubscribe();
    };
  }, [sessionId]);

  const onScroll = () => {
    const el = scrollRef.current;
    if (!el) return;
    pinnedToBottom.current = el.scrollHeight - el.scrollTop - el.clientHeight < 80;
  };

  useLayoutEffect(() => {
    const el = scrollRef.current;
    if (el && pinnedToBottom.current) el.scrollTop = el.scrollHeight;
  }, [events]);

  const send = () => {
    const text = draft.trim();
    if (!text || !running) return;
    // Match the CLI's expected submit: the prompt plus the trailing Enter.
    socket.send({ type: "input", sessionId, data: `${text}\r` });
    setDraft("");
    pinnedToBottom.current = true;
  };

  const onKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      send();
    }
  };

  return (
    <div className="flex h-full flex-col bg-[#0b0d10]">
      <div
        ref={scrollRef}
        onScroll={onScroll}
        className="min-h-0 flex-1 space-y-3 overflow-y-auto p-4"
      >
        {events.length === 0 ? (
          <div className="flex h-full items-center justify-center text-sm text-neutral-600">
            No structured events yet — they appear as the agent works.
          </div>
        ) : (
          events.map((e) => <Bubble key={e.id} event={e} />)
        )}
      </div>
      {running && (
        <div className="border-t border-neutral-800 p-2">
          <div className="flex items-end gap-2">
            <textarea
              ref={taRef}
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={onKeyDown}
              rows={1}
              placeholder="Message the agent…  (Enter to send, Shift+Enter for newline)"
              className="max-h-40 min-h-[2.25rem] flex-1 resize-none rounded-md border border-neutral-700 bg-neutral-900 px-3 py-2 text-sm text-neutral-100 placeholder:text-neutral-600 focus:border-neutral-500 focus:outline-none"
            />
            <button
              onClick={send}
              disabled={!draft.trim()}
              className="rounded-md border border-neutral-700 px-3 py-2 text-sm text-neutral-300 hover:border-emerald-500 hover:text-emerald-400 disabled:opacity-40"
            >
              Send
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

function Bubble({ event }: { event: StructuredEvent }) {
  switch (event.kind) {
    case "user":
      return (
        <div className="flex justify-end">
          <div className="max-w-[80%] whitespace-pre-wrap rounded-lg border border-sky-500/30 bg-sky-500/10 px-3 py-2 text-sm text-sky-100">
            {event.text}
          </div>
        </div>
      );
    case "assistant":
      return (
        <div className="max-w-[85%] whitespace-pre-wrap rounded-lg border border-neutral-700 bg-neutral-900 px-3 py-2 text-sm text-neutral-100">
          {event.text}
        </div>
      );
    case "thinking":
      return (
        <div className="max-w-[85%] whitespace-pre-wrap border-l-2 border-neutral-700 px-3 py-1 text-xs italic text-neutral-500">
          {event.text}
        </div>
      );
    case "tool_use":
      return (
        <div className="max-w-[85%] overflow-hidden rounded-lg border border-violet-500/30 bg-violet-500/5">
          <div className="bg-violet-500/10 px-3 py-1 font-mono text-xs text-violet-300">
            ⚙ {event.toolName}
          </div>
          {event.toolInput && (
            <pre className="overflow-x-auto px-3 py-2 font-mono text-[11px] leading-relaxed text-neutral-400">
              {event.toolInput}
            </pre>
          )}
        </div>
      );
    case "tool_result":
      return (
        <div
          className={`max-w-[85%] overflow-hidden rounded-lg border ${
            event.isError
              ? "border-red-500/40 bg-red-500/5"
              : "border-neutral-800 bg-neutral-900/60"
          }`}
        >
          <pre
            className={`max-h-64 overflow-auto px-3 py-2 font-mono text-[11px] leading-relaxed ${
              event.isError ? "text-red-300" : "text-neutral-400"
            }`}
          >
            {event.text || "(no output)"}
          </pre>
        </div>
      );
    default:
      return null;
  }
}
