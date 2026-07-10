// Bridges the native rendered-screen stream to console viewers. One shared
// ScreenMirror + native subscription per session, no matter how many SSE
// clients watch it: frames are mapped to pre-rendered row HTML (screen-html.ts)
// and fanned out; a late-joining viewer is primed with a full snapshot
// synthesized from the mirror (the native server only snapshots on subscribe).
// Read-only by construction — nothing here can resize or write to the pty.

import { ScreenMirror, onSessionScreen, type ScreenFrame } from "./native-events.ts";
import { rowHtml } from "./screen-html.ts";

/** What a console viewer receives per SSE event: full grid (`reset: true`,
 *  every row) or a diff (only the rows that changed). `html` is the row's
 *  innerHTML — already escaped and styled server-side. */
export interface ScreenPatch {
  reset: boolean;
  cols: number;
  rows: number;
  lines: { row: number; html: string }[];
}

type PatchListener = (patch: ScreenPatch) => void;
type SubscribeFn = (sessionId: string, listener: (frame: ScreenFrame) => void) => () => void;

interface SharedView {
  mirror: ScreenMirror;
  listeners: Set<PatchListener>;
  hasSnapshot: boolean;
  unsubscribe: () => void;
}

const views = new Map<string, SharedView>();

function snapshotPatch(view: SharedView): ScreenPatch {
  const { mirror } = view;
  const lines: ScreenPatch["lines"] = [];
  for (let r = 0; r < mirror.rows; r++) lines.push({ row: r, html: rowHtml(mirror.line(r)) });
  return { reset: true, cols: mirror.cols, rows: mirror.rows, lines };
}

function emitTo(listener: PatchListener, patch: ScreenPatch): void {
  try {
    listener(patch);
  } catch (e) {
    console.warn("oracle-mcp screen patch listener failed:", e instanceof Error ? e.message : e);
  }
}

function emitPatch(view: SharedView, patch: ScreenPatch): void {
  for (const listener of view.listeners) emitTo(listener, patch);
}

/** Attach a viewer to a session's screen. Returns a release function — call it
 *  when the SSE client disconnects so the native subscription doesn't leak.
 *  `subscribe` is injectable for tests; defaults to the shared native WS. */
export function openScreenStream(
  sessionId: string,
  onPatch: PatchListener,
  subscribe: SubscribeFn = onSessionScreen,
): () => void {
  let view = views.get(sessionId);
  if (!view) {
    const v: SharedView = {
      mirror: new ScreenMirror(),
      listeners: new Set(),
      hasSnapshot: false,
      unsubscribe: () => {},
    };
    v.unsubscribe = subscribe(sessionId, (frame) => {
      // A geometry change blanks the mirror's grid even without the reset flag,
      // so anything but a pure same-size diff must go out as a full snapshot.
      const fullRedraw = frame.reset || frame.rows !== v.mirror.rows || frame.cols !== v.mirror.cols;
      v.mirror.apply(frame);
      v.hasSnapshot = true;
      const patch = fullRedraw
        ? snapshotPatch(v)
        : {
            reset: false,
            cols: frame.cols,
            rows: frame.rows,
            lines: frame.lines.map((l) => ({ row: l.row, html: rowHtml(l.segs) })),
          };
      emitPatch(v, patch);
    });
    views.set(sessionId, v);
    view = v;
  }
  view.listeners.add(onPatch);
  if (view.hasSnapshot) emitTo(onPatch, snapshotPatch(view));
  return () => {
    const v = views.get(sessionId);
    if (!v || !v.listeners.delete(onPatch)) return;
    if (v.listeners.size === 0) {
      views.delete(sessionId);
      v.unsubscribe();
    }
  };
}
