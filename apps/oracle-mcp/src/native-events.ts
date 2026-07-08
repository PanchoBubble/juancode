// Native-backend session-event listener for the Oracle sidecar. Owns the single
// long-lived WebSocket client to the native app's embedded server and re-emits
// every `activity` broadcast to in-process subscribers (the Telegram bridge).
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
  if (msg.type !== "activity") return;
  const state = typeof msg.state === "string" ? msg.state : "";
  const sessionId = typeof msg.sessionId === "string" ? msg.sessionId : "";
  if (sessionId && (state === "busy" || state === "idle" || state === "waiting_input")) {
    emitSessionEvent({ sessionId, state, notify: msg.notify === true });
  }
}
