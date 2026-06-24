import { useState } from "react";
import { Panel, PanelGroup, PanelResizeHandle } from "react-resizable-panels";
import { ShellTerminal } from "./ShellTerminal.tsx";

/** One terminal tab: a horizontal row of one or more split shell panes. */
interface Group {
  id: string;
  paneIds: string[];
}

const uid = () => crypto.randomUUID();
const newGroup = (): Group => ({ id: uid(), paneIds: [uid()] });

/**
 * The integrated terminal: a VS Code-style panel of plain shells, all rooted at
 * the session's `cwd`. Each tab is a {@link Group} that can be split into
 * side-by-side panes; every pane is a {@link ShellTerminal} wired to its own
 * server shell pty. Inactive tabs stay mounted (just hidden) so their shells —
 * and scrollback — survive tab switches. `onClose` fires when the last pane is
 * closed, so the parent can collapse the bottom split.
 */
export function TerminalPanel({ cwd, onClose }: { cwd: string; onClose: () => void }) {
  const [initial] = useState(newGroup);
  const [groups, setGroups] = useState<Group[]>(() => [initial]);
  const [activeId, setActiveId] = useState(initial.id);

  const addTab = () => {
    const g = newGroup();
    setGroups((gs) => [...gs, g]);
    setActiveId(g.id);
  };

  const splitActive = () => {
    setGroups((gs) => gs.map((g) => (g.id === activeId ? { ...g, paneIds: [...g.paneIds, uid()] } : g)));
  };

  /** Remove one pane; drop the tab if it empties, and the panel if nothing remains. */
  const closePane = (groupId: string, paneId: string) => {
    setGroups((gs) => {
      const next = gs
        .map((g) => (g.id === groupId ? { ...g, paneIds: g.paneIds.filter((p) => p !== paneId) } : g))
        .filter((g) => g.paneIds.length > 0);
      if (next.length === 0) {
        onClose();
        return gs; // unmount is imminent; leave state as-is
      }
      if (!next.some((g) => g.id === activeId)) setActiveId(next[next.length - 1]!.id);
      return next;
    });
  };

  const closeTab = (groupId: string) => {
    const g = groups.find((x) => x.id === groupId);
    if (g) for (const p of g.paneIds) closePane(groupId, p);
  };

  return (
    <div className="flex h-full flex-col bg-[#0b0d10]">
      <div className="flex items-center gap-1 border-b border-neutral-800 bg-neutral-900/60 px-2 py-1 text-xs">
        <div className="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto">
          {groups.map((g, i) => (
            <div
              key={g.id}
              onClick={() => setActiveId(g.id)}
              className={`group flex cursor-pointer items-center gap-1.5 rounded px-2 py-0.5 ${
                g.id === activeId
                  ? "bg-neutral-800 text-neutral-100"
                  : "text-neutral-400 hover:text-neutral-200"
              }`}
            >
              <span className="font-mono">{`zsh ${i + 1}`}</span>
              <button
                onClick={(e) => {
                  e.stopPropagation();
                  closeTab(g.id);
                }}
                title="Close terminal"
                className="text-neutral-500 opacity-0 hover:text-neutral-200 group-hover:opacity-100"
              >
                ✕
              </button>
            </div>
          ))}
        </div>
        <button
          onClick={splitActive}
          title="Split terminal"
          className="rounded px-1.5 py-0.5 text-neutral-400 hover:bg-neutral-800 hover:text-neutral-200"
        >
          ⊟
        </button>
        <button
          onClick={addTab}
          title="New terminal"
          className="rounded px-1.5 py-0.5 text-neutral-400 hover:bg-neutral-800 hover:text-neutral-200"
        >
          +
        </button>
        <button
          onClick={onClose}
          title="Hide terminal panel"
          className="rounded px-1.5 py-0.5 text-neutral-400 hover:bg-neutral-800 hover:text-neutral-200"
        >
          ⌄
        </button>
      </div>
      <div className="relative min-h-0 flex-1">
        {groups.map((g) => (
          <div key={g.id} className={`absolute inset-0 ${g.id === activeId ? "" : "hidden"}`}>
            <PanelGroup direction="horizontal">
              {g.paneIds.map((paneId, i) => (
                <PaneSlot key={paneId} order={i + 1} showHandle={i > 0}>
                  <div className="group relative h-full w-full">
                    <ShellTerminal cwd={cwd} onExit={() => closePane(g.id, paneId)} />
                    {g.paneIds.length > 1 && (
                      <button
                        onClick={() => closePane(g.id, paneId)}
                        title="Close pane"
                        className="absolute right-1 top-1 z-10 rounded bg-neutral-900/80 px-1.5 text-xs text-neutral-400 opacity-0 hover:text-neutral-200 group-hover:opacity-100"
                      >
                        ✕
                      </button>
                    )}
                  </div>
                </PaneSlot>
              ))}
            </PanelGroup>
          </div>
        ))}
      </div>
    </div>
  );
}

/** A split pane plus the resize handle that precedes it (omitted for the first). */
function PaneSlot({
  order,
  showHandle,
  children,
}: {
  order: number;
  showHandle: boolean;
  children: React.ReactNode;
}) {
  return (
    <>
      {showHandle && (
        <PanelResizeHandle className="relative w-px bg-neutral-800 transition-colors after:absolute after:inset-y-0 after:-left-1 after:w-2 hover:bg-neutral-600 data-[resize-handle-state=drag]:bg-neutral-500" />
      )}
      <Panel order={order} minSize={15} className="overflow-hidden">
        {children}
      </Panel>
    </>
  );
}
