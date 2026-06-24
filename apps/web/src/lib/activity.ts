import { useSyncExternalStore } from "react";
import { socket } from "./socket.ts";
import { notifications } from "./notifications.ts";
import type { ServerMessage, SessionActivity, SessionMeta } from "../protocol.ts";

/**
 * A tiny store of per-session live activity, fed by the server's `activity`
 * broadcasts (one shared socket subscription). Both the sidebar (per-session
 * icons) and the open session view read from it, and notable transitions drive
 * the notification sound / OS alert. Session titles are mirrored in so the alert
 * text can name the session.
 */

type ActivityMap = Record<string, SessionActivity>;

let map: ActivityMap = {};
const titles = new Map<string, string>();
const listeners = new Set<() => void>();
let started = false;

function start(): void {
  if (started) return;
  started = true;
  socket.subscribe((msg: ServerMessage) => {
    if (msg.type !== "activity") return;
    if (map[msg.sessionId] !== msg.state) {
      map = { ...map, [msg.sessionId]: msg.state };
      for (const l of listeners) l();
    }
    if (msg.notify) {
      notifications.fire(msg.state, titles.get(msg.sessionId) ?? "Session", msg.sessionId);
    }
  });
}

/** Keep titles fresh so notifications can name the session (called from the sidebar). */
export function registerSessionTitles(metas: SessionMeta[]): void {
  for (const m of metas) titles.set(m.id, m.title);
}

function subscribe(cb: () => void): () => void {
  start();
  listeners.add(cb);
  return () => listeners.delete(cb);
}

/** Live activity for one session (undefined until the first broadcast). */
export function useActivity(id: string): SessionActivity | undefined {
  return useSyncExternalStore(subscribe, () => map[id]);
}

/** The whole activity map (for rendering many sessions at once). */
export function useActivityMap(): ActivityMap {
  return useSyncExternalStore(subscribe, () => map);
}
