import { useEffect, useRef } from "react";
import { Terminal as XTerm } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { socket } from "../lib/socket.ts";
import type { ServerMessage } from "../protocol.ts";

export function Terminal({ sessionId }: { sessionId: string }) {
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const term = new XTerm({
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace',
      fontSize: 13,
      cursorBlink: true,
      scrollback: 10000,
      theme: { background: "#0b0d10" },
      allowProposedApi: true,
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.loadAddon(new WebLinksAddon());
    term.open(container);
    fit.fit();

    const dims = () => ({ cols: term.cols, rows: term.rows });

    const onData = term.onData((data) => socket.send({ type: "input", sessionId, data }));

    const unsubscribe = socket.subscribe((msg: ServerMessage) => {
      if ("sessionId" in msg && msg.sessionId !== sessionId) return;
      switch (msg.type) {
        case "attached":
          term.reset();
          term.write(msg.scrollback);
          // Sync the (possibly freshly reactivated) pty to our real dimensions —
          // reactivate spawns at a placeholder size until we tell it otherwise.
          socket.send({ type: "resize", sessionId, ...dims() });
          break;
        case "output":
          term.write(msg.data);
          break;
        case "exit":
          term.write(
            `\r\n\x1b[2m── session exited${
              msg.exitCode != null ? ` (code ${msg.exitCode})` : ""
            } ──\x1b[0m\r\n`,
          );
          break;
        case "error":
          term.write(`\r\n\x1b[31m${msg.message}\x1b[0m\r\n`);
          break;
      }
    });

    // Attach after subscribing so we don't miss the initial reply.
    socket.send({ type: "attach", sessionId, ...dims() });

    const resizeObserver = new ResizeObserver(() => {
      try {
        fit.fit();
        socket.send({ type: "resize", sessionId, ...dims() });
      } catch {
        /* container detached */
      }
    });
    resizeObserver.observe(container);

    term.focus();

    return () => {
      resizeObserver.disconnect();
      onData.dispose();
      unsubscribe();
      term.dispose();
    };
  }, [sessionId]);

  return <div ref={containerRef} className="h-full w-full p-2" />;
}
