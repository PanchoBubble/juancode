import type { ClientMessage, ServerMessage } from "../protocol.ts";

type Listener = (msg: ServerMessage) => void;

/** A single shared WebSocket to the juancode server, with auto-reconnect. */
class JuancodeSocket {
  private ws: WebSocket | null = null;
  private readonly listeners = new Set<Listener>();
  private readonly queue: string[] = [];
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;

  private url(): string {
    const proto = location.protocol === "https:" ? "wss" : "ws";
    return `${proto}://${location.host}/ws`;
  }

  private connect(): void {
    if (this.ws && (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING))
      return;

    const ws = new WebSocket(this.url());
    this.ws = ws;

    ws.onopen = () => {
      while (this.queue.length) ws.send(this.queue.shift()!);
    };
    ws.onmessage = (ev) => {
      let msg: ServerMessage;
      try {
        msg = JSON.parse(ev.data as string) as ServerMessage;
      } catch {
        return;
      }
      for (const l of this.listeners) l(msg);
    };
    ws.onclose = () => {
      this.ws = null;
      if (!this.reconnectTimer) {
        this.reconnectTimer = setTimeout(() => {
          this.reconnectTimer = null;
          if (this.listeners.size > 0) this.connect();
        }, 1000);
      }
    };
    ws.onerror = () => ws.close();
  }

  send(msg: ClientMessage): void {
    const data = JSON.stringify(msg);
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(data);
    } else {
      this.queue.push(data);
      this.connect();
    }
  }

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    this.connect();
    return () => this.listeners.delete(listener);
  }
}

export const socket = new JuancodeSocket();
