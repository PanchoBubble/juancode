// Web Push subscription + VAPID-key persistence for the Oracle sidecar
// (juancode-mov). Subscriptions and the VAPID keypair live as JSON files under
// `JUANCODE_ORACLE_DIR` (same control dir as the dispatch/ask mailboxes), so they
// survive sidecar restarts without a database. The store is deliberately tiny —
// add/dedupe-by-endpoint/remove over a flat JSON array — and is unit-tested in
// push-store.test.ts.

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { oracleDir } from "./oracle.ts";

/** A W3C PushSubscription serialized to JSON (what `subscription.toJSON()` yields
 *  in the browser). We keep the full object so `web-push` can send to it. */
export interface StoredPushSubscription {
  endpoint: string;
  expirationTime?: number | null;
  keys: { p256dh: string; auth: string };
}

export interface VapidKeys {
  publicKey: string;
  privateKey: string;
}

const subsFile = () => join(oracleDir(), "push-subscriptions.json");
const vapidFile = () => join(oracleDir(), "vapid.json");

async function ensureDir(): Promise<void> {
  await mkdir(oracleDir(), { recursive: true });
}

/** Read the persisted subscriptions, tolerating a missing/corrupt file (→ []). */
export async function loadSubscriptions(): Promise<StoredPushSubscription[]> {
  const raw = await readFile(subsFile(), "utf8").catch(() => "");
  if (!raw.trim()) return [];
  try {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(isSubscription);
  } catch {
    return [];
  }
}

function isSubscription(v: unknown): v is StoredPushSubscription {
  if (!v || typeof v !== "object") return false;
  const r = v as Record<string, unknown>;
  const keys = r.keys as Record<string, unknown> | undefined;
  return (
    typeof r.endpoint === "string" &&
    r.endpoint.length > 0 &&
    !!keys &&
    typeof keys.p256dh === "string" &&
    typeof keys.auth === "string"
  );
}

async function saveSubscriptions(subs: StoredPushSubscription[]): Promise<void> {
  await ensureDir();
  await writeFile(subsFile(), JSON.stringify(subs, null, 2), "utf8");
}

/** Add a subscription, deduping by `endpoint` (a re-subscribe replaces the old
 *  keys). Returns the full list after the change. */
export async function addSubscription(
  sub: StoredPushSubscription,
): Promise<StoredPushSubscription[]> {
  if (!isSubscription(sub)) throw new Error("invalid push subscription");
  const subs = await loadSubscriptions();
  const next = subs.filter((s) => s.endpoint !== sub.endpoint);
  next.push(sub);
  await saveSubscriptions(next);
  return next;
}

/** Remove a subscription by `endpoint`. Returns the full list after the change. */
export async function removeSubscription(endpoint: string): Promise<StoredPushSubscription[]> {
  const subs = await loadSubscriptions();
  const next = subs.filter((s) => s.endpoint !== endpoint);
  if (next.length !== subs.length) await saveSubscriptions(next);
  return next;
}

/** Load the persisted VAPID keypair, or generate + persist one on first run.
 *  `generate` is injected so this stays unit-testable without `web-push`. */
export async function loadOrCreateVapidKeys(
  generate: () => VapidKeys,
): Promise<VapidKeys> {
  const raw = await readFile(vapidFile(), "utf8").catch(() => "");
  if (raw.trim()) {
    try {
      const parsed = JSON.parse(raw) as Record<string, unknown>;
      if (typeof parsed.publicKey === "string" && typeof parsed.privateKey === "string") {
        return { publicKey: parsed.publicKey, privateKey: parsed.privateKey };
      }
    } catch {
      // fall through and regenerate
    }
  }
  const keys = generate();
  await ensureDir();
  await writeFile(vapidFile(), JSON.stringify(keys, null, 2), "utf8");
  return keys;
}
