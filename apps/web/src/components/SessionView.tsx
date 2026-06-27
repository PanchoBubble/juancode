import { useEffect, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import { Panel, PanelGroup, PanelResizeHandle } from "react-resizable-panels";
import { api } from "../lib/api.ts";
import { socket } from "../lib/socket.ts";
import { useActivity, usePrompt } from "../lib/activity.ts";
import type { ServerMessage } from "../protocol.ts";
import { AttachBar } from "./AttachBar.tsx";
import { BeadsPanel } from "./BeadsPanel.tsx";
import { ChangesPanel } from "./ChangesPanel.tsx";
import { DecisionCard } from "./DecisionCard.tsx";
import { LiveOutput } from "./LiveOutput.tsx";
import { MessageQueue } from "./MessageQueue.tsx";
import { StructuredView } from "./StructuredView.tsx";
import { Terminal } from "./Terminal.tsx";
import { useIsPhone } from "../lib/useMediaQuery.ts";
import { TerminalPanel } from "./TerminalPanel.tsx";
import { toggleTerminalOpen, useTerminalOpen, setTerminalOpen } from "../lib/terminalStore.ts";
import { UsageBadge } from "./UsageBadge.tsx";

/** Which auxiliary view, if any, is open in the collapsible right panel. */
type SidePanel = "changes" | "issues" | null;

/** A file dropped onto the session, uploaded to the server and fed to the prompt. */
interface Attachment {
  id: string;
  name: string;
  size: number;
  isImage: boolean;
  /** Object URL for an image thumbnail (revoked on removal / session switch). */
  previewUrl?: string;
  status: "uploading" | "done" | "error";
  /** Absolute server path once uploaded. */
  path?: string;
  error?: string;
}

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/** Client-side attachment ceiling. The server caps the raw body at 100 MB; we
 *  reject earlier with a friendly message so a huge phone video never uploads. */
const MAX_UPLOAD_BYTES = 50 * 1024 * 1024;

export function SessionView({ id }: { id: string }) {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const sessions = useQuery({ queryKey: ["sessions"], queryFn: api.sessions });
  const meta = sessions.data?.find((s) => s.id === id);
  const [side, setSide] = useState<SidePanel>(null);
  // The integrated shell-terminal panel splits the bottom of the session view.
  // Its open/closed state (and the live shells themselves) live in a module store
  // keyed by session id, so the terminals — and their scrollback — survive
  // navigating to another session and back (VS Code-style), rather than being
  // torn down with this per-session view on every switch.
  const showTerminal = useTerminalOpen(id);
  // On a phone the raw xterm TUI is unreadable, so we swap it for the live
  // rendered-screen view (cheap row-diff stream); desktop keeps the real xterm.
  const isPhone = useIsPhone();
  // How the agent's output is rendered: the raw xterm/ANSI TUI (default) or the
  // opt-in structured message/tool-bubble view fed by the stream-json transcript.
  const [renderMode, setRenderMode] = useState<"terminal" | "structured">("terminal");

  // Track status live off the socket so the header reflects reality without
  // waiting for the next sessions poll (kill → exited, reactivate → running).
  const [liveStatus, setLiveStatus] = useState<"running" | "exited" | null>(null);
  // Live "accept all" state, tracked off the socket so the toggle reflects the
  // revived session immediately after a flip (without waiting for a sessions poll).
  const [liveSkip, setLiveSkip] = useState<boolean | null>(null);
  // True while a flip is in flight (CLI is resume-restarting) — disables the toggle.
  const [flipping, setFlipping] = useState(false);
  // Set when the server reports it found no prior CLI conversation to resume —
  // then the only way forward is a fresh chat in the same folder.
  const [unresumable, setUnresumable] = useState(false);
  useEffect(() => {
    setLiveStatus(null);
    setLiveSkip(null);
    setFlipping(false);
    setUnresumable(false);
    return socket.subscribe((msg: ServerMessage) => {
      if (!("sessionId" in msg) || msg.sessionId !== id) return;
      if (msg.type === "attached") {
        setLiveStatus(msg.session.status);
        setLiveSkip(msg.session.skipPermissions);
        setFlipping(false);
      } else if (msg.type === "exit") setLiveStatus("exited");
      else if (msg.type === "error") setFlipping(false);
      else if (msg.type === "unresumable") {
        setLiveStatus("exited");
        setUnresumable(true);
      }
    });
  }, [id]);

  // Auto-resume: opening a session that already exited should bring it back to
  // life rather than leave a dead transcript. Even sessions with no captured CLI
  // id get a shot — the server tries to recover it from the CLI's transcript. We
  // decide once per session view, off the *persisted* status, so killing a
  // session mid-view doesn't immediately respawn it.
  const decidedFor = useRef<string | null>(null);
  useEffect(() => {
    decidedFor.current = null;
  }, [id]);
  useEffect(() => {
    if (decidedFor.current === id || !meta) return;
    decidedFor.current = id;
    if (meta.status === "exited") {
      setLiveStatus("running"); // optimistic — pty spawn is synchronous server-side
      socket.send({ type: "reactivate", sessionId: id, cols: 80, rows: 24 });
    }
  }, [id, meta]);

  const status = liveStatus ?? meta?.status;
  const canReactivate = status === "exited" && !unresumable;
  const activity = useActivity(id);
  const prompt = usePrompt(id);

  // ── "Accept all" (skip permission prompts) toggle ──────────────────────────
  const skipOn = liveSkip ?? meta?.skipPermissions ?? false;
  /**
   * Flip accept-all on the live session. The server resume-restarts the CLI with
   * the new permission level, preserving the conversation, and replies `attached`.
   */
  const flipSkipPermissions = () => {
    if (status !== "running" || flipping) return;
    const next = !skipOn;
    if (
      next &&
      !window.confirm(
        "Enable accept-all? The agent will run tools and commands with no permission prompts. The session restarts (conversation is kept).",
      )
    ) {
      return;
    }
    setFlipping(true);
    setLiveSkip(next); // optimistic
    socket.send({
      type: "setSkipPermissions",
      sessionId: id,
      skipPermissions: next,
      cols: 80,
      rows: 24,
    });
    void queryClient.invalidateQueries({ queryKey: ["sessions"] });
  };

  // ── Queued follow-up message ───────────────────────────────────────────────
  // Let the user line up their next instruction while the agent is still working
  // (busy or waiting_input). We buffer it client-side and auto-send it as a
  // normal `input` (with the trailing Enter the CLI expects) on the next edge
  // into `idle` for this session. Keyed by id so switching sessions starts clean.
  const [queued, setQueued] = useState<string | null>(null);
  const prevActivity = useRef<typeof activity>(undefined);
  useEffect(() => {
    setQueued(null);
    prevActivity.current = undefined;
  }, [id]);
  useEffect(() => {
    const was = prevActivity.current;
    prevActivity.current = activity;
    // Fire only on a real transition into idle (not the first observation), and
    // only while the session is alive — a dead pty can't receive input.
    if (
      queued !== null &&
      activity === "idle" &&
      was !== undefined &&
      was !== "idle" &&
      status === "running"
    ) {
      socket.send({ type: "input", sessionId: id, data: `${queued}\r` });
      setQueued(null);
    }
  }, [activity, queued, status, id]);

  /** Resume the session (server resumes its CLI conversation, recovering the id if needed). */
  const reactivate = () => {
    setUnresumable(false);
    setLiveStatus("running"); // optimistic — pty spawn is synchronous server-side
    socket.send({ type: "reactivate", sessionId: id, cols: 80, rows: 24 });
  };

  /** Fallback when a conversation can't be resumed: start a fresh one in the same folder. */
  const startFreshHere = () => {
    if (!meta) return;
    const unsub = socket.subscribe((msg) => {
      if (msg.type === "created") {
        unsub();
        void queryClient.invalidateQueries({ queryKey: ["sessions"] });
        void navigate({ to: "/session/$id", params: { id: msg.session.id } });
      } else if (msg.type === "error") {
        unsub();
      }
    });
    socket.send({ type: "create", provider: meta.provider, cwd: meta.cwd, cols: 80, rows: 24 });
  };

  const toggle = (p: Exclude<SidePanel, null>) => setSide((cur) => (cur === p ? null : p));

  // ── Drag-and-drop file attachments ─────────────────────────────────────────
  // Browsers don't expose a dragged file's real path, so we upload the bytes to
  // the local server, then type the saved path into the pty prompt (the CLI on
  // this same machine can then read it). A tray shows a preview of each drop.
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  const [dragging, setDragging] = useState(false);
  // dragenter/dragleave fire for every child element; a depth counter keeps the
  // overlay from flickering as the cursor moves across the terminal.
  const dragDepth = useRef(0);
  const attachmentsRef = useRef<Attachment[]>([]);
  attachmentsRef.current = attachments;

  // Clear the tray (and free thumbnails) when switching sessions or unmounting.
  useEffect(() => {
    setAttachments([]);
    return () => {
      for (const a of attachmentsRef.current) if (a.previewUrl) URL.revokeObjectURL(a.previewUrl);
    };
  }, [id]);

  const removeAttachment = (attId: string) =>
    setAttachments((list) => {
      const found = list.find((a) => a.id === attId);
      if (found?.previewUrl) URL.revokeObjectURL(found.previewUrl);
      return list.filter((a) => a.id !== attId);
    });

  const handleFile = async (file: File) => {
    const attId = crypto.randomUUID();
    const isImage = file.type.startsWith("image/");
    const previewUrl = isImage ? URL.createObjectURL(file) : undefined;
    if (file.size > MAX_UPLOAD_BYTES) {
      setAttachments((list) => [
        ...list,
        {
          id: attId,
          name: file.name,
          size: file.size,
          isImage,
          previewUrl,
          status: "error",
          error: `too large (max ${formatSize(MAX_UPLOAD_BYTES)})`,
        },
      ]);
      return;
    }
    setAttachments((list) => [
      ...list,
      { id: attId, name: file.name, size: file.size, isImage, previewUrl, status: "uploading" },
    ]);
    try {
      const { path } = await api.uploadFile(file);
      setAttachments((list) =>
        list.map((a) => (a.id === attId ? { ...a, status: "done", path } : a)),
      );
      // The saved basename is sanitised server-side to be space-free, so the
      // path can be typed verbatim. Trailing space keeps the prompt usable.
      socket.send({ type: "input", sessionId: id, data: `${path} ` });
    } catch (err) {
      const error = err instanceof Error ? err.message : String(err);
      setAttachments((list) =>
        list.map((a) => (a.id === attId ? { ...a, status: "error", error } : a)),
      );
    }
  };

  const hasFiles = (e: React.DragEvent) => e.dataTransfer.types.includes("Files");
  const onDragEnter = (e: React.DragEvent) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    dragDepth.current += 1;
    setDragging(true);
  };
  const onDragOver = (e: React.DragEvent) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "copy";
  };
  const onDragLeave = (e: React.DragEvent) => {
    if (!hasFiles(e)) return;
    dragDepth.current -= 1;
    if (dragDepth.current <= 0) {
      dragDepth.current = 0;
      setDragging(false);
    }
  };
  const onDrop = (e: React.DragEvent) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    dragDepth.current = 0;
    setDragging(false);
    for (const file of Array.from(e.dataTransfer.files)) void handleFile(file);
  };

  // Pasting an image (e.g. a screenshot) lands as clipboard `Files` rather than
  // text, so xterm would just drop it. We intercept it the same way as a drop:
  // upload the bytes and type the saved path into the prompt. Text pastes are
  // left untouched so xterm/CLI keep handling them. The handler runs in the
  // capture phase so we win before xterm's own paste handling.
  const onPaste = (e: React.ClipboardEvent) => {
    const images = Array.from(e.clipboardData.items).filter((it) => it.type.startsWith("image/"));
    if (images.length === 0) return;
    e.preventDefault();
    e.stopPropagation();
    for (const item of images) {
      const file = item.getAsFile();
      if (file) void handleFile(file);
    }
  };

  return (
    <div
      className="relative flex h-full flex-col"
      onDragEnter={onDragEnter}
      onDragOver={onDragOver}
      onDragLeave={onDragLeave}
      onDrop={onDrop}
      onPasteCapture={onPaste}
    >
      <header className="flex items-center justify-between border-b border-neutral-800 px-4 py-2">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <span className="truncate text-sm font-medium">{meta?.title ?? id}</span>
            {meta?.worktreePath && (
              <span
                title={`Isolated git worktree: ${meta.worktreePath}`}
                className="flex shrink-0 items-center gap-1 rounded border border-sky-500/40 bg-sky-500/10 px-1.5 py-0.5 text-[10px] text-sky-300"
              >
                ⎇ worktree
              </span>
            )}
            {status === "running" && activity === "busy" && (
              <span className="flex shrink-0 items-center gap-1 text-[11px] text-sky-400">
                <span className="h-1.5 w-1.5 animate-pulse rounded-full bg-sky-400" />
                working
              </span>
            )}
            {status === "running" && activity === "waiting_input" && (
              <span className="flex shrink-0 items-center gap-1 text-[11px] text-amber-400">
                <span className="h-1.5 w-1.5 animate-pulse rounded-full bg-amber-400" />
                input needed
              </span>
            )}
          </div>
          <div className="flex items-center gap-2 truncate font-mono text-[11px] text-neutral-500">
            <span className="truncate">{meta?.cwd}</span>
            {meta?.usage && <UsageBadge usage={meta.usage} className="shrink-0 text-neutral-400" />}
          </div>
        </div>
        <nav className="mr-auto ml-4 flex gap-1 text-xs">
          {(["changes", "issues"] as const).map((p) => (
            <button
              key={p}
              onClick={() => toggle(p)}
              className={`rounded-md px-2.5 py-1 capitalize transition-colors ${
                side === p
                  ? "bg-neutral-800 text-neutral-100 hover:bg-neutral-700"
                  : "text-neutral-400 hover:bg-neutral-800/60 hover:text-neutral-200"
              }`}
            >
              {p}
            </button>
          ))}
          <button
            onClick={() => toggleTerminalOpen(id)}
            className={`rounded-md px-2.5 py-1 transition-colors ${
              showTerminal
                ? "bg-neutral-800 text-neutral-100 hover:bg-neutral-700"
                : "text-neutral-400 hover:bg-neutral-800/60 hover:text-neutral-200"
            }`}
          >
            terminal
          </button>
          <button
            onClick={() => setRenderMode((m) => (m === "structured" ? "terminal" : "structured"))}
            title="Toggle the structured message/tool-bubble view (from the stream-json transcript)"
            className={`rounded-md px-2.5 py-1 transition-colors ${
              renderMode === "structured"
                ? "bg-neutral-800 text-neutral-100 hover:bg-neutral-700"
                : "text-neutral-400 hover:bg-neutral-800/60 hover:text-neutral-200"
            }`}
          >
            structured
          </button>
        </nav>
        {status === "running" && (
          <button
            onClick={flipSkipPermissions}
            disabled={flipping}
            title={
              skipOn
                ? "Accept-all is ON — agent runs with no permission prompts. Click to turn off (restarts the session)."
                : "Accept-all is OFF. Click to skip all permission prompts (restarts the session)."
            }
            className={`mr-2 flex items-center gap-1.5 rounded-md border px-3 py-1 text-xs disabled:opacity-50 ${
              skipOn
                ? "border-amber-500/60 bg-amber-500/10 text-amber-300 hover:border-amber-400"
                : "border-neutral-700 text-neutral-400 hover:border-neutral-500 hover:text-neutral-200"
            }`}
          >
            <span
              className={`h-1.5 w-1.5 rounded-full ${skipOn ? "bg-amber-400" : "bg-neutral-600"}`}
            />
            {flipping ? "Restarting…" : skipOn ? "Accept all: on" : "Accept all: off"}
          </button>
        )}
        {status === "running" && (
          <button
            onClick={() => socket.send({ type: "kill", sessionId: id })}
            className="rounded-md border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:border-red-500 hover:text-red-400"
          >
            Kill
          </button>
        )}
        {canReactivate && (
          <button
            onClick={reactivate}
            className="rounded-md border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:border-emerald-500 hover:text-emerald-400"
          >
            Reactivate
          </button>
        )}
        {unresumable && (
          <button
            onClick={startFreshHere}
            title="This conversation can't be resumed — start a new one in the same folder"
            className="rounded-md border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:border-emerald-500 hover:text-emerald-400"
          >
            New chat here
          </button>
        )}
      </header>
      {attachments.length > 0 && (
        <div className="flex flex-wrap gap-2 border-b border-neutral-800 bg-neutral-900/40 px-3 py-2">
          {attachments.map((a) => (
            <div
              key={a.id}
              className="flex items-center gap-2 rounded-md border border-neutral-700 bg-neutral-900 py-1 pl-1 pr-2 text-xs"
              title={a.path ?? a.name}
            >
              {a.isImage && a.previewUrl ? (
                <img src={a.previewUrl} alt={a.name} className="h-8 w-8 rounded object-cover" />
              ) : (
                <div className="flex h-8 w-8 items-center justify-center rounded bg-neutral-800 text-neutral-400">
                  📄
                </div>
              )}
              <div className="min-w-0">
                <div className="max-w-[12rem] truncate text-neutral-200">{a.name}</div>
                <div
                  className={`text-[10px] ${a.status === "error" ? "text-red-400" : "text-neutral-500"}`}
                >
                  {a.status === "uploading"
                    ? "uploading…"
                    : a.status === "error"
                      ? (a.error ?? "failed")
                      : formatSize(a.size)}
                </div>
              </div>
              <button
                onClick={() => removeAttachment(a.id)}
                className="ml-1 text-neutral-500 hover:text-neutral-200"
                title="Remove from tray"
              >
                ✕
              </button>
            </div>
          ))}
        </div>
      )}
      {dragging && (
        <div className="pointer-events-none absolute inset-0 z-20 flex items-center justify-center bg-neutral-950/70 backdrop-blur-sm">
          <div className="rounded-xl border-2 border-dashed border-emerald-500/70 px-8 py-6 text-sm text-emerald-300">
            Drop files to attach their path
          </div>
        </div>
      )}
      <div className="min-h-0 flex-1 bg-[#0b0d10]">
        {/* Vertical split: the agent terminal + side panel on top, the optional
            integrated shell-terminal panel as an adjustable bottom split. */}
        <PanelGroup direction="vertical" autoSaveId="juancode-session-vertical">
          <Panel order={1} minSize={20} className="overflow-hidden">
            {/* The terminal panel is always mounted so the pty/xterm state and
                scroll position survive opening/closing the side panel. xterm
                refits itself via its ResizeObserver as the split is dragged. */}
            <PanelGroup direction="horizontal" autoSaveId="juancode-session-split">
              <Panel id="terminal" order={1} minSize={25} className="overflow-hidden">
                {/* The xterm view stays mounted (hidden under the structured
                    view) so the pty's render + scroll position survive toggling.
                    The structured view mounts only when chosen, so its transcript
                    tail isn't opened for sessions viewed only as a terminal. */}
                <div className="h-full" hidden={renderMode === "structured"}>
                  {isPhone ? (
                    <LiveOutput key={id} sessionId={id} running={status === "running"} />
                  ) : (
                    <Terminal key={id} sessionId={id} />
                  )}
                </div>
                {renderMode === "structured" && (
                  <StructuredView sessionId={id} running={status === "running"} />
                )}
              </Panel>
              {side && (
                <>
                  <PanelResizeHandle className="relative w-px bg-neutral-800 transition-colors after:absolute after:inset-y-0 after:-left-1 after:w-2 hover:bg-neutral-600 data-[resize-handle-state=drag]:bg-neutral-500" />
                  <Panel
                    id="side"
                    order={2}
                    defaultSize={45}
                    minSize={25}
                    className="overflow-hidden"
                  >
                    {side === "changes" ? (
                      <ChangesPanel sessionId={id} />
                    ) : (
                      <BeadsPanel sessionId={id} />
                    )}
                  </Panel>
                </>
              )}
            </PanelGroup>
          </Panel>
          {showTerminal && meta && (
            <>
              <PanelResizeHandle className="relative h-px bg-neutral-800 transition-colors after:absolute after:-top-1 after:h-2 after:w-full hover:bg-neutral-600 data-[resize-handle-state=drag]:bg-neutral-500" />
              <Panel order={2} defaultSize={35} minSize={10} className="overflow-hidden">
                <TerminalPanel sessionId={id} cwd={meta.cwd} onClose={() => setTerminalOpen(id, false)} />
              </Panel>
            </>
          )}
        </PanelGroup>
      </div>
      {/* Phone-only photo/audio composer (desktop has drag-drop + paste). */}
      {status === "running" && (
        <div className="md:hidden">
          <AttachBar onFile={(file) => void handleFile(file)} />
        </div>
      )}
      {status === "running" && activity === "waiting_input" && prompt && (
        <DecisionCard sessionId={id} prompt={prompt} />
      )}
      {status === "running" &&
        (activity === "busy" || activity === "waiting_input" || queued !== null) && (
          <MessageQueue queued={queued} onQueue={setQueued} onCancel={() => setQueued(null)} />
        )}
    </div>
  );
}
