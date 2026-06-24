import type { SessionActivity } from "../protocol.ts";

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

function osNotify(body: string, tag: string): void {
  if (typeof Notification === "undefined" || Notification.permission !== "granted") return;
  // The in-app sound + sidebar icon already cover a focused tab; only escalate
  // to an OS notification when the user has tabbed away.
  if (!document.hidden) return;
  try {
    const n = new Notification("juancode", { body, tag });
    n.onclick = () => {
      window.focus();
      n.close();
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

  /** Fire the alert for a notable activity transition on a session. */
  fire(state: SessionActivity, title: string, sessionId: string): void {
    if (!enabled) return;
    if (state === "waiting_input") {
      playDingDong();
      osNotify(`${title} needs your input`, sessionId);
    } else if (state === "idle") {
      playChime();
      osNotify(`${title} finished`, sessionId);
    }
  },
};
