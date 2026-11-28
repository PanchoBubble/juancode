// Push-to-phone over public ntfy.sh (juancode-3aq8.7). Event-driven off the same
// activity stream as everything else: nothing polls. A session that goes
// waiting_input pushes a generic message when the Mac is away (screen locked or
// display asleep, reported by the app) or the session was started/typed into from
// the phone (reported by the app's relay). The bell toggle mutes per session.
// shortcut: away/driven live in memory, so a sidecar restart forgets them until
// the app reports again; persist them if that ever bites.
import { randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { SessionActivityEvent } from "./native-events.ts";

export const phoneAlertsPath = () => join(homedir(), ".juancode", "phone-alerts.json");

type Send = (topic: string, sessionId: string) => Promise<void>;

/** Generic text on purpose: ntfy.sh is public, so no session title or output goes out. */
const ntfy: Send = async (topic, sessionId) => {
  await fetch(`https://ntfy.sh/${topic}`, {
    method: "POST",
    headers: { Title: "juancode", Click: `juancode://session/${sessionId}` },
    body: "A session needs your input",
    signal: AbortSignal.timeout(10_000),
  });
};

export class PhoneAlerts {
  readonly topic: string;
  private muted: Set<string>;
  private driven = new Set<string>();
  private lastState = new Map<string, SessionActivityEvent["state"]>();
  private away = false;

  constructor(
    private path = phoneAlertsPath(),
    private send: Send = ntfy,
  ) {
    let stored: { topic?: string; muted?: string[] } = {};
    try {
      stored = JSON.parse(readFileSync(path, "utf8"));
    } catch {
      // first run: mint below
    }
    this.topic = stored.topic || `juancode-${randomBytes(16).toString("hex")}`;
    this.muted = new Set(stored.muted ?? []);
    if (!stored.topic) this.save();
  }

  private save(): void {
    mkdirSync(dirname(this.path), { recursive: true });
    writeFileSync(this.path, JSON.stringify({ topic: this.topic, muted: [...this.muted] }), {
      mode: 0o600,
    });
  }

  setAway(away: boolean): void {
    this.away = away;
  }
  markDriven(sessionId: string): void {
    this.driven.add(sessionId);
  }
  setEnabled(sessionId: string, enabled: boolean): void {
    if (enabled === !this.muted.has(sessionId)) return;
    if (enabled) this.muted.delete(sessionId);
    else this.muted.add(sessionId);
    this.save();
  }
  state() {
    return { topic: this.topic, muted: [...this.muted], away: this.away };
  }

  onEvent(ev: SessionActivityEvent): void {
    const entered = this.lastState.get(ev.sessionId) !== "waiting_input";
    this.lastState.set(ev.sessionId, ev.state);
    if (ev.state !== "waiting_input" || !ev.notify || !entered) return;
    // The phone tags the sessions it creates with a "phone-" dispatchId.
    const phoneMade = ev.dispatchId?.startsWith("phone-") === true;
    if (this.muted.has(ev.sessionId) || !(this.away || phoneMade || this.driven.has(ev.sessionId)))
      return;
    void this.send(this.topic, ev.sessionId).catch((e) =>
      console.warn("phone alert failed:", e instanceof Error ? e.message : e),
    );
  }
}
