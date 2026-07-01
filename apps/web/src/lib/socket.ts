import type { ClientMessage, ServerMessage } from "../protocol.ts";
import { getToken, promptForToken } from "./auth.ts";
import { InputAckBuffer } from "./inputAckBuffer.ts";
import { ResizeAckTracker } from "./resizeAckTracker.ts";

type Listener = (msg: ServerMessage) => void;
type InFlightListener = (count: number) => void;

/**
 * Connection state for the shared socket.
 * - `online`     — the socket is open and messages flow.
 * - `connecting` — a connect/reconnect attempt is in flight or scheduled.
 * - `offline`    — idle (no listeners) or the browser reports no network.
 *
 * The UI treats anything other than `online` (while sessions are mounted) as a
 * transient "reconnecting" state rather than a hard error.
 */
export type ConnectionState = "online" | "connecting" | "offline";

type StatusListener = (state: ConnectionState) => void;

// Reconnect backoff: start gentle, grow exponentially, cap so a long outage
// still retries roughly every few seconds rather than backing off forever.
const BACKOFF_BASE_MS = 500;
const BACKOFF_MAX_MS = 10_000;

/** A single shared WebSocket to the juancode server, with auto-reconnect. */
class JuancodeSocket {
  private ws: WebSocket | null = null;
  private readonly listeners = new Set<Listener>();
  private readonly statusListeners = new Set<StatusListener>();
  private readonly inFlightListeners = new Set<InFlightListener>();
  private readonly queue: string[] = [];
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;

  // Sent-but-unacked `input` messages, so a mid-write connection drop no longer
  // silently loses keystrokes (juancode-1u3). Resent on reconnect; cleared per
  // matching `inputAck`.
  private readonly inputBuffer = new InputAckBuffer();
  // Whether the server advertised the `inputAck` capability. `null` until the
  // `serverInfo` handshake arrives (the first frame on connect); we buffer
  // optimistically until then. A server that doesn't ack makes tracking useless
  // (acks would never clear the buffer), so we stop buffering once we know.
  private ackSupported: boolean | null = null;

  // Latest desired terminal grid per session, so a dropped `resize` can't strand
  // the CLI at the wrong size (juancode-uz6). Re-asserted on reconnect; retried
  // when the server acks that the grid didn't reach a live pty.
  private readonly resizeTracker = new ResizeAckTracker();
  // Whether the server advertised the `resizeAck` capability. `null` until the
  // `serverInfo` handshake; we track optimistically until then. A server that
  // doesn't ack (an older embedded native server) makes tracking useless.
  private resizeAckSupported: boolean | null = null;

  private state: ConnectionState = "offline";
  // Consecutive failed reconnect attempts; drives the backoff delay.
  private attempts = 0;

  // Tracks connections that never opened, to distinguish an auth rejection
  // (immediate close before open) from an ordinary dropped connection.
  private opened = false;
  // Once a connection has ever succeeded we never treat a later drop as an auth
  // failure — it's just the network (phone locked, tab backgrounded, wifi
  // blip), so we reconnect silently instead of prompting for a token.
  private everOpened = false;
  private failedCloses = 0;

  constructor() {
    if (typeof window !== "undefined") this.installLifecycleHandlers();
  }

