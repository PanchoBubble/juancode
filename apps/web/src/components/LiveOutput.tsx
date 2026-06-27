import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { socket } from "../lib/socket.ts";
import type { ServerMessage } from "../protocol.ts";

/**
 * The phone-friendly live view of a session: the agent's *rendered screen*,
 * streamed from the server as cheap per-row diffs (the `screen` messages) and
 * shown as reflowing monospace text — so you watch the response as it's typed
 * without cramming the full xterm TUI onto a phone, and without shipping the raw
 * ANSI `output` byte stream over a mobile link.
 *
 * The server sends a full-screen snapshot first (`reset`), then only the rows
 * that change; we keep the grid in a ref and re-render the joined text. Autoscroll
 * sticks to the bottom (where the agent's latest line and input box live) but
 * yields the moment the user scrolls up to read back, so it never fights them.
 */
export function LiveOutput({ sessionId, running }: { sessionId: string; running: boolean }) {
  const [text, setText] = useState("");
  const [exited, setExited] = useState(false);
  const rows = useRef<string[]>([]);
  const scrollRef = useRef<HTMLDivElement>(null);
  const pinnedToBottom = useRef(true);

  useEffect(() => {
    rows.current = [];
    setText("");
    setExited(false);
    pinnedToBottom.current = true;

    const render = () => {
      // Drop trailing blank rows so the input box sits at the visible bottom
      // rather than below a tall run of empty grid.
      let end = rows.current.length;
      while (end > 0 && (rows.current[end - 1] ?? "") === "") end--;
      setText(rows.current.slice(0, end).join("\n"));
    };

    const unsubscribe = socket.subscribe((msg: ServerMessage) => {
      if (!("sessionId" in msg) || msg.sessionId !== sessionId) return;
      if (msg.type === "screen") {
        if (msg.reset) rows.current = new Array(msg.height).fill("");
        else if (msg.height !== rows.current.length) rows.current.length = msg.height;
        for (const r of msg.rows) rows.current[r.i] = r.text;
        render();
      } else if (msg.type === "exit") {
        setExited(true);
      }
    });
    socket.send({ type: "subscribeScreen", sessionId });
    return () => {
      socket.send({ type: "unsubscribeScreen", sessionId });
      unsubscribe();
    };
  }, [sessionId]);

  const onScroll = () => {
    const el = scrollRef.current;
    if (!el) return;
    pinnedToBottom.current = el.scrollHeight - el.scrollTop - el.clientHeight < 48;
  };

  useLayoutEffect(() => {
    const el = scrollRef.current;
    if (el && pinnedToBottom.current) el.scrollTop = el.scrollHeight;
  }, [text]);

  return (
    <div
      ref={scrollRef}
      onScroll={onScroll}
      className="h-full overflow-y-auto bg-[#0b0d10] p-3"
    >
      {text ? (
        <pre className="whitespace-pre-wrap break-words font-mono text-[12px] leading-relaxed text-neutral-200">
          {text}
        </pre>
      ) : (
        <div className="flex h-full items-center justify-center text-sm text-neutral-600">
          {running ? "Waiting for output…" : "Session is not running."}
        </div>
      )}
      {exited && (
        <div className="mt-2 text-[11px] italic text-neutral-500">── session exited ──</div>
      )}
    </div>
  );
}
