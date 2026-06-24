import { useEffect, useRef } from "react";
import { Terminal as XTerm } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { socket } from "../lib/socket.ts";
import type { ServerMessage } from "../protocol.ts";

/**
 * One pane of the integrated terminal: an xterm wired to an ephemeral server
 * shell pty in `cwd`. Mirrors {@link EditorModal}'s pty handshake — it sends
 * `openTerminal` (tagged with a unique `requestId`) and learns the pty's id from
 * the matching `terminalReady`, after which I/O is addressed by that id. The pty
 * is killed on unmount, so closing the pane (or leaving the session) ends the
 * shell. `onExit` fires when the shell itself exits (e.g. typing `exit`).
 */
export function ShellTerminal({ cwd, onExit }: { cwd: string; onExit?: () => void }) {
  const containerRef = useRef<HTMLDivElement>(null);
  // Keep the latest onExit without re-running the (pty-spawning) effect.
  const onExitRef = useRef(onExit);
  onExitRef.current = onExit;

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

    // A unique tag so we pick up only our own terminalReady, even when several
    // panes open at once. The pty's id is learned from that reply.
    const requestId = crypto.randomUUID();
    let terminalId: string | null = null;
    const dims = () => ({ cols: term.cols, rows: term.rows });

    const onData = term.onData((data) => {
      if (terminalId) socket.send({ type: "input", sessionId: terminalId, data });
    });

    const unsubscribe = socket.subscribe((msg: ServerMessage) => {
      if (msg.type === "terminalReady") {
        if (msg.requestId !== requestId) return;
        terminalId = msg.terminalId;
        // Sync the freshly spawned pty to our real size so the shell repaints.
        socket.send({ type: "resize", sessionId: terminalId, ...dims() });
        return;
      }
      if (!("sessionId" in msg) || msg.sessionId !== terminalId) return;
      switch (msg.type) {
        case "output":
          term.write(msg.data);
          break;
        case "exit":
          onExitRef.current?.();
          break;
        case "error":
          term.write(`\r\n\x1b[31m${msg.message}\x1b[0m\r\n`);
          break;
      }
    });

    // Subscribe before opening so we don't miss the terminalReady reply.
    socket.send({ type: "openTerminal", cwd, ...dims(), requestId });

    const resizeObserver = new ResizeObserver(() => {
      try {
        fit.fit();
        if (terminalId) socket.send({ type: "resize", sessionId: terminalId, ...dims() });
      } catch {
        /* container detached / hidden */
      }
    });
    resizeObserver.observe(container);

    return () => {
      resizeObserver.disconnect();
      onData.dispose();
      unsubscribe();
      if (terminalId) socket.send({ type: "kill", sessionId: terminalId });
      term.dispose();
    };
  }, [cwd]);

  return <div ref={containerRef} className="h-full w-full p-2" />;
}
