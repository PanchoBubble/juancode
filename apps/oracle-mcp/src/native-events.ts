// Native-backend session-event listener for the Oracle sidecar. Owns the single
// long-lived WebSocket client to the native app's embedded server and re-emits
// every `activity` broadcast to in-process subscribers (the Telegram bridge),
// plus opt-in rendered-`screen` frames to per-session viewers (juancode-a2h.3).
//
// The native Hummingbird server (127.0.0.1:4280, ws path /ws) broadcasts
// `activity` for every session automatically on connect (no subscribe needed —
// see WebSocketConnection.start()), so we just connect and fan those out.

import { WebSocket } from "ws";

/** Resolve the native backend's WS URL from the same base oracle.ts uses for its
 *  HTTP calls. Kept local (oracle.ts doesn't export nativeApiBase). */
function nativeHttpBase(): string {
  return process.env.JUANCODE_API
    ? process.env.JUANCODE_API.replace(/\/$/, "")
    : `http://127.0.0.1:${process.env.JUANCODE_PORT || "4280"}`;
}

function nativeWsUrl(): string {
  return nativeHttpBase().replace(/^http/, "ws") + "/ws";
}

// ── Session-event fan-out (juancode-2l4) ─────────────────────────────────────
// This module owns the one long-lived WS to the native backend; consumers (the
// Telegram bridge) subscribe here instead of opening their own socket. Every
// `activity` broadcast is re-emitted — including notify:false ones, so subscribers
// can keep a warm per-session state cache — and the `notify` flag carries the
// server's de-spam gate through unchanged.

export interface SessionActivityEvent {
  sessionId: string;
  state: "busy" | "idle" | "waiting_input";
  notify: boolean;
}

type SessionEventListener = (ev: SessionActivityEvent) => void;
const sessionEventListeners: SessionEventListener[] = [];

/** Subscribe to native session activity events. Listener errors are isolated. */
export function onSessionEvent(listener: SessionEventListener): void {
  sessionEventListeners.push(listener);
}

function emitSessionEvent(ev: SessionActivityEvent): void {
  for (const listener of sessionEventListeners) {
    try {
      listener(ev);
    } catch (e) {
      console.warn("oracle-mcp session event listener failed:", e instanceof Error ? e.message : e);
    }
  }
}

// ── Rendered-screen stream (juancode-a2h.3) ──────────────────────────────────
// TS mirror of the native server's `screen` wire frames (see ScreenWire.swift /
// WireProtocol.swift — keep both sides in sync). A screen viewer renders these
// rows directly: no client-side terminal emulator, and — because subscribing is
// read-only server-side — no participation in the desktop's grid ownership.

/** One styled run of a row. `fg`/`bg`: an ANSI-256 index as a number, truecolor
 *  as "#rrggbb", "inv" for default-inverted; absent = the default color. `st` is
 *  a style bitmask (1 bold, 2 underline, 4 blink, 8 inverse, 16 invisible,
 *  32 dim, 64 italic, 128 strikethrough); absent = plain. */
export interface ScreenSegment {
  text: string;
  fg?: number | string;
  bg?: number | string;
  st?: number;
}

/** One row of a `screen` frame: its index in the visible grid (0 = top) and its
 *  segments. Empty `segs` = a blank row. */
export interface ScreenRowUpdate {
  row: number;
  segs: ScreenSegment[];
}

/** A frame of the rendered-screen stream. `reset: true` carries the full grid
 *  (sent first after `subscribeScreen` and again on a geometry / alt-screen
 *  flip); `reset: false` carries only the rows that changed since the last
 *  frame, coalesced server-side on an ~80ms tick. */
export interface ScreenFrame {
  sessionId: string;
  reset: boolean;
  cols: number;
  rows: number;
  cursorX: number;
  cursorY: number;
  cursorVisible: boolean;
  alt: boolean;
  lines: ScreenRowUpdate[];
}

/** Parse a raw WS message object into a ScreenFrame, or null if it isn't one.
 *  Lenient like the rest of this module: malformed frames are dropped, not thrown. */
export function parseScreenFrame(msg: Record<string, unknown>): ScreenFrame | null {
  if (msg.type !== "screen") return null;
  if (typeof msg.sessionId !== "string" || !msg.sessionId) return null;
  if (typeof msg.cols !== "number" || typeof msg.rows !== "number") return null;
  if (!Array.isArray(msg.lines)) return null;
  const lines: ScreenRowUpdate[] = [];
  for (const l of msg.lines as unknown[]) {
    if (typeof l !== "object" || l === null) return null;
    const row = (l as Record<string, unknown>).row;
    const segs = (l as Record<string, unknown>).segs;
    if (typeof row !== "number" || !Array.isArray(segs)) return null;
    lines.push({ row, segs: segs as ScreenSegment[] });
  }
  return {
    sessionId: msg.sessionId,
    reset: msg.reset === true,
    cols: msg.cols,
    rows: msg.rows,
    cursorX: typeof msg.cursorX === "number" ? msg.cursorX : 0,
    cursorY: typeof msg.cursorY === "number" ? msg.cursorY : 0,
    cursorVisible: msg.cursorVisible !== false,
    alt: msg.alt === true,
    lines,
  };
}

