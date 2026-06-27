import type { SessionActivity } from "../protocol.ts";
import { NotifyGate } from "./notifyGate.ts";

/**
 * Alerts for session activity: a sound (distinct ding for "needs input" vs a
 * soft chime for "done") plus an OS notification when the tab is backgrounded.
 * The in-app sidebar icons cover the focused case, so OS notifications only fire
 * when the page is hidden. Everything is gated behind a persisted on/off flag.
 *
 * Sounds are synthesised with the Web Audio API — no asset files, so nothing to
 * bundle or hit CSP over. Browsers won't let an AudioContext make noise until a
 * user gesture, so we unlock it on the first interaction with the page.
 */

const STORAGE_KEY = "juancode-notify";

let enabled = readEnabled();
let audio: AudioContext | null = null;
const stateListeners = new Set<() => void>();
const gate = new NotifyGate();

/** Stable tag for the coalesced "several sessions" summary notification. */
const SUMMARY_TAG = "juancode-activity";

function readEnabled(): boolean {
  try {
    return localStorage.getItem(STORAGE_KEY) !== "off";
  } catch {
    return true;
  }
}

async function ensureAudio(): Promise<void> {
  if (!audio) {
    const Ctor = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!Ctor) return;
    audio = new Ctor();
  }
  if (audio.state === "suspended") {
    try {
      await audio.resume();
    } catch {
      /* still locked — a later gesture will unlock it */
    }
  }
}

/** One short sine blip with a quick attack and exponential decay. */
function tone(at: number, freq: number, dur: number, peak = 0.18): void {
  if (!audio) return;
  const t0 = audio.currentTime + at;
  const osc = audio.createOscillator();
  const gain = audio.createGain();
  osc.type = "sine";
  osc.frequency.value = freq;
  gain.gain.setValueAtTime(0.0001, t0);
  gain.gain.exponentialRampToValueAtTime(peak, t0 + 0.012);
  gain.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
  osc.connect(gain).connect(audio.destination);
  osc.start(t0);
  osc.stop(t0 + dur + 0.02);
}

function playChime(): void {
  void ensureAudio().then(() => tone(0, 660, 0.2));
}

/** A two-tone "ding-dong" — more urgent, for input-required. */
function playDingDong(): void {
  void ensureAudio().then(() => {
    tone(0, 880, 0.16);
    tone(0.17, 660, 0.3);
  });
}

function requestOsPermission(): void {
  if (typeof Notification === "undefined") return;
  if (Notification.permission === "default") void Notification.requestPermission();
}

function osNotify(body: string, tag: string, onAck?: () => void): void {
  if (typeof Notification === "undefined" || Notification.permission !== "granted") return;
  // The in-app sound + sidebar icon already cover a focused tab; only escalate
  // to an OS notification when the user has tabbed away.
  if (!document.hidden) return;
  try {
    // A per-session `tag` with `renotify:false` makes the browser *replace* an
    // existing notification for that session in place (no stacking, no re-alert)
    // rather than piling up a fresh banner each time. `renotify` isn't in the
    // current DOM lib's NotificationOptions type, hence the cast — false is the
    // spec default, so this is belt-and-suspenders on top of the stable tag.
    const opts = { body, tag, renotify: false } as NotificationOptions;
    const n = new Notification("juancode", opts);
    n.onclick = () => {
      window.focus();
      n.close();
      onAck?.();
    };
  } catch {
    /* notification construction can throw on some platforms — ignore */
  }
}

// Unlock audio (and, if enabled, ask for OS permission) on the first gesture.
if (typeof window !== "undefined") {
  const unlock = () => {
    void ensureAudio();
    if (enabled) requestOsPermission();
    window.removeEventListener("pointerdown", unlock);
    window.removeEventListener("keydown", unlock);
  };
  window.addEventListener("pointerdown", unlock);
  window.addEventListener("keydown", unlock);
}

export const notifications = {
  get enabled(): boolean {
    return enabled;
  },

  setEnabled(value: boolean): void {
    enabled = value;
    try {
      localStorage.setItem(STORAGE_KEY, value ? "on" : "off");
    } catch {
      /* private mode / storage disabled — keep the in-memory value */
    }
    if (value) {
      void ensureAudio();
      requestOsPermission();
    }
    for (const l of stateListeners) l();
  },

  /** Subscribe to enabled-state changes (for the toggle UI). */
  subscribe(listener: () => void): () => void {
    stateListeners.add(listener);
    return () => stateListeners.delete(listener);
  },

  /**
   * Fire the alert for a notable activity transition on a session — gated by
   * {@link NotifyGate} so detector flapping / simultaneous turn-ends can't turn
   * into a notification flood.
   */
  fire(state: SessionActivity, title: string, sessionId: string): void {
    if (!enabled) return;
    if (state !== "waiting_input" && state !== "idle") return;

    const action = gate.decide(sessionId, state, Date.now());
    if (action === "drop") return;

    if (action === "coalesce") {
      // A burst across many sessions collapses into one replace-in-place summary
      // (single soft chime) instead of one banner + ding per session.
      playChime();
      osNotify("Multiple sessions need your attention", SUMMARY_TAG);
      return;
    }

    // action === "fire": a single per-session alert, acknowledged on click.
    const ack = () => gate.clear(sessionId);
    if (state === "waiting_input") {
      playDingDong();
      osNotify(`${title} needs your input`, sessionId, ack);
    } else {
      playChime();
      osNotify(`${title} finished`, sessionId, ack);
    }
  },

  /** Forget a session's notification dedup state (e.g. it was closed). */
  clear(sessionId: string): void {
    gate.clear(sessionId);
  },
};
