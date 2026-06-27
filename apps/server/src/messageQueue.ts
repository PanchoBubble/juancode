import { messageQueueDb } from "./db.ts";
import type { QueuedMessage } from "./protocol.ts";

type QueueListener = (items: QueuedMessage[]) => void;

/**
 * The per-session outbound message queue, backed by sqlite ({@link messageQueueDb})
 * with an in-memory fan-out so every watcher (WS connection) and the delivering
 * {@link Session} see the same ordered list. Mutations persist first, then notify
 * — so the queue survives a reconnect / restart and a session reactivation, and
 * is flushed exactly once server-side regardless of how many tabs are open.
 */
class MessageQueueStore {
  private readonly listeners = new Map<string, Set<QueueListener>>();

  /** A session's pending messages, in delivery order. */
  list(sessionId: string): QueuedMessage[] {
    return messageQueueDb.list(sessionId);
  }

  /** The next message to deliver, or null when the queue is empty. */
  peek(sessionId: string): QueuedMessage | null {
    return messageQueueDb.first(sessionId);
  }

  /** Append a message and notify watchers; returns the stored item. */
  add(sessionId: string, text: string): QueuedMessage {
    const item = messageQueueDb.add(sessionId, text);
    this.emit(sessionId);
    return item;
  }

  /** Remove one message (cancel or post-delivery) and notify; true if it existed. */
  remove(sessionId: string, id: string): boolean {
    const removed = messageQueueDb.remove(sessionId, id);
    if (removed) this.emit(sessionId);
    return removed;
  }

  /** Watch a session's queue; the listener is *not* called immediately. */
  onChange(sessionId: string, listener: QueueListener): () => void {
    let set = this.listeners.get(sessionId);
    if (!set) {
      set = new Set();
      this.listeners.set(sessionId, set);
    }
    set.add(listener);
    return () => {
      const s = this.listeners.get(sessionId);
      if (!s) return;
      s.delete(listener);
      if (s.size === 0) this.listeners.delete(sessionId);
    };
  }

  private emit(sessionId: string): void {
    const set = this.listeners.get(sessionId);
    if (!set || set.size === 0) return;
    const items = this.list(sessionId);
    for (const l of set) l(items);
  }
}

export const messageQueue = new MessageQueueStore();