/** Client-side reconstruction of a session's screen from `screen` frames: apply a
 *  full snapshot on `reset`, patch listed rows otherwise. Rendering (2kz.3) reads
 *  `line()`/`lineText()`; `text()` gives the whole screen as plain text. */
export class ScreenMirror {
  cols = 0;
  rows = 0;
  cursorX = 0;
  cursorY = 0;
  cursorVisible = true;
  alt = false;
  private grid: ScreenSegment[][] = [];

  apply(frame: ScreenFrame): void {
    if (frame.reset || frame.rows !== this.rows || frame.cols !== this.cols) {
      this.grid = Array.from({ length: frame.rows }, () => []);
    }
    this.cols = frame.cols;
    this.rows = frame.rows;
    this.cursorX = frame.cursorX;
    this.cursorY = frame.cursorY;
    this.cursorVisible = frame.cursorVisible;
    this.alt = frame.alt;
    for (const line of frame.lines) {
      if (line.row >= 0 && line.row < this.grid.length) this.grid[line.row] = line.segs;
    }
  }

  line(row: number): ScreenSegment[] {
    return this.grid[row] ?? [];
  }

  lineText(row: number): string {
    return this.line(row)
      .map((s) => s.text)
      .join("");
  }

  /** The visible screen as text, trailing blank rows dropped. */
  text(): string {
    const rows: string[] = [];
    for (let r = 0; r < this.grid.length; r++) rows.push(this.lineText(r));
    let end = rows.length;
    while (end > 0 && rows[end - 1] === "") end -= 1;
    return rows.slice(0, end).join("\n");
  }
}

type ScreenListener = (frame: ScreenFrame) => void;
const screenListeners = new Map<string, ScreenListener[]>();

/** Subscribe to a session's rendered-screen stream over the shared native WS.
 *  Sends `subscribeScreen` on first listener (and again on every reconnect, so a
 *  fresh snapshot arrives), `unsubscribeScreen` when the last listener leaves.
 *  Returns an unsubscribe function. Listener errors are isolated. */
export function onSessionScreen(sessionId: string, listener: ScreenListener): () => void {
  const list = screenListeners.get(sessionId) ?? [];
  list.push(listener);
  screenListeners.set(sessionId, list);
  if (list.length === 1) sendToNative({ type: "subscribeScreen", sessionId });
  return () => {
    const cur = screenListeners.get(sessionId);
    if (!cur) return;
    const idx = cur.indexOf(listener);
    if (idx >= 0) cur.splice(idx, 1);
    if (cur.length === 0) {
      screenListeners.delete(sessionId);
      sendToNative({ type: "unsubscribeScreen", sessionId });
    }
  };
}

function emitScreenFrame(frame: ScreenFrame): void {
  for (const listener of screenListeners.get(frame.sessionId) ?? []) {
    try {
      listener(frame);
    } catch (e) {
      console.warn("oracle-mcp screen listener failed:", e instanceof Error ? e.message : e);
    }
  }
}

function sendToNative(msg: Record<string, unknown>): void {
  if (ws?.readyState === WebSocket.OPEN) {
    try {
      ws.send(JSON.stringify(msg));
    } catch {
      // Reconnect re-subscribes; a failed send is recovered there.
    }
  }
}

// ── WS client: native backend → subscribers ──────────────────────────────────

let ws: WebSocket | null = null;
let reconnectMs = 1000;
const MAX_RECONNECT_MS = 30_000;
let stopped = false;

/** Open (and keep open, with backoff) a client WS to the native server and fan
 *  out session activity to subscribers. Safe to call once at startup. */
export function startActivityListener(): void {
  stopped = false;
  connect();
}

export function stopActivityListener(): void {
  stopped = true;
  ws?.close();
  ws = null;
}

function connect(): void {
  if (stopped) return;
  const sock = new WebSocket(nativeWsUrl());
  ws = sock;

  sock.on("open", () => {
    reconnectMs = 1000;
    // Re-assert screen subscriptions: the server replies to each with a fresh
    // full snapshot, so viewers render the correct screen after a reconnect.
    for (const sessionId of screenListeners.keys()) {
      sendToNative({ type: "subscribeScreen", sessionId });
    }
  });

  sock.on("message", (data) => {
    handleMessage(data.toString());
  });

  sock.on("close", () => {
    if (ws === sock) ws = null;
    scheduleReconnect();
  });

  sock.on("error", () => {
    // 'close' fires after 'error'; let scheduleReconnect run there.
    sock.close();
  });
}

function scheduleReconnect(): void {
  if (stopped) return;
  const delay = reconnectMs;
  reconnectMs = Math.min(reconnectMs * 2, MAX_RECONNECT_MS);
  setTimeout(connect, delay);
}

function handleMessage(raw: string): void {
  let msg: Record<string, unknown>;
  try {
    msg = JSON.parse(raw);
  } catch {
    return;
  }
  if (msg.type === "screen") {
    const frame = parseScreenFrame(msg);
    if (frame) emitScreenFrame(frame);
    return;
  }
  if (msg.type !== "activity") return;
  const state = typeof msg.state === "string" ? msg.state : "";
  const sessionId = typeof msg.sessionId === "string" ? msg.sessionId : "";
  if (sessionId && (state === "busy" || state === "idle" || state === "waiting_input")) {
    emitSessionEvent({ sessionId, state, notify: msg.notify === true });
  }
}
