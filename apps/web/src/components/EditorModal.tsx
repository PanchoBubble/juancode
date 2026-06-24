import { useEffect, useRef } from "react";
import { Terminal as XTerm } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { socket } from "../lib/socket.ts";
import type { ServerMessage } from "../protocol.ts";

/**
 * A full-screen terminal overlay that opens one file in the user's real editor
 * ($VISUAL/$EDITOR, default nvim) via an ephemeral server pty — so the file is
 * edited with the genuine editor config (nvim plugins, tree-sitter, colors). On
 * the editor exiting (e.g. `:q`) the overlay closes and the caller refetches the
 * diff. The pty is killed on unmount if it's still alive.
 */
export function EditorModal({
  cwd,
  file,
  onClose,
}: {
  cwd: string;
  file: string;
  onClose: () => void;
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  // Keep the latest onClose without re-running the (pty-spawning) effect.
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const term = new XTerm({
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace',
      fontSize: 13,
      cursorBlink: true,
      scrollback: 1000,
      theme: { background: "#0b0d10" },
      allowProposedApi: true,
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(container);
    fit.fit();

    // The editor pty's id, learned from `editorReady`. Until then we buffer no
    // input and ignore stray output (the handshake is ordered before output).
    let editorId: string | null = null;
    const dims = () => ({ cols: term.cols, rows: term.rows });

    const onData = term.onData((data) => {
      if (editorId) socket.send({ type: "input", sessionId: editorId, data });
    });

    const unsubscribe = socket.subscribe((msg: ServerMessage) => {
      if (msg.type === "editorReady") {
        editorId = msg.editorId;
        // Sync the freshly spawned pty to our real size so the editor repaints.
        socket.send({ type: "resize", sessionId: editorId, ...dims() });
        return;
      }
      if (!("sessionId" in msg) || msg.sessionId !== editorId) return;
      switch (msg.type) {
        case "output":
          term.write(msg.data);
          break;
        case "exit":
          onCloseRef.current();
          break;
        case "error":
          term.write(`\r\n\x1b[31m${msg.message}\x1b[0m\r\n`);
          break;
      }
    });

    // Subscribe before opening so we don't miss the editorReady reply.
    socket.send({ type: "openEditor", cwd, file, ...dims() });

    const resizeObserver = new ResizeObserver(() => {
      try {
        fit.fit();
        if (editorId) socket.send({ type: "resize", sessionId: editorId, ...dims() });
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
      if (editorId) socket.send({ type: "kill", sessionId: editorId });
      term.dispose();
    };
  }, [cwd, file]);

  return (
    <div className="fixed inset-0 z-50 flex flex-col bg-black/80 p-4 backdrop-blur-sm">
      <div className="flex min-h-0 flex-1 flex-col overflow-hidden rounded-lg border border-neutral-700 bg-[#0b0d10] shadow-2xl">
        <div className="flex items-center gap-2 border-b border-neutral-800 px-3 py-1.5 text-xs">
          <span className="text-neutral-400">Editing</span>
          <span className="truncate font-mono text-neutral-200">{file}</span>
          <span className="ml-auto text-neutral-600">
            <span className="font-mono">:q</span> in the editor to close
          </span>
          <button
            onClick={onClose}
            title="Force close (discards an unsaved buffer)"
            className="rounded border border-neutral-700 px-2 py-0.5 text-neutral-300 hover:border-red-500 hover:text-red-400"
          >
            Force close
          </button>
        </div>
        <div ref={containerRef} className="min-h-0 flex-1 p-2" />
      </div>
    </div>
  );
}