  /**
   * Reconnect promptly when the environment suggests the link is back: the tab
   * becomes visible again, the browser fires `online`, or the page is restored
   * from the bfcache (`pageshow`). Mobile Safari/Chrome suspend timers and tear
   * down sockets while backgrounded, so the scheduled backoff timer alone is not
   * enough — these events are what actually fire on resume.
   */
  private installLifecycleHandlers(): void {
    const kick = () => {
      if (this.listeners.size === 0) return;
      if (this.ws?.readyState === WebSocket.OPEN) return;
      // A fresh user-visible resume: drop any pending backoff and retry now.
      this.attempts = 0;
      if (this.reconnectTimer) {
        clearTimeout(this.reconnectTimer);
        this.reconnectTimer = null;
      }
      this.connect();
    };
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible") kick();
    });
    window.addEventListener("online", kick);
    window.addEventListener("offline", () => {
      // No point hammering connect while the OS says we're offline; reflect it
      // in the UI and let the `online` event resume us.
      if (this.listeners.size > 0) this.setState("offline");
    });
    window.addEventListener("pageshow", kick);
  }

  private setState(state: ConnectionState): void {
    if (this.state === state) return;
    this.state = state;
    for (const l of this.statusListeners) l(state);
  }

  get connectionState(): ConnectionState {
    return this.state;
  }

  /** Subscribe to connection-state changes; fires immediately with the current state. */
  subscribeStatus(listener: StatusListener): () => void {
    this.statusListeners.add(listener);
    listener(this.state);
    return () => this.statusListeners.delete(listener);
  }

  private url(): string {
    const proto = location.protocol === "https:" ? "wss" : "ws";
    // Browsers can't set headers on a WebSocket, so the token rides as a query
    // param. The cookie also carries it once set; either suffices server-side.
    // When auth is disabled there is no token and the URL is unchanged.
    const token = getToken();
    const q = token ? `?token=${encodeURIComponent(token)}` : "";
    return `${proto}://${location.host}/ws${q}`;
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer) return;
    if (this.listeners.size === 0) {
      this.setState("offline");
      return;
    }
    const delay = Math.min(BACKOFF_BASE_MS * 2 ** this.attempts, BACKOFF_MAX_MS);
    this.attempts += 1;
    this.setState("connecting");
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      if (this.listeners.size > 0) this.connect();
    }, delay);
  }

  private connect(): void {
    if (
      this.ws &&
      (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING)
    )
      return;

    this.setState("connecting");
    const ws = new WebSocket(this.url());
    this.ws = ws;
    this.opened = false;

    ws.onopen = () => {
      this.opened = true;
      this.everOpened = true;
      this.failedCloses = 0;
      this.attempts = 0;
      this.setState("online");
      // Drain messages queued while offline (attach/resize/etc.) first, then
      // replay any still-unacked keystrokes (juancode-1u3) — these were already
      // handed to a now-dead socket, so the offline queue never held them.
      while (this.queue.length) ws.send(this.queue.shift()!);
      for (const data of this.inputBuffer.pending()) ws.send(data);
      // Re-assert the latest desired grid for every session: a reattached or
      // respawned pty may have booted at a default size, and any resize in flight
      // when the old socket dropped never reached it (juancode-uz6).
      for (const data of this.resizeTracker.pending()) ws.send(data);
    };
    ws.onmessage = (ev) => {
      let msg: ServerMessage;
      try {
        msg = JSON.parse(ev.data as string) as ServerMessage;
      } catch {
        return;
      }
      if (msg.type === "serverInfo") {
        // Feature-detect input acknowledgement. If the peer doesn't ack, the
        // buffer would never drain, so drop it and fall back to best-effort.
        this.ackSupported = msg.capabilities.includes("inputAck");
        if (!this.ackSupported && this.inputBuffer.size > 0) {
          this.inputBuffer.clear();
          this.notifyInFlight();
        }
        // Same feature-detect for resize acking; without it, tracking is useless
        // (acks would never arrive to confirm/retry), so stop tracking.
        this.resizeAckSupported = msg.capabilities.includes("resizeAck");
        if (!this.resizeAckSupported) this.resizeTracker.clear();
      } else if (msg.type === "inputAck") {
        // Clear the acknowledged keystroke; not forwarded to UI listeners.
        if (this.inputBuffer.ack(msg.seq)) this.notifyInFlight();
        return;
      } else if (msg.type === "resizeAck") {
        // Re-assert the grid if it didn't reach a live pty; not forwarded to UI.
        const resend = this.resizeTracker.ack(msg);
        if (resend) setTimeout(() => this.rawSend(resend.data), resend.delayMs);
        return;
      } else if (msg.type === "exit") {
        this.resizeTracker.forget(msg.sessionId);
      }
      for (const l of this.listeners) l(msg);
    };
    ws.onclose = () => {
      this.ws = null;
      // A close before the socket ever opened — and before any connection has
      // ever succeeded this session — most likely means the upgrade was rejected
      // (401 — wrong/missing token). After a couple of such failures, prompt for
      // a token. We only do this for a never-opened socket while the browser
      // reports it's online, so a backgrounded phone or a wifi blip on an
      // already-working session never trips the token prompt.
      if (!this.opened && !this.everOpened && navigator.onLine) {
        this.failedCloses += 1;
        if (this.failedCloses >= 2) {
          this.setState("offline");
          promptForToken();
          return;
        }
      }
      this.scheduleReconnect();
    };
    ws.onerror = () => ws.close();
  }

  send(msg: ClientMessage): void {
    // Track keystrokes/pastes so a mid-write drop can't silently lose them: tag
    // each with a monotonic `seq`, buffer it until the server acks, and rely on
    // `onopen` to resend the buffer on reconnect (juancode-1u3). Skipped when we
    // know the server can't ack — then it's a plain best-effort send.
    if (msg.type === "input" && this.ackSupported !== false) {
      const { data } = this.inputBuffer.track(msg);
      this.notifyInFlight();
      // Don't also push to the offline queue: the input buffer's own replay on
      // `onopen` covers the offline case, so queueing here would double-send.
      if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(data);
      else this.connect();
      return;
    }
    // Track the latest desired grid so a dropped `resize` can't strand the CLI at
    // the wrong size (juancode-uz6). Like input, don't also queue: `onopen`
    // re-asserts every tracked grid, so queueing would double-send.
    if (msg.type === "resize" && this.resizeAckSupported !== false) {
      const { data } = this.resizeTracker.track(msg);
      if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(data);
      else this.connect();
      return;
    }
    const data = JSON.stringify(msg);
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(data);
    } else {
      this.queue.push(data);
      this.connect();
    }
  }

  /** Send a pre-serialized frame if the socket is open, else drop it. Used for a
   * delayed resize retry: if the socket closed in the meantime, `onopen`'s
   * `pending()` replay re-asserts the latest grid, so dropping here is safe. */
  private rawSend(data: string): void {
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(data);
  }

  /** Count of sent-but-unacknowledged keystrokes (for a subtle "unsent" hint). */
  get inFlightInputCount(): number {
    return this.inputBuffer.size;
  }

  /** Subscribe to in-flight input count changes; fires immediately with the current count. */
  subscribeInFlight(listener: InFlightListener): () => void {
    this.inFlightListeners.add(listener);
    listener(this.inputBuffer.size);
    return () => this.inFlightListeners.delete(listener);
  }

  private notifyInFlight(): void {
    const n = this.inputBuffer.size;
    for (const l of this.inFlightListeners) l(n);
  }

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    this.connect();
    return () => this.listeners.delete(listener);
  }
}

export const socket = new JuancodeSocket();
