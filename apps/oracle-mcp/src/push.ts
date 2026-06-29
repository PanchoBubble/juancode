// Web Push subsystem for the Oracle sidecar (juancode-mov). Owns the VAPID
// keypair, sending notifications to all stored subscriptions, and the WebSocket
// client that watches the live native backend for notify-worthy events.
//
// The native Hummingbird server (127.0.0.1:4280, ws path /ws) broadcasts
// `activity` for every session automatically on connect (no subscribe needed —
// see WebSocketConnection.start()), and `trackNotification` only after the client
// sends `subscribeTrackedPrs`. We mirror that: connect, send subscribeTrackedPrs,
// and push on activity{notify:true} / trackNotification.

import webpush from "web-push";
import { WebSocket } from "ws";
import {
  addSubscription,
  loadOrCreateVapidKeys,
  loadSubscriptions,
  removeSubscription,
  type StoredPushSubscription,
} from "./push-store.ts";
import {
  fetchPresence,
  presenceWindowMs,
  suppressForPresence,
  type PresenceFetcher,
} from "./presence.ts";

// VAPID requires a contact (mailto: or https: URL) so push services can reach
// the sender. Override with VAPID_SUBJECT; the fallback is a neutral placeholder.
const VAPID_SUBJECT = process.env.VAPID_SUBJECT?.trim() || "mailto:admin@example.com";

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

/** Resolve a session's human title from the native REST list so notifications can
 *  name it. The `activity` broadcast carries no title; the REST list does. Fetched
 *  fresh each time (notifications are infrequent and titles change as work
 *  progresses) with a short timeout; returns null on any miss/error so callers fall
 *  back to the id. */
async function resolveSessionTitle(sessionId: string): Promise<string | null> {
  if (!sessionId) return null;
  try {
    const res = await fetch(`${nativeHttpBase()}/api/sessions`, {
      signal: AbortSignal.timeout(2000),
    });
    if (!res.ok) return null;
    const data = (await res.json()) as unknown;
    const list = Array.isArray(data)
      ? data
      : ((data as { sessions?: unknown[] })?.sessions ?? []);
    const match = (list as Array<Record<string, unknown>>).find(
      (s) => s && typeof s.id === "string" && s.id === sessionId,
    );
    return match && typeof match.title === "string" && match.title.trim() ? match.title : null;
  } catch {
    return null;
  }
}

let publicKey = "";

/** Initialize VAPID: load-or-generate the keypair, persist it, and configure
 *  web-push. Logs the public key so it can be inspected on first run. Returns the
 *  public key (also served from /api/push/vapid). */
export async function initPush(): Promise<string> {
  const keys = await loadOrCreateVapidKeys(() => webpush.generateVAPIDKeys());
  webpush.setVapidDetails(VAPID_SUBJECT, keys.publicKey, keys.privateKey);
  publicKey = keys.publicKey;
  console.log(`oracle-mcp web-push VAPID public key: ${keys.publicKey}`);
  return keys.publicKey;
}

export function vapidPublicKey(): string {
  return publicKey;
}

export interface PushPayload {
  title: string;
  body: string;
  url?: string;
  tag?: string;
}

/**
 * Presence gate (juancode-2zp): suppress pushes while the user is at the desk so
 * the phone stays quiet — the desktop already shows its own notification. Reads the
 * native server's `/presence` and suppresses when the desktop is active within the
 * configured window (`JUANCODE_PRESENCE_WINDOW_MS`, default 60s). Fails open: if
 * presence is unreachable/errors/times out we still send (better a redundant phone
 * push than a silently dropped one). `fetcher` is injectable for tests.
 */
async function shouldSuppressPush(fetcher: PresenceFetcher = fetchPresence): Promise<boolean> {
  const presence = await fetcher();
  const suppress = suppressForPresence(presence, presenceWindowMs());
  if (presence === null) {
    console.debug("oracle-mcp presence unreachable — sending push (fail-open)");
  } else if (suppress) {
    console.debug("oracle-mcp desktop active — suppressing push");
  }
  return suppress;
}

/** Send one payload to every stored subscription, pruning any that report the
 *  endpoint is gone (HTTP 404/410). */
export async function sendPushToAll(payload: PushPayload): Promise<void> {
  if (await shouldSuppressPush()) return;
  const subs = await loadSubscriptions();
  if (subs.length === 0) return;
  const body = JSON.stringify(payload);
  await Promise.all(subs.map((s) => sendOne(s, body)));
}

async function sendOne(sub: StoredPushSubscription, body: string): Promise<void> {
  try {
    await webpush.sendNotification(sub, body);
  } catch (e) {
    const status = (e as { statusCode?: number }).statusCode;
    if (status === 404 || status === 410) {
      await removeSubscription(sub.endpoint).catch(() => {});
    } else {
      console.warn(`oracle-mcp push send failed (${status ?? "?"}):`, (e as Error).message);
    }
  }
}

// Re-export the store mutations the HTTP endpoints need, so index.ts has a single
// push import surface.
export { addSubscription, removeSubscription };

// ── WS client: native backend → push ─────────────────────────────────────────

let ws: WebSocket | null = null;
let reconnectMs = 1000;
const MAX_RECONNECT_MS = 30_000;
let stopped = false;

/** Open (and keep open, with backoff) a client WS to the native server and push
 *  on notify-worthy broadcasts. Safe to call once at startup. */
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
  const url = nativeWsUrl();
  const sock = new WebSocket(url);
  ws = sock;

  sock.on("open", () => {
    reconnectMs = 1000;
    // activity broadcasts start automatically; trackNotification needs this.
    sock.send(JSON.stringify({ type: "subscribeTrackedPrs" }));
  });

  sock.on("message", (data) => {
    void handleMessage(data.toString());
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

// Notification copy names the session: the `activity` broadcast carries no title,
// so we resolve it from the native REST session list (resolveSessionTitle), falling
// back to a short id slice when unavailable.
async function handleMessage(raw: string): Promise<void> {
  let msg: Record<string, unknown>;
  try {
    msg = JSON.parse(raw);
  } catch {
    return;
  }
  const type = msg.type;

  if (type === "activity" && msg.notify === true) {
    const state = typeof msg.state === "string" ? msg.state : "";
    const sessionId = typeof msg.sessionId === "string" ? msg.sessionId : "";
    const body =
      state === "waiting_input"
        ? "needs your input"
        : state === "idle"
          ? "finished"
          : "updated";
    const title =
      (await resolveSessionTitle(sessionId)) ||
      ("Session " + (sessionId ? sessionId.slice(0, 8) : ""));
    await sendPushToAll({
      title,
      // Deep-link the console straight to this session's reply box.
      url: sessionId ? `/?session=${encodeURIComponent(sessionId)}` : "/",
      body,
      tag: sessionId ? `session-${sessionId}` : "session",
    });
    return;
  }

  if (type === "trackNotification") {
    const notification = (msg.notification ?? {}) as Record<string, unknown>;
    const message =
      typeof notification.message === "string" ? notification.message : "PR needs a decision";
    const prNumber = typeof msg.prNumber === "number" ? msg.prNumber : undefined;
    await sendPushToAll({
      title: prNumber ? `PR #${prNumber}` : "Tracked PR",
      body: message,
      url: "/",
      tag: typeof msg.trackedId === "string" ? `pr-${msg.trackedId}` : "pr",
    });
  }
}

// ── Static assets: service worker, manifest, icons ───────────────────────────

/** Service worker: handles push → showNotification and notificationclick → focus
 *  an open client or open the console. Served at /sw.js with Service-Worker-
 *  Allowed: / so it can control the whole origin. */
export const serviceWorkerJs = /* js */ `
self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) { data = {}; }
  const title = data.title || "Oracle";
  const options = {
    body: data.body || "",
    data: { url: data.url || "/" },
    tag: data.tag,
    icon: "/icon-192.png",
    badge: "/icon-192.png",
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || "/";
  event.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then((wins) => {
      for (const w of wins) {
        if ("focus" in w) {
          // Deep-link (?session=…): steer the open window to it, then focus.
          if (url !== "/" && "navigate" in w) {
            return w.navigate(url).then((c) => (c || w).focus()).catch(() => w.focus());
          }
          return w.focus();
        }
      }
      if (clients.openWindow) return clients.openWindow(url);
    }),
  );
});
`;

export const webManifest = {
  name: "Oracle",
  short_name: "Oracle",
  start_url: "/",
  display: "standalone",
  theme_color: "#0b0d12",
  background_color: "#0b0d12",
  icons: [
    { src: "/icon-192.png", sizes: "192x192", type: "image/png", purpose: "any maskable" },
    { src: "/icon-512.png", sizes: "512x512", type: "image/png", purpose: "any maskable" },
  ],
};

/** A tiny solid-color PNG (the app's --bg navy), generated in-code so we don't
 *  ship a binary asset. Same single pixel for both /icon-192 and /icon-512 — the
 *  browser scales it; juancode-6f0 owns a real icon. */
export function iconPng(): Buffer {
  // 1x1 PNG, RGBA #0b0d12. Hand-built so there's no image dependency.
  return buildSolidPng(0x0b, 0x0d, 0x12);
}

function buildSolidPng(r: number, g: number, b: number): Buffer {
  // Minimal 1x1 8-bit RGB PNG.
  const crcTable = (() => {
    const t: number[] = [];
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      t[n] = c >>> 0;
    }
    return t;
  })();
  const crc32 = (buf: Buffer): number => {
    let c = 0xffffffff;
    for (let i = 0; i < buf.length; i++) c = crcTable[(c ^ buf[i]!)! & 0xff]! ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };
  const chunk = (type: string, data: Buffer): Buffer => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length, 0);
    const typeBuf = Buffer.from(type, "ascii");
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
    return Buffer.concat([len, typeBuf, data, crc]);
  };

  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(1, 0); // width
  ihdr.writeUInt32BE(1, 4); // height
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // color type: truecolor RGB
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;

  // raw scanline: filter byte 0 + RGB
  const raw = Buffer.from([0, r, g, b]);
  // zlib stored block (no compression): 0x78 0x01 header, then deflate stored.
  const zlibHeader = Buffer.from([0x78, 0x01]);
  const blockHeader = Buffer.from([0x01]); // final stored block
  const lenLE = Buffer.alloc(4);
  lenLE.writeUInt16LE(raw.length, 0);
  lenLE.writeUInt16LE(~raw.length & 0xffff, 2);
  const adler = (() => {
    let a = 1;
    let bb = 0;
    for (let i = 0; i < raw.length; i++) {
      a = (a + raw[i]!) % 65521;
      bb = (bb + a) % 65521;
    }
    const out = Buffer.alloc(4);
    out.writeUInt32BE((bb << 16) | a, 0);
    return out;
  })();
  const idatData = Buffer.concat([zlibHeader, blockHeader, lenLE, raw, adler]);

  return Buffer.concat([
    sig,
    chunk("IHDR", ihdr),
    chunk("IDAT", idatData),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}
